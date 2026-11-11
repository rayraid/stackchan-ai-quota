// 每家服务商的读取设置：开关、读取方式、API Key、Cookie。
// 设置都存在 CodexBar 自己的配置文件里（~/.config/codexbar/config.json，CodexBar 应用和命令行共用），
// 小管家只通过 CodexBar 命令行的正式命令去改；Key 和 Cookie 经标准输入递过去，小管家自己不存、界面上也不显示。
import Foundation

/// 某一家 CodexBar 支持什么（来自 `codexbar config providers`）
struct ProviderCaps: Identifiable, Hashable {
    var id: String
    var name: String
    var sourceModes: [String]        // auto / web / cli / oauth / api 里它支持的那几个
    var apiKey: Bool                 // 能在配置里存 API Key
    var cookie: Bool                 // 能在配置里存手动 Cookie
    var accountsTitle: String        // 多个账号叫什么（空 = 不支持多账号）
    var loginCommand: String         // 要在终端里登录的（比如 Copilot）
    var envVars: [String]
    var enabled: Bool
}

/// 某一家现在的设置（来自 `codexbar config dump`，Key 和 Cookie 本身已被它隐去）
struct ProviderConf: Hashable {
    var id: String
    var enabled = false
    var source = "auto"
    var cookieSource = "auto"        // auto 从浏览器读 / manual 手动粘贴的 / off
    var hasAPIKey = false
    var hasCookie = false
    var accounts: [String] = []      // 账号的名字
    var activeAccount = 0
}

enum CodexBarConfig {
    nonisolated(unsafe) private static var capsCache: [ProviderCaps] = []
    private static let lock = NSLock()

    /// 读取方式的说法
    static func sourceName(_ m: String) -> String {
        switch m {
        case "auto": return t("自动")
        case "web": return t("网页登录")
        case "cli": return t("命令行")
        case "oauth": return t("OAuth 登录")
        case "api": return "API Key"
        case "local+web", "local": return t("本机")
        default: return m
        }
    }

    private static func run(_ args: [String], input: String? = nil) -> (ok: Bool, json: Any?, message: String) {
        guard let exe = Engine.codexbarPath() else { return (false, nil, t("找不到 CodexBar 命令行")) }
        let r = Shell.run(exe, args + ["--format", "json"], timeout: 60, cwd: "/tmp", input: input.map { Data($0.utf8) })
        let json = try? JSONSerialization.jsonObject(with: r.stdout)
        var msg = ""
        if let arr = json as? [[String: Any]], let e = arr.first?["error"] as? [String: Any] { msg = e["message"] as? String ?? "" }
        if let d = json as? [String: Any], let e = d["error"] as? [String: Any] { msg = e["message"] as? String ?? "" }
        if msg.isEmpty && r.status != 0 { msg = String(decoding: r.stderr.prefix(300), as: UTF8.self) }
        return (r.status == 0 && msg.isEmpty, json, msg)
    }

