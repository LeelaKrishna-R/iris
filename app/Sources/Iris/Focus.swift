import AppKit
import ApplicationServices

/// Where his attention is on screen right now: the text field he's typing in
/// and, when the app tells us, the caret itself. Cocoa global coordinates
/// (bottom-left origin). Read through Accessibility; Electron apps (VS Code,
/// Discord, Slack) only expose their fields once asked (AXManualAccessibility).
enum Focus {
    struct Seen { var field: CGRect?; var caret: CGRect?; var app: String; var role: String }

    private static var asked = Set<pid_t>()

    static func now() -> Seen? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if !asked.contains(app.processIdentifier) {
            asked.insert(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &el) == .success,
              let e = el else { return Seen(field: nil, caret: nil, app: app.localizedName ?? "", role: "") }
        let ax = e as! AXUIElement
        var roleV: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleV)
        let field = frame(of: ax)
        var caret: CGRect?
        var rng: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXSelectedTextRangeAttribute as CFString, &rng) == .success, let rng {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(ax, kAXBoundsForRangeParameterizedAttribute as CFString, rng, &b) == .success,
               let b {
                var r = CGRect.zero
                if AXValueGetValue(b as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0, r.height < 200 {
                    caret = flip(r)
                }
            }
        }
        return Seen(field: field, caret: caret, app: app.localizedName ?? "", role: roleV as? String ?? "")
    }

    /// Where his keys go (Claude's output in his VS Code counted as his because he had just
    /// typed, into Claude's message box): "terminal" (a shell: what follows is his command's
    /// output), "editor" (code: what follows is his own), "chat" (a message box: he is asking
    /// someone else, and the answer is theirs), "other" (any other field), "unknown" (Accessibility
    /// could not say). `why` names what decided it. `appName` reads that app instead of the front one.
    static func into(appName: String? = nil) -> (kind: String, why: String) {
        guard AXIsProcessTrusted() else { return ("unknown", "no accessibility") }
        let app = appName.flatMap { n in NSWorkspace.shared.runningApplications.first { $0.localizedName == n } }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return ("unknown", "no app") }
        let bundle = app.bundleIdentifier ?? ""
        if terminals.contains(bundle) { return ("terminal", "terminal app \(bundle)") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var el: CFTypeRef?
        var chain: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &el) == .success, let e = el {
            var cur: AXUIElement? = (e as! AXUIElement)
            while let c = cur, chain.count < 14 {
                chain.append(c)
                var p: CFTypeRef?
                cur = AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &p) == .success ? (p as! AXUIElement?) : nil
            }
        } else {
            // VS Code (1.142) answers no focused element while the keys go to a panel's web view
            // (Claude Code's message box, measured); the field itself still says it is focused
            chain = focusedInWindow(axApp)
        }
        guard let field = chain.first else { return ("unknown", "no focused element") }
        let classes = strings(field, "AXDOMClassList")
        if classes.contains("xterm-helper-textarea") { return ("terminal", "xterm.js terminal") }
        // a message box: its own name says so (Discord 'Message #channel', Claude Code 'Message input',
        // Messages 'Message'), or it sits in a chat (Discord chat_…, Claude Code chatContainer_…,
        // Messages MessageEntryView); Monaco editors inside a chat are its diffs, not his code
        let desc = (string(field, "AXDescription") ?? "").lowercased()
        if desc.hasPrefix("message") { return ("chat", "a field named '\(desc.prefix(40))'") }
        for (i, c) in chain.enumerated() {
            for n in strings(c, "AXDOMClassList") + [string(c, "AXIdentifier") ?? ""] {
                let l = n.lowercased()
                if l.contains("chat") || l.contains("message") { return ("chat", "inside \(n) (\(i) up)") }
            }
        }
        if !classes.isDisjoint(with: ["inputarea", "native-edit-context", "cm-content", "ace_text-input"])
            || string(field, "AXRoleDescription") == "editor" {
            return ("editor", "code editor field \(classes.sorted().joined(separator: " "))")
        }
        let role = string(field, "AXRole") ?? ""
        if role == "AXTextArea" && (codeEditors.contains(bundle) || bundle.hasPrefix("com.jetbrains.")) {
            return ("editor", "code editor app \(bundle)")
        }
        return ("other", "\(role) in \(app.localizedName ?? bundle)")
    }

    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                                 "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
                                                 "com.github.wez.wezterm"]
    private static let codeEditors: Set<String> = ["com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
                                                   "dev.zed.Zed", "com.panic.Nova", "com.barebones.bbedit",
                                                   "com.macromates.TextMate"]

    /// The focused field in the app's focused window, found by looking (depth first, at most
    /// 8,000 elements or 1.5 s), with its ancestors: the field first.
    private static func focusedInWindow(_ axApp: AXUIElement) -> [AXUIElement] {
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &w) == .success, let w else { return [] }
        let start = Date()
        var stack: [[AXUIElement]] = [[w as! AXUIElement]]
        var seen = 0
        while let path = stack.popLast(), seen < 8000, Date().timeIntervalSince(start) < 1.5 {
            seen += 1
            let e = path.last!
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXFocusedAttribute as CFString, &f) == .success, (f as? Bool) == true,
               ["AXTextArea", "AXTextField", "AXComboBox"].contains(string(e, "AXRole") ?? "") {
                return path.reversed()
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let ks = kids as? [AXUIElement] {
                for k in ks.reversed() { stack.append(path + [k]) }
            }
        }
        return []
    }

    private static func string(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String : nil
    }

    private static func strings(_ e: AXUIElement, _ a: String) -> Set<String> {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? Set(v as? [String] ?? []) : []
    }

    private static func frame(of ax: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &pv)
        AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &sv)
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv, let sv, AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s),
              s.width > 4, s.height > 4 else { return nil }
        return flip(CGRect(origin: p, size: s))
    }

    /// Accessibility's top-left coordinates to Cocoa's bottom-left.
    private static func flip(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.minY - r.height, width: r.width, height: r.height)
    }
}
