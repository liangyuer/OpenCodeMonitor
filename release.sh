#!/bin/bash
# 发行打包：编译 + 签名 + 生成 DMG / ZIP（产物在 release/）
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw dist/OpenCodeMonitor.app/Contents/Info.plist)

echo "▶ 校验签名与 bundle ..."
codesign --verify --deep --strict --verbose=2 dist/OpenCodeMonitor.app 2>&1 | tail -1
plutil -lint dist/OpenCodeMonitor.app/Contents/Info.plist

rm -rf release dmg_stage
mkdir -p release dmg_stage
cp -R dist/OpenCodeMonitor.app dmg_stage/
ln -s /Applications dmg_stage/Applications

echo "▶ 生成 DMG ..."
hdiutil create -volname "OpenCodeMonitor" -srcfolder dmg_stage -ov -format UDZO \
  "release/OpenCodeMonitor-${VERSION}.dmg" | tail -1

echo "▶ 生成 ZIP ..."
( cd dist && zip -r -q -X "../release/OpenCodeMonitor-${VERSION}.zip" OpenCodeMonitor.app )

rm -rf dmg_stage
echo "✅ 发行产物："
ls -lh release/
echo "   注意：本机 ad-hoc 签名未经 Apple 公证，他人下载需右键 → 打开 首次启动。"
