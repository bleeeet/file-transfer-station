import Foundation
import AppKit

func wait(_ condition: () -> Bool, timeout: TimeInterval = 8) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    precondition(condition(), "操作未完成或超时")
}
let model = Model(config: URL(fileURLWithPath: "/tmp/中转站认证自测-" + UUID().uuidString))
let local = URL(fileURLWithPath: "/tmp/中转站本地自测-" + UUID().uuidString)
try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
let file = local.appendingPathComponent("素材 空格-" + UUID().uuidString + ".txt")
try Data("本地上传下载核对\n".utf8).write(to: file)
model.refresh()
wait { !model.busy }
precondition(model.account == "测试账户")
precondition(model.path == "/文件中转站")
model.upload([file])
wait { !model.busy }
guard let item = model.entries.first(where: { $0.name == file.lastPathComponent }) else { fatalError("上传发布结果缺失") }
let downloads = local.appendingPathComponent("下载")
try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
model.download(item, to: downloads)
wait { !model.busy }
let original = try Data(contentsOf: file)
let downloaded = try Data(contentsOf: downloads.appendingPathComponent(item.name))
precondition(downloaded == original)
let promised = local.appendingPathComponent("拖拽下载")
try FileManager.default.createDirectory(at: promised, withIntermediateDirectories: true)
var promiseDone = false
model.promisedDownload(item, to: promised.appendingPathComponent(item.name)) { error in
    precondition(error == nil); DispatchQueue.main.async { promiseDone = true }
}
wait { promiseDone && !model.busy }
let promisedData = try Data(contentsOf: promised.appendingPathComponent(item.name))
precondition(promisedData == original)
let folder = local.appendingPathComponent("素材 包-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录/更深"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: folder.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
try Data("深层".utf8).write(to: folder.appendingPathComponent("子目录/更深/c.txt"))
model.upload([folder])
wait { !model.busy }
precondition(model.status.hasPrefix("上传完成"), model.status)
precondition(model.entries.contains(where: { $0.name == folder.lastPathComponent && $0.isDirectory }))
print("文件夹上传通过：先建文件夹树再上传，空文件夹保留。")
for name in [item.name, folder.lastPathComponent] {
    model.delete(model.entries.first(where: { $0.name == name })!)
    wait { !model.busy }
    precondition(model.status.hasPrefix("已删除"), model.status)
    precondition(!model.entries.contains(where: { $0.name == name }))
}
precondition(!model.canDelete(RemoteEntry(name: "文件中转站", path: "/文件中转站", size: "-", modified: "", isDirectory: true)))
print("删除通过：文件和文件夹删除后列表核对，中转站本身不可删。")
model.refresh("/")
wait { !model.busy }
precondition(model.path == "/文件中转站")
print("浏览范围通过：请求上级目录时仍停在中转站。")
model.beginLogin(username: "fixture-user", password: "fixture-password")
wait { model.loginText.contains("请输入接收到的验证码") }
model.submitLogin("123456")
wait { !model.loginRunning }
precondition(!model.loginText.contains("fixture-password"))
precondition(model.loginText.contains("登录成功"))
print("本地集成自测通过：自动中转目录、上传发布、下载内容一致、Finder 文件承诺下载回调、账号密码自动提交、验证码提交及凭据遮蔽。")

model.beginLogin(cookie: loginCookieHeader(["BDUSS": "fixture-valid"]))
wait { !model.loginRunning && !model.busy }
precondition(!model.showLogin)
precondition(FileManager.default.fileExists(atPath: model.config.appendingPathComponent("pcs_config.json").path))
precondition(!FileManager.default.fileExists(atPath: model.config.appendingPathComponent("pcs_command_history.txt").path))
model.beginLogin(cookie: loginCookieHeader(["BDUSS": "fixture-invalid"]))
wait { !model.loginRunning }
precondition(model.showLogin)
precondition(model.loginText.contains("凭据导入失败"))
precondition(!model.loginText.contains("fixture-invalid"))
try FileManager.default.removeItem(at: model.config)
print("扫码桥接回归通过：Cookie末尾分号、成功导入、失败保留窗口、无凭据命令历史。")
