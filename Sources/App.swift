import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin
import WebKit

final class Model: ObservableObject {
    static weak var active: Model?
    static let shared = Model()   // 关窗口不退出：重开窗口沿用同一份状态和进行中的传输
    @Published var entries: [RemoteEntry] = []
    @Published var path = "/文件中转站"
    @Published var account = "未登录"
    @Published var busy = false
    @Published var status = "登录后，把文件拖到这里上传"
    @Published var log = ""
    @Published var showLogin = false
    @Published var loginText = ""
    @Published var loginRunning = false
    @Published var loginMode = 0
    @Published var loginStage = ""
    var pendingUser = ""
    var pendingPassword = ""
    var webLogin = false
    var loginOutput = ""
    var loginDirectory: URL?
    @Published var selection: [RemoteEntry] = []
    @Published var progress: Double? = nil
    @Published var progressText = ""
    let station = "/文件中转站"
    var process: Process?
    var openMain: (() -> Void)?
    var loginProcess: Process?
    var master: FileHandle?
    var secrets: [String] = []
    var cancelled = false
    var promises = 0   // Finder 一次拖出多项时，排队中的文件承诺数
    let queue = DispatchQueue(label: "transfer.serial")
    let config: URL
    var executable: URL { Bundle.main.url(forResource: "BaiduPCS-Go", withExtension: nil)! }

