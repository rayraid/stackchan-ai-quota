// 开发调试：BUTLER_SNAPSHOT=<目录> 启动时，把各个界面离屏画成 PNG（不在屏幕上弹窗口），画完退出。
import AppKit
import SwiftUI
import WebKit

@MainActor
enum Snapshot {
    static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let l = ProcessInfo.processInfo.environment["BUTLER_LANG"].flatMap(Lang.init(rawValue:)) { currentLang = l; AppModel.shared.lang = l }
        var jobs: [(String, AnyView, NSSize)] = []
        for p in SettingsPage.allCases { jobs.append(("settings-\(p.rawValue)", AnyView(SettingsView(page: p)), NSSize(width: 820, height: 700))) }
        for i in 0..<8 { jobs.append(("wizard-\(i)", AnyView(WizardView(step: i)), NSSize(width: 820, height: 560))) }
        jobs.append(("menu", AnyView(MenuView().background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 340, height: 520)))
        var windows: [NSWindow] = []
        for (name, view, size) in jobs {
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            w.orderFrontRegardless()
            windows.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        // 机器人预览（网页）单独用 WebKit 自己的截图
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let holder = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        holder.contentView = web
        holder.orderFrontRegardless()
        if let u = Bundle.main.url(forResource: "preview", withExtension: "html") { web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        let states = ["calm", "approval", "done", "low", "list"]
        for (i, st) in states.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.5) {
                let m = AppModel.shared
                let subs: [[String: Any]] = m.subs.map { ["id": $0.id, "name": $0.name, "mono": $0.mono, "hue": $0.hue, "left": $0.shown?.left ?? -1, "label": $0.shown?.label ?? "", "reset": $0.shown?.reset ?? ""] }
                var icons: [String: String] = [:]
                for s in m.subs { if let u = IconStore.pngDataURL(s.id, size: 56, dark: true) { icons[s.id] = u } }
                if let u = IconStore.pngDataURL("claude", size: 56, dark: true) { icons["alert"] = u }
                let p: [String: Any] = ["state": st, "subs": subs, "face": m.engine.faceIds(m.subs, m.settings), "lang": m.lang.rawValue, "blink": false, "icons": icons]
                let js = String(data: try! JSONSerialization.data(withJSONObject: p), encoding: .utf8)!
                web.evaluateJavaScript("render(\(js))") { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        web.takeSnapshot(with: nil) { img, _ in
                            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("preview-\(st).png"))
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { _ = windows; _ = holder; NSApp.terminate(nil) }
    }
}
