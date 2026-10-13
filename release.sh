#!/bin/zsh
# 发布新版：先改 Resources/Info.plist 的 CFBundleShortVersionString，再运行 ./release.sh "更新说明"
set -e
cd "${0:A:h}"
ver=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
./build.sh
rm -f 安装包/*.zip
ditto -c -k --keepParent build/文件中转站.app "安装包/文件中转站-AppleSilicon-v$ver.zip"
# GitHub 会改掉中文附件名，上传用英文名
tmp=$(mktemp -d); cp "安装包/文件中转站-AppleSilicon-v$ver.zip" "$tmp/FileTransferStation-AppleSilicon-v$ver.zip"
gh release create "v$ver" "$tmp/FileTransferStation-AppleSilicon-v$ver.zip" --title "v$ver" --notes "${1:-v$ver}"
rm -rf "$tmp"
