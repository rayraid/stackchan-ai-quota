// 设置窗口：八页，改完马上生效，2 秒内同步到机器人
// 按 Apple 设计规范：顶部工具栏切换各页、窗口标题跟着当前页、下次打开回到上次那页、窗口大小跟着当前页。
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, display, face, alerts, motion, quiet, data, device
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return t("通用"); case .display: return t("屏幕"); case .face: return t("表情")
        case .alerts: return t("提醒"); case .motion: return t("动作与声音"); case .quiet: return t("勿扰")
        case .data: return t("订阅与数据"); case .device: return t("机器人")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"; case .display: return "display"; case .face: return "face.smiling"
        case .alerts: return "bell.badge"; case .motion: return "speaker.wave.2"; case .quiet: return "moon"
        case .data: return "chart.bar"; case .device: return "cpu"
        }
    }
    /// 每页的窗口高度（内容更长的页在里面滚动）
    var height: CGFloat {
        switch self {
        case .general: return 440; case .quiet: return 470; case .device: return 440
        case .face: return 560; case .motion: return 640
        case .display, .alerts, .data: return 660
        }
    }
    static let width: CGFloat = 640
}

struct SettingsView: View {
    @ObservedObject var model = AppModel.shared
    @AppStorage("settingsPage") private var page: SettingsPage = .general

    var body: some View {
        TabView(selection: $page) {
            ForEach(SettingsPage.allCases) { p in
                SettingsPane(page: p)
                    .frame(width: SettingsPage.width, height: p.height)
                    .tabItem { Label(p.title, systemImage: p.symbol) }
                    .tag(p)
            }
        }
        .id(model.lang)
        .activateOnAppear()
    }
}

/// 某一页的内容（离屏截图也用它）
struct SettingsPane: View {
    var page: SettingsPage
    var body: some View {
        switch page {
        case .general: GeneralPage()
        case .display: DisplayPage()
        case .face: FacePage()
        case .alerts: AlertsPage()
        case .motion: MotionPage()
        case .quiet: QuietPage()
        case .data: DataPage()
        case .device: DevicePage()
        }
    }
}

