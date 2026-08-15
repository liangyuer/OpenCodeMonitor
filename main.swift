// -*- coding: utf-8 -*-
// OpenCodeMonitor — macOS 菜单栏版
// 依照 github.com/Hanfei1224/OpenCodeMonitor（Windows 磁贴版）移植：
// 常驻状态栏，随时查看 OpenCode Go 订阅的剩余配额（5 小时 / 本周 / 本月），
// 并统计本机今日 token 消耗（opencode.db + Claude Code 会话记录）。
//
// 配额数据源：官方接口 GET https://opencode.ai/zen/go/v1/usage
//   认证同时携带 Authorization: Bearer 与 x-api-key 两个请求头，
//   返回 {"usage":{"rolling":{percent,resetsAt},...}}（percent 为 0–100 整数）。
// 官方美元配额：5 小时=$12、每周=$30、每月=$60（opencode.ai/docs/go）。

import AppKit
import Foundation
import Darwin
import SQLite3

let APP_VERSION = "1.3.0"
let USAGE_URL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
let DASHBOARD_URL = URL(string: "https://opencode.ai/zen")!
let PLAN_DEFAULT = "OpenCode Go"

// 三个配额窗口：key=接口字段名，limit=官方美元配额，mode=重置倒计时显示粒度
let WINDOWS: [(key: String, name: String, limit: Double, mode: String)] = [
    ("rolling", "5 小时", 12, "minute"),
    ("weekly", "本周", 30, "hour"),
    ("monthly", "本月", 60, "hour"),
]

// MARK: - 配置（与 Windows 版 config.json 同构，多了两个状态栏显示选项）

struct Config: Codable {
    var api_key = ""
    var plan_name = PLAN_DEFAULT
    var refresh_seconds = 60      // 配额刷新间隔（秒）
    var title_window = "monthly"  // 状态栏显示哪个窗口：rolling / weekly / monthly
    var title_remaining = true    // 状态栏显示剩余(true)还是已用(false)
    var accent_color = "#3ddc84"  // 环形图强调色（默认亮绿，与官网仪表盘一致）
    var ring_show_details = false // 圆环下方是否显示具体数值（倒计时/已用/剩余），默认隐藏
    var show_window_rows = false  // 菜单中是否显示三窗口明细行（已用%/剩余$），默认隐藏

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api_key = (try? c.decode(String.self, forKey: .api_key)) ?? ""
        plan_name = (try? c.decode(String.self, forKey: .plan_name)) ?? PLAN_DEFAULT
        refresh_seconds = (try? c.decode(Int.self, forKey: .refresh_seconds)) ?? 60
        title_window = (try? c.decode(String.self, forKey: .title_window)) ?? "monthly"
        title_remaining = (try? c.decode(Bool.self, forKey: .title_remaining)) ?? true
        accent_color = (try? c.decode(String.self, forKey: .accent_color)) ?? "#3ddc84"
        ring_show_details = (try? c.decode(Bool.self, forKey: .ring_show_details)) ?? false
        show_window_rows = (try? c.decode(Bool.self, forKey: .show_window_rows)) ?? false
        if !["rolling", "weekly", "monthly"].contains(title_window) { title_window = "monthly" }
        refresh_seconds = min(max(refresh_seconds, 5), 3600)
    }
}

func configDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("OpenCodeMonitor", isDirectory: true)
}

func configFile() -> URL { configDir().appendingPathComponent("config.json") }

func loadConfig() -> Config {
    do {
        let data = try Data(contentsOf: configFile())
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        return Config()
    }
}

func saveConfig(_ cfg: Config) {
    do {
        try FileManager.default.createDirectory(at: configDir(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: configFile(), options: .atomic)
    } catch {
        NSLog("OpenCodeMonitor: 配置保存失败 \(error)")
    }
}

/// 未配置 key 时，尝试从 opencode 自己的 auth.json 自动导入（type=api 的 opencode-go / opencode 条目）
func importKeyFromOpencodeAuth() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent(".local/share/opencode/auth.json"),
        home.appendingPathComponent("Library/Application Support/opencode/auth.json"),
    ]
    for url in candidates {
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        for entryName in ["opencode-go", "opencode"] {
            if let e = j[entryName] as? [String: Any],
               (e["type"] as? String) == "api",
               let key = e["key"] as? String, key.hasPrefix("sk-") {
                return key
            }
        }
    }
    return nil
}

// MARK: - 用量接口模型

struct WindowUsage: Codable {
    var percent: Double?
    var resetsAt: String?
    var status: String?

    init(percent: Double?, resetsAt: String?, status: String? = nil) {
        self.percent = percent; self.resetsAt = resetsAt; self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 官方返回整数百分比，兼容 Int / Double 两种编码
        if let i = try? c.decode(Int.self, forKey: .percent) { percent = Double(i) }
        else if let d = try? c.decode(Double.self, forKey: .percent) { percent = d }
        resetsAt = try? c.decode(String.self, forKey: .resetsAt)
        status = try? c.decode(String.self, forKey: .status)
    }
}

struct RemoteError: Codable {
    var type: String?
    var message: String?
}

struct UsageResponse: Codable {
    var usage: [String: WindowUsage]?
    var error: RemoteError?
}

