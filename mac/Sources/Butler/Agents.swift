// 各个 AI 工具有没有接上 peon-ping（老办法，只读检查）。小管家自己的钩子见 Hooks.swift
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
            if read("~/.gemini/config/hooks.json").contains("antigravity-hook") { return .connected }   // 旧版小管家的转接脚本
            let la = (try? FileManager.default.contentsOfDirectory(atPath: NSString(string: "~/Library/LaunchAgents").expandingTildeInPath)) ?? []
            return la.contains { $0.lowercased().contains("antigravity") && $0.lowercased().contains("peon") } ? .connected : .none
        default: return .none
        }
    }

    /// 应用启动时把自带的钩子脚本放到应用支持目录（应用挪了位置也不会断；应用更新后脚本也跟着更新）
    static func refreshBundledHooks() {
        let dir = Paths.support.appendingPathComponent("hooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in Bundle.main.urls(forResourcesWithExtension: "sh", subdirectory: "hooks") ?? [] {
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if let a = try? Data(contentsOf: src), (try? Data(contentsOf: dst)) != a {
                try? a.write(to: dst)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            }
        }
        // 旧版的转接脚本（antigravity-hook.sh）已经没人用了
        if !HookInstaller.read(HookInstaller.antigravityHooks).contains("antigravity-hook.sh") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("antigravity-hook.sh"))
        }
    }

    static func howTo(_ agent: String) -> (text: String, command: String) {
        switch agent {
        case "Codex":
            return (t("小管家已经把钩子登记好了。Codex 出于安全，要你确认一次：打开 Codex，输入 /hooks，找到名字是 stackchan-butler 的那几条，选择信任。"), "/hooks")
        case "OpenCode":
            return (t("OpenCode 暂时还要借 peon-ping 接通：装好 peon-ping 后，在「终端」里运行下面这条命令，它会给 OpenCode 装一个很小的插件。装好后重开 OpenCode。"), "bash ~/.claude/hooks/peon-ping/adapters/opencode.sh")
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
                if agent == "OpenCode", Env.peonInstalled {
                    Button(t("打开 peon-ping 文件夹")) { NSWorkspace.shared.open(URL(fileURLWithPath: Env.peonDir)) }
                }
                Spacer()
                Button(t("好")) { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

/// 一个 AI 工具的接通状态和按钮（设置「提醒」页、安装向导共用）
struct AgentConnectControl: View {
    var agent: String
    @ObservedObject var model = AppModel.shared
    @State private var tick = 0
    @State private var error: String?
    @State private var howTo = false

    var body: some View {
        let _ = tick
        let st = HookInstaller.status(agent)
        let installed = HookInstaller.installed(agent)
        HStack(spacing: 8) {
            switch st {
            case .connected:
                Menu {
                    Button(t("断开")) { run { try HookInstaller.disconnect(agent) } }
                } label: { statusLabel(.green, t("已接通")) }
                    .menuStyle(.borderlessButton).fixedSize()
            case .needsTrust:
                statusLabel(.orange, t("还差一步"))
                Button(t("去 Codex 信任…")) { howTo = true }.controlSize(.small)
            case .viaPeon, .none:
                if st == .viaPeon { statusLabel(.green, t("经 peon-ping")) }
                else { statusLabel(.secondary, installed ? t("未接通") : t("没装")) }
                if HookInstaller.oneClick(agent) && installed {
                    Button(t("接通")) {
                        run { try HookInstaller.connect(agent) }
                        if agent == "Codex", error == nil { howTo = true }      // Codex 还要你信任一次
                    }.controlSize(.small)
                } else if agent == "OpenCode" && installed && st == .none {
                    Button(t("接通…")) { howTo = true }.controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $howTo) { AgentHowTo(agent: agent) { howTo = false; tick += 1 } }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(t("好")) {} }
    }

    private func statusLabel(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(s).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private func run(_ f: () throws -> Void) {
        do { try f() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        tick += 1
    }
}