    init(config: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/BaiduPCS-Go")) {
        self.config = config
        Self.active = self
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
    }
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["BAIDUPCS_GO_CONFIG_DIR"] = config.path
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        return env
    }
    func safe(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\x1b\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "••••") }
        return result
    }
    func protectConfig() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil) else { return }
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
    func run(_ args: [String], live: Bool = false) throws -> (String, Int32) {
        let p = Process(), output = Pipe(), input = Pipe()
        p.executableURL = executable; p.arguments = args; p.environment = environment()
        p.standardOutput = output; p.standardError = output; p.standardInput = input
        try p.run(); input.fileHandleForWriting.closeFile()
        DispatchQueue.main.sync { self.process = p }
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if live {
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    self.log = String(self.safe(text).suffix(14000))
                    if let p = transferProgress(text) { self.progress = p.fraction; self.progressText = p.detail }
                }
            }
        }
        p.waitUntilExit()
        DispatchQueue.main.sync { self.process = nil }
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
    func start(_ title: String, work: @escaping () throws -> Void) {
        guard !busy, !loginRunning else { return }
        busy = true; cancelled = false; status = title; log = ""; progress = nil; progressText = ""
        queue.async {
            do {
                try work()
                DispatchQueue.main.async { self.busy = false; self.protectConfig() }
            } catch {
                DispatchQueue.main.async { self.status = "未完成：" + self.safe(error.localizedDescription); self.busy = false; self.progress = nil }
            }
        }
    }
    func failure(_ message: String) -> NSError { NSError(domain: "中转站", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func list(_ remote: String) throws -> [RemoteEntry] {
        let (text, code) = try run(["ls", literalRemotePath(remote)])
        guard code == 0 else { throw failure(text) }
        return try parseListing(text, path: remote)
    }
    func refresh(_ remote: String? = nil) {
        // Only the station and its subfolders are browsable.
        let requested = remote ?? path
        let target = requested == station || requested.hasPrefix(station + "/") ? requested : station
        start("正在读取文件夹…") {
            let (who, _) = try self.run(["who"])
            guard let name = loggedInAccount(who) else {
                DispatchQueue.main.async { self.account = "未登录"; self.entries = [] }
                throw self.failure("请先登录百度网盘")
            }
            // Show the account even if the folder listing below fails.
            DispatchQueue.main.async { self.account = name }
            if target == self.station { try self.ensureStation() }
            let items = try self.list(target)
            DispatchQueue.main.async { self.entries = items; self.path = target; self.status = "已列出 \(items.count) 项 · 可下载" }
        }
    }
    func ensureStation() throws {
        if try list("/").contains(where: { $0.path == station && $0.isDirectory }) { return }
        let (text, code) = try run(["mkdir", station])
        guard code == 0, text.contains("创建目录成功") else { throw failure("无法创建文件中转站：" + text) }
    }
    func enterStation() {
        start("正在打开中转站…") {
            try self.ensureStation()
            let items = try self.list(self.station)
            DispatchQueue.main.async { self.path = self.station; self.entries = items; self.status = "文件中转站 · \(items.count) 项" }
        }
    }
    func chooseUpload() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择要上传到文件中转站的文件或文件夹"
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        start("正在上传到文件中转站…") {
            try self.ensureStation()
            let names = urls.map(\.lastPathComponent)
            guard Set(names).count == names.count else { throw self.failure("所选内容中有同名项目，请先改名后上传。") }
            let existing = try self.list(self.station)
            // Avoid ambiguous replacement: same-name uploads need a distinct local name.
            guard !names.contains(where: { n in existing.contains(where: { $0.name == n }) }) else {
                throw self.failure("中转站已有同名内容。请先改名后上传，避免覆盖已有文件。")
            }
            // The CLI fails every file whose remote folder is missing, so build the folder tree first.
            let folders = urls.flatMap { leafFolders($0) }
            for (i, folder) in folders.enumerated() {
                DispatchQueue.main.async { self.status = "正在建立文件夹 \(i + 1)/\(folders.count)…" }
                let (made, madeCode) = try self.run(["mkdir", self.station + "/" + folder])
                guard madeCode == 0, made.contains("创建目录成功") else { throw self.failure("无法在中转站建立文件夹 " + folder + "：" + transferFailureLines(made)) }
                guard !self.cancelled else { throw self.failure("传输已停止，中转站里可能有已建好的空文件夹") }
            }
            DispatchQueue.main.async { self.status = "正在上传到文件中转站…" }
            // Uploads go straight into the station; same names were refused above, so nothing is overwritten.
            // Measured on an overseas server with 300 MB: 4 threads ≈ 11 MB/s, 16 ≈ 22 MB/s.
            let (text, code) = try self.run(["upload", "-p", "16", "--policy", "skip"] + urls.map(\.path) + [self.station], live: true)
            let items = try self.list(self.station)
            DispatchQueue.main.async { self.path = self.station; self.entries = items }
            let partial = "，中转站里可能有未传完的文件，请检查后删除再重传"
            guard !self.cancelled else { throw self.failure("传输已停止" + partial) }
            guard transferSucceeded(text, code: code, operation: "上传") else { throw self.failure("上传未全部成功" + partial + "。" + transferFailureLines(text)) }
            guard Set(names).isSubset(of: Set(items.map(\.name))) else { throw self.failure("上传后核对不符，请刷新中转站检查。") }
            DispatchQueue.main.async { self.path = self.station; self.entries = items; self.status = "上传完成 · 其他设备刷新中转站即可下载"; self.progress = 1 }
        }
    }
    func chooseDownload(_ items: [RemoteEntry]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = items.count == 1 ? "下载到这里" : "下载 \(items.count) 项到这里"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let folder = panel.url { download(items, to: folder) }
    }
    func downloadWork(_ item: RemoteEntry, to destination: URL) throws {
        guard !cancelled else { throw failure("下载已停止") }
        let folder = destination.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("目标已有同名文件，请选择其他目录。") }
        let expected = item.isDirectory ? try expectedFiles(item.path) : [item.name]
        let temp = folder.appendingPathComponent(".中转站下载-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        // SVIP measured on an overseas server: 1 thread ≈ 2 MB/s, 16 ≈ 34 MB/s, 32 adds little.
        let (text, code) = try run(["download", "-p", "16", "--saveto", temp.path, literalRemotePath(item.path)], live: true)
        guard transferSucceeded(text, code: code, operation: "下载") else { throw failure("下载未全部成功，临时文件保留在目标目录，未标记完成。") }
        guard !cancelled else { throw failure("下载已停止，未完成内容保留在临时目录") }
        let source = temp.appendingPathComponent(item.name)
        guard FileManager.default.fileExists(atPath: source.path) else { throw failure("下载结果路径不符，请查看任务详情。") }
        let base = item.isDirectory ? source : temp
        guard expected.allSatisfy({ FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }) else {
            throw failure("下载结果缺少文件，未标记完成。临时内容保留供检查。")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        try? FileManager.default.removeItem(at: temp)
        DispatchQueue.main.async { self.status = "下载完成 · " + destination.path; self.progress = 1 }
    }
    func expectedFiles(_ remote: String) throws -> [String] {
        var files: [String] = []
        for item in try list(remote) {
            if cancelled { throw failure("下载已停止") }
            if item.isDirectory { files += try expectedFiles(item.path).map { item.name + "/" + $0 } }
            else { files.append(item.name) }
        }
        return files
    }
    func download(_ items: [RemoteEntry], to folder: URL) {
        guard !items.isEmpty else { return }
        start(items.count == 1 ? "正在下载 \(items[0].name)…" : "正在下载 \(items.count) 项…") {
            let taken = items.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
            guard taken.isEmpty else { throw self.failure("目标目录已有同名内容：" + taken.map(\.name).joined(separator: "、") + "。请选择其他目录。") }
            guard items.count > 1 else { return try self.downloadWork(items[0], to: folder.appendingPathComponent(items[0].name)) }
            // 逐项下载；某项失败不影响其余项，最后如实汇报。
            var failed: [String] = [], done = 0
            for (i, item) in items.enumerated() {
                guard !self.cancelled else { break }
                DispatchQueue.main.async { self.status = "正在下载 \(i + 1)/\(items.count) · \(item.name)"; self.progress = nil; self.progressText = "" }
                do { try self.downloadWork(item, to: folder.appendingPathComponent(item.name)); done += 1 } catch { failed.append(item.name) }
            }
            guard !self.cancelled else { throw self.failure("下载已停止，已完成 \(done)/\(items.count) 项；未完成的内容保留在目标目录的临时文件夹里") }
            guard failed.isEmpty else { throw self.failure("已下载 \(done)/\(items.count) 项；未完成：" + failed.joined(separator: "、")) }
            DispatchQueue.main.async { self.status = "下载完成 \(items.count) 项 · " + folder.path; self.progress = 1 }
        }
    }
    func promisedDownload(_ item: RemoteEntry, to destination: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // 同一次拖拽的多项依次排进串行队列；其他传输进行中则拒绝。
            guard self.promises > 0 || !self.busy else { completion(self.failure("已有传输正在进行，请稍后重试")); return }
            if self.promises == 0 { self.busy = true; self.cancelled = false; self.log = "" }
            self.promises += 1
            self.queue.async {
                DispatchQueue.main.async { self.status = "正在下载 \(item.name)…"; self.progress = nil; self.progressText = "" }
                do { try self.downloadWork(item, to: destination); completion(nil) }
                catch { completion(error); DispatchQueue.main.async { self.status = "未完成：" + self.safe(error.localizedDescription); self.progress = nil } }
                DispatchQueue.main.async { self.promises -= 1; if self.promises == 0 { self.busy = false } }
            }
        }
    }
    func canDelete(_ item: RemoteEntry?) -> Bool { item.map { $0.path.hasPrefix(station + "/") } ?? false }
    func confirmDelete(_ items: [RemoteEntry]) {
        guard !items.isEmpty, items.allSatisfy(canDelete), !busy, !loginRunning else { return }
        let alert = NSAlert(); alert.messageText = items.count == 1 ? "删除「\(items[0].name)」？" : "删除选中的 \(items.count) 项？"
        alert.informativeText = (items.contains(where: \.isDirectory) ? "文件夹及其中内容都会删除。" : "") + "删除后可在百度网盘回收站找回。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        delete(items)
    }
    func delete(_ items: [RemoteEntry]) {
        let folder = path
        start(items.count == 1 ? "正在删除 \(items[0].name)…" : "正在删除 \(items.count) 项…") {
            var output = ""
            for item in items {
                guard !self.cancelled else { break }
                output += (try? self.run(["rm", literalRemotePath(item.path)]).0) ?? ""
            }
            let listing = try self.list(folder)
            DispatchQueue.main.async { self.entries = listing }
            // Judge by the listing, not the CLI's wording.
            let left = items.filter { item in listing.contains(where: { $0.path == item.path }) }
            guard left.isEmpty else {
                throw self.failure("已删除 \(items.count - left.count)/\(items.count) 项；未删除：" + left.map(\.name).joined(separator: "、") + (self.cancelled ? "" : "。" + transferFailureLines(output)))
            }
            DispatchQueue.main.async { self.status = (items.count == 1 ? "已删除 \(items[0].name)" : "已删除 \(items.count) 项") + " · 可在网盘回收站找回" }
        }
    }
    func stop() {
        cancelled = true
        status = "正在停止…"
        process?.interrupt()
        if let process {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
    func logout() {
        let alert = NSAlert(); alert.messageText = "退出百度网盘账号？"
        alert.informativeText = "退出后需要重新扫码或输入密码登录。"
        alert.addButton(withTitle: "退出登录"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        start("正在退出登录…") {
            _ = try self.run(["logout", "-y"])
            let (who, _) = try self.run(["who"])
            if let name = loggedInAccount(who) { throw self.failure("退出失败，仍登录为 \(name)") }
            DispatchQueue.main.async { self.account = "未登录"; self.entries = []; self.status = "已退出登录" }
        }
    }
    func showAuthentication() {
        guard !busy else { return }
        showLogin = true; loginText = ""; loginMode = 0; loginStage = ""
    }
    func beginLogin(username: String = "", password: String = "", cookie: String? = nil) {
        guard !busy, !loginRunning else { return }
        showLogin = true; loginText = ""; loginOutput = ""; secrets = []; loginRunning = true
        pendingUser = username; pendingPassword = password; webLogin = cookie != nil
        var masterFD: Int32 = 0, slaveFD: Int32 = 0
        // A wide terminal keeps the REPL from scrolling the cookie line in pieces.
        var size = winsize(ws_row: 50, ws_col: 8000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { loginText = "无法创建认证终端"; loginRunning = false; return }
        let p = Process(), slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        p.executableURL = executable; p.arguments = cookie == nil ? ["login"] : []
        var loginEnv = environment(); loginEnv["TERM"] = "xterm-256color"
        if cookie != nil {
            // Keep REPL credential commands out of CLI history.
            let directory = config.appendingPathComponent(".login-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                loginDirectory = directory
                let existing = config.appendingPathComponent("pcs_config.json")
                if FileManager.default.fileExists(atPath: existing.path) {
                    try FileManager.default.copyItem(at: existing, to: directory.appendingPathComponent("pcs_config.json"))
                }
                try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("pcs_command_history.txt").path, withDestinationPath: "/dev/null")
                loginEnv["BAIDUPCS_GO_CONFIG_DIR"] = directory.path
            } catch { loginText = "无法准备登录：" + error.localizedDescription; loginRunning = false; return }
        }
        p.environment = loginEnv
        p.standardInput = slave; p.standardOutput = slave; p.standardError = slave
        do { try p.run() } catch { loginText = error.localizedDescription; loginRunning = false; return }
        slave.closeFile(); loginProcess = p
        master?.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                if self.webLogin {
                    self.loginOutput = String((self.loginOutput + text).suffix(20000))
                    self.loginText = "正在连接百度网盘并验证登录状态…"
                    return
                }
                self.loginText = String((self.loginText + self.safe(text)).suffix(12000))
                if self.loginText.contains("请输入百度用户名"), !self.pendingUser.isEmpty {
                    let value = self.pendingUser; self.pendingUser = ""; self.submitLogin(value)
                }
                if self.loginText.contains("请输入密码"), !self.pendingPassword.isEmpty {
                    let value = self.pendingPassword; self.pendingPassword = ""; self.submitLogin(value)
                }
                if self.loginText.contains("请输入验证方式") { self.loginStage = "选择验证方式：输入 1（手机）或 2（邮箱）" }
                if self.loginText.contains("请输入接收到的验证码") || self.loginText.contains("请输入验证码 >") { self.loginStage = "请输入收到的验证码或图片验证码" }
            }
        }
        p.terminationHandler = { completed in
            DispatchQueue.main.async {
                self.master?.readabilityHandler = nil; self.master = nil; self.loginProcess = nil
                self.loginRunning = false; self.protectConfig()
                self.pendingPassword = ""; self.pendingUser = ""
                if self.webLogin {
                    let succeeded = completed.terminationStatus == 0 && self.loginOutput.contains("百度帐号登录成功")
                    do {
                        guard succeeded, let directory = self.loginDirectory else {
                            throw self.failure("网页已登录，但传输工具未能接收登录状态。\n" + loginResultLines(self.loginOutput))
                        }
                        let data = try Data(contentsOf: directory.appendingPathComponent("pcs_config.json"))
                        try data.write(to: self.config.appendingPathComponent("pcs_config.json"), options: .atomic)
                        self.protectConfig()
                        self.showLogin = false; self.loginText = ""; self.refresh(self.station)
                    } catch {
                        self.loginText = self.safe(error.localizedDescription)
                    }
                    if let directory = self.loginDirectory { try? FileManager.default.removeItem(at: directory) }
                    self.loginDirectory = nil; self.loginOutput = ""
                } else if self.showLogin { self.loginText += "\n认证流程已结束。点完成后刷新账户。" }
                else { self.refresh(self.station) }
            }
        }
        if let cookie {
            secrets.append(cookie)
            for pair in cookie.split(separator: ";") {
                if let value = pair.split(separator: "=", maxSplits: 1).last { secrets.append(String(value)) }
            }
            // Credentials travel over the PTY, never through argv, shell, or log files.
            let escaped = cookie.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.submitLogin("login --cookies=\"" + escaped + "\"\nquit") }
        }
    }
    func submitLogin(_ input: String) {
        secrets.append(input)
        // Disable echo before sending any credential; output stays in memory only.
        if let master {
            var settings = termios()
            if tcgetattr(master.fileDescriptor, &settings) == 0 { settings.c_lflag &= ~tcflag_t(ECHO); tcsetattr(master.fileDescriptor, TCSANOW, &settings) }
            try? master.write(contentsOf: Data((input + "\n").utf8))
        }
    }
    func closeLogin() {
        loginProcess?.terminate(); showLogin = false; loginText = ""; secrets = []
        if !loginRunning { refresh(station) }
    }
}