/// 同步拉取用量（须在后台线程调用）。返回 (数据, 耗时ms, 错误描述)
func fetchUsage(apiKey: String) -> (UsageResponse?, Int?, String?) {
    var req = URLRequest(url: USAGE_URL)
    req.timeoutInterval = 10
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    // 网关会拦掉默认 UA，模拟浏览器
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

    let sem = DispatchSemaphore(value: 0)
    var result: (UsageResponse?, Int?, String?) = (nil, nil, nil)
    let t0 = CFAbsoluteTimeGetCurrent()
    let task = URLSession.shared.dataTask(with: req) { data, resp, err in
        let latency = Int(round((CFAbsoluteTimeGetCurrent() - t0) * 1000))
        if let err {
            result = (nil, latency, err.localizedDescription)
        } else if let http = resp as? HTTPURLResponse {
            let body = data.flatMap { try? JSONDecoder().decode(UsageResponse.self, from: $0) }
            if http.statusCode == 200 {
                result = (body, latency, nil)
            } else {
                // 优先展示接口返回的错误信息（如 "OpenCode Go subscription required."）
                if let msg = body?.error?.message, !msg.isEmpty {
                    result = (nil, latency, msg)
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    result = (nil, latency, "API Key 无效或无订阅权限")
                } else {
                    result = (nil, latency, "HTTP \(http.statusCode)")
                }
            }
        } else {
            result = (nil, latency, "未知网络错误")
        }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 15)
    return result
}

// MARK: - 今日 token 统计（opencode.db + Claude Code JSONL）

struct TokenRow {
    var ms: Int64
    var total: Int
    var input: Int
    var output: Int
    var cacheRead: Int
}

struct TodayStats {
    var total = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var requests = 0
    var hitRate: Double {
        let denom = cacheRead + input
        return denom > 0 ? Double(cacheRead) / Double(denom) : 0
    }
}

func isoToMs(_ s: String) -> Int64? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
    let f2 = ISO8601DateFormatter()
    if let d = f2.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
    return nil
}

/// opencode 本地库 message 表：data JSON 含 tokens/total、time/created（毫秒）
func scanOpencodeDB(startMs: Int64, endMs: Int64) -> [TokenRow] {
    var rows: [TokenRow] = []
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent(".local/share/opencode/opencode.db").path,
        home.appendingPathComponent("Library/Application Support/opencode/opencode.db").path,
    ]
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM message WHERE json_extract(data, '$.tokens') IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0),
                  let data = String(cString: UnsafePointer(ptr)).data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toks = j["tokens"] as? [String: Any],
                  let total = toks["total"] as? Int, total > 0,
                  let t = j["time"] as? [String: Any],
                  let created = (t["created"] as? NSNumber)?.int64Value,
                  created >= startMs, created < endMs else { continue }
            let cache = toks["cache"] as? [String: Any]
            rows.append(TokenRow(
                ms: created, total: total,
                input: toks["input"] as? Int ?? 0,
                output: toks["output"] as? Int ?? 0,
                cacheRead: cache?["read"] as? Int ?? 0))
        }
    }
    return rows
}

/// Claude Code 会话记录 ~/.claude/projects/**/*.jsonl：assistant 消息的 usage
/// total = input + output + cache_creation + cache_read
func scanClaudeJSONL(startMs: Int64, endMs: Int64) -> [TokenRow] {
    var rows: [TokenRow] = []
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) else { return rows }
    for case let url as URL in en {
        guard url.pathExtension == "jsonl" else { continue }
        guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? fh.close() }
        let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("{") else { continue }
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (j["type"] as? String) == "assistant",
                  let msg = j["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any],
                  let tsStr = j["timestamp"] as? String,
                  let ms = isoToMs(tsStr), ms >= startMs, ms < endMs else { continue }
            let inp = u["input_tokens"] as? Int ?? 0
            let out = u["output_tokens"] as? Int ?? 0
            let cw = u["cache_creation_input_tokens"] as? Int ?? 0
            let cr = u["cache_read_input_tokens"] as? Int ?? 0
            let total = inp + out + cw + cr
            guard total > 0 else { continue }
            rows.append(TokenRow(ms: ms, total: total, input: inp, output: out, cacheRead: cr))
        }
    }
    return rows
}

func collectStats(from start: Date, to end: Date) -> TodayStats? {
    let sMs = Int64(start.timeIntervalSince1970 * 1000)
    let eMs = Int64(end.timeIntervalSince1970 * 1000)
    var rows = scanOpencodeDB(startMs: sMs, endMs: eMs)
    rows += scanClaudeJSONL(startMs: sMs, endMs: eMs)
    guard !rows.isEmpty else { return nil }
    var ts = TodayStats()
    for r in rows {
        ts.total += r.total; ts.input += r.input
        ts.output += r.output; ts.cacheRead += r.cacheRead; ts.requests += 1
    }
    return ts
}

func collectTodayStats() -> TodayStats? {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
    return collectStats(from: start, to: end)
}

// MARK: - 格式化（与 Windows 版口径一致）

