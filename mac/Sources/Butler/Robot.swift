// 通过 USB 线和机器人打交道：找串口、握手、写 WiFi 和口令、装固件、备份出厂固件。
import Foundation
import Darwin

final class SerialPort {
    private var fd: Int32 = -1
    let path: String
    init(path: String) { self.path = path }

    func open() -> Bool {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { return false }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        // 和 pyserial 一样把 DTR、RTS 都拉起：这样打开串口不会让机器人复位
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIS, &bits)
        return true
    }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }

    func write(_ s: String) {
        let d = Array(s.utf8)
        _ = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) }
    }
    func readAvailable() -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        var out = Data()
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
    /// 发一行命令，等到出现 expect 开头的行（或超时），返回那一行
    func command(_ line: String, expect: [String], timeout: Double = 2) -> String? {
        _ = readAvailable()
        write("\n" + line + "\n")
        let deadline = Date().addingTimeInterval(timeout)
        var acc = ""
        while Date() < deadline {
            acc += readAvailable()
            for l in acc.components(separatedBy: "\n") {
                let x = l.trimmingCharacters(in: .whitespacesAndNewlines)
                if expect.contains(where: { x.hasPrefix($0) }) { return x }
            }
            usleep(50_000)
        }
        return nil
    }
    func waitLine(_ prefixes: [String], timeout: Double) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var acc = ""
        while Date() < deadline {
            acc += readAvailable()
            for l in acc.components(separatedBy: "\n") {
                let x = l.trimmingCharacters(in: .whitespacesAndNewlines)
                if prefixes.contains(where: { x.hasPrefix($0) }) { return x }
            }
            usleep(100_000)
        }
        return nil
    }
}

struct RobotHello { var port: String; var fw: String; var configured: Bool; var mac: String }

enum Robot {
    /// 插着的 USB 串口（ESP32-S3 自带的 USB 口叫 usbmodem）
    static func ports() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    /// 问一下插着的是不是装了小管家固件的机器人
    static func hello(_ port: String) -> RobotHello? {
        let sp = SerialPort(path: port)
        guard sp.open() else { return nil }
        defer { sp.close() }
        for _ in 0..<3 {
            if let l = sp.command("hello", expect: ["HELLO aihelper"], timeout: 1.5) {
                var kv: [String: String] = [:]
                for part in l.split(separator: " ") { let p = part.split(separator: "=", maxSplits: 1); if p.count == 2 { kv[String(p[0])] = String(p[1]) } }
                return RobotHello(port: port, fw: kv["fw"] ?? "", configured: kv["configured"] == "1", mac: kv["mac"] ?? "")
            }
        }
        return nil
    }

