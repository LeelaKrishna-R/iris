import AppKit

/// An approval your agent asks for, answered on the Mac: what it wants to do, beside Iris, with Allow and
/// Deny. A click is only recorded here (`decisions`); your agent collects it from /iris/decisions and acts
/// on it once. The card never takes your typing (a non-activating panel); it goes when the ask runs out,
/// when your agent says it was answered elsewhere (/iris/ask_done), or when you click.
final class ApprovalCard: NSObject {
    static let shared = ApprovalCard()
    struct Decision { let id: String; let choice: String; let at: Date }
    private(set) var decisions: [Decision] = []
    private var panel: NSPanel?
    private(set) var showing = ""           // the approval on screen now (Core closes it when answered elsewhere)
    private var closeTimer: Timer?

    /// His clicks Core hasn't confirmed yet. Read, not taken (review emptied on read while Core waited 3 s
    /// for her busy main thread, a click was lost without a word); Core confirms each it decided (ack). One older
    /// than 10 minutes is dropped: an approval runs out by then.
    func pendingDecisions() -> [[String: String]] {
        decisions.removeAll { Date().timeIntervalSince($0.at) > 600 }
        return decisions.map { ["id": $0.id, "choice": $0.choice] }
    }

    func ack(_ ids: [String]) {
        decisions.removeAll { ids.contains($0.id) }
    }

    /// Shows the approval `id` next to `near` (her frame) until `until` (or 10 minutes, at most an hour).
    func show(id: String, title: String, text: String, until: Date?, near: CGRect) {
        close()
        showing = id
        let width: CGFloat = 320
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.preferredMaxLayoutWidth = width - 28
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.textColor = .secondaryLabelColor
        let deny = NSButton(title: "Deny", target: self, action: #selector(denied))
        let allow = NSButton(title: "Allow", target: self, action: #selector(allowed))
        allow.keyEquivalent = ""                     // never answered by a key he happens to press
        allow.bezelColor = .controlAccentColor
        for b in [deny, allow] { b.bezelStyle = .rounded; b.controlSize = .regular }
        let buttons = NSStackView(views: [NSView(), deny, allow])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [head, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            fx.widthAnchor.constraint(equalToConstant: width),
        ])
        fx.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(96, fx.fittingSize.height))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.setFrameOrigin(ApprovalCard.place(size: size, near: near))
        p.orderFrontRegardless()
        panel = p
        let left = until.map { $0.timeIntervalSinceNow } ?? 600
        closeTimer = Timer.scheduledTimer(withTimeInterval: max(5, min(3600, left)), repeats: false) { [weak self] _ in
            self?.close()
        }
        log("approval card: shown \(id.prefix(8))")
    }

    /// Closes the card for `id` (answered elsewhere), or whatever card is up when `id` is nil.
    func close(id: String? = nil) {
        if let id, id != showing { return }
        closeTimer?.invalidate(); closeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        showing = ""
    }

    @objc private func allowed() { decide("approve") }
    @objc private func denied() { decide("reject") }

    private func decide(_ choice: String) {
        guard !showing.isEmpty else { return }
        decisions.append(Decision(id: showing, choice: choice, at: Date()))
        log("approval card: \(choice) \(showing.prefix(8))")
        close()
    }

    /// Beside her head, kept on the screen she's on.
    static func place(size: NSSize, near pet: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var o = NSPoint(x: pet.maxX + 8, y: pet.maxY - size.height)
        if o.x + size.width > vf.maxX { o.x = pet.minX - size.width - 8 }
        o.x = min(max(o.x, vf.minX + 8), vf.maxX - size.width - 8)
        o.y = min(max(o.y, vf.minY + 8), vf.maxY - size.height - 8)
        return o
    }
}
