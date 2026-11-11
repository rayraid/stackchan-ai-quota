// 设置「订阅与数据」里的服务商：每家一行（读没读到 + 设置… + 开关），每家一页设置，以及从 CodexBar 支持的所有服务商里添加。
import AppKit
import SwiftUI

@MainActor
final class ProvidersStore: ObservableObject {
    static let shared = ProvidersStore()
    @Published var caps: [ProviderCaps] = []
    @Published var conf: [String: ProviderConf] = [:]
    @Published var loading = false
    @Published var error: String?
    @Published var touched: [String] = []           // 这次打开设置后动过的（关掉了也留在列表里，方便再打开）

    func load() {
        loading = true
        Task.detached {
            let caps = CodexBarConfig.providers(refresh: true)
            let conf = CodexBarConfig.current()
            await MainActor.run { self.caps = caps; self.conf = conf; self.loading = false }
        }
    }
    func cap(_ id: String) -> ProviderCaps? { caps.first { $0.id == id } }

    /// 改 CodexBar 的设置：在后台跑命令，跑完重新读一遍设置、马上刷新额度
    func apply(_ id: String, _ f: @escaping @Sendable () -> String?) {
        if !touched.contains(id) { touched.append(id) }
        loading = true
        Task.detached {
            let err = f()
            let conf = CodexBarConfig.current()
            await MainActor.run {
                self.conf = conf; self.loading = false
                if let err, !err.isEmpty { self.error = err }
                AppModel.shared.refreshNow()
            }
        }
    }

    /// 列表里放哪几家：CodexBar 里开着的 + 读到过的 + 这次动过的；顺序跟着额度列表
    func rowIds(_ subs: [Subscription]) -> [String] {
        var ids = subs.map { $0.id }
        for (id, c) in conf.sorted(by: { $0.key < $1.key }) where c.enabled && !ids.contains(id) { ids.append(id) }
        for id in touched where !ids.contains(id) { ids.append(id) }
        return ids
    }
}

/// 某一家的小图标（官方 logo / 自己的图 / 字母方块），不在额度列表里的也能画
struct ProviderBadge: View {
    var id: String
    var size: CGFloat = 22
    @ObservedObject var model = AppModel.shared
    var body: some View {
        let sub = model.subs.first { $0.id == id }
        let info = PROVIDERS[id]
        BrandBadge(id: id, mono: sub?.mono ?? model.settings.subMono[id] ?? info?.mono ?? String(id.prefix(2)).uppercased(),
                   hue: sub?.hue ?? model.settings.subHue[id] ?? info?.hue ?? "#aab2bd", size: size)
    }
}

