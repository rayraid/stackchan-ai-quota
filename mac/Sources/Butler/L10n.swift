// 三种语言：中文（源文字）、日文、英文
// 界面上的文字都用 t("中文") 包起来，日文和英文在 Strings.swift 的两张表里。
import Foundation

enum Lang: String, CaseIterable {
    case zh, ja, en

    static func resolve(_ setting: String) -> Lang {
        if let l = Lang(rawValue: setting) { return l }
        for p in Locale.preferredLanguages {
            if p.hasPrefix("zh") { return .zh }
            if p.hasPrefix("ja") { return .ja }
            if p.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// 当前界面语言（设置里改了以后，界面整体刷新）
nonisolated(unsafe) var currentLang: Lang = .zh

func t(_ zh: String) -> String {
    switch currentLang {
    case .zh: return zh
    case .ja: return JA[zh] ?? EN[zh] ?? zh
    case .en: return EN[zh] ?? zh
    }
}

/// 带参数的文字：t("还有 %d 个", 3)
func t(_ zh: String, _ args: CVarArg...) -> String {
    String(format: t(zh), arguments: args)
}

// ---------- 小管家生成、发给机器人的文字 ----------

enum Gen {
    static func windowLabel(_ minutes: Int?, _ l: Lang) -> String {
        guard let m = minutes, m > 0 else { return "" }
        switch l {
        case .zh:
            if m == 300 { return "5小时" }; if m == 1440 { return "今天" }; if m == 10080 { return "本周" }
            if (40000...45000).contains(m) { return "本月" }
            return m < 1440 ? "\(Int((Double(m) / 60).rounded()))小时" : "\(Int((Double(m) / 1440).rounded()))天"
        case .ja:
            if m == 300 { return "5時間" }; if m == 1440 { return "今日" }; if m == 10080 { return "今週" }
            if (40000...45000).contains(m) { return "今月" }
            return m < 1440 ? "\(Int((Double(m) / 60).rounded()))時間" : "\(Int((Double(m) / 1440).rounded()))日"
        case .en:
            if m == 300 { return "5h" }; if m == 1440 { return "Today" }; if m == 10080 { return "Week" }
            if (40000...45000).contains(m) { return "Month" }
            return m < 1440 ? "\(Int((Double(m) / 60).rounded()))h" : "\(Int((Double(m) / 1440).rounded()))d"
        }
    }

    /// 什么时候恢复 / 重置：今天 17:30 恢复、明天、周四、12月1日
    static func resetText(_ date: Date?, minutes: Int?, _ l: Lang, now: Date = Date()) -> String {
        guard let d = date, d > now else { return "" }
        let cal = Calendar.current
        let short = (minutes ?? 0) > 0 && (minutes ?? 0) <= 1440
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        let hm = DateFormatter.cached("HH:mm").string(from: d)
        let wd = cal.component(.weekday, from: d)   // 1 = 周日
        let month = cal.component(.month, from: d), day = cal.component(.day, from: d)
        switch l {
        case .zh:
            let verb = short ? "恢复" : "重置"
            let week = ["日", "一", "二", "三", "四", "五", "六"][wd - 1]
            if days == 0 { return "\(hm) \(verb)" }
            if days == 1 { return "明天 \(hm) \(verb)" }
            if days < 7 { return "周\(week)\(verb)" }
            return "\(month)月\(day)日\(verb)"
        case .ja:
            let verb = short ? "回復" : "リセット"
            let week = ["日", "月", "火", "水", "木", "金", "土"][wd - 1]
            if days == 0 { return "\(hm) \(verb)" }
            if days == 1 { return "明日 \(hm) \(verb)" }
            if days < 7 { return "\(week)曜\(verb)" }
            return "\(month)月\(day)日\(verb)"
        case .en:
            let week = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][wd - 1]
            let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]
            if days == 0 { return short ? "back \(hm)" : "resets \(hm)" }
            if days == 1 { return short ? "back tmrw \(hm)" : "resets tmrw" }
            if days < 7 { return "resets \(week)" }
            return "resets \(mon) \(day)"
        }
    }

    /// 照现在的速度多久用完（CodexBar 给的预测）
    static func paceText(etaSeconds: Double?, willLast: Bool, _ l: Lang) -> String {
        guard !willLast, let eta = etaSeconds, eta > 0 else { return "" }
        if eta >= 86400 * 1.5 {
            let n = Int((eta / 86400).rounded())
            return l == .zh ? "照现在的速度 \(n) 天后用完" : l == .ja ? "このペースだと \(n) 日後に上限" : "runs out in ~\(n)d at this pace"
        }
        if eta >= 3600 {
            let n = Int((eta / 3600).rounded())
            return l == .zh ? "照现在的速度 \(n) 小时后用完" : l == .ja ? "このペースだと \(n) 時間後に上限" : "runs out in ~\(n)h at this pace"
        }
        return l == .zh ? "照现在的速度不到 1 小时用完" : l == .ja ? "このペースだと 1 時間以内に上限" : "runs out within 1h at this pace"
    }

    static func kindText(_ kind: String, detail: String, _ l: Lang) -> String {
        switch kind {
        case "done": return l == .zh ? "做完了，等你看结果" : l == .ja ? "完了しました。結果を確認してください" : "Done, waiting for you to check"
        case "approval":
            let base = l == .zh ? "需要你批准" : l == .ja ? "承認が必要です" : "Needs your approval"
            return detail.isEmpty ? base : base + (l == .en ? ": " : "：") + detail
        case "question": return l == .zh ? "有问题要问你" : l == .ja ? "質問があります" : "Has a question for you"
        case "error": return l == .zh ? "出错停下了" : l == .ja ? "エラーで停止しました" : "Stopped on an error"
        case "restored": return l == .zh ? "额度恢复了" : l == .ja ? "使用量が回復しました" : "Quota is back"
        default: return detail.isEmpty ? (l == .zh ? "有新消息" : l == .ja ? "お知らせ" : "New message") : detail
        }
    }

    static func unknownProject(_ l: Lang) -> String { l == .zh ? "未知项目" : l == .ja ? "不明なプロジェクト" : "unknown project" }
    static func cantRead(_ l: Lang) -> String { l == .zh ? "暂时读不到" : l == .ja ? "取得できません" : "can't read now" }
}

extension DateFormatter {
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()
    static func cached(_ format: String) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[format] { return f }
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        cache[format] = f
        return f
    }
}
