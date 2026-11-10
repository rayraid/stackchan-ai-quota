// 小管家的核心：读额度（CodexBar）、收「等你回复」（peon-ping）、整理成给机器人的状态。
// 从原来的 bridge/butler.py 移植过来，逻辑相同，另外加上设置、语言和一次性命令。
import Foundation

struct ProviderInfo { let name: String; let mono: String; let hue: String }

let PROVIDERS: [String: ProviderInfo] = [
    "codex": .init(name: "Codex", mono: "CX", hue: "#7c9cff"),
    "claude": .init(name: "Claude", mono: "CL", hue: "#e08a63"),
    "cursor": .init(name: "Cursor", mono: "CU", hue: "#cfd4dc"),
    "opencodego": .init(name: "OpenCode Go", mono: "OC", hue: "#5fd3bc"),
    "opencode": .init(name: "OpenCode", mono: "OC", hue: "#5fd3bc"),
    "antigravity": .init(name: "Antigravity", mono: "AG", hue: "#b28cff"),
    "gemini": .init(name: "Gemini", mono: "GM", hue: "#8ab4ff"),
    "copilot": .init(name: "Copilot", mono: "CP", hue: "#9be29b"),
    "grok": .init(name: "Grok", mono: "GK", hue: "#d7dbe0"),
]

/// peon-ping 在标题里附带的工具名 → 显示的名字
let AGENT_NAMES: [(String, String)] = [
    ("Claude Code", "Claude Code"), ("OpenAI Codex", "Codex"), ("Cursor", "Cursor"), ("OpenCode", "OpenCode"),
    ("Antigravity", "Antigravity"), ("Gemini CLI", "Gemini"), ("Grok Build", "Grok"), ("GitHub Copilot", "Copilot"),
    ("Kilo CLI", "Kilo"), ("Kiro", "Kiro"), ("Windsurf", "Windsurf"), ("Kimi Code", "Kimi"), ("Amp", "Amp"),
    ("DeepAgents", "DeepAgents"), ("OpenClaw", "OpenClaw"), ("Rovo Dev CLI", "Rovo Dev"), ("oh-my-pi", "oh-my-pi"),
    ("Qwen Code", "Qwen"), ("iFlow CLI", "iFlow"), ("Trae", "Trae"), ("Kiro IDE", "Kiro"), ("ECA", "ECA"),
]
/// 提醒设置里列出来的几个工具
let KNOWN_AGENTS = ["Claude Code", "Codex", "Cursor", "OpenCode", "Antigravity"]

private let GENERIC_LABELS: Set<String> = ["session", "weekly", "5-hour", "monthly", "daily", "hourly", "primary", "secondary", "tertiary"]
private let CLEAR_EVENTS: Set<String> = ["UserPromptSubmit", "PreToolUse", "SessionEnd", "SessionStart"]
private let SLOTS = ["primary", "secondary", "tertiary"]

// ---------- 给界面用的数据 ----------
struct QuotaWindow: Hashable {
    var label: String; var left: Int; var level: String; var reset: String; var pace: String; var minutes: Int
}
struct Subscription: Identifiable, Hashable {
    var id: String; var name: String; var mono: String; var hue: String
    var windows: [QuotaWindow]
    var ts: Double; var stale: Bool; var source: String; var plan: String
    var shown: QuotaWindow?        // 按设置挑出来显示的那个时间段
    var hidden: Bool
}
struct WaitItem: Identifiable, Hashable {
    var id: String; var agent: String; var mono: String; var project: String
    var kind: String; var detail: String; var since: Double; var acked: Bool; var sessionId: String
    var ttl: Double = 0            // >0 时到点自动消掉（额度恢复的通知）
}
struct DeviceSeen: Hashable { var ip: String; var at: Date; var fw: String; var rssi: Int; var up: Int }

final class Engine: @unchecked Sendable {
    private let lock = NSLock()
    private var cli: [String: [String: Any]] = [:]
    private var cliTs: [String: Double] = [:]
    private var order: [String] = []
    private var cliBad: Set<String> = []
    private var shared: [String: [String: Any]] = [:]
    private var sharedTs: [String: Double] = [:]
    private var sharedMtime: Double = 0
    private var usageSig = ""
    private var waiting: [WaitItem] = []
    private var seq = 0
    private var peonMtime: Double = 0
    private var lastLeft: [String: Int] = [:]
    private(set) var device: DeviceSeen?
    private var cmd: (id: Int, what: String, at: Date)?
    private var cmdSeq = Int(Date().timeIntervalSince1970) % 100000
    private(set) var lastCliRun: Date?
    private(set) var lastCliError = ""
    var rest = false