// ---------- 共用 ----------
struct PreviewHeader: View {
    @State private var state = "calm"
    var body: some View {
        HStack(spacing: 18) {
            RobotScreen(state: state, width: 256)
            VStack(alignment: .leading, spacing: 10) {
                Text(t("机器人上的样子")).font(.headline)
                Picker("", selection: $state) {
                    Text(t("平时")).tag("calm"); Text(t("提醒")).tag("approval"); Text(t("点屏幕后")).tag("list")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Text(t("改动 2 秒内同步到机器人")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

private func minutesBinding(_ b: Binding<String>) -> Binding<Date> {
    Binding<Date>(
        get: {
            let m = Engine.minutes(b.wrappedValue)
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        },
        set: { b.wrappedValue = DateFormatter.cached("HH:mm").string(from: $0) }
    )
}

struct SliderRow: View {
    var title: String
    var note: String = ""
    @Binding var value: Int
    var range: ClosedRange<Double> = 0...100
    var unit = "%"
    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: range).frame(width: 190)
                Text("\(value)\(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
            if !note.isEmpty { Text(note) }
        }
    }
}

// ---------- 通用 ----------
struct GeneralPage: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section {
                Toggle(t("开机自动启动"), isOn: $model.settings.launchAtLogin)
                Picker(t("菜单栏显示"), selection: $model.settings.menuBarMode) {
                    Text(t("小机器人 + 最紧张的额度")).tag(0); Text(t("只显示小机器人")).tag(1); Text(t("小机器人 + 在等你的数量")).tag(2)
                }
                Picker(t("语言"), selection: $model.settings.language) {
                    Text(t("跟随系统")).tag("auto"); Text("简体中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
                }
            } footer: { Text(t("机器人屏幕上的文字也会跟着换")) }
            Section {
                Toggle(t("自动检查更新"), isOn: $model.settings.autoUpdateCheck)
                Toggle(t("更新时先问我"), isOn: $model.settings.askBeforeUpdate)
            }
            Section {
                LabeledContent {
                    Button(t("重新运行…")) { openWizard(0, openWindow) }
                } label: { Text(t("安装向导")); Text(t("换了 WiFi、换了新机器人时用")) }
                LabeledContent(t("导出 / 导入设置")) {
                    Button(t("导出…")) { exportSettings() }
                    Button(t("导入…")) { importSettings() }
                }
                LabeledContent(t("日志")) { Button(t("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([Paths.log]) } }
            }
        }.formStyle(.grouped)
    }

    private func exportSettings() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "StackChan Butler.json"
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { var s = model.settings; s.token = ""; try? JSONEncoder.pretty.encode(s).write(to: u) }
    }
    private func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u), var s = try? JSONDecoder.iso.decode(AppSettings.self, from: d) {
            s.token = model.settings.token; s.macId = model.settings.macId; s.setupDone = model.settings.setupDone
            model.settings = s
        }
    }
}

// ---------- 屏幕 ----------
struct DisplayPage: View {
    @ObservedObject var model = AppModel.shared
    private let themes: [(String, String, [Color])] = [
        ("night", "深夜蓝", [Color(hex: "#131c2d"), Color(hex: "#090c13")]), ("black", "纯黑", [.black, .black]),
        ("warm", "暖色", [Color(hex: "#251d17"), Color(hex: "#120e0b")]), ("light", "浅色", [Color(hex: "#f6f8fb"), Color(hex: "#e2e7ee")]),
    ]
    var body: some View {
        Form {
            Section { PreviewHeader() }
            Section {
                LabeledContent {
                    HomeStylePicker()
                } label: { Text(t("首页样式")); Text(t("平时机器人屏幕上的样子")) }
                LabeledContent {
                    PageStylePicker(state: "list", key: "list", styles: PageStylePicker.list, selection: $model.settings.listStyle)
                } label: { Text(t("全部额度页")); Text(t("在首页点一下看全部额度")) }
                LabeledContent {
                    PageStylePicker(state: "detail", key: "detail", styles: PageStylePicker.detail, selection: $model.settings.detailStyle)
                } label: { Text(t("明细页")); Text(t("点进某一家时")) }
                LabeledContent {
                    PageStylePicker(state: "approval", key: "alert", styles: PageStylePicker.alert, selection: $model.settings.alertStyle)
                } label: { Text(t("提醒画面")); Text(t("AI 等你时整屏显示几秒")) }
            }
            Section {
                LabeledContent(t("配色")) {
                    HStack(spacing: 12) {
                        ForEach(themes, id: \.0) { th in
                            Button { model.settings.theme = th.0 } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: th.2, startPoint: .top, endPoint: .bottom))
                                        .frame(width: 40, height: 28)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.settings.theme == th.0 ? Color.accentColor : Color.black.opacity(0.2), lineWidth: model.settings.theme == th.0 ? 2.5 : 0.5))
                                    Text(t(th.1)).font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                SliderRow(title: t("亮度"), note: t("勿扰时段另有设置"), value: $model.settings.brightness, range: 5...100)
            }
            Section {
                // 跟着首页样式变：A 三格、B 两只眼睛、C 气泡三行、D 不放
                let subs = model.subs.filter { !$0.hidden }
                let slots = Self.slotNames(model.settings.homeStyle)
                if let one = Engine.single(model.subs) {
                    // 只有一家：每一格放它的哪个时间段
                    let split = Engine.splitWindows(one, model.settings)
                    ForEach(Array(slots.prefix(model.settings.homeStyle == "B" ? 2 : 3).enumerated()), id: \.offset) { i, name in
                        Picker(t(name), selection: singleBinding(i)) {
                            Text(t("自动（%@）", i < split.count ? one.windows[split[i]].label : "—")).tag("")
                            Divider()
                            ForEach(one.windows, id: \.key) { w in Text("\(w.label) · \(w.left)%").tag(w.key) }
                        }
                    }
                } else {
                if slots.count > 0 { Picker(t(slots[0]), selection: pinBinding(0)) { ForEach(subs) { Text($0.name).tag($0.id) } } }
                if slots.count > 1 { Picker(t(slots[1]), selection: pinBinding(1)) { ForEach(subs) { Text($0.name).tag($0.id) } } }
                if slots.count > 2 {
                    Picker(t(slots[2]), selection: thirdBinding) {
                        Text(t("自动：最紧张的一家")).tag("__auto")
                        ForEach(subs) { Text($0.name).tag($0.id) }
                    }
                }
                }
                Picker(t("数字表示"), selection: $model.settings.showUsed) {
                    Text(t("还剩多少")).tag(false); Text(t("用了多少")).tag(true)
                }.pickerStyle(.segmented)
            } header: { Text(t("内容")) } footer: {
                if let one = Engine.single(model.subs), model.settings.homeStyle != "D" {
                    Text(t("只有 %@ 一家：首页分成它的几个时间段，点机器人的屏幕直接看明细。", one.name))
                } else { Text(t(Self.slotNote(model.settings.homeStyle)) + t("点机器人的屏幕可以看全部。")) }
            }
            Section {
                Picker(selection: $model.settings.windowPref) {
                    Text(t("最紧张的那个（不算单个模型）")).tag("auto")
                    Text(t("最紧张的那个（单个模型也算）")).tag("tightest")
                    Text(t("尽量显示每周")).tag("week")
                    Text(t("尽量显示 5 小时")).tag("5h")
                } label: { Text(t("显示逻辑")); Text(t("比如 Claude 的「Fable 本周」只算一个模型，默认不拿它和总额度比")) }
                ForEach(model.subs.filter { !$0.hidden }) { sub in
                    if sub.windows.count > 1 {
                        Picker(selection: windowBinding(sub.id)) {
                            Text(t("按显示逻辑（现在是 %@）", Engine.pickWindow(sub.windows, choice: nil, pref: model.settings.windowPref)?.label ?? "—")).tag("")
                            Divider()
                            ForEach(sub.windows, id: \.key) { w in Text("\(w.label) · \(w.left)%").tag(w.key) }
                        } label: { HStack(spacing: 8) { BrandBadge(id: sub.id, mono: sub.mono, hue: sub.hue); Text(sub.name) } }
                    } else {
                        LabeledContent {
                            Text(sub.windows.first.map { t("%@（只有这一个）", $0.label) } ?? "—").foregroundStyle(.secondary)
                        } label: { HStack(spacing: 8) { BrandBadge(id: sub.id, mono: sub.mono, hue: sub.hue); Text(sub.name) } }
                    }
                }
            } header: { Text(t("每家显示哪个额度")) } footer: { Text(t("首页和「全部额度」列表都显示这里选的那一个。")) }
            Section {
                Toggle(t("显示时钟"), isOn: $model.settings.clock)
                Picker(t("没动静多久后变暗"), selection: $model.settings.dimAfter) {
                    Text(t("从不")).tag(0); Text(t("10 分钟")).tag(10); Text(t("30 分钟")).tag(30); Text(t("1 小时")).tag(60)
                }
            } footer: { Text(t("有提醒时会自动亮起来")) }
        }
        .formStyle(.grouped)
        .animation(.default, value: model.settings.homeStyle)
    }

    /// 首页样式 → 「内容」里有哪几格、各叫什么
    static func slotNames(_ home: String) -> [String] {
        switch home {
        case "A": return ["第 1 格", "第 2 格", "第 3 格"]
        case "C": return ["第 1 行", "第 2 行", "第 3 行"]
        case "D": return []
        default: return ["左眼", "右眼"]
        }
    }
    static func slotNote(_ home: String) -> String {
        switch home {
        case "A": return "首页底栏常驻显示这三家。"
        case "C": return "对话气泡里常驻显示这三家。"
        case "D": return "只有脸：平时不显示数字，哪家快用完才在底部露出那一家。"
        default: return "两只眼睛分别显示这两家，其他家只在快用完时以红色小胶囊出现。"
        }
    }

    private func windowBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.settings.subWindow[id] ?? "" }, set: { v in
            if v.isEmpty { model.settings.subWindow.removeValue(forKey: id) } else { model.settings.subWindow[id] = v }
        })
    }
    private func singleBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < model.settings.singleWins.count ? model.settings.singleWins[i] : "" }, set: { v in
            var w = model.settings.singleWins
            while w.count <= i { w.append("") }
            w[i] = v
            model.settings.singleWins = w
        })
    }
    private func pinBinding(_ i: Int) -> Binding<String> {
        Binding(get: { model.settings.pinned.count > i ? model.settings.pinned[i] : "" }, set: { v in
            var p = model.settings.pinned
            while p.count <= i { p.append("") }
            p[i] = v
            model.settings.pinned = p.filter { !$0.isEmpty }
        })
    }
    private var thirdBinding: Binding<String> {
        Binding(get: { model.settings.autoThird ? "__auto" : (model.settings.pinned.count > 2 ? model.settings.pinned[2] : "__auto") }, set: { v in
            if v == "__auto" { model.settings.autoThird = true; model.settings.pinned = Array(model.settings.pinned.prefix(2)) }
            else {
                var p = Array(model.settings.pinned.prefix(2))
                while p.count < 2, let first = model.subs.first(where: { !p.contains($0.id) && $0.id != v }) { p.append(first.id) }
                model.settings.pinned = p + [v]
                model.settings.autoThird = false
            }
        })
    }
}