struct BaiduLoginWeb: NSViewRepresentable {
    static let loginURL = URL(string: "https://passport.baidu.com/v2/?login&tpl=netdisk&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fmain")!
    static let panURL = URL(string: "https://pan.baidu.com/disk/main")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    let onCookies: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCookies) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        // Baidu serves a blank page to WebKit's default user agent.
        web.customUserAgent = Self.userAgent
        web.pageZoom = 0.8
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.web = web
        web.load(URLRequest(url: Self.loginURL))
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        weak var web: WKWebView?
        let callback: (String) -> Void
        var finished = false, openedPan = false, waitingForToken = false
        init(_ callback: @escaping (String) -> Void) { self.callback = callback }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { collect(cookieStore) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { collect(webView.configuration.websiteDataStore.httpCookieStore) }
        // Keep pop-up login pages inside this sheet.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
        func collect(_ store: WKHTTPCookieStore) {
            guard !finished, let host = web?.url?.host, host == "baidu.com" || host.hasSuffix(".baidu.com") else { return }
            store.getAllCookies { cookies in
                guard !self.finished else { return }
                let baidu = cookies.filter { cookieAppliesToPan($0.domain) }
                guard baidu.contains(where: { $0.name == "BDUSS" && !$0.value.isEmpty }) else { return }
                // Logged in; the netdisk token is issued once pan.baidu.com is visited.
                guard self.web?.url?.host == "pan.baidu.com" else {
                    if !self.openedPan { self.openedPan = true; self.web?.load(URLRequest(url: BaiduLoginWeb.panURL)) }
                    return
                }
                if baidu.contains(where: { $0.name == "STOKEN" && !$0.value.isEmpty }) { self.finish(baidu); return }
                guard !self.waitingForToken else { return }
                self.waitingForToken = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    store.getAllCookies { self.finish($0.filter { cookieAppliesToPan($0.domain) }) }
                }
            }
        }
        func finish(_ baidu: [HTTPCookie]) {
            guard !finished, let header = panCookieHeader(baidu) else { return }
            finished = true
            callback(header)
        }
    }
}

