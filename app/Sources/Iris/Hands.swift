import AppKit
import ApplicationServices

/// Her hands: the keyboard and mouse, through Accessibility. Friday Core
/// decides what may be typed or clicked (and asks him when it matters);
/// Iris only does it, and says when she can't.
enum Hands {
    static var permitted: Bool { AXIsProcessTrusted() }

    /// Type text as if from the keyboard (any characters, not just ASCII).
    static func type(_ text: String) -> Bool {
        guard permitted else { return false }
        // A private source and no flags: with the HID-state source, a Command left
        // "held" by an earlier combo turned typed letters into shortcuts (10-11:
        // "ZZZ" was cmd+Z, and a space opened Spotlight).
        let src = CGEventSource(stateID: .privateState)
        for chunk in text.chunked(16) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        return true
    }

    /// "cmd+t", "return", "cmd+shift+4", "escape", "down".
    /// The Mac's own play/pause, next and previous keys (10-12: "pause the music",
    /// "skip this song"): whatever app is playing (Music, a browser) takes them,
    /// as it does from the keyboard's media keys.
    static let mediaKeys: [String: Int32] = ["play": 16, "next": 17, "previous": 18]   // NX_KEYTYPE_*

    static func media(_ name: String) -> Bool {
        guard permitted, let key = mediaKeys[name] else { return false }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                              timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                              data1: data1, data2: -1)?.cgEvent else { return false }
            ev.post(tap: .cghidEventTap)
        }
        return true
    }

    static func keys(_ combo: String) -> Bool {
        guard permitted else { return false }
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: code = keyCodes[part]
            }
        }
        guard let k = code else { return false }
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // and let go of the modifiers: the system kept Command "held" after cmd+up
        // until the next plain key (10-11), so what was typed next became shortcuts
        if !flags.isEmpty, let release = CGEvent(source: src) {
            release.type = .flagsChanged
            release.flags = []
            release.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Click at a point in Cocoa global coordinates (bottom-left origin).
    static func click(x: Double, y: Double, right: Bool = false, double: Bool = false) -> Bool {
        guard permitted else { return false }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: x, y: primaryH - y)
        let (dn, upT, btn): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        for n in 1...(double ? 2 : 1) {
            guard let d = CGEvent(mouseEventSource: nil, mouseType: dn, mouseCursorPosition: p, mouseButton: btn),
                  let u = CGEvent(mouseEventSource: nil, mouseType: upT, mouseCursorPosition: p, mouseButton: btn) else { return false }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: seeing what can be clicked (the Accessibility tree, no pictures, no model)

    struct Thing { let el: AXUIElement; let role: String; let name: String; let frame: CGRect; var dialog = false }

    static let clickable: Set<String> = ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXTab", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXCell", "AXRow", "AXStaticText", "AXImage", "AXDisclosureTriangle", "AXIncrementor",
        "AXSlider", "AXSwitch", "AXToolbarButton", "AXDockItem"]

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        // AX is top-left origin on the primary screen; hand back Cocoa (bottom-left)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryH - p.y - s.height, width: s.width, height: s.height)
    }

    private static let subroleNames = ["AXCloseButton": "close", "AXMinimizeButton": "minimize",
        "AXFullScreenButton": "full screen", "AXZoomButton": "zoom"]

    private static func name(_ e: AXUIElement) -> String {
        if let sr = attr(e, kAXSubroleAttribute) as? String, let n = subroleNames[sr] { return n }
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
            if let s = attr(e, a) as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(s.prefix(120))
            }
        }
        if let t = attr(e, kAXTitleUIElementAttribute), CFGetTypeID(t) == AXUIElementGetTypeID() {
            return (attr(t as! AXUIElement, kAXValueAttribute) as? String).map { String($0.prefix(120)) } ?? ""
        }
        return ""
    }

    static func targetApp(_ named: String) -> NSRunningApplication? {
        let me = Bundle.main.bundleIdentifier
        if named.isEmpty { return NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == me ? nil : $0 } }
        let n = named.lowercased()
        return NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased() == n }
            ?? NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased().contains(n) }
    }

    /// What can be clicked in an app's windows (and its menu bar when asked), on screen and named.
    static func see(app named: String = "", menus: Bool = false, limit: Int = 600) -> (String, [Thing])? {
        guard permitted, let app = targetApp(named) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var out: [Thing] = [], text: [Thing] = []
        var seen = 0
        // what sits in a dialog or sheet comes first: Music's welcome sheet ("Not Now")
        // blocked every action while its buttons were listed after 50 others (10-11)
        func walk(_ e: AXUIElement, _ depth: Int, _ inDialog: Bool = false) {
            guard depth < 30, out.count < limit, seen < 6000 else { return }
            seen += 1
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            let dialog = inDialog || role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(sub)
            // a closed menu's items have no place on screen, but Accessibility can still press them
            let f = frame(e).flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
                ?? (menus && role == "AXMenuItem" ? CGRect.zero : nil)
            if clickable.contains(role), let f {
                let n = name(e)
                // plain text and pictures get their own share, so a long transcript can't crowd out the buttons
                if role == "AXStaticText" || role == "AXImage" {
                    if !n.isEmpty && text.count < limit / 3 { text.append(Thing(el: e, role: role, name: n, frame: f, dialog: dialog)) }
                } else if !n.isEmpty || role != "AXCell" && role != "AXRow" {
                    out.append(Thing(el: e, role: role, name: n, frame: f, dialog: dialog))
                }
            }
            if role == "AXMenu" && !menus { return }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1, dialog) }
        }
        for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        if menus, let bar = attr(root, kAXMenuBarAttribute) { walk(bar as! AXUIElement, 0) }
        let all = out + text
        return (app.localizedName ?? "", all.filter { $0.dialog } + all.filter { !$0.dialog })
    }

    /// Press the best-named thing: Accessibility's own press when it has one, else a real click
    /// at its middle. nth picks among equal names (1-based). Returns what was pressed.
    static func press(_ want: String, role: String = "", app: String = "", nth: Int = 1) -> [String: Any] {
        guard permitted else { return ["ok": false, "reason": "accessibility_not_allowed"] }
        if want.contains(">") { return pressMenuPath(want, app: app) }
        let menusToo = role.lowercased().contains("menu")
        guard let (appName, things) = see(app: app, menus: menusToo, limit: 2000) else {
            return ["ok": false, "reason": "no_such_app"]
        }
        let w = want.lowercased().trimmingCharacters(in: .whitespaces)
        let r = role.isEmpty ? "" : (role.hasPrefix("AX") ? role : "AX" + role.prefix(1).uppercased() + role.dropFirst())
        let pool = things.filter { r.isEmpty || $0.role.lowercased() == r.lowercased() }
        func score(_ t: Thing) -> Int {
            let n = t.name.lowercased()
            if n == w { return 3 }
            if n.hasPrefix(w) { return 2 }
            if n.contains(w) { return 1 }
            return 0
        }
        let best = pool.map { ($0, score($0)) }.filter { $0.1 > 0 }
        guard let top = best.map(\.1).max() else {
            return ["ok": false, "reason": "not_found", "app": appName,
                    "nearby": Array(Set(pool.map(\.name).filter { !$0.isEmpty })).sorted().prefix(25).map { $0 }]
        }
        let hits = best.filter { $0.1 == top }.map(\.0)
        guard nth >= 1, nth <= hits.count else {
            return ["ok": false, "reason": "no_nth", "app": appName, "matches": hits.count]
        }
        let t = hits[nth - 1]
        var actions: CFArray?
        AXUIElementCopyActionNames(t.el, &actions)
        let names = (actions as? [String]) ?? []
        var how = "click"
        if names.contains(kAXPressAction) && AXUIElementPerformAction(t.el, kAXPressAction as CFString) == .success {
            how = "press"
        } else if t.role == "AXTextField" || t.role == "AXTextArea" || t.role == "AXSearchField" || t.role == "AXComboBox",
                  AXUIElementSetAttributeValue(t.el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            how = "focus"
        } else {
            _ = click(x: Double(t.frame.midX), y: Double(t.frame.midY))
        }
        return ["ok": true, "app": appName, "pressed": t.name, "role": t.role, "how": how,
                "matches": hits.count, "at": [Double(t.frame.midX), Double(t.frame.midY)]]
    }

    /// "File > Save", "Format > Font > Show Fonts": one menu item by its path,
    /// so a name that is in several menus ("Close") presses the one he meant.
    static func pressMenuPath(_ path: String, app: String = "") -> [String: Any] {
        let parts = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count >= 2, let target = targetApp(app) else { return ["ok": false, "reason": "no_such_app"] }
        // A menu acts only for the app in front: "Music > Quit Music" pressed in the
        // background answered success and did nothing (10-11). Bring it forward first.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                usleep(50_000)
            }
        }
        let root = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        guard let bar = attr(root, kAXMenuBarAttribute) else { return ["ok": false, "reason": "no_menu_bar"] }
        func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func title(_ e: AXUIElement) -> String { ((attr(e, kAXTitleAttribute) as? String) ?? "").lowercased() }
        // one level: the item named `part` among this element's items (through its menu)
        func step(_ e: AXUIElement, _ part: String) -> AXUIElement? {
            var items = kids(e)
            if items.count == 1, (attr(items[0], kAXRoleAttribute) as? String) == "AXMenu" { items = kids(items[0]) }
            return items.first { title($0) == part }
                ?? items.first { title($0).hasPrefix(part) }       // "save" for "Save…"
        }
        var here = bar as! AXUIElement
        var trail: [String] = []
        for part in parts {
            guard let next = step(here, part) else {
                var items = kids(here)
                if items.count == 1, (attr(items[0], kAXRoleAttribute) as? String) == "AXMenu" { items = kids(items[0]) }
                return ["ok": false, "reason": "not_found", "app": target.localizedName ?? "",
                        "found": trail.joined(separator: " > "),
                        "nearby": items.map { (attr($0, kAXTitleAttribute) as? String) ?? "" }.filter { !$0.isEmpty }.prefix(25).map { $0 }]
            }
            here = next
            trail.append((attr(next, kAXTitleAttribute) as? String) ?? part)
        }
        guard AXUIElementPerformAction(here, kAXPressAction as CFString) == .success else {
            return ["ok": false, "reason": "could_not_press", "app": target.localizedName ?? ""]
        }
        return ["ok": true, "app": target.localizedName ?? "", "pressed": trail.joined(separator: " > "),
                "role": "AXMenuItem", "how": "press", "matches": 1, "at": [0.0, 0.0]]
    }

    /// Move the pointer (Cocoa coordinates), scroll (lines; + is up), or drag between two points.
    static func move(x: Double, y: Double) -> Bool {
        guard permitted else { return false }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: primaryH - y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }

    static func scroll(lines: Int32, x: Double? = nil, y: Double? = nil) -> Bool {
        guard permitted else { return false }
        if let x, let y { _ = move(x: x, y: y) }
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        return true
    }

    static func drag(from a: CGPoint, to b: CGPoint) -> Bool {
        guard permitted else { return false }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func q(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryH - p.y) }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: q(a), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: q(p), mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(15_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: q(b), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        return true
    }

    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "forwarddelete": 117, "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
            "\\": 42, "`": 50,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 111,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6),
            ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
            ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (k, v) in letters { m[k] = v }
        return m
    }()
}

extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in self {
            cur.append(ch)
            if cur.utf16.count >= n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
