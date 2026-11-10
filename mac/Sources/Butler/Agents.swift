// 各个 AI 工具有没有接上 peon-ping（只读检查，不改它们的配置）
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
            return read("~/.codex/config.toml").contains("peon") ? .partial : .none   // 还要在 Codex 里信任一次，这里看不出来
        case "Cursor":
            let h = read("~/.cursor/hooks.json")
            if h.contains("cursor.sh") && h.contains("stop") { return .connected }
            return h.contains("peon") ? .partial : .none
        case "OpenCode":
            let dir = NSString(string: "~/.config/opencode/plugin").expandingTildeInPath
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return files.contains { $0.lowercased().contains("peon") } ? .connected : .none
        case "Antigravity":
            let la = (try? FileManager.default.contentsOfDirectory(atPath: NSString(string: "~/Library/LaunchAgents").expandingTildeInPath)) ?? []
            return la.contains { $0.lowercased().contains("antigravity") && $0.lowercased().contains("peon") } ? .connected : .none
        default: return .none
        }
    }

    static func howTo(_ agent: String) -> (text: String, command: String) {
        switch agent {
        case "Claude Code":
            return (t("装 peon-ping 时会自动接通 Claude Code。如果显示未接通，重新运行一次 peon-ping 的安装。"), "")
        case "Codex":
            return (t("peon-ping 已经在 Codex 的配置里登记了。打开 Codex，输入 /hooks，找到 peon-ping 那一条，选择信任，就接通了。"), "")
        case "Cursor":
            return (t("peon-ping 自带 Cursor 适配脚本。按脚本开头的说明，在 ~/.cursor/hooks.json 里加上 stop 和 beforeShellExecution 两条，指向这个脚本。"), "~/.claude/hooks/peon-ping/adapters/cursor.sh")
        case "OpenCode":
            return (t("在「终端」里运行下面这条命令，它会给 OpenCode 装一个很小的插件。"), "bash ~/.claude/hooks/peon-ping/adapters/opencode.sh")
        case "Antigravity":
            return (t("Antigravity 没有正式的通知。peon-ping 的适配脚本会盯住它的对话文件，几秒没更新就当作做完了，需要先装 fswatch。"), "bash ~/.claude/hooks/peon-ping/adapters/antigravity.sh")
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