func panCookieHeader(_ cookies: [HTTPCookie]) -> String? {
    let baidu = cookies.filter { cookieAppliesToPan($0.domain) }
    guard baidu.contains(where: { $0.name == "BDUSS" && !$0.value.isEmpty }) else { return nil }
    // Prefer more-specific cookie values without repeating names.
    var values: [String: String] = [:]
    for c in baidu.sorted(by: { $0.domain.count < $1.domain.count }) { values[c.name] = c.value }
    return loginCookieHeader(values)
}

// The embedded passport page never reacts to a phone confirmation, so QR login talks to passport directly.
@MainActor final class QRLogin: ObservableObject {
    @Published var image: NSImage?
    @Published var status = ""
    let session = URLSession(configuration: .ephemeral)
    var task: Task<Void, Never>?
    func start(_ done: @escaping (String) -> Void) {
        task?.cancel(); image = nil; status = "正在获取二维码…"
        task = Task {
            do { try await run(done) }
            catch { if !Task.isCancelled { image = nil; status = "扫码登录失败：" + error.localizedDescription } }
        }
    }
    func stop() { task?.cancel() }
    func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://passport.baidu.com" + path)!, timeoutInterval: 60)
        request.setValue(BaiduLoginWeb.userAgent, forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request).0
    }
    func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    func run(_ done: @escaping (String) -> Void) async throws {
        guard let sign = json(try await get("/v2/api/getqrcode?lp=pc&qrloginfrom=pc&apiver=v3&tpl=netdisk"))["sign"] as? String else {
            throw NSError(domain: "QR", code: 1, userInfo: [NSLocalizedDescriptionKey: "百度未返回二维码"])
        }
        image = NSImage(data: try await get("/v2/api/qrcode?sign=" + sign + "&lp=pc&qrloginfrom=pc"))
        status = "用百度网盘 App 或百度 App 扫码"
        let deadline = Date().addingTimeInterval(240)
        var token = ""
        // Each poll is held open up to 30 s; status 1 = scanned, 0 = confirmed with a one-time token.
        while token.isEmpty {
            guard Date() < deadline else { image = nil; status = "二维码已过期，请刷新"; return }
            let reply = json(try await get("/channel/unicast?channel_id=" + sign + "&tpl=netdisk&apiver=v3&callback="))
            guard let value = reply["channel_v"] as? String else { continue }
            let channel = json(Data(value.utf8))
            if channel["status"] as? Int == 0, let v = channel["v"] as? String { token = v }
            else if channel["status"] as? Int == 1 { status = "已扫码，请在手机上确认登录" }
        }
        status = "正在连接百度网盘…"
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        let target = "&tpl=netdisk&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome"
        _ = try await get("/v3/login/main/qrbdusslogin?bduss=" + encoded + "&loginVersion=v4&qrcode=1&apiver=v3" + target)
        // Passport hands the netdisk STOKEN to pan.baidu.com through this redirect.
        _ = try await get("/v3/login/api/auth/?return_type=5" + target)
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        guard let header = panCookieHeader(cookies) else { image = nil; status = "手机已确认，但百度未返回登录状态，请刷新重试"; return }
        done(header)
    }
}

