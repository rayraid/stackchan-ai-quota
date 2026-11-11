// 读各个 AI 工具自己记的会话文件（只读），判断一条「做完了」是不是主任务真的停下来等你了。
// 看不出来（文件找不到、格式变了）时一律当「是」，照常提醒：宁可多提醒一次，也不能漏掉。
import Foundation

/// Claude Code 的会话记录：~/.claude/projects/<目录>/<会话 id>.jsonl；
/// 后台子任务各有一份 <会话 id>/subagents/agent-<子任务 id>.jsonl
enum ClaudeSessions {
    struct Busy: CustomStringConvertible {
        var agents = 0      // 派出去还没回报的后台子任务
        var queued = 0      // 排着队等主任务接着处理的消息（子任务的回报、你在它忙时发的话）
        var description: String { "（后台子任务 \(agents) 个，排队消息 \(queued) 条）" }
    }

    /// 主任务还没真正停下就返回原因：它把活派给后台子任务后会先「停」一下等回报，回报一到又接着干。
    /// 真停下了、或者看不出来，返回 nil
    static func busy(_ path: String, now: Date = Date()) -> Busy? {
        guard !path.isEmpty, let s = scan(path) else { return nil }
        var b = Busy()
        let dir = (path as NSString).deletingPathExtension + "/subagents"
        for (id, at) in s.launched where !s.finished.contains(id) && running(id, launchedAt: at, dir: dir, now: now) {
            b.agents += 1
        }
        // 只算半小时内排进来的：万一记录里少了一条「取走」，不至于这个对话从此再也不提醒
        b.queued = s.queue.filter { now.timeIntervalSince($0) < 1800 }.count
        return b.agents + b.queued > 0 ? b : nil
    }

    /// 按会话 id 找记录文件
    static func transcript(session sid: String) -> String? {
        guard !sid.isEmpty, !sid.contains("/") else { return nil }
        return projectDirs().map { $0 + "/" + sid + ".jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// peon-ping 只告诉我们项目名：找最近两分钟写过、工作目录对得上的那个会话（几个都对得上就要最新写的）
    static func recentTranscript(project: String, within: Double = 120, now: Date = Date()) -> (path: String, session: String)? {
        guard !project.isEmpty, project != "?" else { return nil }
        var best: (path: String, at: Date)?
        for dir in projectDirs() {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                guard let m = mtime(p), now.timeIntervalSince(m) < within, m > (best?.at ?? .distantPast) else { continue }
                let t = tail(p, 128 << 10)
                guard let r = t.range(of: "\"cwd\":\"", options: .backwards) else { continue }
                let cwd = String(t[r.upperBound...].prefix { $0 != "\"" })
                if Workspace.names(cwd).contains(project) { best = (p, m) }
            }
        }
        guard let b = best else { return nil }
        return (b.path, ((b.path as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    // ---------- 一边读一边记：每个会话文件只往后读新写的部分 ----------
    private struct Scan {
        var offset: UInt64 = 0
        var launched: [String: Date] = [:]   // 后台子任务 id → 派出去的时间
        var finished: Set<String> = []
        var queue: [Date] = []               // 还在排队的消息（排进来的时间）
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scans: [String: Scan] = [:]
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path

    private static func scan(_ path: String) -> Scan? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return lock.withLock {
            var s = scans[path] ?? Scan()
            let size = (try? h.seekToEnd()) ?? 0
            if size < s.offset { s = Scan() }               // 文件变短了（被重写）：从头再看
            try? h.seek(toOffset: s.offset)
            let data = (try? h.readToEnd()) ?? Data()
            if let cut = data.lastIndex(of: UInt8(ascii: "\n")) {   // 只处理写完整的行
                for line in String(decoding: data[data.startIndex...cut], as: UTF8.self).split(separator: "\n") { take(line, &s) }
                s.offset += UInt64(data.distance(from: data.startIndex, to: cut) + 1)
            }
            scans[path] = s
            return s
        }
    }

    private static func take(_ line: Substring, _ s: inout Scan) {
        if line.contains("\"type\":\"queue-operation\"") {
            if line.contains("\"operation\":\"enqueue\"") { s.queue.append(stamp(line) ?? Date()) }
            else if !s.queue.isEmpty { s.queue.removeFirst() }      // dequeue（取走处理）、remove（撤掉）
        }
        // 派出后台子任务：工具结果里有 "status":"async_launched","agentId":"…"，文字以这句开头、后面跟着 agentId。
        // 只认没转义的引号：别的工具输出里引用到这些字（比如有人在查这个日志）都是带反斜杠的，不会当真
        if line.contains("\"status\":\"async_launched\"") {
            for id in ids(after: "\"agentId\":\"", in: line) { s.launched[id] = stamp(line) ?? Date() }
        } else if line.contains("\"text\":\"Async agent launched successfully") || line.contains("\"content\":\"Async agent launched successfully") {
            for id in ids(after: "agentId: ", in: line) { s.launched[id] = stamp(line) ?? Date() }
        }
        // 主任务给已经做完的子任务再派活（SendMessage 叫醒它）：又在跑了，等它下一次回报
        if line.contains("\"resumedAgentId\":\"") {
            for id in ids(after: "\"resumedAgentId\":\"", in: line) { s.finished.remove(id); s.launched[id] = stamp(line) ?? Date() }
        }
        // 子任务回报：做完、出错、被停掉都会来一条 <task-notification>；桌面版另有一条「最终报告」
        if line.contains("<task-id>") { s.finished.formUnion(ids(after: "<task-id>", in: line)) }
        if line.contains("Subagent hand-back") { s.finished.formUnion(ids(after: "agent-message from=\\\"", in: line)) }
    }

    /// 派出去还没回报的子任务算不算还在跑：它自己的记录半小时内还在写就算；找不到它的记录，就看是不是一小时内派出去的
    private static func running(_ id: String, launchedAt: Date, dir: String, now: Date) -> Bool {
        if let m = mtime(dir + "/agent-" + id + ".jsonl") { return now.timeIntervalSince(m) < 1800 }
        return now.timeIntervalSince(launchedAt) < 3600
    }

    private static func projectDirs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).map { root + "/" + $0 }
    }
    private static func ids(after marker: String, in line: Substring) -> [String] {
        var out: [String] = []
        var rest = line[...]
        while let r = rest.range(of: marker) {
            let id = rest[r.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            if !id.isEmpty { out.append(String(id)) }
            rest = rest[r.upperBound...]
        }
        return out
    }
}

/// Codex 的会话：~/.codex/sessions/年/月/日/rollout-…-<会话 id>.jsonl，第一行的 source 里有 subagent 的是子任务
enum CodexThreads {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Bool] = [:]
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions").path

    /// 找不到文件或格式变了，就当不是子任务（照常提醒）
    static func isSubagent(_ threadId: String) -> Bool {
        guard !threadId.isEmpty else { return false }
        if let v = lock.withLock({ known[threadId] }) { return v }
        var found: String?
        for dir in dayDirs(3) {                   // 子任务都是最近派出去的：看今天和前两天
            if let f = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(threadId + ".jsonl") }) {
                found = dir + "/" + f; break
            }
        }
        guard let p = found, let h = FileHandle(forReadingAtPath: p) else { return false }
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

    /// 刚刚（默认 10 秒内）做完一轮的 Codex 会话里最晚的那个。peon-ping 那条路不一定知道推送来自哪个会话，用它核对
    static func latestFinished(within secs: Double = 10, now: Date = Date()) -> (id: String, sub: Bool)? {
        var best: (id: String, at: Date)?
        for dir in dayDirs(2) {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") && f.count > 42 {
                let p = dir + "/" + f
                guard let m = mtime(p), now.timeIntervalSince(m) < secs + 5 else { continue }
                for line in tail(p, 256 << 10).split(separator: "\n").reversed() where line.contains("\"type\":\"task_complete\"") {
                    if let at = stamp(line), now.timeIntervalSince(at) < secs, at > (best?.at ?? .distantPast) {
                        best = (String(f.dropLast(6).suffix(36)), at)
                    }
                    break
                }
            }
        }
        return best.map { ($0.id, isSubagent($0.id)) }
    }

    private static func dayDirs(_ n: Int) -> [String] {
        let cal = Calendar.current
        return (0..<n).compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return root + String(format: "/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }
}

/// 一个工作目录可能被叫成什么：文件夹名，和 git 远端仓库名（peon-ping 推送标题里优先用后者，只留字母数字和 ._- 空格）
enum Workspace {
    static func names(_ cwd: String) -> Set<String> {
        guard !cwd.isEmpty else { return [] }
        let clean = { (s: String) in String(s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0)) }) }
        var out: Set<String> = [clean(URL(fileURLWithPath: cwd).lastPathComponent)]
        if let url = originURL(cwd) {
            var name = url.hasSuffix("/") ? String(url.dropLast()) : url
            name = String(name.split(separator: "/").last ?? "")
            if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
            out.insert(clean(name))
        }
        out.remove("")
        return out
    }

