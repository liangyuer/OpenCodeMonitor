// 生成应用图标 AppIcon.icns（环形仪表盘风格：深色圆角底 + 绿色进度环）
// 用法: swift tools/make_icon.swift && mv AppIcon.icns <项目根>
import AppKit
import Foundation

func render(size: Int, to path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("rep") }
    rep.size = NSSize(width: CGFloat(size), height: CGFloat(size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let k = CGFloat(size) / 1024
    let inset: CGFloat = 60 * k
    let bgRect = NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
    NSColor(srgbRed: 0.118, green: 0.137, blue: 0.188, alpha: 1).setFill()  // #1e2330
    NSBezierPath(roundedRect: bgRect, xRadius: 205 * k, yRadius: 205 * k).fill()

    let center = NSPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    let radius: CGFloat = 322 * k
    let lw: CGFloat = 94 * k
    let ringRect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
    let track = NSBezierPath(ovalIn: ringRect)
    track.lineWidth = lw
    NSColor(srgbRed: 0.23, green: 0.26, blue: 0.33, alpha: 1).setStroke()  // 轨道 #3a4254
    track.stroke()

    // 进度弧约 62%，从 12 点方向顺时针（非翻转坐标系的标准配方）
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius,
                  startAngle: 90, endAngle: 90 - 360 * 0.62, clockwise: true)
    arc.lineWidth = lw
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 1).setStroke()  // 强调色 #3ddc84
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let setDir = URL(fileURLWithPath: "/tmp/AppIcon.iconset")
try? FileManager.default.removeItem(at: setDir)
try! FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)
for s in sizes {
    render(size: s.px, to: setDir.appendingPathComponent("\(s.name).png").path)
}
// 也输出一张 512 预览图便于查看
render(size: 512, to: "/tmp/appicon-preview.png")
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: out)
Process.launchedProcess(launchPath: "/usr/bin/iconutil", arguments: ["-c", "icns", setDir.path, "-o", out.path]).waitUntilExit()
print("生成完成: \(out.path)")
