// 读额度用的 CodexBar 命令行（MIT 许可，作者 Peter Steinberger）。
// 装了 CodexBar 应用就用它自带的那份（它自己会更新）；没装就由小管家从 CodexBar 官方 GitHub 下载官方安装包，
// 核对校验值和作者的苹果开发者签名后，只取出里面的命令行，放在小管家自己的目录里，每天看一次有没有新版。
// （官方单独发布的命令行压缩包没有作者签名，核对不了是谁做的，所以不用它。）
import CryptoKit
import Foundation

enum CodexBarCLI {
    /// 作者的苹果开发者团队（CodexBar 应用和命令行都用它签名）
    static let teamID = "Y5PE65HELJ"
    static let repo = "steipete/CodexBar"

    enum Source { case app, managed, path }
    struct State: Equatable {
        var busy = false
        var error = ""
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State()
    static var state: State { lock.withLock { _state } }
    private static func set(_ f: (inout State) -> Void) { lock.withLock { f(&_state) } }

    // ---------- 用哪一份 ----------
    private static let appCands = ["/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
                                   NSString(string: "~/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI").expandingTildeInPath]
    private static let pathCands = ["/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"]
    static var managedRoot: URL { Paths.support.appendingPathComponent("CodexBarCLI") }

    /// 小管家自己下载的那份（目录名就是版本号，只留最新的一个）
    static var managedPath: String? {
        let fm = FileManager.default
        let vers = ((try? fm.contentsOfDirectory(atPath: managedRoot.path)) ?? []).filter { $0.hasPrefix("v") }.sorted { newer($0, than: $1) }
        for v in vers { if let exe = findExecutable(in: managedRoot.appendingPathComponent(v)) { return exe } }
        return nil
    }
    static var managedVersion: String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: managedRoot.path)) ?? []).filter { $0.hasPrefix("v") }.sorted { newer($0, than: $1) }.first
    }

    static func path() -> (String, Source)? {
        if let p = appCands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return (p, .app) }
        if let p = managedPath { return (p, .managed) }
        if let p = pathCands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return (p, .path) }
        return nil
    }

    /// 界面上显示的一句话
    static func describe() -> String {
        let st = state
        if st.busy { return t("正在下载读额度的组件…") }
        guard let (_, src) = path() else { return st.error.isEmpty ? t("还没有读额度的组件") : st.error }
        switch src {
        case .app: return t("用 CodexBar 应用自带的命令行")
        case .managed: return t("CodexBar 官方命令行 %@，小管家自动更新", managedVersion ?? "")
        case .path: return t("用这台 Mac 上装的 CodexBar 命令行")
        }
    }

    // ---------- 下载 / 更新 ----------
    /// 没有可用的就下载；用的是小管家自己那份时，有新版就换新的。返回是否换了新的。
    @discardableResult
    static func ensure() async -> Bool {
        if let (_, src) = path(), src != .managed { return false }      // 用 CodexBar 应用的，它自己会更新
        guard !state.busy else { return false }
        set { $0.busy = true; $0.error = "" }
        defer { set { $0.busy = false } }
        do {
            let rel = try await latestRelease()
            if let cur = managedVersion, !newer(rel.tag, than: cur) { return false }
            try await install(rel)
            log("CodexBar 命令行已就绪：", rel.tag)
            return true
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            set { $0.error = t("下载读额度的组件没成功：%@", msg) }
            log("CodexBar 命令行下载没成功：", msg)
            return false
        }
    }

    struct Release { var tag: String; var zipURL: URL; var shaURL: URL }
    enum CLIError: LocalizedError {
        case noAsset, badChecksum, badSignature(String), noExecutable
        var errorDescription: String? {
            switch self {
            case .noAsset: return t("官方发布里没有这台 Mac 能用的版本")
            case .badChecksum: return t("下载的文件校验不对")
            case .badSignature(let s): return t("签名不是 CodexBar 作者的（%@）", s)
            case .noExecutable: return t("压缩包里没找到命令行程序")
            }
        }
    }

    static func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StackChan-Butler", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (d, _) = try await URLSession.shared.data(for: req)
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]] else { throw CLIError.noAsset }
        // 官方安装包是通用版（Apple 芯片和 Intel 都能用）
        let name = "CodexBar-macos-universal-\(tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))).zip"
        func url(_ n: String) -> URL? { (assets.first { $0["name"] as? String == n }?["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let zip = url(name), let sha = url(name + ".sha256") else { throw CLIError.noAsset }
        return Release(tag: tag, zipURL: zip, shaURL: sha)
    }

    static func install(_ rel: Release) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("butler-cli-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 下载官方安装包（约 80 MB），核对校验值
        let (dl, _) = try await URLSession.shared.download(from: rel.zipURL)
        let zipFile = tmp.appendingPathComponent("CodexBar.zip")
        try fm.moveItem(at: dl, to: zipFile)
        let (shaData, _) = try await URLSession.shared.data(from: rel.shaURL)
        let want = String(decoding: shaData, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
        guard !want.isEmpty, want == (try sha256(of: zipFile)) else { throw CLIError.badChecksum }

        // 解开，核对整个应用是作者签的名，再只取出 Helpers（命令行和它要用的资源）
        let out = tmp.appendingPathComponent("out")
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, out.path], timeout: 120).status == 0,
              let app = ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.pathExtension == "app" })
        else { throw CLIError.noExecutable }
        let appTeam = signingTeam(app.path, deep: true)
        guard appTeam == teamID else { throw CLIError.badSignature(appTeam.isEmpty ? t("没有签名") : appTeam) }
        let helpers = app.appendingPathComponent("Contents/Helpers")
        guard let exe = findExecutable(in: helpers), signingTeam(exe) == teamID else { throw CLIError.noExecutable }

        try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let dest = managedRoot.appendingPathComponent(rel.tag)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try fm.moveItem(at: helpers, to: dest.appendingPathComponent("Helpers"))
        // 旧版本删掉，只留这一份
        for v in (try? fm.contentsOfDirectory(atPath: managedRoot.path)) ?? [] where v != rel.tag {
            try? fm.removeItem(at: managedRoot.appendingPathComponent(v))
        }
        enableDetectedProviders()
    }

    private static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 没装过 CodexBar 应用的 Mac 上没有它的配置：按这台 Mac 上装了哪些 AI 工具，打开对应的几家
    private static func enableDetectedProviders() {
        let cfg = NSString(string: "~/.config/codexbar/config.json").expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: cfg), let (exe, _) = path() else { return }
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: NSString(string: p).expandingTildeInPath) }
        var ids: [String] = []
        if has("~/.claude") || has("/Applications/Claude.app") { ids.append("claude") }
        if has("~/.codex") || has("/Applications/Codex.app") { ids.append("codex") }
        if has("~/.cursor") || has("/Applications/Cursor.app") { ids.append("cursor") }
        if has("~/.gemini") || has("/Applications/Antigravity.app") { ids.append("antigravity") }
        if has("~/.config/opencode") { ids.append("opencodego") }
        for id in ids { _ = Shell.run(exe, ["config", "enable", "--provider", id], timeout: 30, cwd: "/tmp") }
        log("CodexBar 命令行打开了：", ids.joined(separator: "、"))
    }

    // ---------- 小工具 ----------
    private static func findExecutable(in dir: URL) -> String? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let u as URL in e where ["codexbar", "CodexBarCLI"].contains(u.lastPathComponent) {
            if FileManager.default.isExecutableFile(atPath: u.path) { return u.path }
        }
        return nil
    }
    /// 签名的团队 ID（没签名返回空）
    static func signingTeam(_ path: String, deep: Bool = false) -> String {
        let r = Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", path], timeout: 20)
        guard Shell.run("/usr/bin/codesign", ["--verify", "--strict"] + (deep ? ["--deep"] : []) + [path], timeout: 120).status == 0 else { return "" }
        let s = String(decoding: r.stderr + r.stdout, as: UTF8.self)
        for line in s.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") { return String(line.dropFirst(15)) }
        return ""
    }
    /// v0.84.0 比 v0.83.1 新
    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
