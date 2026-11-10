// 小管家自己的提醒钩子：一键接通 / 断开各个 AI 工具。
// 改配置前先备份；只增删小管家自己那几条（命令里带 butler-hook.sh），别人加的钩子一律不碰。
import Foundation

enum HookInstaller {
    enum Status: Equatable {
        case connected      // 小管家自己的钩子已经在用
        case needsTrust     // 已登记，还要你在 Codex 里信任一次
        case viaPeon        // 还在走 peon-ping（老办法，能用）
        case none
    }

    static let marker = "butler-hook.sh"
    static var scriptPath: String { Paths.support.appendingPathComponent("hooks/butler-hook.sh").path }
    static func command(_ tool: String, _ event: String = "") -> String {
        "sh \"\(scriptPath)\" \(tool)" + (event.isEmpty ? "" : " " + event)
    }

    static func agentName(_ tool: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "cursor": "Cursor", "antigravity": "Antigravity", "opencode": "OpenCode"][tool] ?? tool
    }
    /// 能一键接通的工具（OpenCode 的插件格式还没做，先走老办法）
    static func oneClick(_ agent: String) -> Bool { ["Claude Code", "Codex", "Cursor", "Antigravity"].contains(agent) }

    // ---------- 各家的配置文件 ----------
    private static func home(_ p: String) -> String { NSString(string: p).expandingTildeInPath }
    static let claudeSettings = home("~/.claude/settings.json")
    static let codexHooks = home("~/.codex/hooks.json")
    static let codexConfig = home("~/.codex/config.toml")
    static let cursorHooks = home("~/.cursor/hooks.json")
    static let antigravityHooks = home("~/.gemini/config/hooks.json")

    private static let claudeEvents = ["Stop", "StopFailure", "PermissionRequest", "Notification", "UserPromptSubmit",
                                       "PreToolUse", "PostToolUse", "SessionStart", "SessionEnd"]
    private static let codexEvents = ["Stop", "PermissionRequest", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart"]
    private static let cursorEvents = ["stop", "beforeSubmitPrompt"]
    private static let antigravityEvents = ["Stop", "PreInvocation"]
    private static let ourName = "stackchan-butler"

    /// 这台 Mac 上有没有装这个工具（没装就不给「接通」）
    static func installed(_ agent: String) -> Bool {
        let fm = FileManager.default
        switch agent {
        case "Claude Code": return fm.fileExists(atPath: home("~/.claude"))
        case "Codex": return fm.fileExists(atPath: home("~/.codex"))
        case "Cursor": return fm.fileExists(atPath: home("~/.cursor")) || fm.fileExists(atPath: "/Applications/Cursor.app")
        case "Antigravity": return fm.fileExists(atPath: home("~/.gemini")) || fm.fileExists(atPath: "/Applications/Antigravity.app")
        case "OpenCode": return fm.fileExists(atPath: home("~/.config/opencode"))
        default: return false
        }
    }

    static func status(_ agent: String) -> Status {
        switch agent {
        case "Claude Code":
            return read(claudeSettings).contains(marker) ? .connected : peon(agent)
        case "Codex":
            // Codex 出于安全，新钩子要你在 Codex 里信任一次；信任后它在 config.toml 里记下「文件:事件:第几组:第几条」
            guard let i = groupIndex((try? loadJSON(codexHooks)) ?? [:], "Stop") else { return peon(agent) }
            return read(codexConfig).contains("\(codexHooks):stop:\(i):0") ? .connected : .needsTrust
        case "Cursor":
            return read(cursorHooks).contains(marker) ? .connected : peon(agent)
        case "Antigravity":
            let h = read(antigravityHooks)
            return h.contains(marker) ? .connected : peon(agent)
        default:
            return peon(agent)
        }
    }
    private static func peon(_ agent: String) -> Status { AgentHooks.status(agent) == .connected ? .viaPeon : .none }

    // ---------- 接通 / 断开 ----------
    static func connect(_ agent: String) throws {
        AgentHooks.refreshBundledHooks()
        switch agent {
        case "Claude Code": try addGroups(claudeSettings, events: claudeEvents, tool: "claude", extra: [:])
        case "Codex":
            try addGroups(codexHooks, events: codexEvents, tool: "codex", extra: ["name": ourName, "matcher": "*"])
            try enableCodexHooks()
        case "Cursor": try editCursor(add: true)
        case "Antigravity": try editAntigravity(add: true)
        default: throw HookError.unsupported
        }
        log("接通了", agent, "（小管家自己的钩子）")
    }

    static func disconnect(_ agent: String) throws {
        switch agent {
        case "Claude Code": try removeGroups(claudeSettings)
        case "Codex": try removeGroups(codexHooks)
        case "Cursor": try editCursor(add: false)
        case "Antigravity": try editAntigravity(add: false)
        default: throw HookError.unsupported
        }
        log("断开了", agent)
    }

    /// 旧版小管家给 Antigravity 装的是走 peon-ping 的转接脚本；它是小管家自己的条目，启动时直接换成新的
    static func migrateOldAntigravity() {
        if read(antigravityHooks).contains("antigravity-hook.sh") { try? editAntigravity(add: true) }
    }

    enum HookError: LocalizedError {
        case unsupported, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return t("这个工具还不能一键接通")
            case .unreadable(let p): return t("读不懂 %@，没有改它", (p as NSString).abbreviatingWithTildeInPath)
            }
        }
    }

    // ---------- Claude Code / Codex：{"hooks": {"事件": [ {"hooks": [ {"type": "command", "command": …} ]} ]}} ----------
    private static func isOurs(_ group: Any) -> Bool {
        ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains { (($0 as? [String: Any])?["command"] as? String ?? "").contains(marker) }
    }
    private static func groupIndex(_ root: [String: Any], _ event: String) -> Int? {
        ((root["hooks"] as? [String: Any])?[event] as? [Any])?.firstIndex(where: isOurs)
    }
    private static func addGroups(_ path: String, events: [String], tool: String, extra: [String: Any]) throws {
        var root = try loadJSON(path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for ev in events {
            var arr = hooks[ev] as? [Any] ?? []
            if arr.contains(where: isOurs) { continue }
            var g = extra
            g["hooks"] = [["type": "command", "command": command(tool), "timeout": 10]]
            arr.append(g)
            hooks[ev] = arr
            changed = true
        }
        guard changed else { return }
        root["hooks"] = hooks
        try save(root, path)
    }
    private static func removeGroups(_ path: String) throws {
        var root = try loadJSON(path)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false
        for (ev, v) in hooks {
            guard let arr = v as? [Any], arr.contains(where: isOurs) else { continue }
            let rest = arr.filter { !isOurs($0) }
            hooks[ev] = rest.isEmpty ? nil : rest
            changed = true
        }
        guard changed else { return }
        root["hooks"] = hooks
        try save(root, path)
    }

    /// Codex 的钩子功能要在 config.toml 的 [features] 里打开
    private static func enableCodexHooks() throws {
        let text = read(codexConfig)
        var lines = text.components(separatedBy: "\n")
        if let f = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            var end = f + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            if let h = (f + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("hooks") && lines[$0].contains("=") }) {
                if lines[h].contains("true") { return }
                lines[h] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: f + 1)
            }
        } else {
            lines.append(contentsOf: ["", "[features]", "hooks = true", ""])
        }
        backup(codexConfig)
        try lines.joined(separator: "\n").write(toFile: codexConfig, atomically: true, encoding: .utf8)
    }

    // ---------- Cursor：{"version": 1, "hooks": {"stop": [ {"command": …} ]}} ----------
    private static func editCursor(add: Bool) throws {
        var root = try loadJSON(cursorHooks)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let ours = { (x: Any) in ((x as? [String: Any])?["command"] as? String ?? "").contains(marker) }
        var changed = false
        for ev in cursorEvents {
            var arr = hooks[ev] as? [Any] ?? []
            if add, !arr.contains(where: ours) { arr.append(["command": command("cursor")]); changed = true }
            if !add, arr.contains(where: ours) { arr.removeAll(where: ours); changed = true }
            hooks[ev] = arr.isEmpty ? nil : arr
        }
        guard changed else { return }
        if root["version"] == nil { root["version"] = 1 }
        root["hooks"] = hooks
        try save(root, cursorHooks)
    }

    // ---------- Antigravity：{"stackchan-butler": {"Stop": [ {"type": "command", "command": …} ]}} ----------
    private static func editAntigravity(add: Bool) throws {
        var root = try loadJSON(antigravityHooks)
        if add {
            var mine: [String: Any] = [:]
            for ev in antigravityEvents { mine[ev] = [["type": "command", "command": command("antigravity", ev), "timeout": 5]] }
            root[ourName] = mine
        } else {
            guard root[ourName] != nil else { return }
            root[ourName] = nil
        }
        try save(root, antigravityHooks)
    }

    // ---------- 读写 ----------
    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// 文件不存在 = 空的；存在但读不懂就不动它
    private static func loadJSON(_ path: String) throws -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: path), !d.isEmpty else { return [:] }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw HookError.unreadable(path) }
        return j
    }
    private static func save(_ root: [String: Any], _ path: String) throws {
        backup(path)
        let d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    /// 改之前在旁边留一份：文件名.bak-butler-年月日-时分秒
    private static func backup(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let b = path + ".bak-butler-" + DateFormatter.cached("yyyyMMdd-HHmmss").string(from: Date())
        if !FileManager.default.fileExists(atPath: b) { try? FileManager.default.copyItem(atPath: path, toPath: b) }
    }
}
