import Foundation

/// Who she answers to and who she speaks for: your settings, never assumed.
///   defaults write app.iris.companion wakeWords -array iris          (the names that wake her; default "iris")
///   defaults write app.iris.companion agentName "Claude"             (the agent she speaks for; default "your agent")
enum Config {
    private static let d = UserDefaults(suiteName: "app.iris.companion") ?? .standard

    /// Lowercased words that wake her when said first or after a greeting ("Iris, …", "Hey Iris").
    static var wakeWords: [String] {
        let w = (d.stringArray(forKey: "wakeWords") ?? ["iris"]).map { $0.lowercased() }.filter { !$0.isEmpty }
        return w.isEmpty ? ["iris"] : w
    }

    /// The agent her words come from, as she names it in her menu and her reasons ("your agent" until set).
    static var agentName: String {
        let n = (d.string(forKey: "agentName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "your agent" : n
    }
}
