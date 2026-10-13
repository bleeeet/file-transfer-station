# 文件中转站

- 原生 SwiftUI/AppKit，只支持 Apple Silicon；保持轻量，不加入后台常驻、同步、自启。
- `Sources/Core.swift` 为目录解析与传输结果判定；`Sources/App.swift` 为 UI、CLI 子进程和 Finder 文件承诺。
- 修改后运行 Core 测试与 `./build.sh`。涉及传输或认证时使用 `Tests/mock-cli.py` 做本地集成验证，不使用真实用户数据做测试。
- 分发仅包含 `.app`，不得打包登录配置、Cookies、用户文件或测试夹具。
- 云端 `/文件中转站` 复用现有目录；上传直接进入中转站，不建临时目录（用户决定）。不得覆盖同名文件、自动删除原始资料或把部分成功报告为完成。
- 官方网页登录仅向 `baidu.com` 域导入认证；凭据只经子进程输入，不经 argv、日志或 shell。
