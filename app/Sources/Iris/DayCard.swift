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
        if !hidden { show(near: near) }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let id = buttons[sender], !id.isEmpty else { return }
        acts.append((token: UUID().uuidString, id: id))
        sender.isEnabled = false
        sender.title = "…"
        log("day card: \(sender.toolTip ?? "button") clicked")
    }

    /// A row's lines: each item with its button, or Core's text as it came when it sent no items.
    private func lines(_ r: Row, width: CGFloat) -> [NSView] {
        let wrap = { (s: String, w: CGFloat) -> NSTextField in
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: 12)
            t.textColor = r.off ? .secondaryLabelColor : .labelColor
            t.preferredMaxLayoutWidth = w
            return t
        }
        guard !r.items.isEmpty, !r.off else { return [wrap(r.text, width)] }
        var out: [NSView] = r.items.map { item in
            guard !item.act.isEmpty, !item.id.isEmpty else { return wrap(item.text, width) }
            let b = NSButton(title: item.act, target: self, action: #selector(clicked(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.toolTip = "\(item.act): \(item.text)"
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            if acts.contains(where: { $0.id == item.id }) { b.isEnabled = false; b.title = "…" }
            buttons[b] = item.id
            let line = NSStackView(views: [wrap(item.text, width - 60), NSView(), b])
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

    /// He clicked her: the card moves beside her and Core is asked for fresh rows.
    func petted(near: CGRect) {
        guard !hidden else { return }
        refresh = true
        if let p = panel { p.setFrameOrigin(place(size: p.frame.size, near: near)) }
    }

    /// Show My Day / Hide My Day, from her menu.
    func toggle(near: CGRect) {
        UserDefaults.standard.set(!hidden, forKey: DayCard.hiddenKey)
        if hidden { close() } else { refresh = true; if !rows.isEmpty { show(near: near) } }
        log("day card: \(hidden ? "hidden" : "shown") from her menu")
    }

    @objc private func dismissed() {
        UserDefaults.standard.set(true, forKey: DayCard.hiddenKey)
        close()
        log("day card: hidden")
    }

    private func close() { panel?.orderOut(nil); panel = nil }

    /// a row's text as Core read it (core/iris_day_card's key: "todos", "next" …); nil when the card has
    /// no such row or Core couldn't read it ("off"). Iris reads the to-dos for one come due (Body.dayCard).
    func text(_ key: String) -> String? { rows.first { $0.key == key && !$0.off }?.text }
    /// Where the card is on his screen, while it's shown.
    var frame: CGRect? { panel?.frame }

    private func show(near: CGRect) {
        let width: CGFloat = 280
        let title = NSTextField(labelWithString: "Your day")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let when = NSTextField(labelWithString: at.map { "Updated " + DayCard.clock.string(from: $0) } ?? "")
        when.font = .systemFont(ofSize: 11)
        when.textColor = .tertiaryLabelColor
        let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide my day") ?? NSImage(),
                         target: self, action: #selector(dismissed))
        x.isBordered = false
        x.contentTintColor = .secondaryLabelColor
        x.toolTip = "Hide (Show My Day in Iris's menu brings it back)"
        let top = NSStackView(views: [title, when, NSView(), x])
        top.orientation = .horizontal
        top.spacing = 6
        var views: [NSView] = [top]
        buttons = [:]
        for r in rows {
            let head = NSTextField(labelWithString: r.head.uppercased())
            head.font = .systemFont(ofSize: 10, weight: .semibold)
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
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
