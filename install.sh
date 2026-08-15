#!/bin/bash
# 一键安装到 /Applications（未构建则先构建）
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/OpenCodeMonitor.app"
if [ ! -d "$APP" ]; then
  ./build.sh
fi

echo "▶ 安装到 /Applications ..."
rm -rf /Applications/OpenCodeMonitor.app
cp -R "$APP" /Applications/
echo "✅ 已安装。首次运行：open /Applications/OpenCodeMonitor.app"
echo "   （开机自启：系统设置 → 通用 → 登录项 → 添加本应用）"
