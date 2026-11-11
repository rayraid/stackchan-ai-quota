// 安装向导：一步一屏（像连 AirPods）。第一次打开时出现，以后可以从设置里重新打开到某一步。
// 欢迎 → 连接机器人（插线 → 装固件 → 连 WiFi，在一屏里往下走）→ 接通你的 AI → 试一下
import SwiftUI

extension Notification.Name { static let wizardGoTo = Notification.Name("wizardGoTo") }

/// 打开向导并跳到某一步（0 欢迎、1 连接机器人、2 接通 AI、3 试一下）
@MainActor
func openWizard(_ step: Int, _ openWindow: OpenWindowAction) {
    WizardModel.requested = step
    NotificationCenter.default.post(name: .wizardGoTo, object: step)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "wizard")
}

@MainActor
final class WizardModel: ObservableObject {
    static var requested: Int?
    static let steps = 4

    @Published var step = 0
    // 读额度的授权
    @Published var claudeAuth: Bool? = nil
    @Published var authorizing = false
    // 机器人
    @Published var port: String?
    @Published var hello: RobotHello?
    @Published var robotInfo: [String: String] = [:]
    @Published var scanning = false
    @Published var backupFirst = true
    @Published var showOptions = false
    @Published var skipUpgrade = false
    @Published var flashing = false
    @Published var flashStage = ""
    @Published var flashProgress = 0.0
    @Published var flashResult: Bool?
    @Published var flashLog = ""
    // WiFi
    @Published var keepWifi = true
    @Published var ssid = ""
    @Published var password = ""
    @Published var linking = false
    @Published var linkResult: String?
    @Published var linkOK = false
    // 接通 AI、试一下
    @Published var agentTick = 0
    @Published var connectError: String?
    @Published var codexTrust = false
    @Published var tried = false
    @Published var showOthers = false

    var noScan = false               // 离屏截图时不碰串口
    var assumeOffline = false        // 离屏截图时当机器人没连上

    private var scanTimer: Timer?
    let flasher = Flasher()

    /// 「连接机器人」这一步现在走到哪
    enum Phase { case plug, firmware, wifi, linked, online }
    var online: Bool { AppModel.shared.deviceOnline && !assumeOffline }
    var phase: Phase {
        if linkOK { return .linked }
        if port == nil { return online ? .online : .plug }
        if hello == nil || (needsFirmware && !skipUpgrade) || flashing || flashResult == false { return .firmware }
        return .wifi
    }
    var needsFirmware: Bool { hello == nil || (!Flasher.bundledVersion.isEmpty && hello!.fw != Flasher.bundledVersion) }
    /// 这一步做完了才能点「继续」；只有「连接机器人」有前提
    var canContinue: Bool { step != 1 || linkOK || online }

    func goTo(_ s: Int) {
        step = max(0, min(Self.steps - 1, s))
        linkResult = nil; linkOK = false; tried = false; flashResult = nil; flashStage = ""; skipUpgrade = false; password = ""
    }

