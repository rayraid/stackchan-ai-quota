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
        for p in SettingsPage.allCases { jobs.append(("settings-\(p.rawValue)", AnyView(SettingsPane(page: p)), NSSize(width: SettingsPage.width, height: p.height))) }
        // 向导各屏：每一屏一个单独的状态（不碰串口）
        func wiz(_ name: String, _ step: Int, _ set: (WizardModel) -> Void = { _ in }) {
            let m = WizardModel(); m.noScan = true; m.step = step; set(m)
            jobs.append(("wizard-" + name, AnyView(WizardView(model: m)), NSSize(width: WizardView.size.width, height: WizardView.size.height)))
        }
        let fw = Flasher.bundledVersion.isEmpty ? "2.1.2" : Flasher.bundledVersion
        wiz("1-welcome", 0)
        wiz("2a-plug", 1) { $0.assumeOffline = true }
        wiz("2b-firmware", 1) { $0.port = "/dev/x" }
        wiz("2c-flashing", 1) { $0.port = "/dev/x"; $0.flashing = true; $0.flashProgress = 0.62; $0.flashStage = t("正在写入固件…") }
        wiz("2d-upgrade", 1) { $0.port = "/dev/x"; $0.hello = RobotHello(port: "/dev/x", fw: "2.1.0", configured: true, mac: "") }
        wiz("2e-wifi", 1) { $0.port = "/dev/x"; $0.hello = RobotHello(port: "/dev/x", fw: fw, configured: true, mac: ""); $0.robotInfo = ["ssid": "Home-2.4G", "wifi": "3"] }
        wiz("2f-linked", 1) { $0.linkOK = true }
        wiz("3-agents", 2)
        wiz("4-try", 3)
        wiz("4-tried", 3) { $0.tried = true }
        wiz("4-try-offline", 3) { $0.assumeOffline = true }
        jobs.append(("menu", AnyView(MenuView().background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 332, height: 600)))
        // 服务商设置：先把 CodexBar 的设置读进来（只读）
        let st = ProvidersStore.shared
        st.caps = CodexBarConfig.providers(refresh: true); st.conf = CodexBarConfig.current()
        let firstId = AppModel.shared.subs.first?.id ?? "claude"
        jobs.append(("provider-\(firstId)", AnyView(ProviderSheet(id: firstId) {}.background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 520, height: 600)))
        jobs.append(("provider-add", AnyView(AddProviderSheet { _ in }.background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 460, height: 520)))
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
        let states = ["calm", "approval", "done", "low", "list", "detail", "home-A", "home-B", "home-C", "home-D"]
        for (i, st) in states.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.5) {
                let m = AppModel.shared
                let subs: [[String: Any]] = m.subs.map { ["id": $0.id, "name": $0.name, "mono": $0.mono, "hue": $0.hue, "left": $0.shown?.left ?? -1, "label": $0.shown?.label ?? "", "reset": $0.shown?.reset ?? ""] }
                var icons: [String: String] = [:]
                for s in m.subs { if let u = IconStore.pngDataURL(s.id, size: 56, dark: true) { icons[s.id] = u } }
                if let u = IconStore.pngDataURL("claude", size: 56, dark: true) { icons["alert"] = u }
                let vis = m.subs.filter { !$0.hidden }
                let subs2: [[String: Any]] = vis.map { ["id": $0.id, "name": $0.name, "mono": $0.mono, "hue": $0.hue, "left": $0.shown?.left ?? -1, "label": $0.shown?.label ?? "", "reset": $0.shown?.reset ?? "", "level": $0.shown?.level ?? "na",
                    "windows": $0.windows.map { ["label": $0.label, "left": $0.left, "level": $0.level, "reset": $0.reset, "pace": $0.pace, "mins": $0.minutes] }] }
                var p: [String: Any] = ["state": st.hasPrefix("home-") ? "calm" : st, "subs": vis.isEmpty ? subs : subs2, "face": m.engine.faceIds(m.subs, m.settings), "lang": m.lang.rawValue, "blink": false, "look": false, "icons": icons,
                                        "theme": m.settings.theme, "list": m.settings.listStyle, "detail": m.settings.detailStyle, "home": m.settings.homeStyle]
                if st.hasPrefix("home-") { p["home"] = String(st.dropFirst(5)); var s2 = m.settings; s2.homeStyle = p["home"] as! String
                    p["split"] = Engine.single(m.subs).map { one -> [String: Any] in ["id": one.id, "w": Engine.splitWindows(one, s2)] } ?? NSNull() }
                if ProcessInfo.processInfo.environment["BUTLER_NOSUBS"] != nil { p["subs"] = [] }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { _ = windows; _ = holder; NSApp.terminate(nil) }
    }
}
