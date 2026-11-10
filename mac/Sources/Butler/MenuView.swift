// 菜单栏上点开的面板：谁在等你、各家还剩多少、常用开关
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model = AppModel.shared
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
    }
}

struct MenuView: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.serverError.isEmpty { portWarning }
            if !model.waiting.isEmpty { section(t("在等你（%d）", model.waiting.count)) { waitingList } }
            section(t("额度")) { quotaList }
            Divider().padding(.vertical, 6)
            quickActions
            Divider().padding(.vertical, 6)
            menuItem(t("设置…"), key: "⌘,") { open("settings") }
            menuItem(t("重新运行安装向导…")) { open("wizard") }
            menuItem(t("立即刷新额度")) { model.refreshNow() }
            menuItem(t("退出小管家"), key: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(width: 340)
        .id(model.lang)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RobotPreview(state: model.waiting.contains { !$0.acked } ? "approval" : "calm")
                .frame(width: 52, height: 39)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(RoundedRectangle(cornerRadius: 6).fill(.black))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.settings.robotName).font(.system(size: 14, weight: .semibold))
                Text(dataLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.deviceOnline ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(model.deviceOnline ? t("已连接") : t("没连上")).font(.caption).foregroundStyle(model.deviceOnline ? Color.green : .secondary)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
    }

    private var dataLine: String {
        if model.quietNow { return t("勿扰中") + (model.settings.dndUntil.map { " · " + t("到 %@", DateFormatter.cached("HH:mm").string(from: $0)) } ?? "") }
        if let d = model.lastData { return t("数据 %@ 更新", DateFormatter.cached("HH:mm").string(from: d)) }
        return t("正在读取额度…")
    }

    private var portWarning: some View {
        Text(model.serverError == "EADDRINUSE" ? t("端口 %d 被占用：旧版小管家可能还在运行", model.settings.port) : t("小管家没能启动：%@", model.serverError))
            .font(.caption).foregroundStyle(.white)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.85)))
            .padding(.bottom, 6)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Divider().padding(.bottom, 6)
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 4)
        content().padding(.horizontal, 6).padding(.bottom, 6)
    }

    private var waitingList: some View {
        VStack(spacing: 6) {
            ForEach(model.waiting) { w in
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        let iid = IconStore.idForAgent(w.agent)
                        if model.settings.showIcons && IconStore.has(iid) {
                            BrandBadge(id: iid, mono: w.mono, hue: "#aab2bd", size: 26)
                        } else {
                            Text(w.kind == "done" || w.kind == "restored" ? "✓" : w.kind == "question" ? "?" : "!")
                                .font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(w.kind == "done" || w.kind == "restored" ? Color.green : Color.orange))
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(w.agent) · \(kindTitle(w.kind))").font(.system(size: 13, weight: .semibold))
                        Text("\(w.project) · " + t("已等 %@", waited(w.since))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if !w.acked { Button(t("知道了")) { model.engine.ack(w.id) }.controlSize(.small) }
                    else { Text(t("已知道")).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill((w.kind == "done" ? Color.green : Color.orange).opacity(w.acked ? 0.06 : 0.14)))
            }
        }
    }

    private func kindTitle(_ k: String) -> String {
        switch k {
        case "approval": return t("要你批准")
        case "question": return t("有问题问你")
        case "done": return t("做完了")
        case "error": return t("出错停下了")
        case "restored": return t("额度恢复了")
        default: return t("有新消息")
        }
    }
    private func waited(_ since: Double) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970 - since))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var quotaList: some View {
        VStack(spacing: 5) {
            let subs = model.subs.filter { !$0.hidden }
            if subs.isEmpty {
                Text(model.cliError.isEmpty ? t("正在读取额度…") : t(model.cliError)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(subs) { s in
                HStack(spacing: 8) {
                    BrandBadge(id: s.id, mono: s.mono, hue: s.hue)
                    Text(s.name).font(.system(size: 13)).lineLimit(1)
                    Text(s.shown?.label ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let w = s.shown {
                        let v = model.settings.showUsed ? 100 - w.left : w.left
                        QuotaBar(value: v, color: s.stale ? .gray : levelColor(w.level)).frame(width: 64)
                        Text("\(v)%").font(.system(size: 13, weight: .bold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                            .foregroundStyle(s.stale ? Color.secondary : Color.primary)
                    } else {
                        Text(t("暂时读不到")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .help(s.shown?.reset ?? "")
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            if model.settings.dndUntil != nil {
                Button(t("取消勿扰")) { model.settings.dndUntil = nil }
            } else {
                Button(t("勿扰 1 小时")) { model.snooze(hours: 1) }
                Button(t("静音到明早")) { model.snoozeUntilMorning() }
            }
            Button(t("让它点个头")) { model.send("nod") }
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
    }

    private func menuItem(_ title: String, key: String = "", action: @escaping () -> Void) -> some View {
        MenuRow(title: title, key: key, action: action)
    }
}

private struct MenuRow: View {
    var title: String
    var key: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(key).foregroundStyle(hover ? Color.white.opacity(0.7) : Color.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