// ---------- 表情 ----------
struct FacePage: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        Form {
            Section { PreviewHeader() }
            Section {
                LabeledContent(t("眼睛样式")) {
                    HStack(spacing: 10) {
                        ForEach([("capsule", "胶囊"), ("round", "圆点"), ("bar", "竖条")], id: \.0) { e in
                            Button { model.settings.eye = e.0 } label: {
                                VStack(spacing: 4) {
                                    HStack(spacing: 10) {
                                        ForEach(0..<2, id: \.self) { _ in
                                            RoundedRectangle(cornerRadius: e.0 == "bar" ? 2.5 : 6)
                                                .fill(Color(hex: "#e6f3ff"))
                                                .frame(width: e.0 == "capsule" ? 11 : e.0 == "round" ? 13 : 5, height: e.0 == "round" ? 13 : 19)
                                        }
                                    }
                                    Text(t(e.1)).font(.caption2).foregroundStyle(Color(hex: "#c9d0d9"))
                                }
                                .frame(width: 74, height: 50)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#1a2130")))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.settings.eye == e.0 ? Color.accentColor : .clear, lineWidth: 2.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                LabeledContent(t("眼睛颜色")) {
                    Swatches(selection: $model.settings.eyeColor, colors: [("", t("跟随配色")), ("#9ff3ff", t("青")), ("#ffd27a", t("琥珀")), ("#ffb3d1", t("粉")), ("#b8ffb0", t("薄荷"))])
                }
            }
            Section(t("小动作")) {
                Toggle(t("眨眼"), isOn: $model.settings.blink)
                Toggle(t("偶尔左右张望"), isOn: $model.settings.look)
                Toggle(isOn: $model.settings.sleepyNight) { Text(t("晚上 11 点后显得困")); Text(t("眼睛半闭")) }
            }
            Section {
                LabeledContent {
                    TextField("", text: $model.settings.robotName).frame(width: 180)
                } label: { Text(t("给它起个名字")); Text(t("菜单栏里显示")) }
            }
        }.formStyle(.grouped)
    }
}

// ---------- 提醒 ----------
struct AlertsPage: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        Form {
            Section {
                ForEach(KNOWN_AGENTS, id: \.self) { a in
                    LabeledContent {
                        HStack(spacing: 10) {
                            AgentConnectControl(agent: a)
                            Toggle("", isOn: Binding(get: { !model.settings.disabledAgents.contains(a) }, set: { on in
                                model.settings.disabledAgents.removeAll { $0 == a }
                                if !on { model.settings.disabledAgents.append(a) }
                            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                    } label: {
                        Text(a)
                        if a == "Cursor" || a == "Antigravity" { Text(t("只会提醒「做完了」，等你批准时它不告诉外面")) }
                    }
                }
            } header: { Text(t("哪些 AI 工具会提醒你")) }
            Section(t("哪些情况提醒")) {
                Toggle(t("要你批准"), isOn: $model.settings.kindApproval)
                Toggle(t("有问题问你"), isOn: $model.settings.kindQuestion)
                Toggle(t("做完了"), isOn: $model.settings.kindDone)
            }
            Section {
                Picker(t("提醒强度"), selection: $model.settings.alertLevel) {
                    Text(t("轻")).tag(0); Text(t("中")).tag(1); Text(t("强")).tag(2)
                }.pickerStyle(.segmented)
                Text([t("轻：只变脸、亮灯"), t("中：点一下头、响一声"), t("强：还没回去，每 5 分钟再闪一次、点头、响一声")][model.settings.alertLevel])
                    .font(.caption).foregroundStyle(.secondary)
                Picker(selection: $model.settings.alertSecs) {
                    Text(t("5 秒")).tag(5); Text(t("10 秒")).tag(10); Text(t("30 秒")).tag(30); Text(t("一直到我回去")).tag(0)
                } label: { Text(t("提醒画面停多久")); Text(t("停完回到首页；要你批准、有问题、出错时，彩灯和右上角的小 logo 留到你回去")) }
                Picker(t("没回去时再提醒"), selection: $model.settings.remind) {
                    Text(t("不再提醒")).tag(0); Text(t("5 分钟后")).tag(5); Text(t("10 分钟后")).tag(10); Text(t("30 分钟后")).tag(30)
                }
                Picker(selection: Binding(get: { model.settings.doneFlash ? -1 : model.settings.doneTTL }, set: { v in
                    if v < 0 { model.settings.doneFlash = true } else { model.settings.doneFlash = false; model.settings.doneTTL = v }
                })) {
                    Text(t("提醒完就熄")).tag(-1); Text(t("5 分钟")).tag(5); Text(t("10 分钟")).tag(10); Text(t("30 分钟")).tag(30); Text(t("等我回去")).tag(0)
                } label: { Text(t("「做完了」多久后熄灯")); Text(t("AI 已经做完，不是在等你批准")) }
                Picker(t("「要你批准」最多等多久"), selection: $model.settings.waitingTTL) {
                    Text(t("30 分钟")).tag(30); Text(t("1 小时")).tag(60); Text(t("2 小时")).tag(120); Text(t("直到处理")).tag(0)
                }
                LabeledContent(t("试一下")) { Button(t("发一条测试提醒")) { model.testAlert() } }
            }
            Section(t("额度")) {
                SliderRow(title: t("黄色提醒线"), note: t("剩余低于这个数，数字变黄"), value: $model.settings.midPercent, range: 10...80)
                SliderRow(title: t("红色提醒线"), note: t("剩余低于这个数，变红、摇一次头"), value: $model.settings.lowPercent, range: 1...40)
                Toggle(t("快用完时摇头"), isOn: $model.settings.shakeLow)
                Toggle(isOn: $model.settings.notifyRestored) { Text(t("额度恢复时告诉我")); Text(t("比如 5 小时额度恢复了，开心地点个头")) }
            }
        }
        .formStyle(.grouped)
    }
}

// ---------- 动作与声音 ----------
struct MotionPage: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        Form {
            Section(t("头")) {
                Toggle(t("头部动作"), isOn: $model.settings.motion)
                Picker(t("点头幅度"), selection: $model.settings.nod) { Text(t("小")).tag(0); Text(t("中")).tag(1); Text(t("大")).tag(2) }.pickerStyle(.segmented)
                SliderRow(title: t("平时抬头角度"), value: $model.settings.pitch, range: 5...40, unit: "°")
                Toggle(isOn: $model.settings.wander) { Text(t("没事时偶尔转转头")); Text(t("像在看你")) }
                LabeledContent(t("试一下")) { Button(t("让它动一下")) { model.send("nod") } }
            }
            Section(t("声音")) {
                Toggle(t("提示音"), isOn: $model.settings.sound)
                SliderRow(title: t("音量"), value: $model.settings.volume)
                LabeledContent(t("音色")) {
                    Picker("", selection: $model.settings.tone) {
                        Text(t("叮")).tag(0); Text(t("叮咚")).tag(1); Text(t("两声短哔")).tag(2); Text(t("小号角")).tag(3)
                    }.labelsHidden().frame(width: 140)
                    Button(t("试听")) { model.send("chime") }
                }
            }
            Section(t("灯")) {
                let on = model.settings.led, idle = on && model.settings.ledIdleOn
                Toggle(t("彩灯"), isOn: $model.settings.led)
                Toggle(isOn: $model.settings.ledIdleOn) {
                    Text(t("平时也亮着")); Text(t("没事的时候亮一盏微弱的灯。关掉后，只在有 AI 等你、额度快用完时亮"))
                }.disabled(!on)
                LabeledContent(t("平时的颜色")) {
                    Swatches(selection: $model.settings.ledIdle, colors: [("#3ddc84", t("绿")), ("#4aa3ff", t("蓝")), ("#b28cff", t("紫")), ("#ffffff", t("白"))])
                }.disabled(!idle).opacity(idle ? 1 : 0.4)
                LabeledContent(t("等你时的颜色")) {
                    Swatches(selection: $model.settings.ledAttn, colors: [("#ffb020", t("琥珀")), ("#ff7a1a", t("橙")), ("#ff4fa3", t("粉")), ("#4aa3ff", t("蓝"))])
                }.disabled(!on).opacity(on ? 1 : 0.4)
                SliderRow(title: t("亮度"), value: $model.settings.ledBright).disabled(!on)
            }
            Section(t("头顶触摸")) {
                Picker(selection: $model.settings.touch) {
                    Text(t("开心一下")).tag(0); Text(t("切换页面")).tag(1); Text(t("什么都不做")).tag(2)
                } label: { Text(t("平时摸头")); Text(t("有 AI 在等你（灯亮着）时摸头：提醒收起，灯和右上角的小 logo 一起熄掉") + t("。在全部额度页、明细页摸头 = 返回")) }
            }
        }.formStyle(.grouped)
    }
}

// ---------- 勿扰 ----------
struct QuietPage: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        Form {
            Section {
                Toggle(t("定时勿扰"), isOn: $model.settings.quietOn)
                LabeledContent(t("时间")) {
                    DatePicker("", selection: minutesBinding($model.settings.quietStart), displayedComponents: .hourAndMinute).labelsHidden()
                    Text(t("到"))
                    DatePicker("", selection: minutesBinding($model.settings.quietEnd), displayedComponents: .hourAndMinute).labelsHidden()
                }
                Picker(t("周末"), selection: $model.settings.weekend) {
                    Text(t("和平时一样")).tag(0); Text(t("周末全天勿扰")).tag(1); Text(t("周末不勿扰")).tag(2)
                }
            } footer: { Text(model.quietNow ? t("现在是勿扰时间") : "") }
            Section(t("勿扰时")) {
                Toggle(t("不动"), isOn: $model.settings.qStill)
                Toggle(t("不响"), isOn: $model.settings.qMute)
                Toggle(t("关灯"), isOn: $model.settings.qDark)
                SliderRow(title: t("屏幕亮度"), value: $model.settings.qBright, range: 0...60)
                Toggle(isOn: $model.settings.qFace) { Text(t("「要你批准」照样变脸")); Text(t("只变脸，不动不响")) }
            }
            Section {
                Toggle(t("Mac 锁屏或睡眠时，机器人也休息"), isOn: $model.settings.restWhenLocked)
            }
            Section {
                LabeledContent(t("临时勿扰")) {
                    if model.settings.dndUntil != nil {
                        Text(t("到 %@", DateFormatter.cached("MM-dd HH:mm").string(from: model.settings.dndUntil!))).foregroundStyle(.secondary)
                        Button(t("取消")) { model.settings.dndUntil = nil }
                    } else {
                        Button(t("1 小时")) { model.snooze(hours: 1) }
                        Button(t("到明早 8 点")) { model.snoozeUntilMorning() }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

// ---------- 订阅与数据 ----------
struct DataPage: View {
    @ObservedObject var model = AppModel.shared
    @ObservedObject var store = ProvidersStore.shared
    @State private var editing: String?
    @State private var adding = false
    var body: some View {
        Form {
            Section {
                LabeledContent(t("数据来源")) {
                    HStack(spacing: 5) {
                        Circle().fill(model.cliBusy ? Color.gray : Engine.codexbarPath() == nil ? Color.red : model.cliError.isEmpty ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(CodexBarCLI.describe() + (model.lastData.map { " · " + t("%@ 更新", DateFormatter.cached("HH:mm").string(from: $0)) } ?? ""))
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button(t("立即刷新")) { model.refreshNow() }
                }
                Picker(t("多久读一次"), selection: $model.settings.cliInterval) {
                    Text(t("2 分钟")).tag(120); Text(t("5 分钟")).tag(300); Text(t("10 分钟")).tag(600)
                }
                Picker(selection: $model.settings.staleMinutes) {
                    Text(t("10 分钟")).tag(10); Text(t("20 分钟")).tag(20); Text(t("1 小时")).tag(60)
                } label: { Text(t("超过多久没更新算「过期」")); Text(t("过期的数字会变灰")) }
            }
            Section {
                let ids = store.rowIds(model.subs)
                List {
                    ForEach(ids, id: \.self) { id in ProviderRow(id: id) { editing = id } }
                        .onMove { from, to in
                            var o = ids
                            o.move(fromOffsets: from, toOffset: to)
                            model.settings.subOrder = o
                        }
                }
                .frame(minHeight: CGFloat(max(1, ids.count)) * 44 + 10)
                HStack {
                    Button(t("添加服务商…")) { adding = true }.disabled(store.caps.isEmpty)
                    if store.loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
            } header: { Text(t("服务商（拖动排序）")) } footer: { Text(t("读取方式、API Key、提醒线、简称和图标都在每一家的「设置…」里。这些读取设置存在 CodexBar 的配置文件里，装了 CodexBar 应用的话两边共用。")) }
            Section {
                Toggle(t("用图标代替字母"), isOn: $model.settings.showIcons)
                LabeledContent {
                    Button(model.fetchingIcons ? t("正在获取…") : t("从官网获取官方图标")) { model.fetchIcons() }.disabled(model.fetchingIcons)
                } label: {
                    Text(t("官方图标"))
                    Text(t("从 Anthropic、OpenAI、Cursor、OpenCode、Google 的官网品牌素材里取 logo，只存在这台 Mac 上，显示在你自己的机器人和菜单栏里。"))
                }
                if !model.iconProgress.isEmpty {
                    ForEach(IconStore.sources, id: \.brand) { src in
                        if let st = model.iconProgress[src.brand] {
                            LabeledContent(src.brand) {
                                Text(st == nil ? t("正在下载…") : st! ? t("已获取") : t("没取到")).foregroundStyle(st == false ? .red : .secondary)
                            }
                        }
                    }
                }
            } header: { Text(t("图标")) } footer: { Text(t("这些 logo 是各公司的商标，小管家不带、也不上传。")) }
        }
        .formStyle(.grouped)
        .onAppear { store.load(); if let id = DataPage.openProvider { DataPage.openProvider = nil; editing = id } }
        .sheet(item: Binding(get: { editing.map { IdBox(id: $0) } }, set: { editing = $0?.id })) { b in
            ProviderSheet(id: b.id) { editing = nil }
        }
        .sheet(isPresented: $adding) {
            AddProviderSheet { id in
                adding = false
                if let id { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = id } }
            }
        }
    }
}

struct IdBox: Identifiable { var id: String }

extension DataPage {
    /// 从别处（菜单栏面板的黄条）打开设置时，直接打开某一家的设置页
    @MainActor static var openProvider: String?
    static let letterColors: [(String, String)] = [
        ("#e08a63", "陶土"), ("#7c9cff", "蓝"), ("#cfd4dc", "银"), ("#5fd3bc", "青绿"), ("#b28cff", "紫"),
        ("#8ab4ff", "天蓝"), ("#9be29b", "绿"), ("#ffd27a", "琥珀"), ("#ff8fb1", "粉"),
    ]
    /// 菜单里的小色块（不当模板图，保留颜色）
    static func swatch(_ hex: String, size: CGFloat = 12) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @MainActor static func pickIcon(_ id: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .svg, .jpeg]
        if p.runModal() == .OK, let u = p.url, IconStore.importImage(id, from: u) {
            AppModel.shared.settings.showIcons = true
            AppModel.shared.refresh(); AppModel.shared.objectWillChange.send()
        }
    }
}

// ---------- 设备 ----------
struct DevicePage: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var confirmToken = false
    @State private var confirmRestore = false
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    RobotScreen(state: "calm", width: 96)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.settings.robotName).font(.headline)
                        if let d = model.device, model.deviceOnline {
                            Text(t("已连接") + " · " + t("WiFi 信号") + " " + signal(d.rssi) + (d.fw.isEmpty ? "" : " · " + t("固件 %@", d.fw)))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(model.device == nil ? t("还没连上过") : t("没连上，上次 %@", DateFormatter.cached("HH:mm").string(from: model.device!.at)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(t("让它点头找一找")) { model.send("find") }
                }
            }
            Section {
                LabeledContent {
                    Button(t("更改…")) { openWizard(1, openWindow) }
                } label: { Text("WiFi"); Text(t("改 WiFi 要插上 USB 线")) }
                LabeledContent(t("地址"), value: model.device?.ip ?? "—")
                LabeledContent(t("电量"), value: model.deviceOnline ? (model.device?.batteryLong ?? "—") : "—")
                LabeledContent {
                    Text("••••••••").foregroundStyle(.secondary)
                    Button(t("重新生成")) { confirmToken = true }
                } label: { Text(t("连接口令")); Text(t("只有知道口令的设备能来拿数据")) }
            }
            Section {
                let fw = model.device?.fw ?? ""
                let latest = Flasher.bundledVersion
                LabeledContent {
                    Text(fw.isEmpty ? "—" : fw + (latest.isEmpty || fw == latest ? t("（最新）") : "")).foregroundStyle(.secondary)
                    if !latest.isEmpty && !fw.isEmpty && fw != latest {
                        Button(t("通过 WiFi 更新到 %@", latest)) { model.send("ota") }
                    }
                } label: { Text(t("固件")); Text(t("通过 WiFi 更新，不用插线")) }
                LabeledContent(t("重启机器人")) { Button(t("重启")) { model.send("reboot") } }
            }
            Section {
                LabeledContent {
                    Button(t("恢复…"), role: .destructive) { confirmRestore = true }
                } label: { Text(t("恢复出厂固件")); Text(t("需要插上 USB 线，用安装时备份的那份")) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(t("重新生成口令？"), isPresented: $confirmToken) {
            Button(t("重新生成")) { model.settings.token = randomToken(); openWizard(1, openWindow) }
        } message: { Text(t("机器人要插上 USB 线重新配置一次才能连上。")) }
        .alert(t("恢复出厂固件"), isPresented: $confirmRestore) {
            Button(t("打开备份文件夹")) { NSWorkspace.shared.open(Paths.backups) }
            Button(t("取消"), role: .cancel) {}
        } message: { Text(t("备份在小管家的「备份」文件夹里。插上 USB 线后，在安装向导的「连接机器人」一步选择「恢复出厂固件」。")) }
    }
    private func signal(_ rssi: Int) -> String { rssi == 0 ? "—" : rssi > -60 ? t("强") : rssi > -75 ? t("中") : t("弱") }
}
