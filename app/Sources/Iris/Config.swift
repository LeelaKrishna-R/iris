import Foundation

/// Who she answers to and who she speaks for: your settings, never assumed.
///   defaults write app.iris.companion wakeWords -array iris          (the names that wake her; default "iris")
///   defaults write app.iris.companion agentName "Claude"             (the agent she speaks for; default "your agent")
///   defaults write app.iris.companion port -int 7791                 (her local link's port)
///   defaults write app.iris.companion dataDir "~/iris-test"          (where she keeps her files)
enum Config {
    private static let d = UserDefaults(suiteName: "app.iris.companion") ?? .standard

    /// Lowercased words that wake her when said first or after a greeting ("Iris, …", "Hey Iris").
    static var wakeWords: [String] {
        let w = (d.stringArray(forKey: "wakeWords") ?? ["iris"]).map { $0.lowercased() }.filter { !$0.isEmpty }
        return w.isEmpty ? ["iris"] : w
    }

    /// The port her local link listens on (127.0.0.1 only); 7791 unless set.
    static var port: UInt16 {
        let p = d.integer(forKey: "port")
        return (1024...65535).contains(p) ? UInt16(p) : 7791
    }

    /// Where she keeps her files, when not ~/Library/Application Support/Iris (e.g. a second copy for testing).
    static var dataDir: URL? {
        guard let p = d.string(forKey: "dataDir"), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The agent her words come from, as she names it in her menu and her reasons ("your agent" until set).
    static var agentName: String {
        let n = (d.string(forKey: "agentName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "your agent" : n
    }
}
