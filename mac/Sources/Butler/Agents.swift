// 各个 AI 工具有没有接上 peon-ping（只读检查，不改它们的配置；只会更新小管家自己带的 Antigravity 转接脚本）
import AppKit
import SwiftUI

enum AgentHooks {
    enum Status { case connected, partial, none }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)) ?? ""
    }
    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
    }

    static func status(_ agent: String) -> Status {
        switch agent {
        case "Claude Code":
            return read("~/.claude/settings.json").contains("peon-ping") ? .connected : .none
        case "Codex":
            // 钩子写进了 config.toml，还要你在 Codex 里信任一次；信任后 Codex 会在同一个文件里记下 stop 钩子的指纹
            let c = read("~/.codex/config.toml")
            guard c.contains("peon") else { return .none }
            return c.contains("config.toml:stop:") ? .connected : .partial
        case "Cursor":
            let h = read("~/.cursor/hooks.json")
            if let d = (try? JSONSerialization.jsonObject(with: Data(h.utf8))) as? [String: Any] {
                let peon = { (x: Any?) in ((x as? [String: Any])?["command"] as? String ?? "").contains("peon") }
                if let hooks = d["hooks"] as? [String: Any], let stop = hooks["stop"] as? [Any], stop.contains(where: peon) { return .connected }
                if let arr = d["hooks"] as? [[String: Any]], arr.contains(where: { $0["event"] as? String == "stop" && peon($0) }) { return .connected }
            }
            return h.contains("peon") ? .partial : .none      // 装 peon-ping 时只登记了它自己的小命令，还没有「做完了」
        case "OpenCode":
            for sub in ["plugins", "plugin"] {
                let dir = NSString(string: "~/.config/opencode/" + sub).expandingTildeInPath
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                if files.contains(where: { $0.lowercased().contains("peon") }) { return .connected }
            }
            return .none
        case "Antigravity":
            // Antigravity 2 的正式钩子；也认 peon-ping 自己那个「盯文件」的后台程序
            if read("~/.gemini/config/hooks.json").contains("antigravity-hook") { return .connected }
            let la = (try? FileManager.default.contentsOfDirectory(atPath: NSString(string: "~/Library/LaunchAgents").expandingTildeInPath)) ?? []
            return la.contains { $0.lowercased().contains("antigravity") && $0.lowercased().contains("peon") } ? .connected : .none
        default: return .none
        }
    }

    /// Antigravity 钩子调用的转接脚本：放在应用支持目录，应用挪了位置也不会断
    static var antigravityHookPath: String {
        NSString(string: "~/Library/Application Support/StackChan Butler/hooks/antigravity-hook.sh").expandingTildeInPath
    }

    /// 应用启动时把自带的转接脚本放过去（应用更新后脚本也跟着更新）
    static func refreshBundledHooks() {
        guard let src = Bundle.main.url(forResource: "antigravity-hook", withExtension: "sh", subdirectory: "hooks") else { return }
        let dst = URL(fileURLWithPath: antigravityHookPath)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let a = try? Data(contentsOf: src), (try? Data(contentsOf: dst)) != a {
            try? a.write(to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    static func howTo(_ agent: String) -> (text: String, command: String) {
        switch agent {
        case "Claude Code":
            return (t("装 peon-ping 时会自动接通 Claude Code。如果显示未接通，重新运行一次 peon-ping 的安装。"), "")
        case "Codex":
            return (t("peon-ping 已经在 Codex 的配置里登记了。打开 Codex，输入 /hooks，找到 peon-ping 那一条，选择信任，就接通了。"), "")
        case "Cursor":
            return (t("peon-ping 能直接认 Cursor 的事件。在 ~/.cursor/hooks.json 的 stop 和 beforeSubmitPrompt 里各加一条下面这个命令，然后重开 Cursor。"), "bash ~/.claude/hooks/peon-ping/peon.sh")
        case "OpenCode":
            return (t("在「终端」里运行下面这条命令，它会给 OpenCode 装一个很小的插件。装好后重开 OpenCode。"), "bash ~/.claude/hooks/peon-ping/adapters/opencode.sh")
        case "Antigravity":
            return (t("Antigravity 2 有正式的钩子。小管家带了一个转接脚本，把它登记在 ~/.gemini/config/hooks.json 的 Stop 和 PreInvocation 里（后面加上同名参数），然后重开 Antigravity。"), "sh \"" + AgentHooks.antigravityHookPath + "\" Stop")
        default: return ("", "")
        }
    }
}

struct AgentHowTo: View {
    var agent: String
    var close: () -> Void
    var body: some View {
        let h = AgentHooks.howTo(agent)
        VStack(alignment: .leading, spacing: 14) {
            Text(t("接通 %@", agent)).font(.title3.bold())
            Text(h.text).fixedSize(horizontal: false, vertical: true)
            if !h.command.isEmpty {
                HStack {
                    Text(h.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    Button(t("复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(h.command, forType: .string)
                    }
                }
            }
            HStack {
                Button(t("打开 peon-ping 文件夹")) { NSWorkspace.shared.open(URL(fileURLWithPath: Env.peonDir)) }
                Spacer()
                Button(t("好")) { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

/// Codex 的会话是不是子任务：看 Codex 自己记的会话文件（~/.codex/sessions/年/月/日/rollout-…-<会话 id>.jsonl）
/// 第一行的 source 里有没有 subagent。只读；找不到文件或格式变了，就当不是子任务（照常提醒）。
enum CodexThreads {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Bool] = [:]

    static func isSubagent(_ threadId: String) -> Bool {
        guard !threadId.isEmpty else { return false }
        if let v = lock.withLock({ known[threadId] }) { return v }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        var found: URL?
        for back in 0..<3 {                     // 子任务都是最近派出去的：看今天和前两天
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            if let f = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(threadId + ".jsonl") }) {
                found = dir.appendingPathComponent(f); break
            }
        }
        guard let u = found, let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 1 << 20)) ?? Data()
        let first = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: true).first.map { Data($0) } ?? Data()
        var sub = false
        if let o = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any],
           let p = o["payload"] as? [String: Any], let src = p["source"] as? [String: Any] {
            sub = src["subagent"] != nil
        }
        lock.withLock { known[threadId] = sub }
        return sub
    }
}
