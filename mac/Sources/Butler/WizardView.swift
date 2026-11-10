// 安装向导：第一次打开时出现，以后可以从菜单栏重新运行
import SwiftUI

@MainActor
final class WizardModel: ObservableObject {
    @Published var step = 0
    // 必备工具
    @Published var claudeAuth: Bool? = nil
    @Published var authorizing = false
    // 机器人
    @Published var port: String?
    @Published var hello: RobotHello?
    @Published var robotInfo: [String: String] = [:]
    @Published var scanning = false
    @Published var backupFirst = true
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

    private var scanTimer: Timer?
    let flasher = Flasher()

    var needsFirmware: Bool { hello == nil || (!Flasher.bundledVersion.isEmpty && hello!.fw != Flasher.bundledVersion) }

    func startScan() {
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
            DispatchQueue.main.async {
                self.flashing = false; self.flashProgress = ok ? 1 : self.flashProgress
                self.flashResult = ok; self.flashLog = out
                self.hello = h
                self.flashStage = ok ? t("装好了，机器人刚才点了一下头") : t("安装没成功")
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
                self.flashing = false; self.flashResult = ok; self.flashLog = out
                self.flashStage = ok ? t("已恢复出厂固件") : t("恢复没成功")
            }
        }
    }

    func link() {
        guard let p = port else { return }
        linking = true; linkResult = nil; linkOK = false
        let ssid = keepWifi ? nil : self.ssid, pw = password
        let s = AppModel.shared.settings
        DispatchQueue.global().async {
            let r = Robot.provision(port: p, ssid: ssid, password: pw, settings: s)
            DispatchQueue.main.async {
                switch r {
                case .ok: self.linkResult = t("已写进机器人，正在等它连上小管家…"); self.waitOnline(30)
                case .wifiFailed: self.linking = false; self.linkResult = t("连不上这个 WiFi，检查一下名字和密码，并确认是 2.4G 网络")
                case .noResponse: self.linking = false; self.linkResult = t("机器人没有回应，拔掉 USB 线再插上试试")
                }
            }
        }
    }
    private func waitOnline(_ left: Int) {
        if AppModel.shared.deviceOnline { linking = false; linkOK = true; linkResult = t("连上了！"); return }
        if left <= 0 { linking = false; linkResult = t("机器人连上了 WiFi，但没找到这台 Mac。确认两者在同一个网络，并在系统弹窗里允许小管家访问本地网络。"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitOnline(left - 1) }
    }
}

struct WizardView: View {
    @ObservedObject var model = AppModel.shared
    @StateObject private var w: WizardModel
    init(step: Int = 0) { let m = WizardModel(); m.step = step; _w = StateObject(wrappedValue: m) }
    @Environment(\.dismissWindow) private var dismissWindow

