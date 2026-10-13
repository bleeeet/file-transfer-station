import Foundation

struct RemoteEntry: Identifiable {
    let name: String
    let path: String
    let size: String
    let modified: String
    let isDirectory: Bool
    var id: String { path }
}

func parseListing(_ text: String, path: String) throws -> [RemoteEntry] {
    guard text.contains("当前目录:"), text.contains("文件总数:") else {
        throw NSError(domain: "中转站", code: 1, userInfo: [NSLocalizedDescriptionKey: text.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
    let regex = try NSRegularExpression(pattern: #"^\s*\d+\s+(.+?)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+(.+?)\s*$"#)
    let entries: [RemoteEntry] = text.components(separatedBy: .newlines).compactMap { line in
        let s = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: s.length)) else { return nil }
        let rawName = s.substring(with: match.range(at: 3))
        let isDir = rawName.hasSuffix("/")
        let name = isDir ? String(rawName.dropLast()) : rawName
        return RemoteEntry(name: name, path: (path == "/" ? "" : path) + "/" + name,
                           size: s.substring(with: match.range(at: 1)), modified: s.substring(with: match.range(at: 2)), isDirectory: isDir)
    }
    let countPattern = try NSRegularExpression(pattern: #"文件总数:\s*(\d+),\s*目录总数:\s*(\d+)"#)
    let ns = text as NSString
    guard let counts = countPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          let files = Int(ns.substring(with: counts.range(at: 1))),
          let folders = Int(ns.substring(with: counts.range(at: 2))), files + folders == entries.count else {
        throw NSError(domain: "中转站", code: 2, userInfo: [NSLocalizedDescriptionKey: "目录结果不完整，无法确认文件列表"])
    }
    return entries
}

// CLI interprets wildcard characters even when arguments bypass a shell.
func literalRemotePath(_ path: String) -> String {
    path.reduce("") { result, char in result + ("*?[]\\".contains(char) ? "\\" : "") + String(char) }
}

func transferSucceeded(_ text: String, code: Int32, operation: String) -> Bool {
    code == 0 && text.contains(operation + "结束") && !text.contains("以下文件" + operation + "失败")
}

// Deepest folders (relative to the upload's parent); mkdir creates their parents too.
func leafFolders(_ root: URL) -> [String] {
    guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
    let root = root.resolvingSymlinksInPath()
    var folders = [root]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    while let url = walker?.nextObject() as? URL {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isDirectory == true, values?.isSymbolicLink != true { folders.append(url.resolvingSymlinksInPath()) }
    }
    let base = root.deletingLastPathComponent().path
    let paths = folders.map { String($0.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    return paths.filter { p in !paths.contains { $0.hasPrefix(p + "/") } }
}

// Keep only the CLI's own failure reasons so the status line explains what went wrong.
func transferFailureLines(_ text: String) -> String {
    text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("失败") || $0.contains("错误") || $0.localizedCaseInsensitiveContains("error") }
        .suffix(4).joined(separator: "\n")
}

// BaiduPCS-Go reports "[1] ↑ 3.21MB/10.00MB 1.20MB/s in 3s, left 6s ..." without a percentage.
func transferProgress(_ text: String) -> (fraction: Double, detail: String)? {
    let units: [String: Double] = ["B": 1, "KB": 0x1p10, "MB": 0x1p20, "GB": 0x1p30, "TB": 0x1p40]
    let tail = String(text.suffix(4000))
    guard let regex = try? NSRegularExpression(pattern: #"([\d.]+)([KMGT]?B)/([\d.]+)([KMGT]?B) ([\d.]+[KMGT]?B/s) in [^,\s]+(?:, left ([^\s.]+))?"#),
          let m = regex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last else { return nil }
    let part = { (i: Int) in Range(m.range(at: i), in: tail).map { String(tail[$0]) } ?? "" }
    guard let done = Double(part(1)), let total = Double(part(3)), let a = units[part(2)], let b = units[part(4)], total > 0 else { return nil }
    var detail = part(1) + part(2) + " / " + part(3) + part(4) + " · " + part(5)
    if !part(6).isEmpty { detail += " · 剩余 " + part(6) }
    return (min(done * a / (total * b), 1), detail)
}

// BaiduPCS-Go's cookie parser requires a semicolon after BDUSS, even when last.
func loginCookieHeader(_ values: [String: String]) -> String {
    values.keys.sorted().map { $0 + "=" + values[$0]! + ";" }.joined(separator: " ")
}

func cookieAppliesToPan(_ domain: String) -> Bool {
    let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return normalized == "baidu.com" || normalized == "pan.baidu.com"
}

// `who` reports uid 0 and an empty name when no account is stored.
func loggedInAccount(_ who: String) -> String? {
    let ns = who as NSString
    guard let regex = try? NSRegularExpression(pattern: #"uid:\s*(\d+),\s*用户名:\s*(.*?),"#),
          let match = regex.firstMatch(in: who, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let uid = Int(ns.substring(with: match.range(at: 1))) ?? 0
    let name = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
    guard uid > 0 || !name.isEmpty else { return nil }
    return name.isEmpty ? "已登录" : name
}

// The REPL echoes the typed cookie command; keep only its result lines.
func loginResultLines(_ output: String) -> String {
    output.replacingOccurrences(of: #"\x1b\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.contains("BaiduPCS-Go >") && !$0.contains("--cookies") && !$0.contains("BDUSS=") && !$0.hasPrefix("提示:") }
        .joined(separator: "\n")
}

/// "v0.10.0" 比 "0.9.1" 新；逐段按数字比较，缺的段当 0。
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int] { v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
