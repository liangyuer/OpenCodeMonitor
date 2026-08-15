#!/bin/bash
# 编译并打包 OpenCodeMonitor.app（产物在 dist/）
set -euo pipefail
cd "$(dirname "$0")"

rm -rf dist
mkdir -p dist/OpenCodeMonitor.app/Contents/MacOS dist/OpenCodeMonitor.app/Contents/Resources

echo "▶ 编译 main.swift ..."
swiftc -O -framework AppKit -o dist/OpenCodeMonitor.app/Contents/MacOS/OpenCodeMonitor main.swift

cp Info.plist dist/OpenCodeMonitor.app/Contents/Info.plist

# Apple Silicon 必须签名（ad-hoc 即可本机运行）
echo "▶ 签名 ..."
codesign --force --sign - dist/OpenCodeMonitor.app

echo "✅ 构建完成: $(pwd)/dist/OpenCodeMonitor.app"
echo "   运行: open $(pwd)/dist/OpenCodeMonitor.app   （或 ./install.sh 安装到 /Applications）"