    private let sLock = NSLock()
    private var _settings = AppSettings()
    func setSettings(_ s: AppSettings) { sLock.withLock { _settings = s } }
    func settings() -> AppSettings { sLock.withLock { _settings } }
    var onChange: () -> Void = {}

    static let sharedUsagePath = NSString(string: "~/Library/Application Support/CodexBar/CLIUsageCache/usage.json").expandingTildeInPath
    static let peonStatePath = NSString(string: "~/.claude/hooks/peon-ping/.state.json").expandingTildeInPath

    static func codexbarPath() -> String? {
        let cands = ["/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar",
                     "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
                     NSString(string: "~/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI").expandingTildeInPath]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // ---------- 额度：主来源 CodexBar 命令行 ----------
    func runCLI() {
        guard let path = Engine.codexbarPath() else {
            lock.withLock { lastCliError = "找不到 CodexBar 命令行" }
            return
        }
        let out = Shell.run(path, ["usage", "--format", "json"], timeout: 180, cwd: "/tmp")
        lock.withLock { lastCliRun = Date() }
        guard let arr = (try? JSONSerialization.jsonObject(with: out.stdout)) as? [[String: Any]] else {
            log("CodexBar 命令行没跑成：", out.status, String(data: out.stderr.prefix(200), encoding: .utf8) ?? "")
            lock.withLock { cliBad = Set(order); lastCliError = "CodexBar 命令行没跑成" }
            onChange()
            return
        }
        let now = Date().timeIntervalSince1970
        var fresh: [(String, [String: Any])] = []
        for e in arr { if let p = e["provider"] as? String { fresh.append((p, e)) } }
        lock.withLock {
            if !fresh.isEmpty { order = fresh.map { $0.0 } }
            cliBad = Set(fresh.filter { $0.1["error"] != nil }.map { $0.0 })
            for (k, v) in fresh where v["error"] == nil { cli[k] = v; cliTs[k] = now }
            lastCliError = ""
        }
        let ok = fresh.filter { $0.1["error"] == nil }.map { $0.0 }
        let bad = fresh.filter { $0.1["error"] != nil }.map { $0.0 }
        let sig = ok.joined(separator: ",") + "|" + bad.joined(separator: ",")
        if sig != usageSig {
            usageSig = sig
            log("命令行读到：", ok.joined(separator: "、"), bad.isEmpty ? "" : "；读不到：" + bad.joined(separator: "、"))
        }
        checkRestored()
        onChange()
    }

    // ---------- 额度：兜底来源 CodexBar 应用的共享文件 ----------
    func readShared() {
        let p = Engine.sharedUsagePath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { sharedMtime = -1; return }
        if mt == sharedMtime { return }
        guard let data = FileManager.default.contents(atPath: p),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var sh: [String: [String: Any]] = [:], ts: [String: Double] = [:]
        for e in (d["entries"] as? [[String: Any]]) ?? [] {
            guard let pid = e["provider"] as? String, let u = e["usage"] as? [String: Any],
                  let t = parseISO(u["updatedAt"] as? String) else { continue }
            sh[pid] = u; ts[pid] = t.timeIntervalSince1970
        }
        lock.withLock { shared = sh; sharedTs = ts; sharedMtime = mt }
        onChange()
    }

    private func level(_ left: Int, _ s: AppSettings) -> String {
        left < s.lowPercent ? "low" : left < s.midPercent ? "mid" : "ok"
    }

    private func groupOf(_ label: String?) -> String {
        guard let l = label?.trimmingCharacters(in: .whitespaces), !l.isEmpty, !GENERIC_LABELS.contains(l.lowercased()) else { return "" }
        return l.replacingOccurrences(of: " Models", with: "").replacingOccurrences(of: " and ", with: "/").replacingOccurrences(of: " only", with: "").trimmingCharacters(in: .whitespaces)
    }
    private func groupFromTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(.*?)\s+(5-hour|weekly|monthly|daily|hourly)$"#, options: [.regularExpression, .caseInsensitive]) {
            let head = String(t[r]).replacingOccurrences(of: #"\s+(5-hour|weekly|monthly|daily|hourly)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return groupOf(head)
        }
        return groupOf(t)
    }

