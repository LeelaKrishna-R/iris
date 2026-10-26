import AppKit

/// Her first launch: who she is, what each macOS permission is for, and a way to each System Settings pane,
/// before macOS asks on its own. Shown once; "Iris → Welcome" in her menu shows it again.
enum Welcome {
    private static let key = "welcomed"

    static func showIfFirstRun() {
        let d = UserDefaults(suiteName: "app.iris.companion") ?? .standard
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        show()
    }

    static func show() {
        let a = NSAlert()
        a.messageText = "Hi, I'm Iris."
        a.informativeText = """
        I live on your screen. Connect me to an AI agent (Claude Code, Codex, Cursor, or your own) and I'll \
        speak for it and react to its work. Each permission is optional:

        • Screen Recording: so I can react to what's on your screens.
        • Microphone and Speech Recognition: so you can say "Iris, …" and your agent can answer out loud.
        • Accessibility: so I know where your typing goes.

        Agents never get to click or type through me.
        """
        a.addButton(withTitle: "Open Screen Recording")
        a.addButton(withTitle: "Open Microphone")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: open("Privacy_ScreenCapture")
        case .alertSecondButtonReturn: open("Privacy_Microphone")
        default: break
        }
    }

    private static func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}
