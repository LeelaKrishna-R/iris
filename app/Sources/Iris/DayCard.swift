import AppKit

/// A day card beside Iris, filled by your agent: rows it sends to /iris/day (a heading and a line each, a
/// row it couldn't read marked "off" and drawn greyed), with an optional button beside a line ("Done",
/// "Paid"). A click waits under its own token in /iris/day_state until the agent confirms it acted
/// (/iris/day_ack). The card never takes your typing and stays out of screen shares and recordings; x hides
/// it until you pick Show My Day in her menu.
final class DayCard: NSObject {
    static let shared = DayCard()
    /// one line of a row, with the button Core offers beside it ("Done" on a to-do, "Paid" on a bill).
    struct Item { let id: String; let text: String; let act: String }
    struct Row { let key: String; let head: String; let text: String; let off: Bool; let items: [Item] }
    private(set) var rows: [Row] = []
    private var at: Date?
    private var panel: NSPanel?
    private var refresh = false
    /// His clicks on a row's button, each under its own token, kept until Core confirms it acted
    /// (/iris/day_ack): Core takes them on its next look (2 s) and acts once (core/iris_day_card.act_on).
    private var acts: [(token: String, id: String)] = []
    private var buttons: [NSButton: String] = [:]
    private static let hiddenKey = "dayCardHidden"
    var hidden: Bool { UserDefaults.standard.bool(forKey: DayCard.hiddenKey) }

    /// What Core reads every look: whether to rebuild now (his click, read once), whether to bother, and his
    /// button clicks waiting.
    func state() -> [String: Any] {
        defer { refresh = false }
        return ["ok": true, "hidden": hidden, "refresh": refresh, "has": !rows.isEmpty,
                "acts": acts.map { ["token": $0.token, "id": $0.id] }]
    }

    /// Core acted on these clicks; they leave the list.
    func ack(_ tokens: [String]) { acts.removeAll { tokens.contains($0.token) } }

    /// Core's rows, shown beside her (kept, not shown, while he has it hidden).
    func update(rows raw: [[String: Any]], at: Date?, near: CGRect) {
        rows = raw.prefix(8).map { r in
            Row(key: String((r["key"] as? String ?? "").prefix(20)),
                head: String((r["head"] as? String ?? "").prefix(30)),
                text: String((r["text"] as? String ?? "").prefix(300)),
                off: r["off"] as? Bool ?? false,
                items: (r["items"] as? [Any] ?? []).prefix(3).compactMap { $0 as? [String: Any] }.map {
                    Item(id: String(($0["id"] as? String ?? "").prefix(80)),
                         text: String(($0["text"] as? String ?? "").prefix(120)),
                         act: String(($0["act"] as? String ?? "").prefix(12)))
                })
        }
        self.at = at
        if !hidden { show(near: near) } else if peeking { show(near: peekNear) }     // a peek shows the new rows
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let id = buttons[sender], !id.isEmpty else { return }
        if id.hasPrefix("open:") {
            // "Kept for you" (core/iris_day_card.kept): Open is hers to do here, at once, not Core's
            DayCard.open(String(id.dropFirst(5)))
            return
        }
        acts.append((token: UUID().uuidString, id: id))
        sender.isEnabled = false
        sender.title = "…"
        log("day card: \(sender.toolTip ?? "button") clicked")
    }