    private func windows(_ base: [String: Any], extras: [[String: Any]], labels: [String: Any], pace: [String: Any], s: AppSettings, l: Lang) -> [QuotaWindow] {
        var wins: [(QuotaWindow, String)] = []
        var seen = Set<String>()
        func add(_ group: String, _ w: [String: Any], _ p: [String: Any]?, _ key: String) {
            guard !seen.contains(key), let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return }
            seen.insert(key)
            let minutes = (w["windowMinutes"] as? NSNumber)?.intValue ?? 0
            let left = max(0, min(100, Int((100 - used).rounded())))
            let label = (group.isEmpty ? "" : group + " ") + Gen.windowLabel(minutes, l)
            let reset = Gen.resetText(parseISO(w["resetsAt"] as? String), minutes: minutes, l)
            let paceText = Gen.paceText(etaSeconds: (p?["etaSeconds"] as? NSNumber)?.doubleValue, willLast: (p?["willLastToReset"] as? Bool) ?? true, l)
            wins.append((QuotaWindow(label: label, left: left, level: level(left, s), reset: reset, pace: paceText, minutes: minutes), group))
        }
        for slot in SLOTS {
            guard let w = base[slot] as? [String: Any] else { continue }
            let g = groupOf(labels[slot] as? String)
            add(g, w, pace[slot] as? [String: Any], g.isEmpty ? "|" + slot : g + "|" + String(describing: w["windowMinutes"] ?? ""))
        }
        for x in extras {
            guard let w = x["window"] as? [String: Any], w["windowMinutes"] != nil else { continue }
            let g = groupFromTitle(x["title"] as? String ?? "")
            add(g, w, nil, g + "|" + String(describing: w["windowMinutes"] ?? ""))
        }
        var groups: [String] = []
        for (_, g) in wins where !groups.contains(g) { groups.append(g) }
        return wins.sorted { a, b in
            let ia = groups.firstIndex(of: a.1)!, ib = groups.firstIndex(of: b.1)!
            return ia != ib ? ia < ib : a.0.minutes < b.0.minutes
        }.map { $0.0 }
    }

    /// 所有订阅（含隐藏的），按设置排好序、挑好显示的时间段
    func subscriptions(_ s: AppSettings, _ l: Lang) -> [Subscription] {
        let now = Date().timeIntervalSince1970
        return lock.withLock {
            var ids = order
            for k in shared.keys.sorted() where !ids.contains(k) { ids.append(k) }
            var out: [Subscription] = []
            for pid in ids {
                let c = cli[pid] ?? [:]
                let cu = c["usage"] as? [String: Any] ?? [:]
                let su = shared[pid] ?? [:]
                let cTs = cliTs[pid] ?? 0, sTs = sharedTs[pid] ?? 0
                let useShared = !su.isEmpty && (cliBad.contains(pid) || cTs == 0) && sTs > cTs
                let base = useShared ? su : cu
                let extras = (base["extraRateWindows"] as? [[String: Any]]) ?? (cu["extraRateWindows"] as? [[String: Any]]) ?? []
                let wins = windows(base, extras: extras, labels: c["rateWindowLabels"] as? [String: Any] ?? [:], pace: c["pace"] as? [String: Any] ?? [:], s: s, l: l)
                let ts = useShared ? sTs : cTs
                let info = PROVIDERS[pid] ?? .init(name: pid.capitalized, mono: String(pid.prefix(2)).uppercased(), hue: "#aab2bd")
                var sub = Subscription(id: pid, name: info.name, mono: s.subMono[pid] ?? info.mono, hue: s.subHue[pid] ?? info.hue,
                                       windows: wins, ts: ts, stale: ts == 0 || now - ts > Double(s.staleMinutes * 60),
                                       source: ts == 0 ? "" : (useShared ? "app" : "cli"), plan: cu["loginMethod"] as? String ?? "",
                                       shown: nil, hidden: s.subHidden.contains(pid))
                if !wins.isEmpty {
                    var pick = wins.min { $0.left < $1.left }
                    if s.windowPref == "5h", let w = wins.first(where: { $0.minutes == 300 }) { pick = w }
                    if s.windowPref == "week", let w = wins.first(where: { $0.minutes == 10080 }) { pick = w }
                    sub.shown = pick
                }
                out.append(sub)
            }
            if !s.subOrder.isEmpty {
                out.sort { a, b in
                    let ia = s.subOrder.firstIndex(of: a.id) ?? Int.max, ib = s.subOrder.firstIndex(of: b.id) ?? Int.max
                    return ia != ib ? ia < ib : (ids.firstIndex(of: a.id) ?? 0) < (ids.firstIndex(of: b.id) ?? 0)
                }
            }
            return out
        }
    }

    /// 平时画面底部 3 格：固定的几家 + 最紧张的一家
    func faceIds(_ subs: [Subscription], _ s: AppSettings) -> [String] {
        let vis = subs.filter { !$0.hidden }
        var ids = s.pinned.filter { id in vis.contains { $0.id == id } }
        let limit = s.autoThird ? min(2, ids.count) : 3
        ids = Array(ids.prefix(limit))
        let rest = vis.filter { !ids.contains($0.id) && $0.shown != nil }.sorted { ($0.shown?.left ?? 101) < ($1.shown?.left ?? 101) }
        for r in rest where ids.count < 3 { ids.append(r.id) }
        return ids
    }

    // ---------- 额度恢复了（可选提醒） ----------
    private func checkRestored() {
        let s = settings()
        let subs = subscriptions(s, .zh)
        var events: [(String, String)] = []
        lock.withLock {
            for sub in subs {
                for w in sub.windows {
                    let k = sub.id + "|" + String(w.minutes) + "|" + w.label
                    if let prev = lastLeft[k], prev <= 50, w.left >= 95 { events.append((sub.name, w.label)) }
                    lastLeft[k] = w.left
                }
            }
        }
        guard s.notifyRestored else { return }
        for (name, label) in events {
            let item = addWaiting(agent: name, project: label, kind: "restored", detail: "", sessionId: "")
            lock.withLock { if let i = waiting.firstIndex(where: { $0.id == item.id }) { waiting[i].ttl = 90 } }
        }
    }

    // ---------- 等你回复 ----------
    private func peonLastActive() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: Engine.peonStatePath),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return j["last_active"] as? [String: Any] ?? [:]
    }

    @discardableResult
    func addWaiting(agent: String, project: String, kind: String, detail: String, sessionId: String) -> WaitItem {
        let now = Date().timeIntervalSince1970
        let item: WaitItem = lock.withLock {
            waiting.removeAll { w in
                (!sessionId.isEmpty && w.sessionId == sessionId) || (sessionId.isEmpty && w.agent == agent && w.project == project && w.kind != "restored")
            }
            seq += 1
            let mono = ["Claude Code": "CL", "Codex": "CX", "Cursor": "CU", "OpenCode": "OC", "Antigravity": "AG", "Gemini": "GM", "Grok": "GK", "Copilot": "CP"][agent] ?? String(agent.prefix(2)).uppercased()
            let it = WaitItem(id: "w\(seq)", agent: agent, mono: mono, project: project, kind: kind, detail: detail, since: now, acked: false, sessionId: sessionId)
            waiting.append(it)
            return it
        }
        log("等你回复 +", agent, "·", project, "·", kind, detail)
        onChange()
        return item
    }

    func onPeonPush(title: String, body: String) -> WaitItem? {
        var project = title.trimmingCharacters(in: .whitespaces), agent = ""
        for (raw, shown) in AGENT_NAMES where project.hasSuffix(" - " + raw) {
            project = String(project.dropLast(raw.count + 3)); agent = shown; break
        }
        let msg = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = msg.lowercased()
        var kind = "note", detail = ""
        if low.hasPrefix("done") { kind = "done" }
        else if low.hasPrefix("needs approval") {
            kind = "approval"
            if let r = msg.firstIndex(of: ":") { detail = msg[msg.index(after: r)...].trimmingCharacters(in: .whitespaces) }
        }
        else if low.hasPrefix("question") { kind = "question" }
        else if low.hasPrefix("compacting") || low.hasPrefix("working") || low.hasPrefix("ready") { return nil }
        else if low.hasPrefix("error") { kind = "error" }
        else { detail = String(msg.prefix(40)) }
        // 这条推送来自哪个会话：peon-ping 刚刚把它写进了自己的状态文件
        let la = peonLastActive()
        let ts = (la["timestamp"] as? NSNumber)?.doubleValue ?? 0
        let sid = abs(Date().timeIntervalSince1970 - ts) < 6 ? (la["session_id"] as? String ?? "") : ""
        return addWaiting(agent: agent.isEmpty ? "AI" : agent, project: project.isEmpty ? "?" : project, kind: kind, detail: detail, sessionId: sid)
    }

    /// 清掉已经回复的、挂太久的（每秒一次）
    func sweep() {
        let s = settings()
        let now = Date().timeIntervalSince1970
        let ttl = s.waitingTTL > 0 ? Double(s.waitingTTL * 60) : .infinity
        var la: [String: Any]? = nil
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Engine.peonStatePath),
           let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970, mt != peonMtime {
            peonMtime = mt
            la = peonLastActive()
        }
        var changed = false
        lock.withLock {
            let before = waiting.count
            waiting.removeAll { w in
                if w.ttl > 0 && now - w.since > w.ttl { return true }
                if now - w.since > ttl { log("等你回复 -", w.agent, "·", w.project, "（挂太久，自动消掉）"); return true }
                if let la, !w.sessionId.isEmpty, (la["session_id"] as? String) == w.sessionId,
                   CLEAR_EVENTS.contains(la["event"] as? String ?? ""),
                   ((la["timestamp"] as? NSNumber)?.doubleValue ?? 0) > w.since + 0.5 {
                    log("等你回复 -", w.agent, "·", w.project, "（你已经回去了）"); return true
                }
                return false
            }
            changed = before != waiting.count
            if let c = cmd, Date().timeIntervalSince(c.at) > 15 { cmd = nil }
        }
        if changed { onChange() }
    }

    func ack(_ id: String = "") {
        lock.withLock { for i in waiting.indices where id.isEmpty || waiting[i].id == id { waiting[i].acked = true } }
        onChange()
    }
    func clear(_ id: String = "") {
        lock.withLock { waiting.removeAll { id.isEmpty || $0.id == id } }
        onChange()
    }

    /// 按设置过滤后的「等你回复」
    func visibleWaiting(_ s: AppSettings) -> [WaitItem] {
        lock.withLock {
            waiting.filter { w in
                if s.disabledAgents.contains(w.agent) { return false }
                switch w.kind {
                case "approval": return s.kindApproval
                case "question": return s.kindQuestion
                case "done": return s.kindDone
                default: return true
                }
            }.sorted { a, b in
                if a.acked != b.acked { return !a.acked }
                if (a.kind == "done") != (b.kind == "done") { return b.kind == "done" }
                return a.since < b.since
            }
        }
    }

    // ---------- 一次性命令（点头、响一声、找设备、升级……） ----------
    func send(_ what: String) {
        lock.withLock { cmdSeq += 1; cmd = (cmdSeq, what, Date()) }
    }

    func seenDevice(ip: String, query: [String: String]) {
        let d = DeviceSeen(ip: ip, at: Date(), fw: query["fw"] ?? "", rssi: Int(query["rssi"] ?? "") ?? 0, up: Int(query["up"] ?? "") ?? 0)
        let isNew: Bool = lock.withLock {
            let n = device == nil || device!.ip != ip || Date().timeIntervalSince(device!.at) > 60
            device = d
            return n
        }
        if isNew { log("机器人连上来了：", ip, "固件", d.fw); onChange() }
    }

    // ---------- 给机器人的状态 ----------
    func state(forDevice: Bool) -> [String: Any] {
        let s = settings()
        let l = Lang.resolve(s.language)
        let now = Date()
        let subs = subscriptions(s, l).filter { !$0.hidden }
        let wait = visibleWaiting(s)
        var lows: [[String: Any]] = []
        for sub in subs where !sub.stale {
            for w in sub.windows where w.level == "low" {
                lows.append(["id": sub.id, "name": sub.name, "label": w.label, "left": w.left, "reset": w.reset])
            }
        }
        let latest = subs.map { $0.ts }.max() ?? 0
        let ok = latest > 0 && now.timeIntervalSince1970 - latest <= Double(s.staleMinutes * 60)
        let hm = DateFormatter.cached("HH:mm")
        var out: [String: Any] = [
            "v": 2,
            "now": Int(now.timeIntervalSince1970),
            "time": hm.string(from: now),
            "ok": ok,
            "data_time": latest > 0 ? hm.string(from: Date(timeIntervalSince1970: latest)) : "",
            "subs": subs.map { sub -> [String: Any] in
                var d: [String: Any] = ["id": sub.id, "name": sub.name, "mono": sub.mono, "hue": sub.hue, "ts": Int(sub.ts), "stale": sub.stale,
                                        "windows": sub.windows.map { ["label": $0.label, "left": $0.left, "level": $0.level, "reset": $0.reset, "pace": $0.pace] }]
                if let w = sub.shown {
                    d["left"] = w.left; d["label"] = w.label; d["level"] = w.level; d["reset"] = w.reset; d["pace"] = w.pace; d["error"] = ""
                } else {
                    d["left"] = NSNull(); d["label"] = ""; d["level"] = "na"; d["reset"] = ""; d["pace"] = ""; d["error"] = Gen.cantRead(l)
                }
                return d
            },
            "face": faceIds(subs, s),
            "lows": lows,
            "waiting": wait.map { w -> [String: Any] in
                ["id": w.id, "agent": w.agent, "mono": w.mono, "project": w.project, "kind": w.kind,
                 "text": Gen.kindText(w.kind, detail: w.detail, l), "since": Int(w.since), "acked": w.acked]
            },
            "rest": rest && s.restWhenLocked,
            "cfg": Engine.deviceCfg(s, now: now),
        ]
        lock.withLock {
            if let c = cmd {
                out["cmd"] = ["id": c.id, "do": c.what]
                if forDevice { cmd = nil }     // 交给机器人一次就撤掉
            }
        }
        return out
    }

    static func quietNow(_ s: AppSettings, _ now: Date = Date()) -> Bool {
        if let u = s.dndUntil, u > now { return true }
        guard s.quietOn else { return false }
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: now)
        let weekend = wd == 1 || wd == 7
        if weekend && s.weekend == 1 { return true }
        if weekend && s.weekend == 2 { return false }
        let m = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let a = minutes(s.quietStart), b = minutes(s.quietEnd)
        return a < b ? (m >= a && m < b) : (m >= a || m < b)
    }
    static func minutes(_ hm: String) -> Int {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }

    static func deviceCfg(_ s: AppSettings, now: Date = Date()) -> [String: Any] {
        let h = Calendar.current.component(.hour, from: now)
        return [
            "rev": s.rev, "theme": s.theme, "eye": s.eye, "eye_color": s.eyeColor, "bright": s.brightness,
            "used": s.showUsed, "clock": s.clock, "blink": s.blink, "look": s.look,
            "sleepy": s.sleepyNight && (h >= 23 || h < 7), "dim_after": s.dimAfter,
            "alert": s.alertLevel, "remind": s.remind, "motion": s.motion, "nod": s.nod, "pitch": s.pitch,
            "wander": s.wander, "shake_low": s.shakeLow, "sound": s.sound, "volume": s.volume, "tone": s.tone,
            "led": s.led, "led_bright": s.ledBright, "led_idle": s.ledIdle, "led_attn": s.ledAttn, "touch": s.touch,
            "name": s.robotName, "lang": Lang.resolve(s.language).rawValue,
            "quiet": quietNow(s, now), "q_still": s.qStill, "q_mute": s.qMute, "q_dark": s.qDark,
            "q_bright": s.qBright, "q_face": s.qFace,
        ]
    }

    var lastError: String { lock.withLock { lastCliError } }
    var lastRun: Date? { lock.withLock { lastCliRun } }
}

func parseISO(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

// ---------- 跑命令行 ----------
enum Shell {
    struct Result { var status: Int32; var stdout: Data; var stderr: Data }

    static func run(_ path: String, _ args: [String], timeout: Double = 60, cwd: String? = nil, env: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        do { try p.run() } catch { return Result(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8)) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        g.wait()
        return Result(status: p.terminationStatus, stdout: outData, stderr: errData)
    }
}
