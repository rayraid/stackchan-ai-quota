// 设置：存在 ~/Library/Application Support/StackChan Butler/settings.json
// 缺的项用默认值（老版本的设置文件也能直接读）。
import Foundation
import Security

struct AppSettings: Codable, Equatable {
    // 通用
    var launchAtLogin = true
    var menuBarMode = 0              // 0 小机器人 + 最紧张的额度  1 只显示小机器人  2 小机器人 + 在等你的数量
    var language = "auto"            // auto / zh / ja / en
    var autoUpdateCheck = true
    var askBeforeUpdate = true

    // 屏幕
    var homeStyle = "B"              // 平时首页：A 轻底栏 / B 眼睛就是额度 / C 说给你听 / D 只有脸
    var listStyle = "A"              // 全部额度页：A 两列小卡片 / B 一行一家 / C 竖条对比
    var detailStyle = "A"            // 明细页：A 大圆环（周期最短的那个）+ 旁边几行 / B 统一横条
    var theme = "night"              // night / black / warm / light
    var brightness = 70
    var pinned: [String] = ["claude", "codex"]
    var autoThird = true             // 第 3 格自动放最紧张的一家
    var windowPref = "auto"          // 额度显示逻辑（没在 subWindow 里单独选的家都用它）：
                                     //   auto 最紧张的那个，但不算「只限某个模型」的额度（比如 Claude 的 Fable 本周）
                                     //   tightest 最紧张的那个，所有额度都算  week 尽量显示每周  5h 尽量显示 5 小时
    var subWindow: [String: String] = [:]   // 每家显示哪个额度：订阅 id → 时间段的 key（QuotaWindow.key）
    var showUsed = false
    var clock = false
    var dimAfter = 30                // 分钟，0 = 从不

    // 表情
    var eye = "capsule"              // capsule / round / bar
    var eyeColor = ""                // 空 = 跟随配色
    var blink = true
    var look = true
    var sleepyNight = true
    var robotName = "StackChan"

    // 提醒
    var disabledAgents: [String] = []
    var kindApproval = true
    var kindQuestion = true
    var kindDone = true
    var alertLevel = 1               // 0 轻 1 中 2 强
    var alertSecs = 10               // 提醒画面停多久（秒），0 = 一直到你回去；停完回到平时的脸，彩灯继续亮
    var alertStyle = "now"           // 提醒画面：now 整屏变色（经典）/ B 柔和变色 / C 脸 + 底部卡片
    var doneFlash = true             // 「做完了」整屏提醒完就熄灯，不留 logo；false 时按 doneTTL
    var remind = 0                   // 分钟，0 = 不再提醒
    var doneTTL = 10                 // 「做完了」多久后熄灯（分钟），0 = 等你回去
    var waitingTTL = 120             // 「要你批准」最多等多久（分钟），0 = 直到处理
    var midPercent = 40
    var lowPercent = 15
    var shakeLow = true
    var notifyRestored = false

    // 动作与声音
    var motion = true
    var nod = 1
    var pitch = 12
    var wander = false
    var sound = true
    var volume = 60
    var tone = 1
    var led = true
    var ledBright = 50
    var ledIdle = "#3ddc84"
    var ledIdleOn = true             // 平时也亮着：关掉后没事时灯是灭的，有 AI 等你、额度快用完时照样亮
    var ledAttn = "#ffb020"
    var touch = 0                    // 平时摸头：0 开心一下  1 切换页面  2 什么都不做（提醒那几秒里摸头总是提前收起）

    // 勿扰
    var quietOn = true
    var quietStart = "23:00"
    var quietEnd = "08:00"
    var weekend = 0                  // 0 和平时一样  1 周末全天勿扰  2 周末不勿扰
    var qStill = true
    var qMute = true
    var qDark = true
    var qBright = 10
    var qFace = true
    var restWhenLocked = true
    var dndUntil: Date? = nil        // 手动勿扰到什么时候（很远的将来 = 直到你关掉）
    var quietSkipUntil: Date? = nil  // 定时勿扰时段里在面板上关掉了勿扰：到这个时间之前不算勿扰时段

    // 订阅与数据
    var cliInterval = 300
    var staleMinutes = 20
    var subOrder: [String] = []
    var subHidden: [String] = []
    var subMono: [String: String] = [:]
    var subHue: [String: String] = [:]
    var subMid: [String: Int] = [:]  // 某一家单独的黄线（没有 = 跟随总设置）
    var subLow: [String: Int] = [:]  // 某一家单独的红线
    var singleWins: [String] = []    // 只有一家时，首页每一格放它的哪个时间段（QuotaWindow.key；空 = 自动）
    var showIcons = true             // 有图标时，机器人和菜单栏用图标代替字母

    // 连接
    var port = 8787
    var token = ""
    var macId = ""
    var setupDone = false
    var rev = 1                      // 设置每改一次加 1，机器人据此判断要不要重新应用
    var migrated = 0                 // 设置迁移到第几版（见 SettingsFile.load）
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StackChan Butler")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var backups: URL {
        let u = support.appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var log: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StackChan Butler.log")
        return u
    }
}

func randomToken(_ bytes: Int = 18) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

enum SettingsFile {
    static func load() -> AppSettings {
        var s = AppSettings()
        if let data = try? Data(contentsOf: Paths.settings),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defData = try? JSONEncoder.iso.encode(s),
           var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] {
            for (k, v) in saved where merged[k] != nil || k == "dndUntil" || k == "quietSkipUntil" { merged[k] = v }
            if let md = try? JSONSerialization.data(withJSONObject: merged),
               let decoded = try? JSONDecoder.iso.decode(AppSettings.self, from: md) {
                s = decoded
            }
        }
        if s.migrated < 22 {             // 2.2：提醒画面默认停 10 秒（原来默认 5 秒的跟着改）
            if s.alertSecs == 5 { s.alertSecs = 10 }
            s.migrated = 22
        }
        if s.migrated < 23 {             // 2.3：「平时的颜色」里那个没写字的「关」改成单独的「平时也亮着」开关
            if s.ledIdle.isEmpty { s.ledIdleOn = false; s.ledIdle = "#3ddc84" }
            s.migrated = 23
        }
        if s.token.isEmpty { s.token = randomToken() }
        if s.macId.isEmpty { s.macId = randomToken(6).lowercased() }
        return s
    }

    static func save(_ s: AppSettings) {
        if let d = try? JSONEncoder.pretty.encode(s) { try? d.write(to: Paths.settings, options: .atomic) }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let pretty: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

func log(_ items: Any...) {
    let line = DateFormatter.cached("yyyy-MM-dd HH:mm:ss").string(from: Date()) + " " + items.map { "\($0)" }.joined(separator: " ") + "\n"
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: Paths.log)
    }
}