    func startScan() {
        guard !noScan else { return }
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } }
        scan()
    }
    func stopScan() { scanTimer?.invalidate(); scanTimer = nil }

    func scan() {
        guard !scanning, !flashing, !linking else { return }
        let ports = Robot.ports()
        guard let p = ports.first else { port = nil; hello = nil; return }
        if p == port && hello != nil { return }
        scanning = true
        DispatchQueue.global().async {
            let h = Robot.hello(p)
            let info = h != nil ? Robot.info(p) : [:]
            DispatchQueue.main.async {
                self.port = p; self.hello = h; self.robotInfo = info; self.scanning = false
                if let s = info["ssid"], !s.isEmpty, self.ssid.isEmpty { self.ssid = s }
                self.keepWifi = !(info["ssid"] ?? "").isEmpty && info["wifi"] == "3"
            }
        }
    }

    func flash() {
        guard let p = port else { return }
        flashing = true; flashResult = nil; flashProgress = 0; flashLog = ""
        let backup = backupFirst
        let mac = hello?.mac.replacingOccurrences(of: ":", with: "") ?? ""
        DispatchQueue.global().async {
            if backup {
                let name = "stackchan-\(mac.isEmpty ? "factory" : mac)-\(DateFormatter.cached("yyyyMMdd-HHmmss").string(from: Date())).bin"
                DispatchQueue.main.async { self.flashStage = t("正在备份出厂固件…") }
                let (ok, out) = self.flasher.backup(port: p, to: Paths.backups.appendingPathComponent(name)) { v in DispatchQueue.main.async { self.flashProgress = v * 0.45 } }
                if !ok { DispatchQueue.main.async { self.flashing = false; self.flashResult = false; self.flashLog = out; self.flashStage = t("备份没成功，固件没有动") } ; return }
            }
            DispatchQueue.main.async { self.flashStage = t("正在写入固件…") }
            let base = backup ? 0.45 : 0.0
            let (ok, out) = self.flasher.install(port: p) { v in DispatchQueue.main.async { self.flashProgress = base + v * (0.95 - base) } }
            DispatchQueue.main.async { self.flashStage = ok ? t("正在重启…") : t("安装没成功") }
            if ok { sleep(6) }
            let h = ok ? Robot.hello(p) : nil
            let info = h != nil ? Robot.info(p) : [:]
            DispatchQueue.main.async {
                self.flashing = false; self.flashProgress = ok ? 1 : self.flashProgress
                self.flashResult = ok; self.flashLog = out
                self.hello = h; self.robotInfo = info
                self.keepWifi = !(info["ssid"] ?? "").isEmpty && info["wifi"] == "3"
                self.flashStage = ok ? (h == nil ? t("装好了，但没读到机器人，拔掉 USB 线再插上") : "") : t("安装没成功")
                if ok { AppModel.shared.send("nod") }
            }
        }
    }

    func restore(from url: URL) {
        guard let p = port else { return }
        flashing = true; flashResult = nil; flashProgress = 0; flashStage = t("正在恢复出厂固件…")
        DispatchQueue.global().async {
            let (ok, out) = self.flasher.restore(port: p, from: url) { v in DispatchQueue.main.async { self.flashProgress = v } }
            DispatchQueue.main.async {
                self.flashing = false; self.flashResult = ok ? nil : false; self.flashLog = out
                self.flashStage = ok ? t("已恢复出厂固件") : t("恢复没成功")
                self.hello = nil
            }
        }
    }

    func link() {
        guard let p = port else { return }
        if (robotInfo["wifi"] ?? "") != "3" { keepWifi = false }
        linking = true; linkResult = nil; linkOK = false
        let ssid = keepWifi ? nil : self.ssid, pw = password
        let s = AppModel.shared.settings
        DispatchQueue.global().async {
            let r = Robot.provision(port: p, ssid: ssid, password: pw, settings: s)
            DispatchQueue.main.async {
                switch r {
                case .ok: self.linkResult = t("已写进机器人，正在等它连上这台 Mac…"); self.waitOnline(30)
                case .wifiFailed: self.linking = false; self.linkResult = t("连不上这个 WiFi，检查一下名字和密码，并确认是 2.4G 网络")
                case .noResponse: self.linking = false; self.linkResult = t("机器人没有回应，拔掉 USB 线再插上试试")
                }
            }
        }
    }
    private func waitOnline(_ left: Int) {
        if AppModel.shared.deviceOnline { linking = false; linkOK = true; linkResult = nil; AppModel.shared.send("nod"); return }
        if left <= 0 { linking = false; linkResult = t("机器人连上了 WiFi，但没找到这台 Mac。确认两者在同一个网络，并在系统弹窗里允许小管家访问本地网络。"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitOnline(left - 1) }
    }

    /// 还能一键接通的工具
    var connectable: [String] {
        let _ = agentTick
        return KNOWN_AGENTS.filter { HookInstaller.installed($0) && HookInstaller.oneClick($0) && HookInstaller.status($0) == .none }
    }
    func connect(_ agents: [String]) {
        var errs: [String] = []
        for a in agents {
            do { try HookInstaller.connect(a) } catch { errs.append(a + "：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) }
        }
        connectError = errs.isEmpty ? nil : errs.joined(separator: "\n")
        if agents.contains("Codex") && HookInstaller.status("Codex") == .needsTrust { codexTrust = true }   // Codex 还要你信任一次
        agentTick += 1
    }
}

struct WizardView: View {
    @ObservedObject var model = AppModel.shared
    @StateObject private var w: WizardModel
    init(step: Int = 0, model w: WizardModel? = nil) {
        let m = w ?? WizardModel()
        if w == nil { m.step = step }
        _w = StateObject(wrappedValue: m)
    }
    @Environment(\.dismissWindow) private var dismissWindow
    static let size = CGSize(width: 620, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) { page }
                .padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .id(model.lang)
        .activateOnAppear()
        .onAppear {
            if let s = WizardModel.requested { w.goTo(s); WizardModel.requested = nil }
            if w.step == 1 { w.startScan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wizardGoTo)) { n in
            if let s = n.object as? Int { w.goTo(s); WizardModel.requested = nil }
        }
        .onChange(of: w.step) { _, s in if s == 1 { w.startScan() } else { w.stopScan() } }
        .onDisappear { w.stopScan() }
        .sheet(isPresented: $w.codexTrust) { AgentHowTo(agent: "Codex") { w.codexTrust = false; w.agentTick += 1 } }
        .alert(w.connectError ?? "", isPresented: Binding(get: { w.connectError != nil }, set: { if !$0 { w.connectError = nil } })) { Button(t("好")) {} }
    }

    // ---------- 底部：返回 / 小圆点 / 继续 ----------
    private var footer: some View {
        HStack(spacing: 10) {
            if w.step == 0 {
                HStack(spacing: 4) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Picker("", selection: $model.settings.language) {
                        Text(t("跟随系统")).tag("auto"); Text("简体中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
                    }.labelsHidden().fixedSize()
                }
            } else {
                Button(t("返回")) { w.step -= 1 }.disabled(w.flashing || w.linking)
            }
            if w.step == 1 && !w.canContinue {
                Button(t("先跳过，以后再连")) { w.step = 2 }
                    .buttonStyle(.link).font(.callout).disabled(w.flashing || w.linking)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<WizardModel.steps, id: \.self) { i in
                    Circle().fill(i == w.step ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            if w.step == 2 && !w.connectable.isEmpty {
                Button(t("全部接通")) { w.connect(w.connectable) }
            }
            Button(nextTitle) { next() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!w.canContinue || w.flashing || w.linking)
        }
        .controlSize(.large)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var nextTitle: String { w.step == 0 ? t("开始") : w.step == WizardModel.steps - 1 ? t("开始使用") : t("继续") }
    private func next() {
        if w.step == WizardModel.steps - 1 {
            model.settings.setupDone = true
            dismissWindow(id: "wizard")
            return
        }
        w.step += 1
    }

    @ViewBuilder private var page: some View {
        switch w.step {
        case 0: welcome
        case 1: robot
        case 2: agents
        default: tryIt
        }
    }

    // ---------- 共用：大图、标题、一句话、卡片 ----------
    private func header(_ title: String, _ lead: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            Text(lead).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460)
    }
    private func hero<V: View>(_ height: CGFloat = 178, @ViewBuilder _ v: () -> V) -> some View {
        v().frame(height: height)
    }

    // ---------- ① 欢迎 ----------
    private var welcome: some View {
        VStack(spacing: 12) {
            hero { RobotScreen(state: "calm", width: 210) }
            header(t("让 StackChan 帮你盯着 AI"), t("它会一直显示各家 AI 还剩多少额度；有 AI 等你回复时，它会变色、点头、响一声。"))
            WizardCard {
                WizardRow(symbol: "cpu", title: t("一台 StackChan"))
                WizardRow(symbol: "cable.connector", title: t("一根能传数据的 USB-C 线"), note: t("只能充电的线插上没反应"))
                WizardRow(symbol: "wifi", title: t("和这台 Mac 同一个 WiFi（2.4G）"))
            }
            Text(t("大约 5 分钟")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // ---------- ② 连接机器人：插线 → 装固件 → 连 WiFi ----------
    @ViewBuilder private var robot: some View {
        switch w.phase {
        case .plug:
            hero { PlugArt(found: false) }
            header(t("把机器人接到这台 Mac"), t("用 USB-C 线连起来，插上就会自动找到，不用点什么。"))
            WizardCard {
                WizardRow(title: t("正在找机器人…"), note: t("插上 10 秒还没反应：换一根线，或者换一个 USB 口")) { ProgressView().controlSize(.small) }
            }
        case .firmware:
            hero { PlugArt(found: true) }
            if let h = w.hello, w.needsFirmware {
                header(t("找到了，可以升级固件"), t("它装的是小管家固件 %@，这个版本的小管家带的是 %@。", h.fw, Flasher.bundledVersion))
            } else {
                header(t("找到了，给它装上小管家固件"), t("大约 1 分钟。装之前会先把出厂固件备份到这台 Mac，以后想换回去点一下就行。"))
            }
            firmwareCard
        case .wifi:
            hero { FaceArt(kind: .look, width: 200) }
            header(t("让它连上 WiFi"), t("要和这台 Mac 同一个网络。密码经 USB 线直接写进机器人，不经过网络。"))
            wifiCard
        case .linked, .online:
            hero { FaceArt(kind: .happy, width: 200) }
            header(w.phase == .linked ? t("连上了！") : t("机器人已经连上了"),
                   w.phase == .linked ? t("它刚才点了一下头。现在可以拔掉 USB 线了，插着也行（顺便充电）。") : t("要换 WiFi 或重新装固件，就用 USB 线把它接到这台 Mac。"))
            WizardCard {
                WizardRow(title: t("StackChan 已连上这台 Mac"),
                          note: model.device.map { t("地址 %@ · 固件 %@", $0.ip, $0.fw.isEmpty ? "—" : $0.fw) } ?? "") { CheckDot() }
            }
        }
    }

    private var firmwareCard: some View {
        VStack(spacing: 8) {
            WizardCard {
                WizardRow(title: w.hello == nil ? t("StackChan（CoreS3）") : "StackChan",
                          note: w.hello.map { t("小管家固件 %@", $0.fw) } ?? t("现在是出厂固件")) { CheckDot() }
                VStack(alignment: .leading, spacing: 7) {
                    if w.flashing || w.flashResult == true {
                        HStack { Text(w.flashStage).font(.callout); Spacer(); Text("\(Int(w.flashProgress * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                        ProgressView(value: w.flashProgress)
                    } else {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                if w.flashResult == false {
                                    Text(w.flashStage).foregroundStyle(.red)
                                    Text(t("拔掉 USB 线再插上，然后再试一次")).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(w.hello == nil ? t("装好后机器人会点一下头") : t("升级不会清掉 WiFi 和设置"))
                                    Text(t("装的时候别拔线")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if w.hello != nil { Button(t("先不升级")) { w.skipUpgrade = true } }
                            Button(w.flashResult == false ? t("再试一次") : w.hello == nil ? t("安装") : t("升级")) { w.flash() }
                                .buttonStyle(.borderedProminent).disabled(!Flasher.available)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            if !Flasher.available { Text(t("这个版本的小管家没有打包固件，请从开源仓库下载完整版。")).font(.caption).foregroundStyle(.red) }
            if w.flashResult == false && !w.flashLog.isEmpty {
                ScrollView { Text(w.flashLog.suffix(1500)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 70).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            DisclosureGroup(isExpanded: $w.showOptions) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(t("先备份出厂固件（推荐，以后可以一键恢复）"), isOn: $w.backupFirst).disabled(w.flashing || w.hello != nil)
                    Menu(t("恢复出厂固件…")) {
                        let files = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "bin" }
                        if files.isEmpty { Text(t("还没有备份")) }
                        ForEach(files, id: \.self) { f in Button(f.lastPathComponent) { w.restore(from: f) } }
                    }.fixedSize().disabled(w.flashing)
                }.padding(.top, 4)
            } label: { Text(t("选项…")).font(.callout).foregroundStyle(.secondary) }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .frame(maxWidth: 460)
    }

    private var wifiCard: some View {
        let connected = (w.robotInfo["wifi"] ?? "") == "3"
        let cur = w.robotInfo["ssid"] ?? ""
        return VStack(spacing: 10) {
            WizardCard {
                VStack(alignment: .leading, spacing: 9) {
                    if connected && !cur.isEmpty {
                        Picker("", selection: $w.keepWifi) {
                            Text(t("用它现在连着的：%@", cur)).tag(true)
                            Text(t("换一个 WiFi")).tag(false)
                        }.pickerStyle(.radioGroup).labelsHidden()
                    }
                    if !w.keepWifi || !connected {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t("WiFi 名称")).font(.caption).foregroundStyle(.secondary)
                                TextField("", text: $w.ssid)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t("密码")).font(.caption).foregroundStyle(.secondary)
                                SecureField(t("输入 WiFi 密码"), text: $w.password)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            HStack(spacing: 10) {
                Button(t("连上")) { w.link() }
                    .buttonStyle(.borderedProminent)
                    .disabled(w.linking || ((!w.keepWifi || !connected) && w.ssid.isEmpty))
                if w.linking { ProgressView().controlSize(.small) }
                Text(w.linkResult ?? t("只支持 2.4G")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .frame(maxWidth: 460)
    }

    // ---------- ③ 接通你的 AI ----------
    private var agents: some View {
        let _ = w.agentTick
        let cliOK = Engine.codexbarPath() != nil && !model.cliBusy
        let claudeOK = w.claudeAuth ?? model.subs.contains { $0.id == "claude" && $0.shown != nil }
        return VStack(spacing: 12) {
            hero(64) {
                HStack(spacing: 14) {
                    ForEach(installedAgents.isEmpty ? KNOWN_AGENTS : installedAgents, id: \.self) { a in AgentLogo(agent: a, size: 52) }
                }
            }
            header(t("接通你的 AI"), t("接通后，这个 AI 等你回复时机器人会提醒你。小管家会在它的设置里加一行，改之前先备份，随时可以断开。"))
            WizardCard {
                // 只列这台 Mac 上装了的；没装的收进「其他 AI 工具」
                if installedAgents.isEmpty {
                    WizardRow(title: t("这台 Mac 上还没装支持的 AI 工具"), note: t("装好以后可以在设置「提醒」里接通"), leading: { SymbolCircle(symbol: "questionmark") }) { EmptyView() }
                }
                ForEach(installedAgents, id: \.self) { a in WizardAgentRow(agent: a, w: w) }
                let others = KNOWN_AGENTS.filter { !installedAgents.contains($0) }
                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $w.showOthers) {
                        ForEach(others, id: \.self) { a in WizardAgentRow(agent: a, w: w) }
                    } label: {
                        Text(t("其他 AI 工具（这台 Mac 上没装）：%@", others.joined(separator: "、"))).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            WizardCard {
                if !cliOK {
                    WizardRow(title: model.cliBusy ? t("正在准备读取额度的组件…") : t("读取额度的组件没准备好"), note: CodexBarCLI.describe()) {
                        if model.cliBusy { ProgressView().controlSize(.small) } else { Button(t("重试")) { model.prepareCLI() } }
                    }
                }
                WizardRow(title: t("读取 Claude 的额度"), note: claudeOK ? "" : t("要你在钥匙串弹窗里点一次「始终允许」"), leading: { AgentLogo(agent: "Claude Code", size: 26) }) {
                    if claudeOK && !w.authorizing { StatusPill(color: .green, text: t("已允许")) }
                    else {
                        Button(w.authorizing ? t("等你点允许…") : t("允许读取")) {
                            w.authorizing = true
                            Env.authorizeClaude { ok in DispatchQueue.main.async { w.authorizing = false; w.claudeAuth = ok; model.refreshNow() } }
                        }.disabled(w.authorizing || !cliOK)
                    }
                }
            }
        }
    }

    private var installedAgents: [String] { let _ = w.agentTick; return KNOWN_AGENTS.filter { HookInstaller.installed($0) } }

    // ---------- ④ 试一下 ----------
    private var tryIt: some View {
        let online = model.deviceOnline && !w.assumeOffline
        return VStack(spacing: 12) {
            hero { RobotScreen(state: w.tried ? "approval" : "calm", width: 210) }
            header(w.tried ? t("看到了吗？") : t("试一下"),
                   w.tried ? t("真的有 AI 等你时就是这样。几秒后它自己收起；摸一下它的头能马上收起。")
                           : t("点下面的按钮，机器人会像真的有 AI 在等你批准那样提醒你一次。"))
            if online {
                Button(w.tried ? t("再来一次") : t("发一条测试提醒")) { model.testAlert(); w.tried = true }
                    .controlSize(.large).buttonStyle(.bordered)
            }
            WizardCard {
                if !online {
                    WizardRow(title: t("机器人还没连上"), note: t("连上以后才能试；也可以以后在设置里试")) {
                        Button(t("去连接")) { w.step = 1 }
                    }
                }
                WizardRow(symbol: "menubar.rectangle", title: t("以后在菜单栏右上角的小机器人里找到我"), note: t("额度、勿扰、设置都在那里"))
                HStack {
                    Toggle(t("开机时自动打开小管家"), isOn: $model.settings.launchAtLogin).toggleStyle(.checkbox)
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
    }
}

// ---------- 向导里的小零件 ----------

/// 浅灰色圆角卡片，里面一行一行用细线隔开
struct WizardCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedRows()) { content() }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        .frame(maxWidth: 460)
    }
}
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { c in
            if c.id != children.first?.id { Divider().padding(.leading, 12) }
            c
        }
    }
}

struct WizardRow<Leading: View, Trailing: View>: View {
    var title: String
    var note: String = ""
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension WizardRow where Leading == SymbolCircle {
    init(symbol: String, title: String, note: String = "", @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, note: note, leading: { SymbolCircle(symbol: symbol) }, trailing: trailing)
    }
}
extension WizardRow where Leading == SymbolCircle, Trailing == EmptyView {
    init(symbol: String, title: String, note: String = "") {
        self.init(title: title, note: note, leading: { SymbolCircle(symbol: symbol) }, trailing: { EmptyView() })
    }
}
extension WizardRow where Leading == EmptyView {
    init(title: String, note: String = "", @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, note: note, leading: { EmptyView() }, trailing: trailing)
    }
}

struct SymbolCircle: View {
    var symbol: String
    var on = false
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .frame(width: size, height: size)
            .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.075)))
    }
}

struct CheckDot: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, .green)
    }
}

struct StatusPill: View {
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// AI 工具的图标：官方 logo 放在白色圆角方块里，没有就用字母方块
struct AgentLogo: View {
    var agent: String
    var size: CGFloat = 26
    static func iconId(_ agent: String) -> String {
        ["Claude Code": "claude", "Codex": "codex", "Cursor": "cursor", "OpenCode": "opencode", "Antigravity": "antigravity"][agent] ?? agent.lowercased()
    }
    var body: some View {
        let id = Self.iconId(agent)
        let info = PROVIDERS[id] ?? .init(name: agent, mono: String(agent.prefix(2)).uppercased(), hue: "#aab2bd")
        BrandBadge(id: id, mono: info.mono, hue: info.hue, size: size * 0.6)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// 「接通你的 AI」里的一行：一个状态 + 最多一个按钮
struct WizardAgentRow: View {
    var agent: String
    @ObservedObject var w: WizardModel
    @State private var howTo = false
    var body: some View {
        let _ = w.agentTick
        let installed = HookInstaller.installed(agent)
        let st = HookInstaller.status(agent)
        let note: String = agent == "Codex" && st == .none && installed ? t("接通后还要在 Codex 里点一次「信任」")
            : (agent == "Cursor" || agent == "Antigravity") ? t("只会提醒「做完了」") : ""
        WizardRow(title: agent, note: note, leading: { AgentLogo(agent: agent) }) {
            if !installed {
                Text(t("这台 Mac 上没装")).font(.caption).foregroundStyle(.secondary)
            } else {
                switch st {
                case .connected, .viaPeon: StatusPill(color: .green, text: t("已接通"))
                case .needsTrust:
                    StatusPill(color: .orange, text: t("还差一步"))
                    Button(t("去 Codex 信任…")) { howTo = true }
                case .none:
                    if HookInstaller.oneClick(agent) { Button(t("接通")) { w.connect([agent]) } }
                    else { Button(t("怎么接通…")) { howTo = true } }
                }
            }
        }
        .opacity(installed ? 1 : 0.5)
        .sheet(isPresented: $howTo) { AgentHowTo(agent: agent) { howTo = false; w.agentTick += 1 } }
    }
}

/// 机器人小屏的示意脸（向导的大图、菜单面板里机器人没连上时用）：和固件一样的胶囊眼
struct FaceArt: View {
    enum Kind { case calm, look, happy, sleep }
    var kind: Kind
    var width: CGFloat = 200
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 320
            func capsule(_ x: CGFloat, _ dx: CGFloat) {
                let r = CGRect(x: (x - 21 + dx) * k, y: (104 - 30) * k, width: 42 * k, height: 60 * k)
                var g = ctx; g.addFilter(.shadow(color: .white.opacity(0.55), radius: 6 * k))
                g.fill(Path(roundedRect: r, cornerRadius: 21 * k), with: .color(.white))
            }
            switch kind {
            case .calm: capsule(112, 0); capsule(208, 0)
            case .look: capsule(112, -14); capsule(208, -14)
            case .happy:
                var g = ctx; g.addFilter(.shadow(color: .white.opacity(0.5), radius: 5 * k))
                for x in [112.0, 208.0] {       // 两只眼睛各画各的，不然中间会连一道线
                    var a = Path(); a.addArc(center: CGPoint(x: x * k, y: 116 * k), radius: 24 * k, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    g.stroke(a, with: .color(.white), style: StrokeStyle(lineWidth: 11 * k, lineCap: .round))
                }
            case .sleep:
                var p = Path()
                for x in [112.0, 208.0] { p.move(to: CGPoint(x: (x - 20) * k, y: 106 * k)); p.addLine(to: CGPoint(x: (x + 20) * k, y: 106 * k)) }
                ctx.stroke(p, with: .color(Color(white: 0.55)), style: StrokeStyle(lineWidth: 9 * k, lineCap: .round))
                ctx.draw(Text("z").font(.system(size: 26 * k, weight: .bold)).foregroundColor(Color(white: 0.55)), at: CGPoint(x: 258 * k, y: 62 * k))
                ctx.draw(Text("z").font(.system(size: 18 * k, weight: .bold)).foregroundColor(Color(white: 0.42)), at: CGPoint(x: 276 * k, y: 42 * k))
            }
        }
        .frame(width: width, height: width * 0.75)
        .background(Color(red: 0.02, green: 0.03, blue: 0.04))
        .padding(width / 30)
        .background(RoundedRectangle(cornerRadius: width / 22).fill(Color.black))
    }
}

/// 插线示意：机器人 ⟷ USB 线 ⟷ Mac。还没找到时线是会流动的虚线，找到了变成绿色实线加一个勾
struct PlugArt: View {
    var found: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: found)) { tl in
            let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)) * -24
            Canvas { ctx, _ in
                let fill = GraphicsContext.Shading.color(Color.primary.opacity(0.06))
                let line = GraphicsContext.Shading.color(Color.primary.opacity(0.25))
                func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path { Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r) }
                // 机器人
                let head = rr(26, 22, 118, 98, 20); ctx.fill(head, with: fill); ctx.stroke(head, with: line, lineWidth: 1.5)
                ctx.fill(rr(37, 33, 96, 70, 8), with: .color(Color(red: 0.02, green: 0.03, blue: 0.04)))
                if found {
                    for x in [72.0, 98.0] {
                        var a = Path(); a.addArc(center: CGPoint(x: x, y: 76), radius: 10, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                        ctx.stroke(a, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                } else {
                    ctx.fill(rr(56, 55, 15, 24, 7.5), with: .color(.white)); ctx.fill(rr(84, 55, 15, 24, 7.5), with: .color(.white))
                }
                let base = rr(48, 120, 74, 34, 9); ctx.fill(base, with: fill); ctx.stroke(base, with: line, lineWidth: 1.5)
                ctx.fill(rr(138, 126, 12, 9, 2), with: .color(Color.primary.opacity(0.45)))
                // Mac
                let disp = rr(232, 18, 128, 86, 9); ctx.fill(disp, with: fill); ctx.stroke(disp, with: line, lineWidth: 1.5)
                ctx.fill(rr(240, 26, 112, 66, 3), with: .color(Color.accentColor.opacity(0.16)))
                ctx.fill(rr(240, 26, 112, 7, 0), with: .color(Color.accentColor.opacity(0.24)))
                var stand = Path(); stand.move(to: CGPoint(x: 284, y: 104)); stand.addLine(to: CGPoint(x: 308, y: 104)); stand.addLine(to: CGPoint(x: 313, y: 130)); stand.addLine(to: CGPoint(x: 279, y: 130)); stand.closeSubpath()
                ctx.fill(stand, with: fill); ctx.stroke(stand, with: line, lineWidth: 1.2)
                ctx.fill(rr(266, 130, 60, 6, 3), with: line)
                ctx.fill(rr(254, 136, 10, 8, 2), with: .color(Color.primary.opacity(0.45)))
                // 线
                var cable = Path(); cable.move(to: CGPoint(x: 150, y: 131)); cable.addCurve(to: CGPoint(x: 262, y: 142), control1: CGPoint(x: 200, y: 166), control2: CGPoint(x: 222, y: 118))
                if found {
                    ctx.stroke(cable, with: .color(.green), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: 177, y: 115, width: 26, height: 26)), with: .color(.green))
                    var ck = Path(); ck.move(to: CGPoint(x: 184, y: 128)); ck.addLine(to: CGPoint(x: 188, y: 132)); ck.addLine(to: CGPoint(x: 196, y: 124))
                    ctx.stroke(ck, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                } else {
                    ctx.stroke(cable, with: .color(Color.primary.opacity(0.4)), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5], dashPhase: phase))
                }
            }
            .frame(width: 380, height: 170)
        }
    }
}
