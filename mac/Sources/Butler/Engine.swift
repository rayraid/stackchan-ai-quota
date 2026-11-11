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
    var key = ""                     // 「分组|分钟数」，不随语言变，设置里「每家显示哪个额度」记的就是它
}
struct Subscription: Identifiable, Hashable {
    var id: String; var name: String; var mono: String; var hue: String
    var windows: [QuotaWindow]
    var ts: Double; var stale: Bool; var source: String; var plan: String
    var shown: QuotaWindow?        // 按设置挑出来显示的那个时间段
    var hidden: Bool
    var error = ""                 // 最近一次读不到的原因（CodexBar 给的原话）
    var via = ""                   // CodexBar 这次是怎么读到的：web / oauth / cli / api…
}
struct WaitItem: Identifiable, Hashable {
    var id: String; var agent: String; var mono: String; var project: String
    var kind: String; var detail: String; var since: Double; var acked: Bool; var sessionId: String
    var ttl: Double = 0            // >0 时到点自动消掉（额度恢复的通知）
}
struct DeviceSeen: Hashable {
    var ip: String; var at: Date; var fw: String; var rssi: Int; var up: Int
    var bat: Int? = nil          // 电量百分比（固件 2.1.2 起报上来）
    var power = false            // 插着线：正在充电或已充满
    var mv = 0, ma = 0           // 电池电压（毫伏）、电流（毫安，放电为正）

    /// 菜单栏面板顶部用的短说法
    var batteryShort: String? {
        guard let b = bat else { return nil }
        if power && b >= 99 { return t("已充满") }
        return power ? t("充电中 %d%%", b) : t("电量 %d%%", b)
    }
    /// 「设置 → 机器人」里用的说法
    var batteryLong: String {
        guard let b = bat else { return "—" }
        if power && b >= 99 { return t("已充满") }
        return power ? t("%d%%（正在充电）", b) : t("%d%%（用电池）", b)
    }
}

final class Engine: @unchecked Sendable {
    private let lock = NSLock()
    private var cli: [String: [String: Any]] = [:]
    private var cliTs: [String: Double] = [:]
    private var order: [String] = []
    private var cliBad: Set<String> = []
    private var cliErr: [String: String] = [:]
    private var shared: [String: [String: Any]] = [:]
    private var sharedTs: [String: Double] = [:]
    private var sharedMtime: Double = 0
    private var usageSig = ""
    private var waiting: [WaitItem] = []
    private var hookSeen: Set<String> = []
    private var lastDone: [String: Double] = [:]    // 每个对话最近一次报「做完了」的时间（挑出重复的那条）
    private var lastBattLogged = -100
    private var lastBattPower = false
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

    static func codexbarPath() -> String? { CodexBarCLI.path()?.0 }

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
            for (k, v) in fresh {
                if let e = v["error"] as? [String: Any] { cliErr[k] = e["message"] as? String ?? "" }
                else if let e = v["error"] as? String { cliErr[k] = e }
                else { cliErr[k] = nil }
            }
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

