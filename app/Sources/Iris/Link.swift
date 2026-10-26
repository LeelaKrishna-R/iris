import CryptoKit
import Foundation
import Network

/// The private line between Friday Core and Iris, on this Mac only:
/// 127.0.0.1:7791, every request signed like Core's other Mac helper —
/// HMAC-SHA256 over "<unix ts>.<nonce>.<body>" with a key only this macOS user can
/// read (~/Library/Application Support/Iris/link.key, 0600). No public
/// route, no sign-in, no key leaves the machine.
final class Link {
    static let port: UInt16 = 7791
    typealias Reply = (Int, [String: Any]) -> Void
    typealias Handler = (_ path: String, _ query: [String: String], _ body: [String: Any], _ reply: @escaping Reply) -> Void

    private var listener: NWListener?
    private let key: SymmetricKey
    private let handler: Handler
    private let q = DispatchQueue(label: "iris.link")
    private var seen: [String: Date] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
        key = SymmetricKey(data: Link.loadKey())
    }

    static func loadKey() -> Data {
        let u = Store.url("link.key")
        if let hex = try? String(contentsOf: u, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           hex.count == 64, let d = Data(hex: hex) { return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: u.path, contents: hex.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
        return Data(bytes)
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Link.port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { st in log("link: \(st)") }
        l.start(queue: q)
        listener = l
        Store.save(["port": Int(Link.port)], "link.json")
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let d = data { b.append(d) }
            if b.count > 8 << 20 { self.send(c, 413, ["ok": false, "reason": "too_large"]); return }
            if let req = Request.parse(b) {
                self.handle(c, req)
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, b)
            }
        }
    }

    private func handle(_ c: NWConnection, _ r: Request) {
        guard verify(r) else { send(c, 401, ["ok": false, "reason": "bad_signature"]); return }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        handler(r.path, r.query, body) { [weak self] status, obj in self?.send(c, status, obj) }
    }

    private func verify(_ r: Request) -> Bool {
        // the signature covers time, nonce, method, path and body, so a captured request
        // can't be replayed to another route (core/iris.call sends it as x-iris-sig2)
        guard let ts = r.headers["x-iris-ts"], let nonce = r.headers["x-iris-nonce"], let sig = r.headers["x-iris-sig2"],
              let t = Double(ts), abs(Date().timeIntervalSince1970 - t) < 60, nonce.count >= 16 else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(ts).\(nonce).\(r.method) \(r.path).".utf8) + r.body, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        guard hex.count == sig.count, zip(hex.utf8, sig.lowercased().utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return false }
        // a replay of the same signed request is refused
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        if seen[nonce] != nil { return false }
        seen[nonce] = now
        return true
    }

    private func send(_ c: NWConnection, _ status: Int, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// A complete request from the bytes so far, or nil if more are coming.
    static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.count - bodyStart >= len else { return nil }
        let target = String(first[1])
        var path = target, query: [String: String] = [:]
        if let qi = target.firstIndex(of: "?") {
            path = String(target[..<qi])
            for kv in target[target.index(after: qi)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if p.count == 2 { query[p[0]] = p[1] }
            }
        }
        return Request(method: String(first[0]), path: path, query: query, headers: headers,
                       body: Data(d[bodyStart..<(bodyStart + len)]))
    }
}

extension Data {
    init?(hex: String) {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