func fmtNum(_ n: Int) -> String {
    if n < 10000 { return String(n) }
    let k = Int((Double(n) / 1000).rounded())
    if k < 10000 { return "\(k)k" }
    let m = Int((Double(n) / 1_000_000).rounded())
    if m < 10000 { return "\(m)M" }
    return "\(Int((Double(n) / 1_000_000_000).rounded()))B"
}

func fmtUSD(_ v: Double) -> String { String(format: "$%.2f", v) }

func fmtReset(_ iso: String?, mode: String) -> String {
    guard let iso, let ms = isoToMs(iso) else { return "–" }
    let remain = ms - Int64(Date().timeIntervalSince1970 * 1000)
    if remain <= 0 { return "即将重置" }
    let totalMin = Int((Double(remain) / 60000).rounded())
    if mode == "minute" {
        let h = totalMin / 60, m = totalMin % 60
        if h == 0 { return "\(m) 分钟后重置" }
        if m == 0 { return "\(h) 小时后重置" }
        return "\(h) 小时 \(m) 分后重置"
    }
    let totalH = Int((Double(totalMin) / 60).rounded())
    let d = totalH / 24, h = totalH % 24
    if d == 0 { return "\(h) 小时后重置" }
    if h == 0 { return "\(d) 天后重置" }
    return "\(d) 天 \(h) 小时后重置"
}

// MARK: - 环形配额卡片（菜单顶部自定义视图，风格参照官网仪表盘）

extension NSColor {
    convenience init(hexString: String, fallback: NSColor = NSColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1)) {
        let h = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 6, let v = UInt32(h, radix: 16) {
            self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                      green: CGFloat((v >> 8) & 0xFF) / 255,
                      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        } else {
            self.init(cgColor: fallback.cgColor)!
        }
    }
}

/// 三环配额图：环中心百分比；showDetails=false 时仅显示窗口名（默认，紧凑），
/// true 时额外显示名称下方倒计时 / 已用美元 / 剩余美元
final class RingCardView: NSView {
    var usage: [String: WindowUsage]?
    var accent: NSColor = NSColor(hexString: "#3ddc84")
    var showDetails = false

    override var isFlipped: Bool { true }  // 自上而下布局

    func update(usage: [String: WindowUsage]?, accent: NSColor, showDetails: Bool) {
        self.usage = usage
        self.accent = accent
        self.showDetails = showDetails
        needsDisplay = true
    }

    private func ringColor(_ p: Double) -> NSColor {
        if p >= 90 { return .systemRed }
        if p >= 70 { return .systemOrange }
        return accent
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 深色圆角卡片
        let card = bounds.insetBy(dx: 10, dy: 9)
        NSColor(srgbRed: 0.118, green: 0.137, blue: 0.188, alpha: 1).setFill()  // #1e2330
        NSBezierPath(roundedRect: card, xRadius: 13, yRadius: 13).fill()

        let slotW = card.width / CGFloat(WINDOWS.count)
        for (i, w) in WINDOWS.enumerated() {
            let cx = card.minX + slotW * (CGFloat(i) + 0.5)
            let p = usage?[w.key]?.percent
            if showDetails {
                drawRing(center: NSPoint(x: cx, y: card.minY + 52), pct: p)
                drawTexts(w, p: p, cx: cx, cardMinY: card.minY)
            } else {
                drawRing(center: NSPoint(x: cx, y: card.minY + 42), pct: p)
                drawName(w.name, cx: cx, y: card.minY + 78)
            }
        }
    }

    private func drawName(_ name: String, cx: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var a = attrs
        a[.paragraphStyle] = style
        (name as NSString).draw(in: NSRect(x: cx - 60, y: y, width: 120, height: 16), withAttributes: a)
    }

    private func drawRing(center: NSPoint, pct: Double?) {
        let radius: CGFloat = 29, lw: CGFloat = 7
        let rect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        // 轨道
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lw
        NSColor(srgbRed: 0.23, green: 0.26, blue: 0.33, alpha: 1).setStroke()  // #3a4254
        track.stroke()
        // 进度弧（从 12 点方向顺时针；flipped 视图下角度取负）
        if let pct, pct > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: -90, endAngle: -90 + 360 * min(pct, 100) / 100,
                          clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            ringColor(pct).setStroke()
            arc.stroke()
        }
        // 中心百分比
        let text = pct.map { "\(Int($0.rounded()))%" } ?? "–"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let tr = NSRect(x: center.x - 60, y: center.y - size.height / 2,
                        width: 120, height: size.height)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var centered = attrs
        centered[.paragraphStyle] = style
        (text as NSString).draw(in: tr, withAttributes: centered)
    }

    private func drawTexts(_ w: (key: String, name: String, limit: Double, mode: String),
                           p: Double?, cx: CGFloat, cardMinY: CGFloat) {
        func line(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
            ]
            let h = s.size(withAttributes: attrs).height
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            var a = attrs
            a[.paragraphStyle] = style
            (s as NSString).draw(in: NSRect(x: cx - 60, y: y, width: 120, height: h + 2),
                                 withAttributes: a)
        }
        let reset = fmtReset(usage?[w.key]?.resetsAt, mode: w.mode)
        line(w.name, y: cardMinY + 101, size: 12.5, weight: .bold, color: .white)
        line(reset, y: cardMinY + 121, size: 10, weight: .regular,
             color: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.74, alpha: 1))
        if let p {
            let used = p / 100 * w.limit
            line("已用 \(fmtUSD(used)) / \(fmtUSD(w.limit))", y: cardMinY + 138,
                 size: 10, weight: .medium, color: .white)
            line("剩余 \(fmtUSD(w.limit - used))", y: cardMinY + 154,
                 size: 10, weight: .medium, color: ringColor(p))
        } else {
            line("已用 – / \(fmtUSD(w.limit))", y: cardMinY + 138, size: 10, weight: .medium, color: .white)
            line("剩余 –", y: cardMinY + 154, size: 10, weight: .medium, color: ringColor(0))
        }
    }
}