    // 按 Apple 设计规范只留必须的几步；显示哪些 AI、机器人长什么样都有默认值，以后在设置里改
    private var steps: [String] { [t("欢迎"), t("读取额度和提醒"), t("连接机器人"), t("连上 WiFi"), t("完成")] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 步骤列表：和 macOS 安装器一样的小圆点
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, name in
                        HStack(spacing: 10) {
                            Circle().fill(i == w.step ? Color.accentColor : Color.secondary.opacity(i < w.step ? 0.8 : 0.4)).frame(width: 9, height: 9)
                            Text(name).foregroundStyle(i == w.step ? Color.primary : i < w.step ? Color.primary.opacity(0.85) : Color.secondary)
                                .fontWeight(i == w.step ? .bold : .regular)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 22)
                .frame(width: 200, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { page }
                        .padding(.horizontal, 30).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Spacer()
                if w.step > 0 { Button(t("返回")) { go(-1) }.disabled(w.flashing || w.linking) }
                Button(w.step == steps.count - 1 ? t("完成") : t("继续")) { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(w.flashing || w.linking)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 820, height: 560)
        .id(model.lang)
        .activateOnAppear()
        .onChange(of: w.step) { _, s in if s == 2 || s == 3 { w.startScan() } else { w.stopScan() } }
        .onDisappear { w.stopScan() }
    }

    private func go(_ d: Int) {
        if w.step == steps.count - 1 && d > 0 {
            model.settings.setupDone = true
            dismissWindow(id: "wizard")
            return
        }
        w.step = max(0, min(steps.count - 1, w.step + d))
    }

    @ViewBuilder private var page: some View {
        switch w.step {
        case 0: welcome
        case 1: tools
        case 2: robot
        case 3: wifi
        default: finish
        }
    }

    private func title(_ s: String, _ sub: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s).font(.title.bold())
            if !sub.isEmpty { Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func hint(_ head: String, _ body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            (Text(head + "　").fontWeight(.semibold) + Text(body).foregroundStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func checkRow(_ ok: Bool?, _ name: String, _ note: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.circle.fill" : "circle.dotted")
                .font(.system(size: 20))
                .foregroundStyle(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 6)
    }

    // ---------- 1 欢迎 ----------
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                RobotScreen(state: "calm", width: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("让 StackChan 帮你盯着 AI")).font(.title.bold())
                    Text(t("装好以后，它会一直显示各家 AI 订阅还剩多少；任何一个 AI 编程助手在等你回复时，它会变脸、点头、亮灯、响一声。"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            hint(t("需要准备"), t("一台 StackChan、一根 USB-C 数据线、它和这台 Mac 连同一个 WiFi（2.4G）。大约 5 分钟。"))
            Picker(t("语言"), selection: $model.settings.language) {
                Text(t("跟随系统")).tag("auto"); Text("简体中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
            }.frame(width: 300)
        }
    }

    // ---------- 2 读取额度和提醒 ----------
    // 读额度的 CodexBar 命令行小管家自己准备；提醒用小管家自己的钩子，每个 AI 工具一键接通
    private var tools: some View {
        let cliOK = Engine.codexbarPath() != nil && !model.cliBusy
        return VStack(alignment: .leading, spacing: 12) {
            title(t("读取额度和提醒"), t("读额度的组件小管家会自己准备。下面点几下，让它能读到 Claude 的额度、知道哪个 AI 在等你。"))
            VStack(spacing: 0) {
                checkRow(model.cliBusy ? nil : cliOK, t("读取额度的组件"), CodexBarCLI.describe()) {
                    if model.cliBusy { ProgressView().controlSize(.small) }
                    else if !cliOK { Button(t("重试")) { model.prepareCLI() } }
                }
                Divider()
                checkRow(w.claudeAuth ?? model.subs.contains { $0.id == "claude" && $0.shown != nil }, t("读取 Claude 额度的授权"), t("会弹出钥匙串窗口，请点「始终允许」")) {
                    Button(w.authorizing ? t("等你点允许…") : t("去授权")) {
                        w.authorizing = true
                        Env.authorizeClaude { ok in DispatchQueue.main.async { w.authorizing = false; w.claudeAuth = ok; model.refreshNow() } }
                    }.disabled(w.authorizing || !cliOK)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            Text(t("哪些 AI 在等你时提醒")).font(.headline).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(KNOWN_AGENTS.enumerated()), id: \.offset) { i, a in
                    if i > 0 { Divider() }
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a)
                            if a == "Cursor" || a == "Antigravity" { Text(t("只会提醒「做完了」")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        AgentConnectControl(agent: a)
                    }.padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // ---------- 3 连接机器人 ----------
    private var robot: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(t("用 USB 线把 StackChan 接到这台 Mac"))
            HStack(spacing: 12) {
                if w.port == nil {
                    ProgressView().controlSize(.small)
                    Text(t("等你插上…（用能传数据的 USB-C 线）")).foregroundStyle(.secondary)
                } else if let h = w.hello {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading) {
                        Text(t("找到了：StackChan（CoreS3）")).fontWeight(.semibold)
                        Text(t("已经装了小管家固件 %@", h.fw) + (w.needsFirmware ? " · " + t("可以升级到 %@", Flasher.bundledVersion) : " · " + t("是最新的"))).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading) {
                        Text(t("找到了一台设备")).fontWeight(.semibold)
                        Text(t("现在是出厂固件或别的固件，需要装小管家固件")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if w.port != nil {
                if w.hello == nil || w.needsFirmware {
                    Toggle(t("先备份出厂固件（推荐，约 1 分钟，以后可以一键恢复）"), isOn: $w.backupFirst).disabled(w.flashing || w.hello != nil)
                }
                HStack(spacing: 12) {
                    if w.hello == nil || w.needsFirmware {
                        Button(w.hello == nil ? t("安装小管家固件") : t("升级固件")) { w.flash() }
                            .buttonStyle(.borderedProminent).disabled(w.flashing || !Flasher.available)
                    }
                    Menu(t("恢复出厂固件")) {
                        let files = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "bin" }
                        if files.isEmpty { Text(t("还没有备份")) }
                        ForEach(files, id: \.self) { f in Button(f.lastPathComponent) { w.restore(from: f) } }
                    }.fixedSize().disabled(w.flashing)
                    Text(w.flashStage.isEmpty ? t("安装时不要拔线；装好后机器人的头会动一下") : w.flashStage).font(.caption).foregroundStyle(w.flashResult == false ? .red : .secondary)
                }
                if w.flashing || w.flashResult != nil { ProgressView(value: w.flashProgress) }
                if !Flasher.available { Text(t("这个版本的小管家没有打包固件，请从开源仓库下载完整版。")).font(.caption).foregroundStyle(.red) }
                if w.flashResult == false && !w.flashLog.isEmpty {
                    ScrollView { Text(w.flashLog.suffix(1500)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 110).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    // ---------- 4 WiFi ----------
    private var wifi: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(t("告诉机器人连哪个 WiFi"), t("要和这台 Mac 连同一个网络。密码通过 USB 线直接写进机器人，不会经过网络、也不会上传。"))
            if w.hello == nil {
                Text(t("先在上一步插上机器人并装好固件。")).foregroundStyle(.orange)
            } else {
                if let cur = w.robotInfo["ssid"], !cur.isEmpty, w.robotInfo["wifi"] == "3" {
                    Picker("", selection: $w.keepWifi) {
                        Text(t("保持现在的 WiFi：%@", cur)).tag(true)
                        Text(t("换一个 WiFi")).tag(false)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                if !w.keepWifi || (w.robotInfo["wifi"] ?? "") != "3" {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(t("WiFi 名称")).font(.caption).foregroundStyle(.secondary)
                        TextField("", text: $w.ssid).frame(width: 280)
                        Text(t("密码")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        SecureField(t("输入 WiFi 密码"), text: $w.password).frame(width: 280)
                    }
                }
                HStack(spacing: 12) {
                    Button(t("写进机器人")) {
                        if (w.robotInfo["wifi"] ?? "") != "3" { w.keepWifi = false }
                        w.link()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(w.linking || (!w.keepWifi && w.ssid.isEmpty))
                    if w.linking { ProgressView().controlSize(.small) }
                    if let r = w.linkResult { Text(r).font(.callout).foregroundStyle(w.linkOK ? .green : .secondary).fixedSize(horizontal: false, vertical: true) }
                }
                hint(t("只支持 2.4G"), t("机器人不支持 5G WiFi。如果家里路由器两个频段同名，一般也能连上。"))
            }
        }
    }

    // ---------- 5 完成（顺便试一下） ----------
    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(t("装好了"), t("以后在屏幕右上角菜单栏的小机器人图标里找到我。"))
            checkRow(model.deviceOnline, model.deviceOnline ? t("机器人已连上，刚才点了一下头") : t("机器人还没连上"),
                     model.device.map { t("地址 %@ · 固件 %@", $0.ip, $0.fw.isEmpty ? "—" : $0.fw) } ?? t("回到「连上 WiFi」那一步再试一次")) { EmptyView() }
            HStack(spacing: 8) {
                Button(t("再试一次")) { model.send("nod") }
                Button(t("发一条测试提醒")) { model.testAlert() }
                Button(t("消掉测试提醒")) { model.engine.clear() }
            }
            .disabled(!model.deviceOnline)
            .padding(.leading, 34)
            Form {
                Toggle(t("开机自动启动"), isOn: $model.settings.launchAtLogin)
                Picker(t("菜单栏显示"), selection: $model.settings.menuBarMode) {
                    Text(t("小机器人 + 最紧张的额度")).tag(0); Text(t("只显示小机器人")).tag(1); Text(t("小机器人 + 在等你的数量")).tag(2)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).scrollDisabled(true).frame(maxWidth: 480, maxHeight: 110)
            hint(t("小提示"), t("要显示哪些 AI、机器人长什么样，以后都能在设置里改。") + t("夜里 %@ 到 %@ 默认勿扰，可以在设置里改。", model.settings.quietStart, model.settings.quietEnd))
        }
        .onAppear { if model.deviceOnline { model.send("nod") } }
    }
}
