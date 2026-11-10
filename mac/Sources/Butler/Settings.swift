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
    var theme = "night"              // night / black / warm / light
    var brightness = 70
    var pinned: [String] = ["claude", "codex"]
    var autoThird = true             // 第 3 格自动放最紧张的一家
    var windowPref = "auto"          // auto / 5h / week
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
    var remind = 0                   // 分钟，0 = 不再提醒
    var waitingTTL = 120             // 分钟，0 = 直到处理
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
    var ledAttn = "#ffb020"
    var touch = 0                    // 0 知道了  1 切换页面  2 什么都不做

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
    var dndUntil: Date? = nil

    // 订阅与数据
    var cliInterval = 300
    var staleMinutes = 20
    var subOrder: [String] = []
    var subHidden: [String] = []
    var subMono: [String: String] = [:]
    var subHue: [String: String] = [:]
    var showIcons = true             // 有图标时，机器人和菜单栏用图标代替字母

    // 连接
    var port = 8787
    var token = ""
    var macId = ""
    var setupDone = false
    var rev = 1                      // 设置每改一次加 1，机器人据此判断要不要重新应用
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
            for (k, v) in saved where merged[k] != nil || k == "dndUntil" { merged[k] = v }
            if let md = try? JSONSerialization.data(withJSONObject: merged),
               let decoded = try? JSONDecoder.iso.decode(AppSettings.self, from: md) {
                s = decoded
            }
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