// MARK: - 应用状态与菜单构建

struct AppState {
    var config = Config()
    var usage: [String: WindowUsage]?
    var lastRefresh: Date?
    var latencyMs: Int?
    var errorMsg: String?
    var todayStats: TodayStats?
}

/// 状态栏显示模式（窗口 + 剩余/已用），挂在菜单项 representedObject 上
final class TitleMode: NSObject {
    let window: String
    let remaining: Bool
    init(window: String, remaining: Bool) { self.window = window; self.remaining = remaining }
}

@objc protocol MenuActions {
    func refreshNow()
    func openSetup()
    func copyWindow(_ sender: NSMenuItem)
    func copyToday(_ sender: NSMenuItem)
    func setRefresh(_ sender: NSMenuItem)
    func setTitleMode(_ sender: NSMenuItem)
    func setAccent(_ sender: NSMenuItem)
    func toggleRingDetails()
    func toggleWindowRows()
    func openDashboard()
    func quitApp()
}

/// 纯菜单构建器：AppDelegate 与 --print-menu 共用，便于无 GUI 验证
enum MenuBuilder {
    static func build(state: AppState, target: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let cfg = state.config

        let head = NSMenuItem(title: "\(cfg.plan_name) 配额监控 v\(APP_VERSION)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        // 环形配额图（自定义视图；明细默认隐藏，可在「设置」中开启）
        let ringItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let ringH: CGFloat = cfg.ring_show_details ? 188 : 118
        let ringView = RingCardView(frame: NSRect(x: 0, y: 0, width: 360, height: ringH))
        ringView.autoresizingMask = [.width]
        ringView.update(usage: state.usage, accent: NSColor(hexString: cfg.accent_color),
                        showDetails: cfg.ring_show_details)
        ringItem.view = ringView
        menu.addItem(ringItem)
        menu.addItem(.separator())

        if cfg.api_key.isEmpty {
            let item = NSMenuItem(title: "⚠︎ 未配置 API Key，点击设置", action: #selector(MenuActions.openSetup), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }

        // 三窗口明细行（默认隐藏，可在「设置」中开启）
        if cfg.show_window_rows {
            for w in WINDOWS {
                let item = NSMenuItem(title: windowLine(state: state, key: w.key),
                                      action: #selector(MenuActions.copyWindow(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = w.key
                let sub = NSMenu()
                let p = state.usage?[w.key]?.percent
                if let p {
                    let used = p / 100 * w.limit
                    addDisabled(sub, "已用 \(fmtUSD(used)) / \(fmtUSD(w.limit))")
                    addDisabled(sub, "剩余 \(fmtUSD(w.limit - used))")
                    addDisabled(sub, "重置倒计时：\(fmtReset(state.usage?[w.key]?.resetsAt, mode: w.mode))")
                    let cp = NSMenuItem(title: "复制本行详情", action: #selector(MenuActions.copyWindow(_:)), keyEquivalent: "")
                    cp.target = target
                    cp.representedObject = w.key
                    sub.addItem(cp)
                } else {
                    addDisabled(sub, "暂无数据")
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }

        var hasBody = false
        if let ts = state.todayStats, ts.total > 0 {
            let t = NSMenuItem(
                title: "今日 token  总 \(fmtNum(ts.total)) · 输入 \(fmtNum(ts.input))"
                    + " · 输出 \(fmtNum(ts.output)) · 缓存 \(fmtNum(ts.cacheRead))"
                    + " · 缓存率 \(String(format: "%.1f", ts.hitRate * 100))%",
                action: #selector(MenuActions.copyToday(_:)), keyEquivalent: "")
            t.target = target
            menu.addItem(t)
            hasBody = true
        }
        if cfg.show_window_rows { hasBody = true }
        if hasBody { menu.addItem(.separator()) }

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(MenuActions.refreshNow), keyEquivalent: "r")
        refresh.target = target
        menu.addItem(refresh)
        let dash = NSMenuItem(title: "打开官网仪表盘", action: #selector(MenuActions.openDashboard), keyEquivalent: "")
        dash.target = target
        menu.addItem(dash)

        menu.addItem(.separator())
        // 「设置」子菜单：API Key / 圆环明细 / 刷新间隔 / 状态栏显示 / 环图颜色
        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let sSub = NSMenu()

        let setup = NSMenuItem(title: "设置 API Key…", action: #selector(MenuActions.openSetup), keyEquivalent: "")
        setup.target = target
        sSub.addItem(setup)

        let ringDetail = NSMenuItem(title: "显示圆环明细", action: #selector(MenuActions.toggleRingDetails), keyEquivalent: "")
        ringDetail.target = target
        ringDetail.state = cfg.ring_show_details ? .on : .off
        sSub.addItem(ringDetail)

        let windowRows = NSMenuItem(title: "显示窗口明细行", action: #selector(MenuActions.toggleWindowRows), keyEquivalent: "")
        windowRows.target = target
        windowRows.state = cfg.show_window_rows ? .on : .off
        sSub.addItem(windowRows)

        sSub.addItem(.separator())

        let ri = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let riSub = NSMenu()
        for s in [5, 10, 30, 60] {
            let it = NSMenuItem(title: "\(s) 秒", action: #selector(MenuActions.setRefresh(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = s
            it.state = cfg.refresh_seconds == s ? .on : .off
            riSub.addItem(it)
        }
        ri.submenu = riSub
        sSub.addItem(ri)

        let tw = NSMenuItem(title: "状态栏显示", action: nil, keyEquivalent: "")
        let twSub = NSMenu()
        let modes: [(String, String, Bool)] = [
            ("monthly", "本月", true), ("monthly", "本月", false),
            ("weekly", "本周", true), ("rolling", "5 小时", true),
        ]
        for (key, name, remaining) in modes {
            let it = NSMenuItem(title: "\(name)\(remaining ? "剩余" : "已用") %",
                                action: #selector(MenuActions.setTitleMode(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = TitleMode(window: key, remaining: remaining)
            it.state = (cfg.title_window == key && cfg.title_remaining == remaining) ? .on : .off
            twSub.addItem(it)
        }
        tw.submenu = twSub
        sSub.addItem(tw)

        let ac = NSMenuItem(title: "环图颜色", action: nil, keyEquivalent: "")
        let acSub = NSMenu()
        let accents: [(String, String)] = [
            ("绿色", "#3ddc84"), ("蓝色", "#5b9bff"), ("橙色", "#ff9f0a"),
            ("紫色", "#bf5af2"), ("红色", "#ff5f57"),
        ]
        for (name, hex) in accents {
            let it = NSMenuItem(title: name, action: #selector(MenuActions.setAccent(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = hex
            it.state = cfg.accent_color.lowercased() == hex ? .on : .off
            acSub.addItem(it)
        }
        ac.submenu = acSub
        sSub.addItem(ac)

        settings.submenu = sSub
        menu.addItem(settings)

        menu.addItem(.separator())
        var statusLine = "尚未刷新"
        if let lr = state.lastRefresh {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            statusLine = "上次刷新 \(f.string(from: lr))"
            if let lat = state.latencyMs { statusLine += " · 响应 \(lat) ms" }
        }
        let st = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        if let err = state.errorMsg {
            let e = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            e.attributedTitle = NSAttributedString(
                string: "获取失败：\(err)",
                attributes: [.foregroundColor: NSColor.systemRed])
            e.isEnabled = false
            menu.addItem(e)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 OpenCodeMonitor", action: #selector(MenuActions.quitApp), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
        return menu
    }

    private static func addDisabled(_ menu: NSMenu, _ title: String) {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
    }

    private static func windowLine(state: AppState, key: String) -> String {
        let meta = WINDOWS.first { $0.key == key }!
        guard let w = state.usage?[key], let p = w.percent else {
            return "\(meta.name)：–"
        }
        let used = p / 100 * meta.limit
        return "\(meta.name)：已用 \(Int(p.rounded()))% · 剩 \(fmtUSD(meta.limit - used))"
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, MenuActions {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var config = loadConfig()
    private var usage: [String: WindowUsage]?
    private var lastRefresh: Date?
    private var latencyMs: Int?
    private var errorMsg: String?
    private var todayStats: TodayStats?
    private var statsThrottle = Date.distantPast
    private var fetching = false
    private var flashRestore: DispatchWorkItem?

    private var setupPanel: NSPanel?
    private var setupKeyField: NSSecureTextField?
    private var setupStatusLabel: NSTextField?

    private var state: AppState {
        AppState(config: config, usage: usage, lastRefresh: lastRefresh,
                 latencyMs: latencyMs, errorMsg: errorMsg, todayStats: todayStats)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 纯菜单栏应用，不占 Dock
        if config.api_key.isEmpty, let k = importKeyFromOpencodeAuth() {
            config.api_key = k
            saveConfig(config)
        }
        setupStatusItem()
        startTimer()
        refreshNow()
        if config.api_key.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openSetup() }
        }
    }

    // MARK: 状态栏外观

    private func setupStatusItem() {
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "OpenCodeMonitor") {
                img.isTemplate = true
                btn.image = img
                btn.imagePosition = .imageLeading
            }
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        }
        updateTitle()
        rebuildMenu()
    }

    private func updateTitle() {
        guard let btn = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        if let w = usage?[config.title_window], let p = w.percent {
            let shown = config.title_remaining ? 100 - p : p
            let color: NSColor = p >= 90 ? .systemRed : (p >= 70 ? .systemOrange : .labelColor)
            btn.attributedTitle = NSAttributedString(string: "\(Int(shown.rounded()))%",
                                                     attributes: [.font: font, .foregroundColor: color])
        } else if errorMsg != nil {
            btn.attributedTitle = NSAttributedString(string: "OC !",
                                                     attributes: [.font: font, .foregroundColor: NSColor.systemRed])
        } else {
            btn.attributedTitle = NSAttributedString(string: "OC",
                                                     attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        btn.toolTip = makeTooltip()
    }

    private func makeTooltip() -> String {
        var lines = ["\(config.plan_name) 配额监控 v\(APP_VERSION)"]
        if let usage {
            for w in WINDOWS {
                if let ww = usage[w.key], let p = ww.percent {
                    let used = p / 100 * w.limit
                    lines.append("\(w.name) 已用 \(Int(p.rounded()))% · 剩余 \(fmtUSD(w.limit - used))"
                        + " · \(fmtReset(ww.resetsAt, mode: w.mode))")
                }
            }
        } else if let errorMsg {
            lines.append("获取失败：\(errorMsg)")
        } else if config.api_key.isEmpty {
            lines.append("未配置 API Key，点击菜单「设置 API Key…」")
        } else {
            lines.append("获取中…")
        }
        if let ts = todayStats, ts.total > 0 {
            lines.append("今日 token：总 \(fmtNum(ts.total)) · 输入 \(fmtNum(ts.input))"
                + " · 输出 \(fmtNum(ts.output)) · 缓存率 \(String(format: "%.1f", ts.hitRate * 100))%")
        }
        return lines.joined(separator: "\n")
    }

    private func rebuildMenu() {
        statusItem.menu = MenuBuilder.build(state: state, target: self)
    }

    // MARK: 刷新

    @objc func refreshNow() {
        guard !fetching else { return }
        fetching = true
        let key = config.api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.fetching = false }
            var resp: UsageResponse?
            var lat: Int?
            var err: String?
            if key.isEmpty {
                err = "config_missing"
            } else {
                (resp, lat, err) = fetchUsage(apiKey: key)
            }
            var ts: TodayStats?
            if let self, Date().timeIntervalSince(self.statsThrottle) >= 60 {
                self.statsThrottle = Date()
                ts = collectTodayStats()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.latencyMs = lat
                    if err == "config_missing" {
                        self.usage = nil; self.errorMsg = nil; self.lastRefresh = nil
                    } else {
                        // 失败时保留上次成功的数据，仅在菜单里提示错误
                        self.errorMsg = err; self.lastRefresh = Date()
                    }
                } else {
                    self.usage = resp?.usage
                    self.errorMsg = nil
                    self.lastRefresh = Date()
                    self.latencyMs = lat
                }
                if let ts { self.todayStats = ts }
                self.rebuildMenu()
                self.updateTitle()
                self.debugLog()
            }
        }
    }

    /// OPENCODE_DEBUG_LOG=<path> 时，每次刷新追加一行状态（排障用）
    private func debugLog() {
        guard let path = ProcessInfo.processInfo.environment["OPENCODE_DEBUG_LOG"] else { return }
        let title = statusItem.button?.attributedTitle.string ?? "?"
        let entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "title": title,
            "error": errorMsg as Any,
            "usage": (usage ?? [:]).mapValues { ["percent": $0.percent as Any, "resetsAt": $0.resetsAt as Any] },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: entry),
           let line = String(data: d, encoding: .utf8) {
            let fh = FileHandle(forWritingAtPath: path)
            if fh == nil { FileManager.default.createFile(atPath: path, contents: nil) }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write((line + "\n").data(using: .utf8)!)
                try? fh.close()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(max(5, config.refresh_seconds)), repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 菜单动作

    @objc func setRefresh(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Int else { return }
        config.refresh_seconds = s
        saveConfig(config)
        startTimer()
        rebuildMenu()
    }

    @objc func setTitleMode(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? TitleMode else { return }
        config.title_window = m.window
        config.title_remaining = m.remaining
        saveConfig(config)
        rebuildMenu()
        updateTitle()
    }

    @objc func setAccent(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        config.accent_color = hex
        saveConfig(config)
        rebuildMenu()
    }

    @objc func toggleRingDetails() {
        config.ring_show_details.toggle()
        saveConfig(config)
        rebuildMenu()
    }

    @objc func toggleWindowRows() {
        config.show_window_rows.toggle()
        saveConfig(config)
        rebuildMenu()
    }

    @objc func openDashboard() { NSWorkspace.shared.open(DASHBOARD_URL) }

    @objc func copyWindow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let meta = WINDOWS.first(where: { $0.key == key }) else { return }
        var s = "\(config.plan_name) \(meta.name)配额："
        if let w = usage?[key], let p = w.percent {
            let used = p / 100 * meta.limit
            s += "已用 \(Int(p.rounded()))%（\(fmtUSD(used)) / \(fmtUSD(meta.limit))），剩余 \(fmtUSD(meta.limit - used))"
            let r = fmtReset(w.resetsAt, mode: meta.mode)
            if r != "–" { s += "，\(r)" }
        } else {
            s += "暂无数据"
        }
        copyToClipboard(s)
    }

    @objc func copyToday(_ sender: NSMenuItem) {
        guard let ts = todayStats else { return }
        copyToClipboard("今日 token：总 \(fmtNum(ts.total)) · 输入 \(fmtNum(ts.input))"
            + " · 输出 \(fmtNum(ts.output)) · 缓存 \(fmtNum(ts.cacheRead))"
            + " · 请求 \(ts.requests) 次 · 缓存率 \(String(format: "%.1f", ts.hitRate * 100))%")
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        flashTitle("已复制 ✓")
    }

    private func flashTitle(_ s: String) {
        flashRestore?.cancel()
        statusItem.button?.attributedTitle = NSAttributedString(
            string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                                    .foregroundColor: NSColor.labelColor])
        let w = DispatchWorkItem { [weak self] in self?.updateTitle() }
        flashRestore = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    // MARK: API Key 设置面板

    @objc func openSetup() {
        if let panel = setupPanel {
            setupStatusLabel?.stringValue = errorMsg.map { "上次请求失败：\($0)" } ?? ""
            panel.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }
        let W: CGFloat = 480, H: CGFloat = 210
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "设置 API Key"
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let hint = NSTextField(labelWithString: "填入 OpenCode Go 订阅的 API Key（sk-…），在 opencode.ai 的 Zen 设置中获取。")
        hint.frame = NSRect(x: 20, y: H - 62, width: W - 40, height: 40)
        hint.lineBreakMode = .byWordWrapping
        hint.usesSingleLineMode = false
        cv.addSubview(hint)

        let field = NSSecureTextField(frame: NSRect(x: 20, y: H - 100, width: W - 40, height: 26))
        field.placeholderString = "sk-opencode-…"
        field.stringValue = config.api_key
        cv.addSubview(field)

        let status = NSTextField(labelWithString: errorMsg.map { "上次请求失败：\($0)" } ?? "")
        status.frame = NSRect(x: 20, y: H - 126, width: W - 40, height: 18)
        status.textColor = .systemRed
        status.lineBreakMode = .byTruncatingTail
        cv.addSubview(status)

        let cancel = NSButton(title: "取消", target: self, action: #selector(closeSetup))
        cancel.frame = NSRect(x: W - 200, y: 14, width: 80, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        cv.addSubview(cancel)

        let save = NSButton(title: "保存并连接", target: self, action: #selector(saveKey))
        save.frame = NSRect(x: W - 108, y: 14, width: 88, height: 28)
        save.keyEquivalent = "\r"
        cv.addSubview(save)

        panel.contentView = cv
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activateApp()
        setupPanel = panel
        setupKeyField = field
        setupStatusLabel = status
    }

    @objc func closeSetup() { setupPanel?.orderOut(nil) }

    @objc func saveKey() {
        config.api_key = setupKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        saveConfig(config)
        setupPanel?.orderOut(nil)
        rebuildMenu()
        updateTitle()
        refreshNow()
    }

    private func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - 无 GUI 验证模式（--check / --print-menu）

func runCheck() {
    var cfg = loadConfig()
    var imported = false
    if cfg.api_key.isEmpty, let k = importKeyFromOpencodeAuth() {
        cfg.api_key = k; imported = true
    }
    var out: [String: Any] = [
        "key_configured": !cfg.api_key.isEmpty,
        "key_imported": imported,
        "plan_name": cfg.plan_name,
        "refresh_seconds": cfg.refresh_seconds,
    ]
    if cfg.api_key.isEmpty {
        out["error"] = "config_missing"
    } else {
        let (resp, lat, err) = fetchUsage(apiKey: cfg.api_key)
        if let err {
            out["error"] = err
            out["latency_ms"] = lat as Any
        } else {
            out["latency_ms"] = lat as Any
            if let usage = resp?.usage {
                var m: [String: Any] = [:]
                for w in WINDOWS {
                    if let ww = usage[w.key] {
                        m[w.key] = ["percent": ww.percent as Any, "resetsAt": ww.resetsAt as Any,
                                    "status": ww.status as Any]
                    }
                }
                out["usage"] = m
            } else {
                out["error"] = "usage field missing"
            }
        }
    }
    if let ts = collectTodayStats() {
        out["today_stats"] = [
            "total": ts.total, "input": ts.input, "output": ts.output,
            "cache_read": ts.cacheRead, "requests": ts.requests,
            "hit_rate": Double(round(ts.hitRate * 10000) / 10000),
        ]
    }
    if CommandLine.arguments.contains("--check-all") {
        // 调试模式：统计近 365 天（验证本地数据源扫描）
        let now = Date()
        if let ts = collectStats(from: Calendar.current.date(byAdding: .day, value: -365, to: now)!, to: now) {
            out["stats_365d"] = [
                "total": ts.total, "input": ts.input, "output": ts.output,
                "cache_read": ts.cacheRead, "requests": ts.requests,
                "hit_rate": Double(round(ts.hitRate * 10000) / 10000),
            ]
        }
    }
    let d = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
    print(String(decoding: d, as: UTF8.self))
}

func runPrintMenu() {
    _ = NSApplication.shared
    var cfg = loadConfig()
    if cfg.api_key.isEmpty, let k = importKeyFromOpencodeAuth() { cfg.api_key = k }
    var state = AppState(config: cfg)
    if ProcessInfo.processInfo.environment["OPENCODE_MOCK_USAGE"] == "1" {
        // 调试模式：注入示例数据，验证有配额时的菜单/标题渲染
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        state.usage = [
            "rolling": WindowUsage(percent: 12,
                                   resetsAt: iso.string(from: now.addingTimeInterval(3 * 3600 + 24 * 60))),
            "weekly": WindowUsage(percent: 9,
                                  resetsAt: iso.string(from: now.addingTimeInterval(2 * 86400 + 5 * 3600))),
            "monthly": WindowUsage(percent: 26,
                                   resetsAt: iso.string(from: now.addingTimeInterval(9 * 86400 + 2 * 3600))),
        ]
        state.latencyMs = 210
        state.errorMsg = nil
        state.lastRefresh = now
        state.todayStats = TodayStats()
        state.todayStats?.total = 123456
        state.todayStats?.input = 45000
        state.todayStats?.output = 12000
        state.todayStats?.cacheRead = 60000
        state.todayStats?.requests = 37
    } else if !cfg.api_key.isEmpty {
        let (resp, lat, err) = fetchUsage(apiKey: cfg.api_key)
        state.usage = resp?.usage
        state.latencyMs = lat
        state.errorMsg = err
        state.lastRefresh = Date()
    }
    if ProcessInfo.processInfo.environment["OPENCODE_MOCK_USAGE"] != "1" {
        state.todayStats = collectTodayStats()
    }
    let dummy = DummyTarget()
    let menu = MenuBuilder.build(state: state, target: dummy)
    // 预览状态栏标题
    let titlePreview: String = {
        if let w = state.usage?[cfg.title_window], let p = w.percent {
            let shown = cfg.title_remaining ? 100 - p : p
            return "[状态栏标题] \(Int(shown.rounded()))%"
                + (p >= 90 ? "（红）" : p >= 70 ? "（橙）" : "")
        }
        if state.errorMsg != nil { return "[状态栏标题] OC !" }
        return "[状态栏标题] OC"
    }()
    print(titlePreview)
    func dump(_ m: NSMenu, _ indent: String) {
        for it in m.items {
            var t = it.title
            if let att = it.attributedTitle { t = att.string }
            if it.view != nil { t = "⬡ [环形配额图视图]" }
            print("\(indent)\(t)\(it.submenu != nil ? " ▸" : "")")
            if let s = it.submenu { dump(s, indent + "    ") }
        }
    }
    withExtendedLifetime(dummy) { dump(menu, "") }
}

/// --snapshot <path>：把环形配额卡片渲染成 PNG（无 GUI 验证 / 预览用）
func runSnapshot(path: String) {
    _ = NSApplication.shared
    var cfg = loadConfig()
    if cfg.api_key.isEmpty, let k = importKeyFromOpencodeAuth() { cfg.api_key = k }
    var usage: [String: WindowUsage]?
    var errNote: String? = nil
    if cfg.api_key.isEmpty {
        errNote = "config_missing"
    } else {
        let (resp, _, err) = fetchUsage(apiKey: cfg.api_key)
        usage = resp?.usage
        errNote = err
    }
    if usage == nil, ProcessInfo.processInfo.environment["OPENCODE_MOCK_USAGE"] != "0" {
        // 无有效数据时用示例数据渲染，便于预览外观
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        usage = [
            "rolling": WindowUsage(percent: 11,
                                   resetsAt: iso.string(from: now.addingTimeInterval(1 * 3600 + 19 * 60))),
            "weekly": WindowUsage(percent: 24,
                                  resetsAt: iso.string(from: now.addingTimeInterval(3 * 86400 + 9 * 3600))),
            "monthly": WindowUsage(percent: 34,
                                   resetsAt: iso.string(from: now.addingTimeInterval(21 * 86400 + 21 * 3600))),
        ]
    }
    let v = RingCardView(frame: NSRect(x: 0, y: 0, width: 360,
                                       height: cfg.ring_show_details ? 188 : 118))
    v.update(usage: usage, accent: NSColor(hexString: cfg.accent_color),
             showDetails: cfg.ring_show_details)
    let pxW = Int(v.bounds.width * 2), pxH = Int(v.bounds.height * 2)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        print("render failed"); exit(1)
    }
    rep.size = v.bounds.size
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("png failed"); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("saved: \(path)  (数据来源: \(errNote == nil ? "实时接口" : "示例数据"), 错误: \(errNote ?? "无"))")
}

final class DummyTarget: NSObject, MenuActions {
    func refreshNow() {}
    func openSetup() {}
    func copyWindow(_ sender: NSMenuItem) {}
    func copyToday(_ sender: NSMenuItem) {}
    func setRefresh(_ sender: NSMenuItem) {}
    func setTitleMode(_ sender: NSMenuItem) {}
    func setAccent(_ sender: NSMenuItem) {}
    func toggleRingDetails() {}
    func toggleWindowRows() {}
    func openDashboard() {}
    func quitApp() {}
}

// MARK: - 启动

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    runSnapshot(path: args[i + 1])
    exit(0)
}
if args.contains("--check") {
    runCheck()
    exit(0)
}
if args.contains("--print-menu") {
    runPrintMenu()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