    /// 往上找 .git（工作树里的 .git 是个文件，指向主仓库的 .git/worktrees/…），读 config 里 origin 的 url
    private static func originURL(_ cwd: String) -> String? {
        var dir = cwd
        for _ in 0..<8 {
            let g = dir + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: g, isDirectory: &isDir) {
                var cfg = g + "/config"
                if !isDir.boolValue, let t = try? String(contentsOfFile: g, encoding: .utf8),
                   let r = t.range(of: "gitdir: ") {
                    let gitdir = t[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    cfg = (gitdir.components(separatedBy: "/worktrees/").first ?? gitdir) + "/config"
                }
                guard let text = try? String(contentsOfFile: cfg, encoding: .utf8) else { return nil }
                var inOrigin = false
                for raw in text.components(separatedBy: "\n") {
                    let l = raw.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("[") { inOrigin = l == "[remote \"origin\"]"; continue }
                    if inOrigin, l.hasPrefix("url"), let eq = l.firstIndex(of: "=") {
                        return l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                return nil
            }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir || up.isEmpty { break }
            dir = up
        }
        return nil
    }
}

// ---------- 小工具 ----------
private func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
/// 文件最后 n 个字节（从下一个整行开始）
private func tail(_ path: String, _ n: Int) -> String {
    guard let h = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let from = size > UInt64(n) ? size - UInt64(n) : 0
    try? h.seek(toOffset: from)
    var d = (try? h.readToEnd()) ?? Data()
    if from > 0, let nl = d.firstIndex(of: UInt8(ascii: "\n")) { d = d[d.index(after: nl)...] }
    return String(decoding: d, as: UTF8.self)
}
/// 一行记录自己的时间：第一个 "timestamp"（Codex 放在最前面；Claude Code 放在消息正文后面，正文里的引号都转义了，不会先碰到）
private func stamp(_ line: Substring) -> Date? {
    guard let r = line.range(of: "\"timestamp\":\"") else { return nil }
    return parseISO(String(line[r.upperBound...].prefix { $0 != "\"" }))
}
