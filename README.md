# OpenCodeMonitor for macOS

> [Hanfei1224/OpenCodeMonitor](https://github.com/Hanfei1224/OpenCodeMonitor)（Windows 磁贴版）的 macOS 移植 ——
> 常驻**菜单栏**的 OpenCode Go 配额监控，随时点开即查剩余配额。

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Tech](https://img.shields.io/badge/tech-Swift%20%2F%20AppKit-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## 简介

通过 OpenCode 官方用量接口 `GET https://opencode.ai/zen/go/v1/usage` 拉取 **OpenCode Go** 订阅
三个时间窗口的配额用量，常驻菜单栏展示：

- **5 小时（rolling）** 滚动窗口
- **本周（weekly）** 自然周
- **本月（monthly）** 订阅周期

状态栏标题默认显示**本月剩余百分比**（用量 ≥70% 变橙、≥90% 变红）；点击图标弹出菜单，顶部是一张
**环形配额图**（与官网仪表盘同风格：深色卡片上三个进度环，环中心为已用百分比、环下方仅窗口名，
紧凑干净；倒计时/已用/剩余等明细默认隐藏，可在「设置 → 显示圆环明细」开启）。三窗口文字明细行
也默认隐藏（「设置 → 显示窗口明细行」），菜单默认极简；悬停图标（tooltip）随时可看三窗口完整摘要。

菜单内还会显示**今日 token 统计**（总 / 输入 / 输出 / 缓存 / 缓存率），来自本机综合采集：
`opencode.db` + Claude Code 会话记录，监测程序未运行时产生的消耗下次启动也会自动补全。

## 功能特性

- 📊 状态栏实时百分比：剩余 / 已用可切换，可显示本月、本周或 5 小时窗口
- 🎯 **环形配额图**：菜单顶部三环并排（5 小时 / 本周 / 本月），环中心已用百分比；
  下方明细（倒计时/已用/剩余）默认隐藏，可在「设置」中开启；用量 ≥70% 该环变橙、
  ≥90% 变红，颜色可切换（绿/蓝/橙/紫/红）
- 🗂️ **极简菜单**：顶层只保留环形图、「立即刷新」「打开官网仪表盘」；三窗口明细行默认隐藏，
  API Key / 刷新间隔 / 状态栏显示 / 环图颜色等全部收进「设置」子菜单
- 💵 三窗口明细：开启「显示窗口明细行」后出现，点击行复制详情，子菜单含已用/剩余美元与重置倒计时（分钟/小时/天粒度）
- 📈 今日 token 统计：opencode.db + `~/.claude/projects/*.jsonl` 双数据源聚合
- 🔑 自动导入 API Key：优先读取 opencode 自己的 `auth.json`（`opencode-go` 条目），
  无需重复填写；也可在「设置 API Key…」面板手动填写/更换
- 🔄 自动刷新（5/10/30/60 秒可调）+ 手动「立即刷新」（⌘R），底部显示上次刷新时间与响应耗时
- 🖥️ 纯菜单栏应用（LSUIElement）：不占 Dock、不占桌面空间
- 🚫 无 Electron / 无 Python 依赖：单文件原生 Swift 二进制，内存占用极小

## 安装

```bash
# 本机已装 Xcode 命令行工具（swiftc）即可
git clone https://github.com/liangyuer/OpenCodeMonitor.git
cd OpenCodeMonitor
./build.sh          # 编译并打包到 dist/OpenCodeMonitor.app
./install.sh        # 可选：安装到 /Applications
open dist/OpenCodeMonitor.app
```

> 首次启动若本地有 opencode 登录信息（`~/.local/share/opencode/auth.json`）会自动导入 key；
> 否则弹出「设置 API Key」面板，填入 OpenCode Go 订阅的 key（`sk-…`）后点「保存并连接」。

**开机自启**：系统设置 → 通用 → 登录项与扩展 → 添加 `OpenCodeMonitor.app`。

## 截图

默认紧凑模式（仅窗口名）：

![环形配额图（紧凑）](preview/ring-compact.png)

「设置 → 显示圆环明细」开启后：

![环形配额图（明细）](preview/ring-details.png)

> 菜单顶部的环形配额图（实时数据渲染）。

## 使用

- **状态栏标题**：默认显示本月剩余百分比，颜色随用量变化（正常 / 橙 ≥70% / 红 ≥90%）
- **点击图标**：展开菜单，顶部环形图查看三窗口配额，下方查看今日 token；点击任一窗口行复制详情
- **⌘R**：立即刷新；**⌘Q** 或菜单「退出」：退出程序
- 菜单「设置」子菜单：API Key、显示圆环明细、显示窗口明细行、刷新间隔（5/10/30/60s）、状态栏显示、环图颜色

## 配置

配置文件位于 `~/Library/Application Support/OpenCodeMonitor/config.json`，首次运行自动生成：

| 键 | 类型 | 默认值 | 说明 |
| --- | ---- | ------ | ---- |
| `api_key` | string | `""` | OpenCode Go API Key（空则自动从 opencode auth.json 导入） |
| `plan_name` | string | `"OpenCode Go"` | 套餐名，显示在菜单头部 |
| `refresh_seconds` | int | `60` | 配额刷新间隔（秒） |
| `title_window` | string | `"monthly"` | 状态栏显示哪个窗口：`rolling` / `weekly` / `monthly` |
| `title_remaining` | bool | `true` | 状态栏显示剩余（true）还是已用（false）百分比 |
| `accent_color` | string | `"#3ddc84"` | 环形图强调色（也可在菜单「设置 → 环图颜色」中切换预设） |
| `ring_show_details` | bool | `false` | 圆环下方是否显示具体数值（倒计时/已用/剩余），默认隐藏 |
| `show_window_rows` | bool | `false` | 菜单中是否显示三窗口明细行（已用% / 剩余$），默认隐藏 |

## 数据来源与口径

- **配额（三窗口）**：官方接口 `GET https://opencode.ai/zen/go/v1/usage`，同时携带
  `Authorization: Bearer <key>` 与 `x-api-key: <key>` 两个请求头。接口返回 0–100 的整数
  `percent` 与 `resetsAt`；「已用美元」按官方配额换算：**5 小时 = $12、每周 = $30、每月 = $60**。
  key 未绑定 Go 订阅时接口返回 `EntitlementError`，菜单会原样显示该错误。
- **今日统计**：合并本机两个数据源按天聚合——
  - opencode 本地库 `~/.local/share/opencode/opencode.db`（或 `~/Library/Application Support/opencode/opencode.db`）message 表的 tokens 明细
  - Claude Code 会话记录 `~/.claude/projects/*.jsonl` 中 assistant 消息的 usage

  口径与 Windows 版一致：`total = input + output + cache_read + cache_write`，
  缓存率 = `cache_read ÷ (cache_read + input)`。

## 从源码构建

```bash
./build.sh    # swiftc -O 编译 + 打包 .app + ad-hoc 签名
```

调试/验证模式（无需 GUI）：

```bash
dist/OpenCodeMonitor.app/Contents/MacOS/OpenCodeMonitor --check        # 拉取一次并打印 JSON
dist/OpenCodeMonitor.app/Contents/MacOS/OpenCodeMonitor --print-menu   # 打印菜单结构
dist/OpenCodeMonitor.app/Contents/MacOS/OpenCodeMonitor --snapshot out.png  # 环形图渲染为 PNG
```

## 与 Windows 原版的差异

| Windows 磁贴版 | macOS 菜单栏版 |
| -------------- | -------------- |
| pywebview 悬浮窗口 + pystray 托盘 | 原生 NSStatusItem 菜单栏 |
| 三环用量图（HTML 磁贴） | 菜单顶部环形图（原生绘制） |
| 主题自定义（背景/透明度/强调色） | 环图颜色 5 种预设（系统原生菜单） |
| 置顶/鼠标穿透 | 菜单栏天然不遮挡 |
| 月度 token 日历窗口 | 今日 token 摘要（菜单内一行） |
| 手动填 API Key | 自动导入 + 手动填写均可 |

## 许可证

基于 [MIT License](LICENSE)，移植自 [Hanfei1224/OpenCodeMonitor](https://github.com/Hanfei1224/OpenCodeMonitor)。
