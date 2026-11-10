// 订阅和 AI 工具的图标。
// 各家 logo 是它们的商标：仓库和安装包里不带，只在用户点「从官网获取」或自己选图片后，存在这台 Mac 上，发给自己的机器人显示。
// 存放：~/Library/Application Support/StackChan Butler/Icons/<id>-dark.svg|png（深色背景用）、<id>-light.…（浅色背景用，可选）
import AppKit
import CryptoKit
import Foundation

enum IconStore {
    static var dir: URL {
        let u = Paths.support.appendingPathComponent("Icons")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// AI 工具名 → 用哪一家的图标
    static func idForAgent(_ agent: String) -> String {
        switch agent {
        case "Claude Code": return "claude"
        case "Codex": return "codex"
        case "Cursor": return "cursor"
        case "OpenCode": return file("opencodego", dark: true) != nil ? "opencodego" : "opencode"
        case "Antigravity": return "antigravity"
        case "Gemini": return "antigravity"
        default: return ""
        }
    }

    static func file(_ id: String, dark: Bool) -> URL? {
        guard !id.isEmpty else { return nil }
        for v in dark ? ["dark"] : ["light", "dark"] {
            for ext in ["png", "svg", "jpg", "jpeg"] {
                let u = dir.appendingPathComponent("\(id)-\(v).\(ext)")
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }
    static func has(_ id: String) -> Bool { file(id, dark: true) != nil }

    /// 图标的版本号：文件变了，机器人就重新来取
    static func version(_ id: String) -> String {
        var parts: [String] = []
        for dark in [true, false] {
            if let u = file(id, dark: dark), let a = try? FileManager.default.attributesOfItem(atPath: u.path) {
                parts.append("\(u.lastPathComponent)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.size] ?? 0)")
            }
        }
        if parts.isEmpty { return "" }
        parts.append("trim3")       // 画法变了就换一个，机器人会重新来取
        let h = SHA256.hash(data: Data(parts.joined(separator: ";").utf8))
        return h.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func image(_ id: String, dark: Bool) -> NSImage? {
        guard let u = file(id, dark: dark) else { return nil }
        return NSImage(contentsOf: u)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    /// 画成 size×size 的像素，保持比例居中。返回每个像素 B、G、R、A（不预乘），给机器人用
    static func bgra(_ id: String, size: Int, dark: Bool) -> Data? {
        let key = "\(id)|\(size)|\(dark)|\(version(id))"
        if let d = cacheLock.withLock({ cache[key] }) { return d }
        guard let img = image(id, dark: dark), let rep = render(img, size: size) else { return nil }
        var out = Data(count: size * size * 4)
        out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            let o = p.bindMemory(to: UInt8.self)
            guard let src = rep.bitmapData else { return }
            for y in 0..<size {
                for x in 0..<size {
                    let s = y * rep.bytesPerRow + x * 4, d = (y * size + x) * 4
                    let r = src[s], g = src[s + 1], b = src[s + 2], a = src[s + 3]
                    func un(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(c) * 255 / Int(a))) }
                    o[d] = un(b); o[d + 1] = un(g); o[d + 2] = un(r); o[d + 3] = a
                }
            }
        }
        cacheLock.withLock { cache[key] = out }
        return out
    }

    /// 给界面（网页预览）用的 PNG
    static func pngDataURL(_ id: String, size: Int, dark: Bool) -> String? {
        guard let img = image(id, dark: dark), let rep = render(img, size: size),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// 把图片画进 side×side 的透明画布：整张图按比例缩放后，再按 (scale, center) 放大、平移
    private static func draw(_ img: NSImage, side: Int, scale: CGFloat = 1, center: CGPoint? = nil) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let s = CGFloat(side), w = max(img.size.width, 1), h = max(img.size.height, 1)
        let k = min(s / w, s / h)
        var r = NSRect(x: (s - w * k) / 2, y: (s - h * k) / 2, width: w * k, height: h * k)
        if let c = center {      // c 是「内容的中心」，用 0~1 表示（相对整张画布）；挪到正中再放大
            r = NSRect(x: (r.minX / s - c.x) * scale * s + s / 2, y: (r.minY / s - c.y) * scale * s + s / 2,
                       width: r.width * scale, height: r.height * scale)
        }
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 各家官网的 logo 四周留白差别很大（OpenAI 的结只占画布六成），直接缩放会一个大一个小。
    /// 这里先找出不透明的部分、去掉四周的空白，再按「看起来一样大」放进去：
    /// 圆形、镂空的 logo 放满，实心方块类的（不透明部分占满自己外框的）缩小一点，免得显得更大。
    private static func render(_ img: NSImage, size: Int) -> NSBitmapImageRep? {
        let P = 256
        guard let probe = draw(img, side: P), let px = probe.bitmapData else { return draw(img, side: size) }
        var x0 = P, y0 = P, x1 = -1, y1 = -1, ink = 0
        for y in 0..<P {
            for x in 0..<P where px[y * probe.bytesPerRow + x * 4 + 3] > 16 {
                ink += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0, y1 >= y0 else { return draw(img, side: size) }
        let bw = CGFloat(x1 - x0 + 1), bh = CGFloat(y1 - y0 + 1)
        let coverage = CGFloat(ink) / (bw * bh)                       // 外框里有多少是实心的
        let solid = min(1, max(0, (coverage - 0.5) / 0.45))
        let square = min(bw, bh) / max(bw, bh)                        // 越接近正方形，实心时看起来越大
        let fill = 0.98 - 0.18 * solid * square * square              // 放满到画布的几成
        let scale = fill * CGFloat(P) / max(bw, bh)
        // 位图的行是从上往下数的，画图坐标是从下往上
        let center = CGPoint(x: (CGFloat(x0) + bw / 2) / CGFloat(P), y: 1 - (CGFloat(y0) + bh / 2) / CGFloat(P))
        return draw(img, side: size, scale: scale, center: center)
    }

    /// 给 Mac 界面用：和机器人上一样去掉留白、统一大小
    static func normalizedImage(_ id: String, dark: Bool) -> NSImage? {
        guard let img = image(id, dark: dark), let rep = render(img, size: 128) else { return nil }
        let out = NSImage(size: NSSize(width: 64, height: 64))
        out.addRepresentation(rep)
        return out
    }

    // ---------- 用户自己选图片 / 换回字母 ----------
    static func importImage(_ id: String, from url: URL) -> Bool {
        guard NSImage(contentsOf: url) != nil else { return false }
        remove(id)
        let ext = url.pathExtension.lowercased()
        let dst = dir.appendingPathComponent("\(id)-dark.\(["png", "svg", "jpg", "jpeg"].contains(ext) ? ext : "png")")
        return (try? FileManager.default.copyItem(at: url, to: dst)) != nil
    }
    static func remove(_ id: String) {
        for v in ["dark", "light"] { for ext in ["png", "svg", "jpg", "jpeg"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id)-\(v).\(ext)")) } }
    }

    // ---------- 从各家官网获取官方图标 ----------
    struct Source {
        let ids: [String]
        let brand: String
        let url: String
        let zipDark: String?     // 压缩包里要的文件（按文件名结尾匹配）；nil 表示 url 本身就是图片
        let zipLight: String?
        let lightURL: String?
    }
    static let sources: [Source] = [
        .init(ids: ["claude"], brand: "Claude", url: "https://www.anthropic.com/press-kit", zipDark: "Claude Spark - Clay.svg", zipLight: nil, lightURL: nil),
        .init(ids: ["codex"], brand: "OpenAI / Codex", url: "https://cdn.openai.com/brand/openai-logos.zip", zipDark: "OAI_OpenAI-Blossom_White.svg", zipLight: "OAI_OpenAI-Blossom_Black.svg", lightURL: nil),
        .init(ids: ["cursor"], brand: "Cursor", url: "https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip", zipDark: "CUBE_2D_DARK.svg", zipLight: "CUBE_2D_LIGHT.svg", lightURL: nil),
        .init(ids: ["opencodego", "opencode"], brand: "OpenCode", url: "https://opencode.ai/brand/files/opencode-logo-dark.svg", zipDark: nil, zipLight: nil, lightURL: "https://opencode.ai/brand/files/opencode-logo-light.svg"),
        .init(ids: ["antigravity"], brand: "Antigravity", url: "https://antigravity.google/assets/image/brand/antigravity-icon__full-color.png", zipDark: nil, zipLight: nil, lightURL: nil),
    ]

    /// 逐家下载，progress(品牌, 结果)；结果为 nil 表示正在下载
    static func fetchOfficial(progress: @escaping (String, Bool?) -> Void) async {
        for src in sources {
            progress(src.brand, nil)
            let ok = await fetch(src)
            progress(src.brand, ok)
        }
    }

    private static func download(_ s: String) async -> URL? {
        guard let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 120
        guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent)
        try? FileManager.default.moveItem(at: tmp, to: keep)
        return keep
    }

    private static func unzipOne(_ zip: URL, suffix: String) -> URL? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = Shell.run("/usr/bin/unzip", ["-j", "-o", "-q", zip.path, "*" + suffix, "-d", out.path], timeout: 120)
        guard r.status == 0, let f = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasSuffix(suffix) }) else { return nil }
        return f
    }

    private static func place(_ file: URL, ids: [String], variant: String) -> Bool {
        guard NSImage(contentsOf: file) != nil else { return false }
        let ext = file.pathExtension.lowercased()
        for id in ids {
            if variant == "dark" { remove(id) }
            let dst = dir.appendingPathComponent("\(id)-\(variant).\(ext)")
            try? FileManager.default.removeItem(at: dst)
            guard (try? FileManager.default.copyItem(at: file, to: dst)) != nil else { return false }
        }
        return true
    }

    private static func fetch(_ s: Source) async -> Bool {
        guard let got = await download(s.url) else { return false }
        defer { try? FileManager.default.removeItem(at: got) }
        if let zd = s.zipDark {
            guard let dark = unzipOne(got, suffix: zd), place(dark, ids: s.ids, variant: "dark") else { return false }
            if let zl = s.zipLight, let light = unzipOne(got, suffix: zl) { _ = place(light, ids: s.ids, variant: "light") }
            return true
        }
        guard place(got, ids: s.ids, variant: "dark") else { return false }
        if let l = s.lightURL, let light = await download(l) { _ = place(light, ids: s.ids, variant: "light"); try? FileManager.default.removeItem(at: light) }
        return true
    }
}
