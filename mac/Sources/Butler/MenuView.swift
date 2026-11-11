// 菜单栏上点开的面板：控制中心式。
// 顶上是机器人此刻的样子和状态；出问题时一条黄色提示；勿扰 / 提示音 / 灯三个大圆按钮；各家额度；关于、设置、退出。
import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        let alert = model.waiting.contains { !$0.acked }
        HStack(spacing: 3) {
            Image(nsImage: MenuIcon.image(alert: alert))
            switch model.settings.menuBarMode {
            case 0: if let l = model.lowest?.shown { Text("\(model.settings.showUsed ? 100 - l.left : l.left)%").monospacedDigit() }
            case 2: if !model.waiting.isEmpty { Text("\(model.waiting.count)") }
            default: EmptyView()
            }
        }
        .task {
            // 菜单栏图标一直在，借它把「打开窗口」交给 AppKit 那边用（在访达里再次打开小管家时弹设置）
            Openers.settings = { NSApp.activate(ignoringOtherApps: true); openSettings() }
            Openers.wizard = { step in openWizard(step, openWindow) }
            if !model.settings.setupDone { openWindow(id: "wizard") }
        }
    }
}

/// 从 AppKit（应用代理）、面板里打开 SwiftUI 窗口用
@MainActor
enum Openers {
    static var settings: (() -> Void)?
    static var wizard: ((Int) -> Void)?
}

