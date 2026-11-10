// 界面里共用的小零件：机器人预览、颜色、图标
import AppKit
import SwiftUI
import WebKit

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xaab2bd
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

func levelColor(_ level: String) -> Color {
    switch level {
    case "ok": return Color(hex: "#30c048")
    case "mid": return Color(hex: "#e2a400")
    case "low": return Color(hex: "#ff453a")
    default: return .secondary
    }
}

/// 机器人屏幕的预览（用和固件一样的画法，在网页里画）
struct RobotPreview: NSViewRepresentable {
    var state: String = "calm"
    var overrides: [String: Any] = [:]
    @ObservedObject var model = AppModel.shared

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var pending: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending { webView.evaluateJavaScript("render(\(p))"); pending = nil }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero)
        w.navigationDelegate = context.coordinator
        w.setValue(false, forKey: "drawsBackground")
        if let u = Bundle.main.url(forResource: "preview", withExtension: "html") {
            w.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
        }
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        let s = model.settings
        let subs: [[String: Any]] = model.subs.filter { !$0.hidden }.map { sub in
            ["id": sub.id, "name": sub.name, "mono": sub.mono, "hue": sub.hue,
             "left": sub.shown?.left ?? -1, "label": sub.shown?.label ?? "", "reset": sub.shown?.reset ?? ""]
        }
        var icons: [String: String] = [:]
        if s.showIcons {
            for id in model.subs.map({ $0.id }) + ["claude"] where icons[id] == nil {
                if let u = IconStore.pngDataURL(id, size: 56, dark: s.theme != "light") { icons[id] = u }
            }
            if let u = IconStore.pngDataURL("claude", size: 56, dark: true) { icons["alert"] = u }
        }
        var p: [String: Any] = [
            "state": state, "home": s.homeStyle, "theme": s.theme, "icons": icons, "eye": s.eye, "eyeColor": s.eyeColor, "clock": s.clock, "used": s.showUsed,
            "blink": s.blink, "look": s.look, "lang": model.lang.rawValue, "subs": subs,
            "face": model.engine.faceIds(model.subs, s), "mid": s.midPercent, "low": s.lowPercent,
        ]
        for (k, v) in overrides { p[k] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: p), let js = String(data: d, encoding: .utf8) else { return }
        if context.coordinator.loaded { w.evaluateJavaScript("render(\(js))") } else { context.coordinator.pending = js }
    }
}

/// 外面套一圈黑色边框，看起来像机器人的屏幕
struct RobotScreen: View {
    var state = "calm"
    var width: CGFloat = 288
    var overrides: [String: Any] = [:]
    @ObservedObject var model = AppModel.shared
    var body: some View {
        RobotPreview(state: state, overrides: overrides)
            .frame(width: width, height: width * 0.75)
            .brightness(-0.35 + Double(model.settings.brightness) / 100 * 0.35)
            .padding(width / 30)
            .background(RoundedRectangle(cornerRadius: width / 22).fill(Color.black))
    }
}

/// 首页样式：四个缩略图，点一下就换
struct HomeStylePicker: View {
    @ObservedObject var model = AppModel.shared
    static let styles: [(String, String)] = [("A", "A 轻底栏"), ("B", "B 眼睛就是额度"), ("C", "C 说给你听"), ("D", "D 只有脸")]
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Self.styles, id: \.0) { st in
                Button { model.settings.homeStyle = st.0 } label: {
                    VStack(spacing: 5) {
                        RobotPreview(state: "calm", overrides: ["home": st.0, "look": false, "blink": false])
                            .frame(width: 96, height: 72)
                            .allowsHitTesting(false)
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.settings.homeStyle == st.0 ? Color.accentColor : Color.clear, lineWidth: 2.5))
                        Text(t(st.1)).font(.caption).foregroundStyle(model.settings.homeStyle == st.0 ? .primary : .secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}

/// 设置侧边栏里那种彩色小方块图标
struct SideIcon: View {
    var symbol: String
    var color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.gradient))
    }
}

/// 一排颜色圆点
struct Swatches: View {
    @Binding var selection: String
    var colors: [(String, String)]     // (值, 名字)；值为空 = 「跟随配色」/「关」
    var body: some View {
        HStack(spacing: 8) {
            ForEach(colors, id: \.0) { c in
                Button { selection = c.0 } label: {
                    ZStack {
                        Circle().fill(c.0.isEmpty ? AnyShapeStyle(LinearGradient(colors: [.white, Color(hex: "#9aa3ae")], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(hex: c.0)))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                        if selection == c.0 { Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 26, height: 26) }
                    }.frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(c.1)
            }
        }
    }
}

/// 订阅的小色块（CL、CX……）
struct MonoBadge: View {
    var mono: String
    var hue: String
    var size: CGFloat = 22
    var body: some View {
        Text(mono)
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: "#0b0e13"))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color(hex: hue)))
    }
}

/// 图标：有官方 logo 就用 logo，没有就用字母方块
struct BrandBadge: View {
    var id: String
    var mono: String
    var hue: String
    var size: CGFloat = 22
    @ObservedObject var model = AppModel.shared
    var body: some View {
        if model.settings.showIcons, let img = IconCache.image(id, dark: model.isDark) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        } else {
            MonoBadge(mono: mono, hue: hue, size: size)
        }
    }
}

enum IconCache {
    nonisolated(unsafe) private static var images: [String: NSImage] = [:]
    static func image(_ id: String, dark: Bool) -> NSImage? {
        let v = IconStore.version(id)
        guard !v.isEmpty else { return nil }
        let key = "\(id)|\(v)|\(dark)"
        if let i = images[key] { return i }
        let i = IconStore.image(id, dark: dark)
        images[key] = i
        return i
    }
}

struct QuotaBar: View {
    var value: Int
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(max(0, value)) / 100))
            }
        }.frame(height: 6)
    }
}

/// 菜单栏上的小机器人图标
enum MenuIcon {
    static func image(alert: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: alert ? 22 : 18, height: 14), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 16.5, height: 12.5), xRadius: 3.5, yRadius: 3.5)
            NSColor.black.setStroke()
            body.lineWidth = 1.5
            body.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 4.5, width: 2.6, height: 5), xRadius: 1.3, yRadius: 1.3).fill()
            NSBezierPath(roundedRect: NSRect(x: 10.9, y: 4.5, width: 2.6, height: 5), xRadius: 1.3, yRadius: 1.3).fill()
            if alert { NSBezierPath(ovalIn: NSRect(x: 17, y: 8, width: 5, height: 5)).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }
}

extension View {
    /// 打开一个窗口时把应用带到前面（菜单栏应用默认不在前台）
    func activateOnAppear() -> some View {
        onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}
