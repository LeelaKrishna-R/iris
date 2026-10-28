import Foundation

/// Where Iris keeps what she learns and sees: ~/Library/Application Support/Iris (or Config.dataDir).
/// Agents run as the same macOS user, so they read the link key from here; nobody else can (0600).
enum Store {
    static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = Config.dataDir ?? base.appendingPathComponent("Iris", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let tmp = url(name + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url(name), withItemAt: tmp)
        } catch {
            try? data.write(to: url(name), options: .atomic)
        }
    }

    /// One JSON object per line, rotated at `cap` bytes (the old file kept as .1).
    static func append(_ object: [String: Any], to name: String, cap: Int = 20_000_000) {
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let u = url(name)
        if let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int, size > cap {
            let old = url(name + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: u, to: old)
        }
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line + Data([0x0A]))
    }
}

/// when his "stop watching" / "stop listening" ends (seconds since 1970; 0 = on), kept across her restarts.
struct OffUntil: Codable { let at: Double }

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