struct QRLoginView: View {
    @StateObject var qr = QRLogin()
    let onCookies: (String) -> Void
    var body: some View {
        VStack(spacing: 14) {
            if let image = qr.image { Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220) }
            else { ProgressView().frame(width: 220, height: 220) }
            Text(qr.status)
            Button("刷新二维码") { qr.start(onCookies) }
        }.frame(maxWidth: .infinity).onAppear { qr.start(onCookies) }.onDisappear { qr.stop() }
    }
}

// Finder requests a promised file only after it knows the drop destination.
struct CloudTable: NSViewRepresentable {
    @ObservedObject var model: Model
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.rowHeight = 34; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true   // ⌘ 点选、⇧ 连选
        for (id, title, width) in [("name", "名称", 360.0), ("size", "大小", 100.0), ("date", "修改时间", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openRow)
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        context.coordinator.table = table
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        // Progress updates also land here; reload only when the listing changed.
        let old = context.coordinator.items, new = model.entries
        guard old.map(\.id) != new.map(\.id) || old.map(\.modified) != new.map(\.modified) else { return }
        context.coordinator.items = new; (view.documentView as? NSTableView)?.reloadData()
        DispatchQueue.main.async { model.selection = [] }
    }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSFilePromiseProviderDelegate, NSMenuDelegate {
        let model: Model; var items: [RemoteEntry] = []; weak var table: NSTableView?
        init(_ model: Model) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row], cell = NSTableCellView(), label = NSTextField(labelWithString: "")
            let id = tableColumn?.identifier.rawValue ?? "name"
            label.stringValue = id == "name" ? item.name : id == "size" ? item.size : item.modified
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
            if id == "name" {
                let icon = NSImageView(frame: NSRect(x: 7, y: 8, width: 18, height: 18)); icon.image = NSImage(systemSymbolName: item.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil); icon.contentTintColor = item.isDirectory ? .systemBlue : .secondaryLabelColor; cell.addSubview(icon)
            }
            label.frame = NSRect(x: id == "name" ? 33 : 8, y: 8, width: (tableColumn?.width ?? 100) - (id == "name" ? 38 : 12), height: 19)
            label.autoresizingMask = [.width]; cell.addSubview(label); cell.textField = label; return cell
        }
        @objc func openRow() { guard let row = table?.clickedRow, items.indices.contains(row) else { return }; if items[row].isDirectory { model.refresh(items[row].path) } else { model.chooseDownload([items[row]]) } }
        // 右键点在选中项上就作用于全部选中项，否则只作用于点到的那一行（同 Finder）。
        var menuTargets: [RemoteEntry] {
            guard let table, items.indices.contains(table.clickedRow) else { return [] }
            let rows = table.selectedRowIndexes.contains(table.clickedRow) ? table.selectedRowIndexes : [table.clickedRow]
            return rows.filter { items.indices.contains($0) }.map { items[$0] }
        }
        @objc func downloadRow() { model.chooseDownload(menuTargets) }
        @objc func deleteRow() { model.confirmDelete(menuTargets) }
        func tableViewSelectionDidChange(_ notification: Notification) {
            model.selection = (table?.selectedRowIndexes ?? []).filter { items.indices.contains($0) }.map { items[$0] }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = menuTargets
            guard !targets.isEmpty, !model.busy, !model.loginRunning else { return }
            menu.addItem(withTitle: targets.count == 1 ? "下载到…" : "下载 \(targets.count) 项到…", action: #selector(downloadRow), keyEquivalent: "").target = self
            if targets.allSatisfy(model.canDelete) { menu.addItem(withTitle: targets.count == 1 ? "删除" : "删除 \(targets.count) 项", action: #selector(deleteRow), keyEquivalent: "").target = self }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard !model.busy else { return nil }
            let item = items[row]
            let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            let promise = NSFilePromiseProvider(fileType: type.identifier, delegate: self); promise.userInfo = item; return promise
        }
        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { (provider.userInfo as! RemoteEntry).name }
        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) { model.promisedDownload(provider.userInfo as! RemoteEntry, to: url, completion: completionHandler) }
    }
}