    private func level(_ left: Int, _ s: AppSettings, _ pid: String = "") -> String {
        let low = s.subLow[pid] ?? s.lowPercent, mid = s.subMid[pid] ?? s.midPercent
        return left < low ? "low" : left < mid ? "mid" : "ok"
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

    private func windows(_ base: [String: Any], extras: [[String: Any]], labels: [String: Any], pace: [String: Any], s: AppSettings, l: Lang, pid: String) -> [QuotaWindow] {
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
            wins.append((QuotaWindow(label: label, left: left, level: level(left, s, pid), reset: reset, pace: paceText, minutes: minutes, key: group + "|" + String(minutes)), group))
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
                let wins = windows(base, extras: extras, labels: c["rateWindowLabels"] as? [String: Any] ?? [:], pace: c["pace"] as? [String: Any] ?? [:], s: s, l: l, pid: pid)
                let ts = useShared ? sTs : cTs
                let info = PROVIDERS[pid] ?? .init(name: ProviderNames.get(pid) ?? pid.capitalized, mono: String(pid.prefix(2)).uppercased(), hue: "#aab2bd")
                var sub = Subscription(id: pid, name: info.name, mono: s.subMono[pid] ?? info.mono, hue: s.subHue[pid] ?? info.hue,
                                       windows: wins, ts: ts, stale: ts == 0 || now - ts > Double(s.staleMinutes * 60),
                                       source: ts == 0 ? "" : (useShared ? "app" : "cli"), plan: cu["loginMethod"] as? String ?? "",
                                       shown: nil, hidden: s.subHidden.contains(pid),
                                       error: cliBad.contains(pid) ? (cliErr[pid] ?? "") : "", via: useShared ? "app" : c["source"] as? String ?? "")
                if !wins.isEmpty { sub.shown = Engine.pickWindow(wins, choice: s.subWindow[pid], pref: s.windowPref) }
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

    /// 按「额度显示逻辑」挑这一家显示哪个时间段。choice 是这一家单独选的 key（subWindow），pref 是总的 windowPref（auto / tightest / week / 5h）。
    /// 「只限某个模型」的额度（分组名非空，比如 Claude 的 Fable 本周）在 auto / week / 5h 下让位给总额度；只有这种额度的家照常挑。
    static func pickWindow(_ wins: [QuotaWindow], choice: String?, pref: String) -> QuotaWindow? {
        if let c = choice, let w = wins.first(where: { $0.key == c }) { return w }      // 这一家单独选过
        let general = wins.filter { $0.key.hasPrefix("|") }
        let pool = general.isEmpty ? wins : general
        let tightest = { (ws: [QuotaWindow]) in ws.min { $0.left < $1.left } }
        switch pref {
        case "tightest": return tightest(wins)
        case "week": return pool.first { $0.minutes == 10080 } ?? wins.first { $0.minutes == 10080 } ?? tightest(pool)
        case "5h": return pool.first { $0.minutes == 300 } ?? wins.first { $0.minutes == 300 } ?? tightest(pool)
        default: return tightest(pool)
        }
    }

    /// 只有一家订阅时，首页的几格放它的哪几个时间段（下标对应 sub.windows）。
    /// 默认：总额度按周期从短到长（不算只限某个模型的）；不够两个就把所有时间段都算上。少于两个就不拆。
    static func splitWindows(_ sub: Subscription, _ s: AppSettings) -> [Int] {
        let ws = sub.windows
        guard ws.count >= 2 else { return [] }
        let slots = s.homeStyle == "B" ? 2 : 3
        var auto = ws.indices.filter { ws[$0].key.hasPrefix("|") }
        if auto.count < 2 { auto = Array(ws.indices) }
        auto.sort { ws[$0].minutes < ws[$1].minutes }
        var out: [Int] = []
        for i in 0..<slots {
            let want = i < s.singleWins.count ? s.singleWins[i] : ""
            if let k = ws.firstIndex(where: { $0.key == want }), !want.isEmpty, !out.contains(k) { out.append(k); continue }
            if let k = auto.first(where: { !out.contains($0) }) { out.append(k) }
        }
        return out.count >= 2 ? out : []
    }
    /// 现在看得到的订阅是不是只有一家（这时首页拆成它的几个时间段、点屏幕直接进明细）
    static func single(_ subs: [Subscription]) -> Subscription? {
        let vis = subs.filter { !$0.hidden }
        return vis.count == 1 ? vis[0] : nil
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

    // ---------- 小管家自己的钩子（butler-hook.sh）：AI 工具直接报事件 ----------
    /// tool：claude / codex / cursor / antigravity；event：钩子名（Antigravity 由命令行参数给，其他在 JSON 里）
    @discardableResult
    func onHook(tool: String, event argEvent: String, _ d: [String: Any]) -> WaitItem? {
        func str(_ keys: String...) -> String {
            for k in keys { if let v = d[k] as? String, !v.isEmpty { return v } }
            return ""
        }
        var ev = argEvent.isEmpty ? str("hook_event_name", "hookName", "event") : argEvent
        // Cursor 用小写开头的名字
        ev = ["stop": "Stop", "beforeSubmitPrompt": "UserPromptSubmit", "sessionStart": "SessionStart", "sessionEnd": "SessionEnd",
              "preToolUse": "PreToolUse", "postToolUse": "PostToolUse"][ev] ?? ev
        let rawSid = str("session_id", "sessionId", "conversation_id", "conversationId", "thread_id")
        let sid = rawSid.isEmpty ? "" : tool + ":" + rawSid
        let roots = (d["workspace_roots"] ?? d["workspacePaths"] ?? d["workspaceRoots"]) as? [String] ?? []
        let cwd = str("cwd").isEmpty ? (roots.first ?? "") : str("cwd")
        let project = cwd.isEmpty ? "?" : URL(fileURLWithPath: cwd).lastPathComponent
        let agent = HookInstaller.agentName(tool)
        let fromSubagent = !str("agent_id").isEmpty         // Claude Code 子任务里的事件
        let toolName = str("tool_name", "toolName")
        if lock.withLock({ hookSeen.insert(tool).inserted }) { log("收到", agent, "的钩子事件（小管家自己的钩子在工作）") }

        switch ev {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart", "SessionEnd", "PreInvocation":
            // 你回到这个对话了（发了消息、批准了操作、重开了对话）：熄灯
            if !fromSubagent, !sid.isEmpty { clear(session: sid, why: "你已经回去了") }
            return nil
        case "PermissionRequest":
            return addWaiting(agent: agent, project: project, kind: toolName == "AskUserQuestion" ? "question" : "approval",
                              detail: toolName, sessionId: sid)
        case "Notification":
            // 批准弹窗走 PermissionRequest；Claude Code 空闲时每分钟重复的 idle_prompt 不理
            if str("notification_type") == "elicitation_dialog" {
                return addWaiting(agent: agent, project: project, kind: "question", detail: "", sessionId: sid)
            }
            return nil
        case "StopFailure":
            return addWaiting(agent: agent, project: project, kind: "error", detail: "", sessionId: sid)
        case "Stop":
            if fromSubagent { return nil }                  // 子任务自己停下（正常走 SubagentStop，没登记；保险起见）
            if tool == "codex", CodexThreads.isSubagent(rawSid) {
                log("Codex 子任务做完了（主任务还在跑），不提醒：", project); return nil
            }
            // Claude Code 把活派给后台子任务后会先「停」一下等回报，回报一到又接着干：这时不是在等你
            if tool == "claude", let b = ClaudeSessions.busy(str("transcript_path").isEmpty ? (ClaudeSessions.transcript(session: rawSid) ?? "") : str("transcript_path")) {
                log("Claude Code 主任务还在等后台子任务，不提醒：", project, b); return nil
            }
            // Antigravity 每次都带 error 字段，正常停下时是空字符串，只有 terminationReason 是 ERROR 才是出错；
            // Cursor 用 status：completed / aborted / error
            let reason = str("terminationReason", "status")
            let errText: String = {
                guard let e = d["error"], !(e is NSNull) else { return "" }
                return ((e as? String) ?? "\(e)").trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            if tool == "antigravity" {
                log("Antigravity 停下：", reason.isEmpty ? "?" : reason, "fullyIdle=\(d["fullyIdle"].map { "\($0)" } ?? "?")", errText.isEmpty ? "" : "error=" + errText.prefix(80))
            }
            if reason == "USER_CANCELED" || reason == "aborted" { return nil }     // 你自己停的：你就在跟前
            if (d["fullyIdle"] as? Bool) == false { return nil }                  // Antigravity：后台还有活在跑
            let failed = reason == "ERROR" || reason == "error" || (reason.isEmpty && !errText.isEmpty)
            if !failed, repeatDone(sid.isEmpty ? agent + "|" + project : sid) { return nil }
            return addWaiting(agent: agent, project: project, kind: failed ? "error" : "done", detail: "", sessionId: sid)
        default:
            return nil
        }
    }

    /// 同一个对话几秒前刚报过「做完了」、中间你没回去过：这条是重复的（peon-ping 那条路偶尔把子任务的结束也报成做完了）
    private func repeatDone(_ key: String) -> Bool {
        let now = Date().timeIntervalSince1970
        let dup: Bool = lock.withLock {
            if let t = lastDone[key], now - t < 8 { return true }
            lastDone[key] = now
            return false
        }
        if dup { log("重复的「做完了」，不再提醒：", key) }
        return dup
    }

    /// 这个对话的提醒全部熄掉
    func clear(session sid: String, why: String) {
        var changed = false
        lock.withLock {
            lastDone[sid] = nil
            waiting.removeAll { w in
                guard w.sessionId == sid else { return false }
                log("等你回复 -", w.agent, "·", w.project, "（\(why)）"); changed = true; return true
            }
        }
        if changed { onChange() }
    }

    func onPeonPush(title: String, body: String) -> WaitItem? {
        var project = title.trimmingCharacters(in: .whitespaces), agent = ""
        for (raw, shown) in AGENT_NAMES where project.hasSuffix(" - " + raw) {
            project = String(project.dropLast(raw.count + 3)); agent = shown; break
        }
        // 已经用小管家自己的钩子接通的工具，peon-ping 再发来的就不要了（不然同一件事提醒两次）
        if !agent.isEmpty, HookInstaller.status(agent) == .connected { return nil }
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
        // 这条推送来自哪个会话：peon-ping 刚刚把它写进了自己的状态文件。可那个文件只有一格，
        // 几个对话同时在跑时，推送发出来之前可能已经被别的对话改写了：时间新、工作目录也对得上才信
        let la = peonLastActive()
        let ts = (la["timestamp"] as? NSNumber)?.doubleValue ?? 0
        let laCwd = la["cwd"] as? String ?? ""
        let trusted = abs(Date().timeIntervalSince1970 - ts) < 6
            && (project.isEmpty || laCwd.isEmpty || Workspace.names(laCwd).contains(project))
        var sid = trusted ? (la["session_id"] as? String ?? "") : ""
        // 子任务做完（SubagentStop）peon-ping 也报「做完了」：Claude Code 回完一条后还会在后台跑个小任务，
        // 两三秒后结束又报一次，机器人就闪两遍。主任务真做完时有自己的 Stop，这条不用提醒
        if trusted, la["event"] as? String == "SubagentStop" {
            log("子任务做完了，不提醒：", agent.isEmpty ? "AI" : agent, "·", project)
            return nil
        }
        // Codex 主任务派出去的子任务（plan、review……）做完时也报「做完了」，其实主任务还在跑，没在等你。
        // 状态文件不可信时，直接看 Codex 自己的记录：刚做完一轮的是不是子任务
        if agent == "Codex", ["done", "error", "note"].contains(kind) {
            if !sid.hasPrefix("codex-") { sid = "" }        // 同一个项目里别的工具（比如 Claude Code）的对话
            let latest = sid.isEmpty ? CodexThreads.latestFinished() : nil
            if sid.isEmpty ? latest?.sub == true : CodexThreads.isSubagent(String(sid.dropFirst(6))) {
                log("Codex 子任务做完了（主任务还在跑），不提醒：", project)
                return nil
            }
            if let l = latest { sid = "codex-" + l.id }
        }
        // Claude Code 主任务把活派给后台子任务后会先「停」一下等回报（回报一到又接着干），子任务做完时也会报一次：都不是在等你
        if agent == "Claude Code", ["done", "note"].contains(kind) {
            // 状态文件里的会话找不到 Claude Code 的记录（是别的工具的，或者不可信），就按项目名找最近在写的那个
            let found = ClaudeSessions.transcript(session: sid).map { (path: $0, session: sid) } ?? ClaudeSessions.recentTranscript(project: project)
            if let f = found {
                if let b = ClaudeSessions.busy(f.path) {
                    log("Claude Code 主任务还在等后台子任务，不提醒：", project, b)
                    return nil
                }
                sid = f.session
            }
        }
        let shownAgent = agent.isEmpty ? "AI" : agent, shownProject = project.isEmpty ? "?" : project
        if kind == "done", repeatDone(sid.isEmpty ? shownAgent + "|" + shownProject : sid) { return nil }
        return addWaiting(agent: shownAgent, project: shownProject, kind: kind, detail: detail, sessionId: sid)
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
            if let la, CLEAR_EVENTS.contains(la["event"] as? String ?? ""), let s = la["session_id"] as? String { lastDone[s] = nil }
            let before = waiting.count
            waiting.removeAll { w in
                if w.ttl > 0 && now - w.since > w.ttl { return true }
                // 「做完了」「出错停下了」不挡着 AI 干活，到设定时间就熄灯；「要你批准」「有问题问你」挂到 ttl
                let doneKind = ["done", "note"].contains(w.kind)
                // 「做完了」提醒完就熄：机器人闪完会来 /clear；机器人不在、勿扰不闪时，过一会儿这里兜底
                if s.doneFlash, doneKind, now - w.since > Double(max(s.alertSecs, 10) + 120) {
                    log("等你回复 -", w.agent, "·", w.project, "（做完了，提醒过了）"); return true
                }
                if s.doneTTL > 0, w.kind == "error" || (doneKind && !s.doneFlash), now - w.since > Double(s.doneTTL * 60) {
                    log("等你回复 -", w.agent, "·", w.project, "（做完了，到时间自动熄灯）"); return true
                }
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
    func clear(ids: [String], why: String) {
        lock.withLock {
            waiting.removeAll { w in
                guard ids.contains(w.id) else { return false }
                log("等你回复 -", w.agent, "·", w.project, "（\(why)）"); return true
            }
        }
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
        var d = DeviceSeen(ip: ip, at: Date(), fw: query["fw"] ?? "", rssi: Int(query["rssi"] ?? "") ?? 0, up: Int(query["up"] ?? "") ?? 0)
        d.bat = query["bat"].flatMap { Int($0) }
        d.power = query["pwr"] == "1"
        d.mv = Int(query["bmv"] ?? "") ?? 0
        d.ma = Int(query["bma"] ?? "") ?? 0
        let (isNew, logBatt): (Bool, Bool) = lock.withLock {
            let n = device == nil || device!.ip != ip || Date().timeIntervalSince(device!.at) > 60
            // 电量记进日志：刚连上、插拔线、每变 10 个点（方便以后校准电压和百分比的对应）
            var lb = false
            if let b = d.bat {
                if n || d.power != lastBattPower || abs(b - lastBattLogged) >= 10 { lb = true; lastBattLogged = b; lastBattPower = d.power }
            }
            device = d
            return (n, lb)
        }
        if isNew { log("机器人连上来了：", ip, "固件", d.fw); onChange() }
        if logBatt, let b = d.bat {
            log("机器人电量", "\(b)%", d.power ? "（插着线）" : "（用电池）", String(format: "%.2fV %.3fA", Double(d.mv) / 1000, Double(d.ma) / 1000))
        }
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
                                        "icon": s.showIcons ? IconStore.version(sub.id) : "",
                                        "windows": sub.windows.map { ["label": $0.label, "left": $0.left, "level": $0.level, "reset": $0.reset, "pace": $0.pace, "mins": $0.minutes] }]
                if let w = sub.shown {
                    d["left"] = w.left; d["label"] = w.label; d["level"] = w.level; d["reset"] = w.reset; d["pace"] = w.pace; d["error"] = ""
                } else {
                    d["left"] = NSNull(); d["label"] = ""; d["level"] = "na"; d["reset"] = ""; d["pace"] = ""; d["error"] = Gen.cantRead(l)
                }
                return d
            },
            "face": faceIds(subs, s),
            "split": Engine.single(subs).map { one -> [String: Any] in ["id": one.id, "w": Engine.splitWindows(one, s)] } ?? NSNull(),
            "lows": lows,
            "waiting": wait.map { w -> [String: Any] in
                let iid = s.showIcons ? IconStore.idForAgent(w.kind == "restored" ? "" : w.agent) : ""
                let rid = w.kind == "restored" ? (subs.first { $0.name == w.agent }?.id ?? "") : iid
                let v = s.showIcons ? IconStore.version(rid) : ""
                return ["id": w.id, "agent": w.agent, "mono": w.mono, "project": w.project, "kind": w.kind,
                        "text": Gen.kindText(w.kind, detail: w.detail, l), "since": Int(w.since), "acked": w.acked,
                        "icon": v.isEmpty ? "" : rid, "icon_v": v]
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
        if let k = s.quietSkipUntil, k > now { return false }
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: now)
        let weekend = wd == 1 || wd == 7
        if weekend && s.weekend == 1 { return true }
        if weekend && s.weekend == 2 { return false }
        let m = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let a = minutes(s.quietStart), b = minutes(s.quietEnd)
        return a < b ? (m >= a && m < b) : (m >= a || m < b)
    }
    /// 定时勿扰这一段什么时候结束（下一个「结束时间」）
    static func quietEnds(_ s: AppSettings, _ now: Date = Date()) -> Date {
        let m = minutes(s.quietEnd), cal = Calendar.current
        var d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: now) ?? now
        if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }
    static func minutes(_ hm: String) -> Int {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }

    static func deviceCfg(_ s: AppSettings, now: Date = Date()) -> [String: Any] {
        let h = Calendar.current.component(.hour, from: now)
        return [
            "rev": s.rev, "home": s.homeStyle, "list": s.listStyle, "detail": s.detailStyle, "alert_secs": s.alertSecs, "alert_style": s.alertStyle, "done_flash": s.doneFlash,
            "theme": s.theme, "eye": s.eye, "eye_color": s.eyeColor, "bright": s.brightness,
            "used": s.showUsed, "clock": s.clock, "blink": s.blink, "look": s.look,
            "sleepy": s.sleepyNight && (h >= 23 || h < 7), "dim_after": s.dimAfter,
            "alert": s.alertLevel, "remind": s.remind, "motion": s.motion, "nod": s.nod, "pitch": s.pitch,
            "wander": s.wander, "shake_low": s.shakeLow, "sound": s.sound, "volume": s.volume, "tone": s.tone,
            "led": s.led, "led_bright": s.ledBright, "led_idle": s.ledIdleOn ? s.ledIdle : "", "led_attn": s.ledAttn, "touch": s.touch,
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

    /// input：写进程序标准输入的内容（API Key、Cookie 走这里，不放在命令行参数里，免得别的程序用 ps 看到）
    static func run(_ path: String, _ args: [String], timeout: Double = 60, cwd: String? = nil, env: [String: String]? = nil, input: Data? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe }
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        do { try p.run() } catch { return Result(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8)) }
        if let inPipe, let input { inPipe.fileHandleForWriting.write(input); try? inPipe.fileHandleForWriting.close() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        g.wait()
        return Result(status: p.terminationStatus, stdout: outData, stderr: errData)
    }
}