    /// CodexBar 支持的所有服务商（每次打开设置时刷新；CodexBar 自己每天更新，新支持的会自动出现）
    static func providers(refresh: Bool = false) -> [ProviderCaps] {
        if !refresh, let c = lock.withLock({ capsCache.isEmpty ? nil : capsCache }) { return c }
        let r = run(["config", "providers"])
        guard let arr = r.json as? [[String: Any]] else { return lock.withLock { capsCache } }
        let caps: [ProviderCaps] = arr.compactMap { p in
            guard let id = p["provider"] as? String else { return nil }
            let a = p["authentication"] as? [String: Any] ?? [:]
            let ta = a["tokenAccounts"] as? [String: Any]
            return ProviderCaps(id: id, name: p["displayName"] as? String ?? id,
                                sourceModes: a["sourceModes"] as? [String] ?? ["auto"],
                                apiKey: a["supportsConfigAPIKey"] as? Bool ?? false,
                                cookie: a["supportsConfigCookieHeader"] as? Bool ?? false,
                                accountsTitle: ta?["title"] as? String ?? "",
                                loginCommand: a["loginCommand"] as? String ?? "",
                                envVars: a["environmentVariables"] as? [String] ?? [],
                                enabled: p["enabled"] as? Bool ?? false)
        }
        lock.withLock { capsCache = caps }
        ProviderNames.set(Dictionary(caps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        return caps
    }

    /// 每家现在的设置
    static func current() -> [String: ProviderConf] {
        let r = run(["config", "dump"])
        guard let d = r.json as? [String: Any], let ps = d["providers"] as? [[String: Any]] else { return [:] }
        var out: [String: ProviderConf] = [:]
        for p in ps {
            guard let id = p["id"] as? String else { continue }
            var c = ProviderConf(id: id)
            c.enabled = p["enabled"] as? Bool ?? false
            c.source = p["source"] as? String ?? "auto"
            c.cookieSource = p["cookieSource"] as? String ?? "auto"
            c.hasAPIKey = p["apiKey"] != nil
            c.hasCookie = p["cookieHeader"] != nil
            if let ta = p["tokenAccounts"] as? [String: Any], let accs = ta["accounts"] as? [[String: Any]] {
                c.accounts = accs.map { $0["label"] as? String ?? "—" }
                c.activeAccount = ta["activeIndex"] as? Int ?? 0
            }
            out[id] = c
        }
        return out
    }

    @discardableResult static func setEnabled(_ id: String, _ on: Bool) -> String? {
        let r = run(["config", on ? "enable" : "disable", "--provider", id])
        log(on ? "CodexBar 打开了：" : "CodexBar 关掉了：", id, r.ok ? "" : r.message)
        return r.ok ? nil : r.message
    }
    @discardableResult static func setSource(_ id: String, _ mode: String) -> String? {
        let r = run(["config", "set-source", "--provider", id, "--source", mode])
        log("CodexBar 读取方式：", id, mode, r.ok ? "" : r.message)
        return r.ok ? nil : r.message
    }
    @discardableResult static func setAPIKey(_ id: String, _ key: String) -> String? {
        let r = run(["config", "set-api-key", "--provider", id, "--stdin"], input: key.trimmingCharacters(in: .whitespacesAndNewlines))
        log("CodexBar 存了 API Key：", id, r.ok ? "" : r.message)
        return r.ok ? nil : r.message
    }
    @discardableResult static func setCookie(_ id: String, _ cookie: String) -> String? {
        let r = run(["config", "set-cookie", "--provider", id, "--stdin"], input: cookie.trimmingCharacters(in: .whitespacesAndNewlines))
        log("CodexBar 存了手动 Cookie：", id, r.ok ? "" : r.message)
        return r.ok ? nil : r.message
    }
    @discardableResult static func clearAPIKey(_ id: String) -> String? {
        let r = run(["config", "clear-credential", "--provider", id, "--api-key"])
        log("CodexBar 清除了 API Key：", id, r.ok ? "" : r.message)
        return r.ok ? nil : r.message
    }
    /// 清掉手动 Cookie，并改回「自动从浏览器读」（命令行没有改回的命令，只改配置文件里这一项）
    @discardableResult static func clearCookie(_ id: String) -> String? {
        let r = run(["config", "clear-credential", "--provider", id, "--cookie"])
        log("CodexBar 清除了手动 Cookie：", id, r.ok ? "" : r.message)
        if !r.ok { return r.message }
        let path = NSString(string: "~/.config/codexbar/config.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var ps = root["providers"] as? [[String: Any]],
              let i = ps.firstIndex(where: { $0["id"] as? String == id }),
              ps[i]["cookieSource"] as? String == "manual" else { return nil }
        ps[i]["cookieSource"] = "auto"
        root["providers"] = ps
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return nil
    }
}

/// CodexBar 给的服务商名字（我们自己的表里没有的那几百家用它）
enum ProviderNames {
    nonisolated(unsafe) private static var names: [String: String] = [:]
    private static let lock = NSLock()
    static func set(_ d: [String: String]) { lock.withLock { names = d } }
    static func get(_ id: String) -> String? { lock.withLock { names[id] } }
}