struct MainView: View {
    @ObservedObject var model = Model.shared
    @Environment(\.openWindow) var openWindow
    @State var input = ""
    @State var username = ""
    @State var password = ""
    @State var targeted = false
    @State var details = false
    @State var webPage = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let logo = Bundle.main.url(forResource: "AppLogo", withExtension: "png"), let image = NSImage(contentsOf: logo) {
                    Image(nsImage: image).resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 3) { Text("文件中转站").font(.title3.bold()); Text("百度网盘 · " + model.account).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button(model.account == "未登录" ? "登录账户" : "退出登录") { model.account == "未登录" ? model.showAuthentication() : model.logout() }.disabled(model.busy || model.loginRunning)
                    Button("检查更新") { Updater.check(manual: true) }.help("当前版本 \(Updater.current)")
                }
            }.padding(18)
            Divider()
            HStack {
                Button { model.refresh((model.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "chevron.up") }.help("上一级").disabled(model.path == model.station)
                Text(model.path).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("中转站") { model.enterStation() }
            }.padding(12).disabled(model.busy || model.loginRunning)
            ZStack {
                CloudTable(model: model)
                if model.entries.isEmpty {
                    VStack(spacing: 10) { Image(systemName: "tray.and.arrow.up").font(.system(size: 35)).foregroundStyle(.blue); Text(model.account == "未登录" ? "先登录百度网盘" : "把文件拖到这里").font(.headline); Text("文件会上传到 /文件中转站\n上传成功后，其他设备刷新即可下载").multilineTextAlignment(.center).font(.caption).foregroundStyle(.secondary) }.allowsHitTesting(false)
                }
                if targeted { RoundedRectangle(cornerRadius: 8).stroke(.blue, lineWidth: 3).padding(5).allowsHitTesting(false) }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard !model.busy, !model.loginRunning else { return false }
                let group = DispatchGroup(), lock = NSLock(); var urls: [URL] = []
                for provider in providers {
                    group.enter(); provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url { lock.lock(); urls.append(url); lock.unlock() }; group.leave()
                    }
                }
                group.notify(queue: .main) { model.upload(urls) }; return true
            }
            Divider()
            HStack {
                Button("选择文件上传…") { model.chooseUpload() }.disabled(model.busy || model.loginRunning)
                Button(model.selection.count > 1 ? "下载 \(model.selection.count) 项…" : "下载…") { model.chooseDownload(model.selection) }
                    .disabled(model.busy || model.loginRunning || model.selection.isEmpty).help("下载选中的内容；按住 ⌘ 或 ⇧ 可多选")
                Button(model.selection.count > 1 ? "删除 \(model.selection.count) 项" : "删除") { model.confirmDelete(model.selection) }.disabled(model.busy || model.loginRunning || model.selection.isEmpty || !model.selection.allSatisfy(model.canDelete))
                    .help("删除选中的中转站内容（可在网盘回收站找回）")
                Text("⌘/⇧ 多选，右键下载或删除，或拖到 Finder 文件夹").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { Button("停止") { model.stop() } }
            }.padding(12)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(details ? "收起" : "详情") { details.toggle() }.buttonStyle(.link)
                    Button { model.refresh(); Updater.check() } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15)) }
                        .buttonStyle(.borderless).help("刷新云端文件列表，并检查应用更新").accessibilityLabel("刷新云端文件列表")
                        .disabled(model.busy || model.loginRunning)
                }
                if let progress = model.progress {
                    HStack {
                        ProgressView(value: progress)
                        Text(model.busy && !model.progressText.isEmpty ? model.progressText : "\(Int(progress * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if details { ScrollView { Text(model.log.isEmpty ? "暂无传输记录" : model.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120) }
            }.padding(12).background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 440)
        .onAppear { model.openMain = { openWindow(id: "main") }; model.refresh() }
        .sheet(isPresented: $model.showLogin, onDismiss: { model.closeLogin() }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("登录百度网盘").font(.title3.bold())
                Text("登录状态保存在这台 Mac，不需要安装百度网盘客户端。").font(.caption).foregroundStyle(.secondary)
                Picker("登录方式", selection: $model.loginMode) { Text("扫码登录").tag(0); Text("账号密码").tag(1) }.pickerStyle(.segmented).disabled(model.loginRunning)
                if model.loginMode == 0 {
                    if model.webLogin && model.loginRunning { ProgressView("正在验证登录状态…").frame(height: 500) }
                    else if model.webLogin && !model.loginText.isEmpty {
                        ScrollView { Text(model.loginText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 300)
                        Button("重新扫码") { model.loginText = ""; model.webLogin = false }
                    } else if webPage { BaiduLoginWeb { cookie in model.beginLogin(cookie: cookie) }.frame(height: 500) }
                    else { QRLoginView { cookie in model.beginLogin(cookie: cookie) }.frame(height: 500) }
                    HStack {
                        Text("手机确认后自动连接网盘。").font(.caption).foregroundStyle(.secondary)
                        Button(webPage ? "改回扫码" : "改用百度网页登录") { webPage.toggle() }.buttonStyle(.link).disabled(model.loginRunning)
                    }
                } else {
                    if !model.loginRunning && model.loginText.isEmpty {
                        TextField("手机号 / 邮箱 / 百度用户名", text: $username)
                        SecureField("密码", text: $password)
                        Button("登录") { model.beginLogin(username: username, password: password); password = "" }.disabled(username.isEmpty || password.isEmpty)
                    }
                    if !model.loginText.isEmpty || model.loginRunning {
                        ScrollView { Text(model.loginText.isEmpty ? "正在连接…" : model.loginText).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 200)
                        if model.loginRunning {
                            Text(model.loginStage.isEmpty ? "正在认证，若需要验证会在这里提示" : model.loginStage).font(.caption)
                            HStack { TextField("验证码 / 验证方式", text: $input).onSubmit { model.submitLogin(input); input = "" }; Button("提交") { model.submitLogin(input); input = "" }.disabled(input.isEmpty) }
                            Button("查看图片验证码") { NSWorkspace.shared.open(model.config) }
                        } else { Button("重新登录") { model.loginText = "" } }
                    }
                }
                HStack { Spacer(); Button(model.loginRunning ? "取消" : "完成") { model.closeLogin() } }
            }.padding(22).frame(width: 900)
        }
    }
}

