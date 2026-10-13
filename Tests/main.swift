import Foundation

let fixture = """
当前目录: /文件中转站
----
 # 文件大小 修改日期 文件(目录)
 0  12.34 MB  2026-10-13 12:01:02  视频 素材.zip
 1  -         2026-10-13 12:01:03  设计文件/
 2  1 B       2026-10-13 12:01:04  a[1].txt
 总: 12.34 MB 文件总数: 2, 目录总数: 1
----
"""
let entries = try parseListing(fixture, path: "/文件中转站")
assert(entries.count == 3)
assert(entries[0].name == "视频 素材.zip")
assert(entries[1].isDirectory)
assert(entries[2].path == "/文件中转站/a[1].txt")
assert(literalRemotePath(entries[2].path) == "/文件中转站/a\\[1\\].txt")
do { _ = try parseListing("网络错误: failed", path: "/"); assertionFailure("error mistaken for empty directory") } catch {}
do { _ = try parseListing(fixture.replacingOccurrences(of: "文件总数: 2", with: "文件总数: 5"), path: "/"); assertionFailure("partial listing accepted") } catch {}
assert(transferSucceeded("上传结束, 总大小: 10 MB", code: 0, operation: "上传"))
assert(!transferSucceeded("下载结束\n以下文件下载失败:", code: 0, operation: "下载"))
assert(!transferSucceeded("上传结束", code: 1, operation: "上传"))
assert(!transferSucceeded("未登录", code: 0, operation: "下载"))
print("目录解析、带空格/通配符文件名、失败识别：全部通过")
precondition(loginCookieHeader(["BDUSS": "fixture"]) == "BDUSS=fixture;")
precondition(loginCookieHeader(["BDUSS": "fixture", "BAIDUID": "id"]).contains("BDUSS=fixture;"))

precondition(cookieAppliesToPan(".baidu.com"))
precondition(cookieAppliesToPan("pan.baidu.com"))
precondition(!cookieAppliesToPan("passport.baidu.com"))
precondition(!cookieAppliesToPan("tieba.baidu.com"))
precondition(!cookieAppliesToPan("baidu.com.example.org"))

precondition(loggedInAccount("当前帐号 uid: 123, 用户名: 测试账户, 性别: , 年龄: 0.0") == "测试账户")
precondition(loggedInAccount("当前帐号 uid: 0, 用户名: , 性别: , 年龄: 0.0") == nil)
precondition(loggedInAccount("当前帐号 uid: 0, 用户名: 测试账户, 性别: , 年龄: 0.0") == "测试账户")
precondition(loggedInAccount("网络错误") == nil)
let replEcho = "BaiduPCS-Go > login --cookies=\"BDUSS=fixture;\"\r\nquit\r\n检测BDUSS有效性错误代码: 1\r\n用户未登录\r\nBaiduPCS-Go > quit\r\n"
precondition(!loginResultLines(replEcho).contains("fixture"))
precondition(loginResultLines(replEcho).contains("检测BDUSS有效性错误代码: 1"))
print("登录状态识别、登录输出遮蔽：全部通过")

let upLog = "[1] 加入上传队列: /a.mov\n[1] ↑ 0B/2.00GB 0B/s in 1s ............\r[1] ↑ 512.00MB/2.00GB 10.50MB/s in 50s, left 2m25s ............"
let up = transferProgress(upLog)!
precondition(up.fraction == 0.25 && up.detail == "512.00MB / 2.00GB · 10.50MB/s · 剩余 2m25s")
precondition(transferProgress("[1] ↓ 1.00KB/4.00KB 1.00KB/s in 1s ...")!.fraction == 0.25)
precondition(transferProgress("上传结束, 总大小: 1 KB") == nil)
precondition(transferFailureLines("[1] 开始上传文件...\n[1] 上传文件失败, 错误代码: 31045\n\n以下文件上传失败:\n/a.mov") == "[1] 上传文件失败, 错误代码: 31045\n以下文件上传失败:")
print("传输进度解析、失败原因提取：全部通过")

let tree = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("叶子目录自测-" + UUID().uuidString)
let top = tree.appendingPathComponent("素材 包")
for sub in ["子目录/更深", "空文件夹"] { try FileManager.default.createDirectory(at: top.appendingPathComponent(sub), withIntermediateDirectories: true) }
try Data("x".utf8).write(to: top.appendingPathComponent("a.txt"))
precondition(Set(leafFolders(top)) == ["素材 包/子目录/更深", "素材 包/空文件夹"])
precondition(leafFolders(top.appendingPathComponent("a.txt")).isEmpty)
let bare = tree.appendingPathComponent("单层")
try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
precondition(leafFolders(bare) == ["单层"])
try FileManager.default.removeItem(at: tree)
print("上传前文件夹结构：全部通过")
precondition(isNewerVersion("v0.2.0", than: "0.1.0"))
precondition(isNewerVersion("v0.10.0", than: "0.9.1"))
precondition(!isNewerVersion("v0.1.0", than: "0.1.0"))
precondition(!isNewerVersion("0.1", than: "0.1.0"))
precondition(!isNewerVersion("v0.1.9", than: "0.2.0"))
