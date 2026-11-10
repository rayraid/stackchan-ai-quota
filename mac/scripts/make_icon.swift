// 画应用图标：深色圆角屏幕 + 两只发光的胶囊眼 + 底部三格额度
// 用法：swift scripts/make_icon.swift Resources/AppIcon.icns
import AppKit

func draw(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let s = size / 1024
        let inset = 100 * s
        let box = r.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: box, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSGradient(starting: NSColor(red: 0.12, green: 0.17, blue: 0.27, alpha: 1), ending: NSColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: path, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
        // 细边
        NSColor.white.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 4 * s
        path.stroke()
        // 眼睛
        let eyeW = 120 * s, eyeH = 168 * s
        for cx in [box.midX - 135 * s, box.midX + 135 * s] {
            let e = NSRect(x: cx - eyeW / 2, y: box.midY + 20 * s, width: eyeW, height: eyeH)
            for k in stride(from: 4, through: 1, by: -1) {
                let g = CGFloat(k) * 14 * s
                NSColor(red: 0.5, green: 0.76, blue: 1, alpha: 0.07).setFill()
                NSBezierPath(roundedRect: e.insetBy(dx: -g, dy: -g), xRadius: eyeW / 2 + g, yRadius: eyeW / 2 + g).fill()
            }
            NSColor(red: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: e, xRadius: eyeW / 2, yRadius: eyeW / 2).fill()
        }
        // 底部三格额度
        let colors = [NSColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1), NSColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1), NSColor(red: 0.96, green: 0.77, blue: 0.26, alpha: 1)]
        let fills: [CGFloat] = [0.74, 0.92, 0.35]
        let pw = 190 * s, gap = 28 * s
        let x0 = box.midX - (pw * 3 + gap * 2) / 2
        for i in 0..<3 {
            let pr = NSRect(x: x0 + CGFloat(i) * (pw + gap), y: box.minY + 150 * s, width: pw, height: 26 * s)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: pr, xRadius: 13 * s, yRadius: 13 * s).fill()
            colors[i].setFill()
            NSBezierPath(roundedRect: NSRect(x: pr.minX, y: pr.minY, width: pr.width * fills[i], height: pr.height), xRadius: 13 * s, yRadius: 13 * s).fill()
        }
        return true
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = draw(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "图标已生成：\(out)" : "iconutil 失败")
