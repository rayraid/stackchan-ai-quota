// 应用的总控：设置、核心、HTTP 服务、定时任务，以及给界面用的快照。
import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    private var bumping = false
    private func settingsChanged(from old: AppSettings) {
        if bumping || settings == old { return }
        bumping = true
        settings.rev = old.rev + 1          // 每次改动版本号加 1，机器人据此重新应用
        bumping = false
        engine.setSettings(settings)
        SettingsFile.save(settings)
        applySideEffects(old: old)
        refresh()
    }
    @Published private(set) var subs: [Subscription] = []
    @Published private(set) var waiting: [WaitItem] = []
    @Published private(set) var device: DeviceSeen?
    @Published private(set) var serverError = ""
    @Published private(set) var lastData: Date?
    @Published private(set) var cliError = ""
    @Published var lang: Lang = .zh

    let engine = Engine()
    let server = HTTPServer()
    private var timers: [Timer] = []
    private let work = DispatchQueue(label: "butler.work")

    private init() {
        settings = SettingsFile.load()
        SettingsFile.save(settings)
        lang = Lang.resolve(settings.language)
        currentLang = lang
        engine.setSettings(settings)
        engine.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        server.handler = { [weak self] req in self?.handle(req) ?? .json(["error": "gone"], status: 503) }
        server.onState = { [weak self] in DispatchQueue.main.async { self?.serverError = self?.server.error ?? "" } }
    }

    func start() {
        startServer()
        work.async { [engine] in engine.readShared(); engine.runCLI() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.work.async { self?.engine.readShared() } }
        })
        scheduleCLI()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.global().async { self.engine.sweep() }
                self.device = self.engine.device
                if let u = self.settings.dndUntil, u < Date() { self.settings.dndUntil = nil }
            }
        })
        watchSleepAndLock()
        if settings.launchAtLogin { setLoginItem(true) }
    }

    private var cliTimer: Timer?
    private func scheduleCLI() {
        cliTimer?.invalidate()
        cliTimer = Timer.scheduledTimer(withTimeInterval: Double(max(60, settings.cliInterval)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }
    func refreshNow() { work.async { [engine] in engine.runCLI() } }

    func startServer() {
        let name = settings.robotName.isEmpty ? "StackChan Butler" : "StackChan Butler (\(Host.current().localizedName ?? "Mac"))"
        server.start(port: settings.port, macId: settings.macId, name: name)
    }

    func refresh() {
        let s = settings
        let l = Lang.resolve(s.language)
        subs = engine.subscriptions(s, l)
        waiting = engine.visibleWaiting(s)
        device = engine.device
        cliError = engine.lastError
        let latest = subs.map { $0.ts }.max() ?? 0
        lastData = latest > 0 ? Date(timeIntervalSince1970: latest) : nil
    }

    private func applySideEffects(old: AppSettings) {
        if settings.language != old.language {
            lang = Lang.resolve(settings.language)
            currentLang = lang
        }
        if settings.launchAtLogin != old.launchAtLogin { setLoginItem(settings.launchAtLogin) }
        if settings.cliInterval != old.cliInterval { scheduleCLI() }
        if settings.port != old.port || settings.macId != old.macId { startServer() }
        if settings.language != old.language || settings.windowPref != old.windowPref || settings.midPercent != old.midPercent || settings.lowPercent != old.lowPercent { refreshNow() }
    }

    // ---------- HTTP ----------
    nonisolated private func handle(_ r: HTTPRequest) -> HTTPResponse {
        if r.path == "/health" { return .json(["ok": true]) }
        let token = engine.settings().token
        var got = r.query["t"] ?? r.headers["x-token"] ?? ""
        if got.isEmpty, let a = r.headers["authorization"], a.hasPrefix("Bearer ") { got = String(a.dropFirst(7)) }
        if !r.isLocal && (token.isEmpty || got != token) { return .json(["error": "需要口令"], status: 401) }

        switch (r.method, r.path) {
        case ("GET", "/state"):
            if !r.isLocal { engine.seenDevice(ip: r.remoteIP, query: r.query) }
            return .json(engine.state(forDevice: !r.isLocal))
        case ("GET", "/firmware.bin"):
            let u = Flasher.firmwareDir.appendingPathComponent("firmware.bin")
            guard let d = try? Data(contentsOf: u) else { return .json(["error": "没有固件"], status: 404) }
            log("机器人来取新固件：", r.remoteIP, d.count, "字节")
            return HTTPResponse(status: 200, contentType: "application/octet-stream", body: d)
        case ("POST", let p) where p.hasPrefix("/ntfy/"):
            let item = engine.onPeonPush(title: r.headers["title"] ?? "", body: String(decoding: r.body, as: UTF8.self))
            return .json(["id": item?.id ?? "", "event": "message"])
        default: break
        }
        let d = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        switch (r.method, r.path) {
        case ("POST", "/event"):
            let it = engine.addWaiting(agent: d["agent"] as? String ?? "AI", project: d["project"] as? String ?? "test",
                                       kind: d["kind"] as? String ?? "done", detail: d["text"] as? String ?? "", sessionId: "")
            return .json(["id": it.id])
        case ("POST", "/ack"):
            engine.ack(d["id"] as? String ?? ""); return .json(["ok": true])
        case ("POST", "/clear"):
            engine.clear(d["id"] as? String ?? ""); return .json(["ok": true])
        case ("POST", "/cmd") where r.isLocal:      // 本机脚本用：让机器人点头、响一声、升级……
            engine.send(d["do"] as? String ?? "nod"); return .json(["ok": true])
        default:
            return .json(["error": "没有这个地址"], status: 404)
        }
    }

    // ---------- Mac 锁屏、睡眠：告诉机器人也休息 ----------
    private func watchSleepAndLock() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.engine.rest = true }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.engine.rest = false }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.engine.rest = true }
        dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.engine.rest = false }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { try SMAppService.mainApp.unregister() }
        } catch { log("开机自启设置失败：", error) }
    }

    // ---------- 给界面用 ----------
    var deviceOnline: Bool { device.map { Date().timeIntervalSince($0.at) < 15 } ?? false }
    var lowest: Subscription? {
        subs.filter { !$0.hidden && $0.shown != nil && !$0.stale }.min { ($0.shown?.left ?? 101) < ($1.shown?.left ?? 101) }
    }
    var quietNow: Bool { Engine.quietNow(settings) }
    func snooze(hours: Double) { settings.dndUntil = Date().addingTimeInterval(hours * 3600) }
    func snoozeUntilMorning() {
        let cal = Calendar.current
        var d = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        if d < Date() { d = cal.date(byAdding: .day, value: 1, to: d)! }
        settings.dndUntil = d
    }
    func send(_ what: String) { engine.send(what) }
    func testAlert() {
        let l = lang
        engine.addWaiting(agent: "Claude Code", project: l == .zh ? "测试" : l == .ja ? "テスト" : "test", kind: "approval", detail: "Bash", sessionId: "")
    }
}
