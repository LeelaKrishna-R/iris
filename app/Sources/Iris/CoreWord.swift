import Foundation

/// Core's last word on what only Core knows (core/iris_status: her voice, today's spend, her quiet hour), for
/// "How Iris is" (HowIris), and her menu's quiet asks waiting for Core. Core sends /iris/status every 30 s
/// (and at once after an ask); each reply hands it the asks not yet done. Main thread only.
@MainActor          // its own rule (main thread only), said for the compiler
final class CoreWord {
    static let shared = CoreWord()
    private(set) var status: [String: Any]?
    private(set) var at: Date?
    private var asks: [(token: String, what: String, at: Date)] = []
    /// A click waits this long for Core: one made while Core was away isn't done whenever it returns (review).
    static let askForS: Double = 120

    /// Core's post: its status, when it sent one, and the asks it has done (they leave); the reply is what still waits.
    func received(_ body: [String: Any]) -> [String: Any] {
        if let s = body["status"] as? [String: Any] { status = s; at = Date() }
        let done = Set((body["done"] as? [Any] ?? []).compactMap { $0 as? String })
        asks.removeAll { done.contains($0.token) }
        expire()
        return ["ok": true, "asks": asks.map { ["token": $0.token, "do": $0.what] }]
    }

    /// His click: "quiet" (an hour) or "talk" (quiet over), for Core's next look.
    func ask(_ what: String) {
        asks.removeAll { $0.what == "quiet" || $0.what == "talk" }      // the latest click is what he wants
        asks.append((token: UUID().uuidString, what: what, at: Date()))
        log("menu: asked \(Config.agentName) for \(what)")
    }

    private func expire() {
        let before = asks.count
        asks.removeAll { Date().timeIntervalSince($0.at) > CoreWord.askForS }
        if asks.count < before { log("menu: \(Config.agentName) didn't take my ask in \(Int(CoreWord.askForS)) s; it's dropped") }
    }

    var asking: Bool { expire(); return !asks.isEmpty }
}