struct MenuView: View {
    @ObservedObject var model = AppModel.shared
    @AppStorage("dndChoice") private var dndChoice = 1      // 打开勿扰时：1 = 1 小时，0 = 到明早 8 点，2 = 直到你关掉
    @State private var nodded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            robotCard
            if let b = banner { b.padding(.horizontal, 3).padding(.bottom, 6) }
            tiles
            HStack {
                Text(t("额度")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let d = model.lastData { Text(t("%@ 更新", DateFormatter.cached("HH:mm").string(from: d))).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 3)
            quotaList
            PanelDivider()
            PanelRow(action: showAbout) { Text(t("关于小管家")) }
            PanelRow(action: { model.showSettings() }) { Text(t("小管家设置…")); Spacer(); Text("⌘,").foregroundStyle(.secondary) }
            PanelRow(action: { NSApp.terminate(nil) }) { Text(t("退出小管家")); Spacer(); Text("⌘Q").foregroundStyle(.secondary) }
        }
        .padding(6)
        .frame(width: 320)
        .id(model.lang)
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]
        let credits = NSMutableAttributedString(string: t("开源（MIT）") + "\n", attributes: base)
        var link = base
        link[.link] = URL(string: "https://github.com/rayraid/stackchan-ai-quota")!
        credits.append(NSAttributedString(string: "github.com/rayraid/stackchan-ai-quota", attributes: link))
        credits.append(NSAttributedString(string: "\n\n" + t("致谢：%@", "CodexBar · peon-ping · M5Stack · Noto Sans · Inter"), attributes: base))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: t("小管家"), .credits: credits])
    }

    // ---------- 顶上：机器人此刻的样子 + 名字 + 状态 ----------
    private var robotCard: some View {
        let online = model.deviceOnline
        return HStack(spacing: 12) {
            Button {
                guard online else { return }
                model.send("nod")
                nodded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { nodded = false }
            } label: {
                Group {
                    if online { RobotScreen(state: "calm", width: 104) } else { FaceArt(kind: .sleep, width: 104).opacity(0.75) }
                }
                .allowsHitTesting(false)
            }
            .buttonStyle(.plain)
            .help(online ? t("点一下：让它点个头") : "")
            VStack(alignment: .leading, spacing: 5) {
                Text(model.settings.robotName).font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack(spacing: 4) {
                    StatusPill(color: online ? .green : .secondary, text: online ? t("已连接") : t("没连上"))
                    if online, let d = model.device, let b = d.bat {
                        HStack(spacing: 3) {
                            Image(systemName: d.power ? "bolt.fill" : b <= 20 ? "battery.25percent" : "battery.75percent").font(.system(size: 9, weight: .semibold))
                            Text("\(b)%").font(.caption).monospacedDigit()
                        }
                        .foregroundStyle(!d.power && b <= 20 ? Color.red : Color.primary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(cardNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 8)
    }
    private var cardNote: String {
        if nodded { return t("它点了一下头") }
        if model.deviceOnline { return t("点小屏让它点个头") }
        if let d = model.device { return t("上次 %@", DateFormatter.cached("HH:mm").string(from: d.at)) }
        return t("还没连上过")
    }

    // ---------- 出问题时的黄色提示（一次只放最要紧的一条） ----------
    private var banner: PanelBanner? {
        if !model.serverError.isEmpty {
            return PanelBanner(title: t("小管家没能启动"),
                               note: model.serverError == "EADDRINUSE" ? t("端口 %d 被占用：旧版小管家可能还在运行", model.settings.port) : model.serverError)
        }
        let settled = Date().timeIntervalSince(model.startedAt) > 20      // 刚启动时机器人还没来得及连上，先别报
        if settled && model.device == nil {
            return PanelBanner(title: t("还没连上机器人"), note: t("插上 USB 线，跟着向导走一遍"), button: t("去连接")) { closeMenuPanel(); Openers.wizard?(1) }
        }
        if let d = model.device, !model.deviceOnline {
            return PanelBanner(title: t("机器人没连上"), note: t("上次 %@ · 可能没电了，或者换了 WiFi", DateFormatter.cached("HH:mm").string(from: d.at)), button: t("怎么办")) {
                closeMenuPanel(); model.showSettings(.device)
            }
        }
        if model.subs.filter({ !$0.hidden && $0.shown != nil }).isEmpty && (model.engine.lastCliRun != nil || !model.cliError.isEmpty) {
            if !model.cliError.isEmpty {
                return PanelBanner(title: t("额度读不到"), note: t(model.cliError), button: t("重试")) { model.refreshNow() }
            }
            return PanelBanner(title: t("还没读到任何额度"), note: t("在设置里添加你订阅的 AI 服务"), button: t("去添加")) {
                closeMenuPanel(); model.showSettings(.data)
            }
        }
        if let d = model.device, model.deviceOnline, !d.fw.isEmpty, !Flasher.bundledVersion.isEmpty, d.fw != Flasher.bundledVersion {
            return PanelBanner(title: t("机器人固件可以更新到 %@", Flasher.bundledVersion), note: t("通过 WiFi 更新，大约 3 分钟，别断电"), button: t("更新")) {
                model.send("ota"); closeMenuPanel()
            }
        }
        return nil
    }

    // ---------- 勿扰 / 提示音 / 灯 ----------
    private var tiles: some View {
        let dnd = model.dndText
        return HStack(spacing: 6) {
            PanelTile(symbol: "moon.fill", title: t("勿扰"), on: dnd != nil, toggle: { model.setDnd(dnd == nil, choice: dndChoice) }) {
                Menu {
                    Button(t("1 小时")) { dndChoice = 1; model.setDnd(true, choice: 1) }
                    Button(t("到明早 8 点")) { dndChoice = 0; model.setDnd(true, choice: 0) }
                    Button(t("直到我关掉")) { dndChoice = 2; model.setDnd(true, choice: 2) }
                    if dnd != nil { Divider(); Button(t("关掉勿扰")) { model.setDnd(false, choice: dndChoice) } }
                } label: { Text(dnd ?? t("关")) }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            PanelTile(symbol: model.settings.sound ? "speaker.wave.2.fill" : "speaker.slash.fill", title: t("提示音"), on: model.settings.sound,
                      toggle: { model.settings.sound.toggle() }) {
                Text(model.settings.sound ? t("开") : t("关")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            PanelTile(symbol: model.settings.led ? "lightbulb.fill" : "lightbulb.slash", title: t("灯"), on: model.settings.led,
                      toggle: { model.settings.led.toggle() }) {
                Text(model.settings.led ? t("开") : t("关")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 3).padding(.bottom, 4)
    }

    // ---------- 各家额度：名字下面一行写时间段和什么时候重置 ----------
    private var quotaList: some View {
        VStack(spacing: 0) {
            let subs = model.subs.filter { !$0.hidden }
            if subs.isEmpty {
                Text(model.cliError.isEmpty ? t("正在读取额度…") : t(model.cliError))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 4)
            }
            if let one = Engine.single(model.subs), one.windows.count > 1 {
                // 只有一家：名字一行，下面它的每个时间段各一行
                HStack(spacing: 10) {
                    CircleBadge(id: one.id, mono: one.mono, hue: one.hue)
                    Text(one.name).fontWeight(.semibold)
                    Spacer()
                    if !one.plan.isEmpty { Text(one.plan).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                ForEach(one.windows, id: \.key) { w in
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 26, height: 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.label).lineLimit(1)
                            if !w.reset.isEmpty { Text(w.reset).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 6)
                        let v = model.settings.showUsed ? 100 - w.left : w.left
                        QuotaBar(value: v, color: one.stale ? .gray : levelColor(w.level)).frame(width: 56)
                        Text("\(v)%").fontWeight(.semibold).monospacedDigit().frame(width: 40, alignment: .trailing)
                            .foregroundStyle(one.stale ? Color.secondary : Color.primary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                }
            } else {
            ForEach(subs) { s in
                HStack(spacing: 10) {
                    CircleBadge(id: s.id, mono: s.mono, hue: s.hue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).lineLimit(1)
                        if let w = s.shown {
                            Text(w.reset.isEmpty ? w.label : w.label + " · " + w.reset).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if let w = s.shown {
                        let v = model.settings.showUsed ? 100 - w.left : w.left
                        QuotaBar(value: v, color: s.stale ? .gray : levelColor(w.level)).frame(width: 56)
                        Text("\(v)%").fontWeight(.semibold).monospacedDigit().frame(width: 40, alignment: .trailing)
                            .foregroundStyle(s.stale ? Color.secondary : Color.primary)
                    } else {
                        Text(t("暂时读不到")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .help(s.windows.map { "\($0.label) \($0.left)%" + ($0.reset.isEmpty ? "" : " · \($0.reset)") }.joined(separator: "\n"))
            }
            }
        }
    }
}

/// 控制中心式的一块：上面一个圆按钮（蓝色 = 开），下面名字和一行小字。点圆或名字 = 开 / 关
struct PanelTile<Sub: View>: View {
    var symbol: String
    var title: String
    var on: Bool
    var toggle: () -> Void
    @ViewBuilder var sub: () -> Sub
    @State private var hover = false
    var body: some View {
        VStack(spacing: 3) {
            Button(action: toggle) {
                VStack(spacing: 4) {
                    SymbolCircle(symbol: symbol, on: on, size: 32)
                    Text(title).font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            sub().frame(height: 14)
        }
        .padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover ? 0.09 : 0.055)))
        .onHover { hover = $0 }
    }
}

/// 面板里的黄色提示：一句话 + 一个能点的按钮
struct PanelBanner: View {
    var title: String
    var note: String
    var button: String? = nil
    var action: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let b = button { Button(b, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.yellow.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

/// 面板里可以点的一行：鼠标移上去整行浅色高亮；点了以后面板收起来（和系统菜单一样）
struct PanelRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        Button(action: { closeMenuPanel(); action() }) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 收起菜单栏弹出的面板
@MainActor
func closeMenuPanel() {
    let panel = NSApp.windows.first { $0.isVisible && $0.className.contains("MenuBarExtra") } ?? NSApp.keyWindow
    panel?.close()
}

struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 9).padding(.vertical, 5) }
}

/// 额度那一行左边的图标：官方 logo 放在灰色圆里；没有 logo 就用字母方块
struct CircleBadge: View {
    var id: String
    var mono: String
    var hue: String
    @ObservedObject var model = AppModel.shared
    var body: some View {
        if model.settings.showIcons, let img = IconCache.image(id, dark: model.isDark) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: 15, height: 15)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.12)))
        } else {
            MonoBadge(mono: mono, hue: hue, size: 26)
        }
    }
}
