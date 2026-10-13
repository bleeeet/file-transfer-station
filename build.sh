#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p build/文件中转站.app/Contents/MacOS build/文件中转站.app/Contents/Resources
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/Core.swift Sources/App.swift -o build/文件中转站.app/Contents/MacOS/Transfer -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework WebKit
cp Resources/BaiduPCS-Go Resources/BaiduPCS-Go-LICENSE Resources/BaiduLogo.png Resources/AppIcon.icns build/文件中转站.app/Contents/Resources/
chmod 755 build/文件中转站.app/Contents/Resources/BaiduPCS-Go
cp Resources/Info.plist build/文件中转站.app/Contents/Info.plist
codesign --force --deep --sign - build/文件中转站.app