    static func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }

    enum LinkResult { case ok(String), wifiFailed, noResponse }

    /// 把 WiFi（可选）和小管家的口令、位置写进机器人
    static func provision(port: String, ssid: String?, password: String, settings: AppSettings) -> LinkResult {
        let sp = SerialPort(path: port)
        guard sp.open() else { return .noResponse }
        defer { sp.close() }
        guard sp.command("hello", expect: ["HELLO"], timeout: 2) != nil else { return .noResponse }
        if let ssid, !ssid.isEmpty {
            let cmd = password.isEmpty ? "cfg wifi \(hex(ssid))" : "cfg wifi \(hex(ssid)) \(hex(password))"
            guard sp.command(cmd, expect: ["OK", "ERR"], timeout: 2) == "OK" else { return .noResponse }
        }
        let host = (ProcessInfo.processInfo.hostName.hasSuffix(".local") ? ProcessInfo.processInfo.hostName : localHostName() + ".local")
        guard sp.command("cfg link \(settings.token) \(settings.macId) \(hex(host)) \(settings.port)", expect: ["OK", "ERR"], timeout: 2) == "OK" else { return .noResponse }
        guard sp.command("cfg save", expect: ["OK", "ERR"], timeout: 3) == "OK" else { return .noResponse }
        if ssid == nil || ssid!.isEmpty { return .ok("") }
        if let l = sp.waitLine(["WIFI ok", "WIFI fail"], timeout: 25) {
            return l.hasPrefix("WIFI ok") ? .ok(String(l.dropFirst(8))) : .wifiFailed
        }
        return .wifiFailed
    }

    /// 机器人现在连着哪个 WiFi（用来判断要不要重新配）
    static func info(_ port: String) -> [String: String] {
        let sp = SerialPort(path: port)
        guard sp.open() else { return [:] }
        defer { sp.close() }
        guard let l = sp.command("info", expect: ["INFO"], timeout: 2) else { return [:] }
        var kv: [String: String] = [:]
        for part in l.split(separator: " ") { let p = part.split(separator: "=", maxSplits: 1); if p.count == 2 { kv[String(p[0])] = String(p[1]) } }
        return kv
    }

    static func localHostName() -> String {
        let r = Shell.run("/usr/sbin/scutil", ["--get", "LocalHostName"], timeout: 5)
        return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ---------- 装固件（打包在应用里的 esptool） ----------
final class Flasher: @unchecked Sendable {
    static var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }
    static var esptool: String {
        #if arch(arm64)
        resources.appendingPathComponent("esptool/esptool-arm64").path
        #else
        resources.appendingPathComponent("esptool/esptool-x86_64").path
        #endif
    }
    static var firmwareDir: URL { resources.appendingPathComponent("firmware") }
    static var bundledVersion: String {
        (try? String(contentsOf: firmwareDir.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: esptool) && FileManager.default.fileExists(atPath: firmwareDir.appendingPathComponent("firmware.bin").path) }

    private var proc: Process?

    /// 运行 esptool，边跑边回报百分比
    private func run(_ args: [String], progress: @escaping (Double) -> Void) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Flasher.esptool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var all = ""
        let re = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s?%"#)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            all += s
            let ns = s as NSString
            if let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last, let v = Double(ns.substring(with: m.range(at: 1))) {
                progress(min(100, v) / 100)
            }
        }
        do { try p.run() } catch { return (false, error.localizedDescription) }
        proc = p
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return (p.terminationStatus == 0, all)
    }

    func backup(port: String, to url: URL, progress: @escaping (Double) -> Void) -> (Bool, String) {
        run(["--chip", "esp32s3", "--port", port, "--baud", "921600", "read-flash", "0", "0x1000000", url.path], progress: progress)
    }

    /// 只写引导程序、分区表和应用，不动 NVS（机器人里存的 WiFi 和口令）
    func install(port: String, progress: @escaping (Double) -> Void) -> (Bool, String) {
        let d = Flasher.firmwareDir
        return run(["--chip", "esp32s3", "--port", port, "--baud", "921600", "write-flash",
                    "0x0", d.appendingPathComponent("bootloader.bin").path,
                    "0x8000", d.appendingPathComponent("partitions.bin").path,
                    "0xe000", d.appendingPathComponent("boot_app0.bin").path,
                    "0x10000", d.appendingPathComponent("firmware.bin").path], progress: progress)
    }

    func restore(port: String, from url: URL, progress: @escaping (Double) -> Void) -> (Bool, String) {
        run(["--chip", "esp32s3", "--port", port, "--baud", "921600", "write-flash", "0x0", url.path], progress: progress)
    }

    func cancel() { proc?.terminate() }
}

// ---------- 这台 Mac 上缺什么 ----------
enum Env {
    static var codexbarCLI: String? { Engine.codexbarPath() }

    static let peonDir = NSString(string: "~/.claude/hooks/peon-ping").expandingTildeInPath
    static var peonInstalled: Bool { FileManager.default.fileExists(atPath: peonDir + "/peon.sh") }
    static var peonConfigPath: String { peonDir + "/config.json" }

    static func peonPointsHere(port: Int) -> Bool {
        guard let d = FileManager.default.contents(atPath: peonConfigPath),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let m = j["mobile_notify"] as? [String: Any] else { return false }
        let server = m["server"] as? String ?? ""
        return (m["enabled"] as? Bool ?? false) && server.contains("127.0.0.1:\(port)") && (m["service"] as? String) == "ntfy"
    }

    /// 让 peon-ping 把「等你回复」推给小管家（改之前备份）
    static func pointPeonHere(port: Int) -> Bool {
        let p = peonConfigPath
        guard let d = FileManager.default.contents(atPath: p),
              var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        let bak = p + ".bak-" + DateFormatter.cached("yyyyMMdd-HHmmss").string(from: Date())
        try? d.write(to: URL(fileURLWithPath: bak))
        var m = j["mobile_notify"] as? [String: Any] ?? [:]
        m["enabled"] = true
        m["service"] = "ntfy"
        m["topic"] = (m["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "aihelper"
        m["server"] = "http://127.0.0.1:\(port)/ntfy"
        j["mobile_notify"] = m
        j["volume"] = 0.0                 // 提示音交给机器人来出
        j["desktop_notifications"] = false
        j["notification_title_ide"] = true
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: p), options: .atomic)) != nil
    }

    /// Claude 的额度要读 Claude 桌面版的登录信息，会弹出钥匙串授权
    static func authorizeClaude(done: @escaping (Bool) -> Void) {
        guard let cli = codexbarCLI else { done(false); return }
        DispatchQueue.global().async {
            let r = Shell.run(cli, ["cookie", "refresh", "--provider", "claude", "--allow-keychain-prompt"], timeout: 120, cwd: "/tmp")
            done(r.status == 0 || String(decoding: r.stdout + r.stderr, as: UTF8.self).contains("refreshed"))
        }
    }
}
