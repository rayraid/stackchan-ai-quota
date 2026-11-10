// 菜单栏上点开的面板：排法和系统自带的 Wi‑Fi / 电池面板一样（Apple 设计规范）
// 上面是连接状态和各家额度，中间是勿扰和小动作，下面是关于、设置、退出。
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
            Openers.wizard = { NSApp.activate(ignoringOtherApps: true); openWindow(id: "wizard") }
            if !model.settings.setupDone { openWindow(id: "wizard") }
        }
    }
}

/// 从 AppKit（应用代理）里打开 SwiftUI 窗口用
@MainActor
enum Openers {
    static var settings: (() -> Void)?
    static var wizard: (() -> Void)?
}

struct MenuView: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage("dndChoice") private var dndChoice = 1      // 打开勿扰时：1 = 1 小时，0 = 到明早 8 点

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.serverError.isEmpty { portWarning }
            sectionHeader(t("额度"))
            quotaList
            PanelDivider()
            dndRow
            PanelRow(action: { model.send("nod") }) { Text(t("让它点个头")) }
            PanelDivider()
            PanelRow(action: showAbout) { Text(t("关于小管家")) }
            PanelRow(action: showSettings) { Text(t("小管家设置…")); Spacer(); Text("⌘,").foregroundStyle(.secondary) }
            PanelRow(action: { NSApp.terminate(nil) }) { Text(t("退出小管家")); Spacer(); Text("⌘Q").foregroundStyle(.secondary) }
        }
        .padding(6)
        .frame(width: 320)
        .id(model.lang)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
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

    // ---------- 顶部：名字 + 连接状态 ----------
    private var header: some View {
        HStack(spacing: 6) {
            Text(model.settings.robotName).font(.headline)
            Spacer()
            Circle().fill(model.deviceOnline ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 6)
    }

    private var statusLine: String {
        var s = model.deviceOnline ? t("已连接") : t("没连上")
        if model.deviceOnline, let b = model.device?.batteryShort { s += " · " + b }
        if let d = model.lastData { s += " · " + t("%@ 更新", DateFormatter.cached("HH:mm").string(from: d)) }
        return s
    }

    private var portWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(model.serverError == "EADDRINUSE" ? t("端口 %d 被占用：旧版小管家可能还在运行", model.settings.port) : t("小管家没能启动：%@", model.serverError))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.bottom, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 2).padding(.bottom, 3)
    }

    // ---------- 各家额度 ----------
    private var quotaList: some View {
        VStack(spacing: 0) {
            let subs = model.subs.filter { !$0.hidden }
            if subs.isEmpty {
                Text(model.cliError.isEmpty ? t("正在读取额度…") : t(model.cliError))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 4)
            }
            ForEach(subs) { s in
                HStack(spacing: 10) {
                    CircleBadge(id: s.id, mono: s.mono, hue: s.hue)
                    Text(s.name).lineLimit(1)
                    Spacer(minLength: 6)
                    if let w = s.shown {
                        let v = model.settings.showUsed ? 100 - w.left : w.left
                        Text(w.label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        QuotaBar(value: v, color: s.stale ? .gray : levelColor(w.level)).frame(width: 56)
                        Text("\(v)%").fontWeight(.semibold).monospacedDigit().frame(width: 40, alignment: .trailing)
                            .foregroundStyle(s.stale ? Color.secondary : Color.primary)
                    } else {
                        Text(t("暂时读不到")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .help(s.shown?.reset ?? "")
            }
        }
    }

    // ---------- 勿扰：一个开关，旁边选时长 ----------
    private var dndRow: some View {
        HStack(spacing: 8) {
            Text(t("勿扰"))
            Spacer()
            if let u = model.settings.dndUntil {
                Text(t("到 %@", DateFormatter.cached("HH:mm").string(from: u))).font(.subheadline).foregroundStyle(.secondary)
            } else if model.quietNow {
                Text(t("勿扰时段中")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Menu {
                    Picker("", selection: $dndChoice) {
                        Text(t("1 小时")).tag(1)
                        Text(t("到明早 8 点")).tag(0)
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(dndChoice == 1 ? t("1 小时") : t("到明早 8 点")).font(.subheadline)
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }
            Toggle("", isOn: Binding(get: { model.settings.dndUntil != nil }, set: { on in
                if !on { model.settings.dndUntil = nil }
                else if dndChoice == 1 { model.snooze(hours: 1) }
                else { model.snoozeUntilMorning() }
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
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
