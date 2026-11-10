// 一个很小的 HTTP 服务（Network.framework），并用 Bonjour 公布 _aihelper._tcp，机器人靠它找到这台 Mac。
import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]     // 小写键
    var body: Data
    var remoteIP: String
    var isLocal: Bool { remoteIP == "127.0.0.1" || remoteIP == "::1" || remoteIP.hasPrefix("::ffff:127.") }
}
struct HTTPResponse {
    var status: Int = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8))
    }
}

final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "butler.http", attributes: .concurrent)
    var handler: (HTTPRequest) -> HTTPResponse = { _ in .json(["error": "not ready"], status: 503) }
    private(set) var error: String = ""
    private(set) var running = false
    var onState: () -> Void = {}

    func start(port: Int, macId: String, name: String) {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            var txt = NWTXTRecord()
            txt["v"] = "2"
            txt["id"] = macId
            l.service = NWListener.Service(name: name, type: "_aihelper._tcp", domain: nil, txtRecord: txt)
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready: self.running = true; self.error = ""; log("小管家已启动，端口", port)
                case .failed(let e):
                    self.running = false
                    self.error = "\(e)"
                    log("端口", port, "启动失败：", e)
                    if case .posix(let code) = e, code == .EADDRINUSE { self.error = "EADDRINUSE" }
                    // 端口被占着（比如旧版还没退干净）：过 5 秒再试
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, !self.running else { return }
                        self.start(port: port, macId: macId, name: name)
                    }
                default: break
                }
                self.onState()
            }
            l.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let ep): log("Bonjour 已公布：", ep)
                case .remove(let ep): log("Bonjour 已撤下：", ep)
                @unknown default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            self.error = "\(error)"
            onState()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf, c) {
                let resp = self.handler(req)
                self.send(c, resp)
                return
            }
            if done || err != nil || buf.count > 2_000_000 { c.cancel(); return }
            self.receive(c, buffer: buf)
        }
    }

    private func parse(_ buf: Data, _ c: NWConnection) -> HTTPRequest? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<headEnd.lowerBound], encoding: .utf8) ?? String(data: buf[..<headEnd.lowerBound], encoding: .isoLatin1) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buf.count - bodyStart >= len else { return nil }
        let target = String(first[1])
        var comps = URLComponents(string: target) ?? URLComponents()
        if comps.path.isEmpty { comps.path = target }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        var ip = ""
        if case .hostPort(let host, _) = c.endpoint {
            switch host {
            case .ipv4(let a): ip = "\(a)"
            case .ipv6(let a): ip = "\(a)"
            case .name(let n, _): ip = n
            @unknown default: ip = ""
            }
        }
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        return HTTPRequest(method: String(first[0]), path: comps.path, query: q, headers: headers,
                           body: buf.subdata(in: bodyStart..<(bodyStart + len)), remoteIP: ip)
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found", 503: "Service Unavailable"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        if r.status == 0 { head = "" }
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