/// 一家一行：图标、名字、读没读到 + 设置… + 读取开关
struct ProviderRow: View {
    var id: String
    @ObservedObject var model = AppModel.shared
    @ObservedObject var store = ProvidersStore.shared
    var open: () -> Void
    var body: some View {
        let sub = model.subs.first { $0.id == id }
        let on = store.conf[id]?.enabled ?? (sub != nil)
        HStack(spacing: 10) {
            ProviderBadge(id: id)
            VStack(alignment: .leading, spacing: 1) {
                Text(sub?.name ?? store.cap(id)?.name ?? id)
                ProviderStatus(id: id, enabled: on).font(.caption)
            }
            Spacer()
            Button(t("设置…"), action: open).controlSize(.small)
            Toggle("", isOn: Binding(get: { on }, set: { v in store.apply(id) { CodexBarConfig.setEnabled(id, v) } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// 读没读到的一句话：读到了 · 网页登录 · 15:22 / 读不到：原因 / 关着
struct ProviderStatus: View {
    var id: String
    var enabled: Bool
    @ObservedObject var model = AppModel.shared
    var body: some View {
        let sub = model.subs.first { $0.id == id }
        if !enabled {
            Text(t("关着，不读取")).foregroundStyle(.secondary)
        } else if let s = sub, s.error.isEmpty, s.ts > 0 {
            let via = s.via.isEmpty ? "" : " · " + (s.via == "app" ? t("CodexBar 应用") : CodexBarConfig.sourceName(s.via))
            (Text("● ").foregroundColor(.green) + Text(t("读到了") + via + " · " + DateFormatter.cached("HH:mm").string(from: Date(timeIntervalSince1970: s.ts))).foregroundColor(.secondary))
                .lineLimit(1)
        } else if let s = sub, !s.error.isEmpty {
            Text("⚠ " + t("读不到：%@", s.error)).foregroundStyle(.orange).lineLimit(2)
        } else {
            Text(t("还没读到（下次刷新时读）")).foregroundStyle(.secondary)
        }
    }
}

/// 每家一页：读取方式、API Key、Cookie、账号、显示哪个额度、提醒线、简称颜色图标
struct ProviderSheet: View {
    var id: String
    var close: () -> Void
    @ObservedObject var model = AppModel.shared
    @ObservedObject var store = ProvidersStore.shared
    @State private var secret: SecretKind?
    @State private var authorizing = false
    enum SecretKind: String, Identifiable { case apiKey, cookie; var id: String { rawValue } }

    var body: some View {
        let cap = store.cap(id)
        let c = store.conf[id] ?? ProviderConf(id: id)
        let sub = model.subs.first { $0.id == id }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProviderBadge(id: id, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sub?.name ?? cap?.name ?? id).font(.headline)
                    ProviderStatus(id: id, enabled: c.enabled).font(.caption)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button(t("完成"), action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            Form {
                Section(t("读取")) {
                    Toggle(t("读取这一家"), isOn: Binding(get: { c.enabled }, set: { v in store.apply(id) { CodexBarConfig.setEnabled(id, v) } }))
                    if let modes = cap?.sourceModes, modes.count > 1 {
                        Picker(selection: Binding(get: { c.source }, set: { v in store.apply(id) { CodexBarConfig.setSource(id, v) } })) {
                            ForEach(["auto"] + modes.filter { $0 != "auto" }, id: \.self) { m in Text(CodexBarConfig.sourceName(m)).tag(m) }
                        } label: { Text(t("读取方式")); Text(t("「自动」会按顺序试，读不到时再换别的")) }
                    }
                    if cap?.apiKey == true {
                        LabeledContent {
                            Text(c.hasAPIKey ? t("已保存") : t("没有")).foregroundStyle(.secondary)
                            Button(t("粘贴…")) { secret = .apiKey }
                            if c.hasAPIKey { Button(t("清除")) { store.apply(id) { CodexBarConfig.clearAPIKey(id) } } }
                        } label: { Text("API Key"); Text(t("存在 CodexBar 的配置文件里，小管家不保存、不显示")) }
                    }
                    if cap?.cookie == true {
                        LabeledContent {
                            Text(c.cookieSource == "manual" ? t("手动粘贴的") : c.cookieSource == "off" ? t("不用") : t("自动从浏览器读")).foregroundStyle(.secondary)
                            Button(t("粘贴…")) { secret = .cookie }
                            if c.cookieSource == "manual" { Button(t("改回自动")) { store.apply(id) { CodexBarConfig.clearCookie(id) } } }
                        } label: { Text(t("登录信息（Cookie）")); Text(t("网页登录读不到时，可以从浏览器复制 Cookie 粘贴进来")) }
                    }
                    if !c.accounts.isEmpty {
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(Array(c.accounts.enumerated()), id: \.offset) { i, a in
                                    Text((i == c.activeAccount ? "✓ " : "") + a).foregroundStyle(i == c.activeAccount ? .primary : .secondary)
                                }
                            }
                        } label: { Text(cap?.accountsTitle.isEmpty == false ? cap!.accountsTitle : t("账号")); Text(t("添加和切换账号暂时要在 CodexBar 应用里做")) }
                    }
                    if let lc = cap?.loginCommand, !lc.isEmpty {
                        LabeledContent {
                            Text(lc).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button(t("复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lc, forType: .string) }
                        } label: { Text(t("登录")); Text(t("在「终端」里运行这条命令登录一次")) }
                    }
                    if id == "claude" {
                        LabeledContent {
                            Button(authorizing ? t("等你点允许…") : t("重新授权…")) {
                                authorizing = true
                                Env.authorizeClaude { _ in DispatchQueue.main.async { authorizing = false; model.refreshNow() } }
                            }.disabled(authorizing)
                        } label: { Text(t("钥匙串授权")); Text(t("读不到 Claude 时点一下，在弹窗里点「始终允许」")) }
                    }
                }
                Section(t("显示")) {
                    Toggle(t("在机器人和菜单栏上显示"), isOn: Binding(get: { !model.settings.subHidden.contains(id) }, set: { on in
                        model.settings.subHidden.removeAll { $0 == id }
                        if !on { model.settings.subHidden.append(id) }
                    }))
                    if let s = sub, s.windows.count > 1 {
                        Picker(t("显示哪个额度"), selection: Binding(get: { model.settings.subWindow[id] ?? "" }, set: { v in
                            if v.isEmpty { model.settings.subWindow.removeValue(forKey: id) } else { model.settings.subWindow[id] = v }
                        })) {
                            Text(t("按显示逻辑（现在是 %@）", Engine.pickWindow(s.windows, choice: nil, pref: model.settings.windowPref)?.label ?? "—")).tag("")
                            Divider()
                            ForEach(s.windows, id: \.key) { w in Text("\(w.label) · \(w.left)%").tag(w.key) }
                        }
                    }
                    Picker(selection: Binding(get: { model.settings.subLow[id] != nil }, set: { custom in
                        if custom { model.settings.subLow[id] = model.settings.lowPercent; model.settings.subMid[id] = model.settings.midPercent }
                        else { model.settings.subLow.removeValue(forKey: id); model.settings.subMid.removeValue(forKey: id) }
                    })) {
                        Text(t("跟随总设置（黄 %d%% · 红 %d%%）", model.settings.midPercent, model.settings.lowPercent)).tag(false)
                        Text(t("这一家单独设")).tag(true)
                    } label: { Text(t("提醒线")); Text(t("剩余低于黄线数字变黄，低于红线变红、摇一次头")) }
                    if model.settings.subLow[id] != nil {
                        SliderRow(title: t("黄色提醒线"), value: Binding(get: { model.settings.subMid[id] ?? model.settings.midPercent }, set: { model.settings.subMid[id] = $0 }), range: 10...80)
                        SliderRow(title: t("红色提醒线"), value: Binding(get: { model.settings.subLow[id] ?? model.settings.lowPercent }, set: { model.settings.subLow[id] = $0 }), range: 1...40)
                    }
                    LabeledContent(t("简称和颜色")) {
                        TextField("", text: Binding(get: { model.settings.subMono[id] ?? sub?.mono ?? String(id.prefix(2)).uppercased() }, set: { v in
                            model.settings.subMono[id] = String(v.uppercased().prefix(2))
                        })).frame(width: 44).multilineTextAlignment(.center)
                        Menu {
                            ForEach(DataPage.letterColors, id: \.0) { col in
                                Button { model.settings.subHue[id] = col.0 } label: { Label { Text(t(col.1)) } icon: { Image(nsImage: DataPage.swatch(col.0)) } }
                            }
                        } label: { Image(nsImage: DataPage.swatch(sub?.hue ?? model.settings.subHue[id] ?? "#aab2bd", size: 14)) }
                            .menuStyle(.borderlessButton).frame(width: 34)
                    }
                    LabeledContent(t("图标")) {
                        Button(t("选择图片…")) { DataPage.pickIcon(id) }
                        Button(t("用字母")) { IconStore.remove(id); model.refresh(); model.objectWillChange.send() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 600)
        .sheet(item: $secret) { k in
            SecretSheet(title: k == .apiKey ? t("粘贴 %@ 的 API Key", sub?.name ?? id) : t("粘贴 %@ 的 Cookie", sub?.name ?? id),
                        note: k == .apiKey ? t("在它官网的设置里找到 API Key，复制后粘贴到这里。") : t("在浏览器里登录它的网站，用开发者工具复制请求里的 Cookie 那一整行，粘贴到这里。"),
                        long: k == .cookie) { value in
                secret = nil
                guard let v = value, !v.isEmpty else { return }
                store.apply(id) { k == .apiKey ? CodexBarConfig.setAPIKey(id, v) : CodexBarConfig.setCookie(id, v) }
            }
        }
        .alert(store.error ?? "", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button(t("好")) {} }
    }
}

/// 粘贴 API Key / Cookie 的小窗：输入的东西不显示出来
struct SecretSheet: View {
    var title: String
    var note: String
    var long = false
    var done: (String?) -> Void
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(long ? "name=value; name2=value2" : "sk-…", text: $value)
            Text(t("会交给 CodexBar 存在它的配置文件里（~/.config/codexbar/config.json），小管家自己不保存。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(t("取消")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(t("保存")) { done(value) }.keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// 添加服务商：从 CodexBar 支持的所有服务商里搜
struct AddProviderSheet: View {
    var done: (String?) -> Void
    @ObservedObject var store = ProvidersStore.shared
    @State private var q = ""
    var body: some View {
        let list = store.caps.filter { !(store.conf[$0.id]?.enabled ?? $0.enabled) }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 10) {
            Text(t("添加服务商")).font(.headline)
            Text(t("CodexBar 现在支持 %d 家，它每天自动更新，新支持的会出现在这里。", store.caps.count)).font(.callout).foregroundStyle(.secondary)
            TextField(t("搜索"), text: $q).textFieldStyle(.roundedBorder)
            List(list) { p in
                HStack(spacing: 10) {
                    ProviderBadge(id: p.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(Self.hint(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t("添加")) { store.apply(p.id) { CodexBarConfig.setEnabled(p.id, true) }; done(p.id) }
                }
            }
            .frame(minHeight: 340)
            HStack { Spacer(); Button(t("取消")) { done(nil) }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460, height: 520)
    }
    static func hint(_ p: ProviderCaps) -> String {
        if !p.loginCommand.isEmpty { return t("要在终端里登录一次") }
        if p.sourceModes.allSatisfy({ $0 == "api" || $0 == "auto" }) && p.apiKey { return t("要填 API Key") }
        if p.sourceModes.contains("web") { return t("读浏览器里的登录") }
        if p.sourceModes.contains("cli") || p.sourceModes.contains("oauth") { return t("读这台 Mac 上的登录") }
        return ""
    }
}