/// 启动时查 GitHub 最新 Release；有新版且用户同意，就下载 zip、替换当前 .app 并重启。
enum Updater {
    static let latest = URL(string: "https://api.github.com/repos/bleeeet/file-transfer-station/releases/latest")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static var inProgress = false   // 已在弹窗或下载中，不重复提示

    /// manual：用户点「检查更新」时，没有新版或查询失败也弹窗告知；自动检查则静默。
    static func check(manual: Bool = false) {
        guard !inProgress else { return }
        URLSession.shared.dataTask(with: latest) { data, _, _ in
            guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if manual { DispatchQueue.main.async { show("检查更新失败，请检查网络后重试。") } }
                return
            }
            guard isNewerVersion(tag, than: current) else {
                if manual { DispatchQueue.main.async { show("已是最新版本 \(current)") } }
                return
            }
            guard let assets = json["assets"] as? [[String: Any]],
                  let link = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".zip") }),
                  let url = URL(string: link) else {
                if manual { DispatchQueue.main.async { show("新版本 \(tag) 的安装包还没上传好，请稍后再试。") } }
                return
            }
            DispatchQueue.main.async { guard !inProgress else { return }; inProgress = true; offer(tag, notes: json["body"] as? String ?? "", from: url) }
        }.resume()
    }

    static func offer(_ tag: String, notes: String, from url: URL) {
        let alert = NSAlert(); alert.messageText = "发现新版本 \(tag)"
        alert.informativeText = "当前版本 \(current)。\n\n\(notes)".trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addButton(withTitle: "立即更新"); alert.addButton(withTitle: "以后再说")
        guard alert.runModal() == .alertFirstButtonReturn else { inProgress = false; return }
        download(tag, from: url)
    }

    static func download(_ tag: String, from url: URL) {
        // 启动刷新、传输或登录进行中时，等它结束再下载替换
        if Model.active?.busy == true || Model.active?.loginRunning == true {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { download(tag, from: url) }
        }
        Model.active?.status = "正在下载更新 \(tag)…"
        URLSession.shared.downloadTask(with: url) { file, _, error in
            do {
                guard let file else { throw error ?? URLError(.badServerResponse) }
                let target = Bundle.main.bundleURL
                let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); unzip.arguments = ["-x", "-k", file.path, dir.path]
                try unzip.run(); unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                      Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw URLError(.cannotDecodeContentData) }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async {
                    if Model.active?.busy == true || Model.active?.loginRunning == true { Model.active?.status = "更新 \(tag) 已安装，下次打开生效"; return }
                    let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open"); relaunch.arguments = ["-n", target.path]
                    try? relaunch.run(); NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async { inProgress = false; Model.active?.status = "更新失败"; show("更新失败：\(error.localizedDescription)\n可到 GitHub Releases 手动下载。") }
            }
        }.resume()
    }

    static func show(_ text: String) { let a = NSAlert(); a.messageText = text; a.runModal() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self; NSUpdateDynamicServices()
        Updater.check()
    }
    /// Finder 右键「上传到百度云中转站」：等手头的刷新/传输结束再上传。
    @objc func uploadFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        NSApp.activate(ignoringOtherApps: true); Model.shared.openMain?()
        uploadWhenIdle(urls)
    }
    func uploadWhenIdle(_ urls: [URL]) {
        let model = Model.shared
        guard !model.busy, !model.loginRunning else { return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.uploadWhenIdle(urls) } }
        model.upload(urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        for process in [Model.active?.process, Model.active?.loginProcess].compactMap({ $0 }) where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Model.active?.busy == true || Model.active?.loginRunning == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "停止传输并退出？"
        alert.informativeText = "未完成的内容保留在临时区；已完成的文件不受影响。"
        alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "继续传输")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main struct TransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Window("文件中转站", id: "main") { MainView() }.defaultSize(width: 760, height: 530) }
}
