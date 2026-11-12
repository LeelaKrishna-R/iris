import AppKit
import ApplicationServices
import os

/// an Accessibility element that gives up after `timeout` instead of macOS's 6-second default, so an app
/// that doesn't answer (busy, hung, a slow Electron window) can't stall her main thread, where these reads run.
enum AXQuick {
    static let timeout: Float = 0.25

    static func app(_ pid: pid_t) -> AXUIElement { element(AXUIElementCreateApplication(pid)) }

    @discardableResult
    static func element(_ e: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }
}

/// Where his attention is on screen right now: the text field he's typing in
/// and, when the app tells us, the caret itself. Cocoa global coordinates
/// (bottom-left origin). Read through Accessibility; Electron apps (VS Code,
/// Discord, Slack) only expose their fields once asked (AXManualAccessibility).
enum Focus {
    struct Seen { var field: CGRect?; var caret: CGRect?; var app: String; var role: String }

    /// The apps already asked to expose their fields, once each (kept in a lock, so Focus can be read from any thread).
    private static let asked = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static func now() -> Seen? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let axApp = AXQuick.app(app.processIdentifier)
        if asked.withLock({ $0.insert(app.processIdentifier).inserted }) {
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &el) == .success,
              let e = el else { return Seen(field: nil, caret: nil, app: app.localizedName ?? "", role: "") }
        let ax = AXQuick.element(e as! AXUIElement)
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
                if AXValueGetValue(b as! AXValue, .cgRect, &r), caretLooksReal(r) {
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
        let axApp = AXQuick.app(app.processIdentifier)
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
        let nodes = chain.map { Node(classes: strings($0, "AXDOMClassList"), identifier: string($0, "AXIdentifier") ?? "") }
        return kind(bundle: bundle, appName: app.localizedName ?? bundle, chain: nodes,
                    description: string(field, "AXDescription") ?? "", roleDescription: string(field, "AXRoleDescription") ?? "",
                    role: string(field, "AXRole") ?? "")
    }

    /// One element of the focused field's chain, as kind(...) reads it: its DOM classes and its identifier.
    struct Node { var classes: Set<String>; var identifier: String }

    /// Where his keys go, from what Accessibility said of the focused field and its ancestors (the field first)
    /// (pure, tested; into(appName) reads them).
    static func kind(bundle: String, appName: String, chain: [Node], description: String, roleDescription: String,
                     role: String) -> (kind: String, why: String) {
        guard let field = chain.first else { return ("unknown", "no focused element") }
        if terminals.contains(bundle) { return ("terminal", "terminal app \(bundle)") }
        let classes = field.classes
        if classes.contains("xterm-helper-textarea") { return ("terminal", "xterm.js terminal") }
        // a message box: its own name says so (Discord 'Message #channel', Claude Code 'Message input',
        // Messages 'Message'), or it sits in a chat (Discord chat_…, Claude Code chatContainer_…,
        // Messages MessageEntryView); Monaco editors inside a chat are its diffs, not his code
        let desc = description.lowercased()
        if desc.hasPrefix("message") { return ("chat", "a field named '\(desc.prefix(40))'") }
        for (i, c) in chain.enumerated() {
            for n in c.classes + [c.identifier] {
                let l = n.lowercased()
                if l.contains("chat") || l.contains("message") { return ("chat", "inside \(n) (\(i) up)") }
            }
        }
        if !classes.isDisjoint(with: ["inputarea", "native-edit-context", "cm-content", "ace_text-input"])
            || roleDescription == "editor" {
            return ("editor", "code editor field \(classes.sorted().joined(separator: " "))")
        }
        if role == "AXTextArea" && (codeEditors.contains(bundle) || bundle.hasPrefix("com.jetbrains.")) {
            return ("editor", "code editor app \(bundle)")
        }
        return ("other", "\(role) in \(appName)")
    }

    /// A caret's bounds Accessibility gave that are a caret, not a whole line or nothing (pure, tested).
    static func caretLooksReal(_ r: CGRect) -> Bool { r.width >= 0 && r.height > 0 && r.height < 200 }

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
    private static func flip(_ r: CGRect) -> CGRect { flip(r, primaryHeight: NSScreen.screens.first?.frame.height ?? 0) }

    /// The same, for a primary screen `primaryHeight` tall (pure, tested).
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }
}