    /// A row's lines: each item with its button, or Core's text as it came when it sent no items.
    private func lines(_ r: Row, width: CGFloat) -> [NSView] {
        let wrap = { (s: String, w: CGFloat) -> NSTextField in
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .preferredFont(forTextStyle: .body)            // 13 pt by default (was a fixed 12)
            t.textColor = r.off ? .secondaryLabelColor : .labelColor
            t.preferredMaxLayoutWidth = w
            return t
        }
        guard !r.items.isEmpty, !r.off else { return [wrap(r.text, width)] }
        var out: [NSView] = r.items.map { item in
            guard !item.act.isEmpty, !item.id.isEmpty else { return wrap(item.text, width) }
            let b = NSButton(title: item.act, target: self, action: #selector(clicked(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .regular                                // a 22-pt button (an 11-pt inline one was ~16)
            b.toolTip = "\(item.act): \(item.text)"
            b.setAccessibilityLabel("\(item.act): \(item.text)")      // "Check off" alone said nothing of which
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            if acts.contains(where: { $0.id == item.id }) { b.isEnabled = false; b.title = "…" }
            buttons[b] = item.id
            // the text gives up the button's own width ("Check off", "I paid it" are wider than the "Done"
            // and "Paid" the fixed 76 pt was set for)
            let line = NSStackView(views: [wrap(item.text, width - max(76, b.fittingSize.width + 12)), NSView(), b])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 6
            return line
        }
        // Core sends buttons for the first few; "and N more" stays as its text said it
        if let more = r.text.split(separator: "\n").last, more.hasPrefix("and "), more.hasSuffix(" more") {
            out.append(wrap(String(more), width))
        }
        return out
    }

    /// Friday's app on this Mac (FridayMac), on `screen` ("notifications"): its friday:// link, which the app takes to
    /// that screen (NotificationRouting.macScreen). A Friday installed before it took the link opens where he left it,
    /// and that is said in her log.
    static var fridayApp: String { Config.agentApp }

    static func open(_ screen: String) {
        let ws = NSWorkspace.shared
        if let link = URL(string: "friday://\(screen)"), let app = ws.urlForApplication(toOpen: link),
           Bundle(url: app)?.bundleIdentifier == fridayApp {
            ws.open(link)
            log("day card: opened \(Config.agentName)'s \(screen)")
        } else if let app = ws.urlForApplication(withBundleIdentifier: fridayApp) {
            ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            log("day card: opened \(Config.agentName), not its \(screen): this \(Config.agentName) doesn't take friday:// links yet")
        } else {
            log("day card: \(Config.agentName)'s \(screen) not opened: \(Config.agentName) isn't installed on this Mac")
        }
    }

    // MARK: a peek
    // The card had been hidden since (× hid it for good), so a click on her only giggled. A click on her
    // now always peeks: the card beside her until he types, moves his pointer well away, clicks her again, or a
    // minute passes (Stages.peekEnds); it never stays on its own. Pinned (Show My Day), a click moves it beside her.
    private(set) var peeking = false
    private var peekAt = Date.distantPast
    private var peekNear = CGRect.zero
    private var peekWatch: Timer?

    /// He clicked her: a peek at the card (a second click puts it away); pinned, it moves beside her. Core is asked
    /// for fresh rows either way.
    func peek(near: CGRect) {
        refresh = true
        if !hidden {
            if let p = panel { p.setFrameOrigin(place(size: p.frame.size, near: near)) }
            return
        }
        if peeking { unpeek("he clicked her again"); return }
        guard !rows.isEmpty else { log("day card: no rows yet to peek at"); return }
        peeking = true
        peekAt = Date()
        peekNear = near
        show(near: near)
        log("day card: peek")
        peekWatch?.invalidate()
        peekWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchPeek() }           // scheduled on the main run loop
        }
    }

    /// The peek put away, with why in her log; nothing when there is none.
    func unpeek(_ why: String) {
        guard peeking else { return }
        peeking = false
        peekWatch?.invalidate(); peekWatch = nil
        close()
        log("day card: peek over (\(why))")
    }

    /// Four times a second while it's up: his keys since it opened (his hands only: the HID count, as Eyes reads idle; no keys read), and how
    /// far his pointer is outside her and the card.
    private func watchPeek() {
        // his keys inside the card (a keyboard user moving through it) don't put it away; his typing elsewhere does
        let typed = !(panel?.isKeyWindow ?? false)
            && CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < Date().timeIntervalSince(peekAt)
        let p = NSEvent.mouseLocation
        let near = (panel?.frame ?? peekNear).union(peekNear)
        let dx = max(near.minX - p.x, 0, p.x - near.maxX), dy = max(near.minY - p.y, 0, p.y - near.maxY)
        if let why = Stages.peekEnds(shownFor: Date().timeIntervalSince(peekAt), typedSince: typed,
                                     away: Double(hypot(dx, dy))) {
            unpeek(why)
        }
    }

    /// Her one line for his pointer resting on her (Stages.hoverHint), from these rows; nil before there are any.
    func hint() -> String? { Stages.hoverHint(rows: rows.map { (key: $0.key, head: $0.head, text: $0.text, off: $0.off) }) }

    /// Show My Day / Hide My Day, from her menu.
    func toggle(near: CGRect) {
        if peeking { unpeek("pinned from her menu") }
        UserDefaults.standard.set(!hidden, forKey: DayCard.hiddenKey)
        if hidden { close() } else { refresh = true; if !rows.isEmpty { show(near: near) } }
        log("day card: \(hidden ? "hidden" : "shown") from her menu")
    }

    /// ×: a peek closes (a click still peeks again); the pinned card unpins, and a click on her still peeks.
    @objc private func dismissed() {
        if peeking { unpeek("he closed it"); return }
        UserDefaults.standard.set(true, forKey: DayCard.hiddenKey)
        close()
        log("day card: unpinned (a click on her still peeks)")
    }

    private func close() { (panel as? CardPanel)?.giveKeysBack(); panel?.orderOut(nil); panel = nil }

    /// a row's text as Core read it (core/iris_day_card's key: "todos", "next" …); nil when the card has
    /// no such row or Core couldn't read it ("off"). Iris reads the to-dos for one come due (Body.dayCard).
    func text(_ key: String) -> String? { rows.first { $0.key == key && !$0.off }?.text }
    /// Where the card is on his screen, while it's shown.
    var frame: CGRect? { panel?.frame }

    private func show(near: CGRect) {
        let width: CGFloat = 300
        let title = NSTextField(labelWithString: "Your day")
        title.font = .preferredFont(forTextStyle: .headline)
        title.setAccessibilityRole(.staticText)
        let when = NSTextField(labelWithString: at.map { "Updated " + DayCard.clock.string(from: $0) } ?? "")
        when.font = .preferredFont(forTextStyle: .subheadline)
        when.textColor = .secondaryLabelColor                       // tertiary read too faint on the popover
        let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close your day") ?? NSImage(),
                         target: self, action: #selector(dismissed))
        x.isBordered = false
        x.contentTintColor = .secondaryLabelColor
        x.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([x.widthAnchor.constraint(equalToConstant: 24),
                                     x.heightAnchor.constraint(equalToConstant: 24)])   // a 24-pt target, not the glyph
        x.toolTip = peeking ? "Close (a click on Iris shows it again)" : "Unpin (Show My Day in Iris's menu pins it again)"
        let top = NSStackView(views: [title, when, NSView(), x])
        top.orientation = .horizontal
        top.spacing = 6
        var views: [NSView] = [top]
        buttons = [:]
        for r in rows {
            // sentence case, the style's own size (DESIGN.md: never small caps); was 10-pt capitals
            let head = NSTextField(labelWithString: r.head)
            head.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            head.textColor = .secondaryLabelColor
            let one = NSStackView(views: [head] + lines(r, width: width - 28))
            one.orientation = .vertical
            one.alignment = .leading
            one.spacing = 2
            views.append(one)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        top.translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            fx.widthAnchor.constraint(equalToConstant: width),
        ])
        fx.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(80, fx.fittingSize.height))
        let p = panel ?? {
            // a panel that can take keys once he clicks into it (Tab between its buttons, Space presses one);
            // shown, it never takes his typing (orderFrontRegardless, non-activating)
            let p = CardPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.sharingType = .none
            return p
        }()
        p.contentView = fx
        // VoiceOver: the card is "Your day", its rows read in order; the keyboard reaches each button
        fx.setAccessibilityElement(true)
        fx.setAccessibilityRole(.group)
        fx.setAccessibilityLabel("Your day")
        p.setAccessibilityTitle("Your day")
        p.autorecalculatesKeyViewLoop = true
        p.initialFirstResponder = buttons.keys.sorted { $0.frame.minY > $1.frame.minY }.first ?? x
        p.setContentSize(size)
        p.setFrameOrigin(place(size: size, near: near))
        p.orderFrontRegardless()
        panel = p
    }

    /// Beside her, on the other side from her approval card (which goes to her right), kept on her screen.
    private func place(size: NSSize, near pet: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var o = NSPoint(x: pet.minX - size.width - 8, y: pet.maxY - size.height)
        if o.x < vf.minX { o.x = pet.maxX + 8 }
        o.x = min(max(o.x, vf.minX + 8), vf.maxX - size.width - 8)
        if let a = ApprovalCard.shared.frame, a.intersects(NSRect(origin: o, size: size)) {
            o.y = a.minY - size.height - 8                   // under the approval card, never over it
        }
        o.y = min(max(o.y, vf.minY + 8), vf.maxY - size.height - 8)
        return o
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}


/// the day card's panel. Key (taking keys, so Tab moves between its buttons and Space presses one) only for a
/// keyboard user who moves into it, VoiceOver or Full Keyboard Access on, never from a mouse click: 5e124c06 let any
/// click make it key, and his next keystrokes went to the card instead of his app (review). When it closes
/// while key, the app he was in gets its keys back.
final class CardPanel: NSPanel {
    static var keyboardUser: Bool { NSApp.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled }
    private var byMouse = false
    private var hisApp: NSRunningApplication?

    override var canBecomeKey: Bool { !byMouse && CardPanel.keyboardUser }

    override func sendEvent(_ e: NSEvent) {
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard mouse.contains(e.type) else { return super.sendEvent(e) }
        byMouse = true                        // a click presses its button; it doesn't make the card take his keys
        defer { byMouse = false }
        super.sendEvent(e)
    }

    override func becomeKey() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { hisApp = front }
        super.becomeKey()
        log("day card: keys taken (keyboard user)")
    }

    /// Closing: if the card held the keys, they go back to the app he was in.
    func giveKeysBack() {
        guard isKeyWindow else { return }
        resignKey()
        hisApp?.activate()
        hisApp = nil
    }
}
