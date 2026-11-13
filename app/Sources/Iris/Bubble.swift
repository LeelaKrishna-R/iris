import AppKit
import QuartzCore

/// Her speech bubble (redesign):
/// a native card in the system's light or dark, a hairline edge and a real
/// shadow, a soft tail toward her, her name with a little sound wave that moves
/// while she speaks, and rounded type. It springs out of her head, the words
/// type out at a speaking pace, and it shrinks back into her when done.
// (strict concurrency): her bubble is AppKit, on her main thread. @preconcurrency until Body, which makes and
// moves it, is main-actor too: its calls from there compile as before.
@preconcurrency @MainActor
final class Bubble {
    private let window: NSPanel
    private let view = BubbleView()
    private var hideAt = Date.distantPast
    private var full = ""
    private var shown = 0
    private var typer: Timer?
    private var tailX: CGFloat = 0.5
    private var wave: Timer?

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.sharingType = .none                       // out of screen shares until her body says otherwise (share)
        window.contentView = view
    }

    /// Her menu's "Show Me in Screen Shares" (Menu.screenShares): her bubble follows her body.
    func share(_ type: NSWindow.SharingType) { window.sharingType = type }

    func say(_ text: String, for seconds: Double) {
        full = text
        shown = 0
        let size = view.fit(text)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.text = ""
        view.spoken = text
        // accessibility pass: the bubble is drawn, so VoiceOver had nothing to read; it is told her words
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: "Iris: \(text)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideAt = Date().addingTimeInterval(Bubble.shownFor(text, seconds: seconds))
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
        pop(from: 0.55, to: 1, spring: true)
        // the sound wave by her name, while the words come
        view.speaking = true
        wave?.invalidate()
        let speakFor = Date().addingTimeInterval(Bubble.waveFor(text))
        // scheduled on the main run loop, so it fires on main
        wave = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            MainActor.assumeIsolated {
                self.view.phase += 0.45
                if Date() > speakFor { self.view.speaking = false; self.wave?.invalidate() }
            }
        }
        typer?.invalidate()
        // about 30 characters a second: close to how fast she speaks
        typer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            MainActor.assumeIsolated {
                self.shown = min(self.full.count, self.shown + 1)
                self.view.text = String(self.full.prefix(self.shown))
                if self.shown >= self.full.count { self.typer?.invalidate() }
            }
        }
    }

    /// How long her bubble stays: the seconds asked for, and longer for a longer line (0.03 s a character), so it is
    /// up while it types out and a moment after (pure, tested).
    nonisolated static func shownFor(_ text: String, seconds: Double) -> Double { seconds + Double(text.count) * 0.03 }

    /// How long the sound wave by her name moves: her speaking pace, about 14 characters a second, and 0.6 s more.
    nonisolated static func waveFor(_ text: String) -> Double { Double(text.count) / 14 + 0.6 }

    /// Where her bubble's tail points, as a share of its width: at her, never closer than 18 pt to its edges.
    nonisolated static func tail(width: CGFloat, petMidX: CGFloat, originX: CGFloat) -> CGFloat {
        max(18, min(width - 18, petMidX - originX)) / width
    }

    /// Where her bubble goes: above her head, unless that covers what they're typing in (their field,
    /// the caret's neighbourhood) — then shifted aside, beside her, or above their field; always on
    /// her screen. A pure function, so the simulator checks it too.
    nonisolated static func place(size: NSSize, pet: CGRect, screens: [Display], avoid: [CGRect]) -> CGPoint {
        let vis = (screens.first { $0.frame.intersects(pet) } ?? screens.first)?.visibleFrame ?? .infinite
        func onScreen(_ o: CGPoint) -> CGPoint {
            CGPoint(x: min(vis.maxX - size.width, max(vis.minX, o.x)), y: min(vis.maxY - size.height, max(vis.minY, o.y)))
        }
        let above = pet.maxY - 14
        var candidates = [
            CGPoint(x: pet.midX - size.width / 2, y: above),                  // over her head (the usual)
            CGPoint(x: pet.midX - size.width + 30, y: above),                 // leaning left
            CGPoint(x: pet.midX - 30, y: above),                              // leaning right
            CGPoint(x: pet.minX - size.width + 24, y: pet.maxY - 70),         // beside her head, left
            CGPoint(x: pet.maxX - 24, y: pet.maxY - 70),                      // beside her head, right
        ]
        for a in avoid { candidates.append(CGPoint(x: pet.midX - size.width / 2, y: a.maxY + 6)) }   // up over their field
        func overlap(_ o: CGPoint) -> CGFloat {
            let r = CGRect(origin: o, size: size)
            return avoid.reduce(0) { t, a in let i = r.intersection(a); return t + (i.isNull ? 0 : i.width * i.height) }
        }
        let placed = candidates.map(onScreen)
        return placed.first { overlap($0) == 0 } ?? placed.min { overlap($0) < overlap($1) }!
    }

    /// Scale her bubble about the tip of its tail (where she is), springy on the way in.
    private func pop(from: CGFloat, to: CGFloat, spring: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let b = view.bounds
        let anchor = CGPoint(x: max(0.1, min(0.9, view.tail)), y: 0)
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: b.width * anchor.x, y: b.height * anchor.y)
        let a: CABasicAnimation
        if spring {
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.damping = 11; s.stiffness = 220; s.mass = 0.9
            s.duration = s.settlingDuration
            a = s
        } else {
            a = CABasicAnimation(keyPath: "transform.scale")
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        a.fromValue = from
        a.toValue = to
        layer.transform = CATransform3DMakeScale(to, to, 1)
        layer.add(a, forKey: "pop")
    }

    func follow(_ pet: CGRect, avoid: [CGRect] = []) {
        if Date() > hideAt {
            if window.isVisible && window.alphaValue > 0.99 {
                pop(from: 1, to: 0.7, spring: false)
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.22; window.animator().alphaValue = 0 },
                                                     completionHandler: { [weak self] in
                    MainActor.assumeIsolated {                    // AppKit calls it on main
                        self?.window.orderOut(nil)
                        self?.view.layer?.transform = CATransform3DIdentity
                    }
                })
            }
            return
        }
        let f = window.frame
        let o = Bubble.place(size: f.size, pet: pet, screens: world.screens, avoid: avoid)
        let tail = Bubble.tail(width: f.width, petMidX: pet.midX, originX: o.x)
        if abs(tail - view.tail) > 0.01 { view.tail = tail }
        if window.frame.origin != o { window.setFrameOrigin(o) }
    }
}

final class BubbleView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var tail: CGFloat = 0.5 { didSet { needsDisplay = true } }
    /// The little sound wave by her name moves while she speaks (0 = still).
    var phase: CGFloat = 0 { didSet { needsDisplay = true } }
    var speaking = false { didSet { needsDisplay = true } }
    /// Her whole line, for VoiceOver (the drawn text types out a character at a time).
    var spoken = ""

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Iris" }
    override func accessibilityValue() -> Any? { spoken }

    private static let pad = NSEdgeInsets(top: 10, left: 14, bottom: 13, right: 15)
    private static let header: CGFloat = 16
    private static let tailH: CGFloat = 10
    private static let maxW: CGFloat = 270
    private static let radius: CGFloat = 16

    static var font: NSFont {
        let base = NSFont.systemFont(ofSize: 14, weight: .medium)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 14) { return f }
        return base
    }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private var attrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: BubbleView.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }

    /// The bubble's size for the whole text (so it doesn't grow while typing).
    func fit(_ text: String) -> NSSize {
        // no height cap: a long line was cut at 400 pt
        let r = (text as NSString).boundingRect(with: NSSize(width: BubbleView.maxW, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: attrs)
        let p = BubbleView.pad
        return NSSize(width: max(96, ceil(r.width) + p.left + p.right),
                      height: ceil(r.height) + p.top + p.bottom + BubbleView.header + BubbleView.tailH)
    }

    /// Her bubble's outline: a rounded card and a soft tail toward her.
    func outline() -> NSBezierPath {
        let body = NSRect(x: 0.5, y: BubbleView.tailH, width: bounds.width - 1, height: bounds.height - BubbleView.tailH - 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: BubbleView.radius, yRadius: BubbleView.radius)
        let tx = max(22, min(bounds.width - 22, bounds.width * tail))
        let t = NSBezierPath()
        t.move(to: NSPoint(x: tx - 9, y: body.minY + 0.5))
        t.curve(to: NSPoint(x: tx, y: 1), controlPoint1: NSPoint(x: tx - 5, y: body.minY - 2),
                controlPoint2: NSPoint(x: tx - 2, y: 3))
        t.curve(to: NSPoint(x: tx + 9, y: body.minY + 0.5), controlPoint1: NSPoint(x: tx + 2, y: 3),
                controlPoint2: NSPoint(x: tx + 5, y: body.minY - 2))
        path.append(t)
        return path
    }

    override func draw(_ dirty: NSRect) {
        let p = BubbleView.pad
        let path = outline()
        (dark ? NSColor(white: 0.12, alpha: 0.96) : NSColor(white: 1.0, alpha: 0.97)).setFill()
        path.fill()
        (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.09)).setStroke()
        path.lineWidth = 1
        path.stroke()
        // her name, small, with a sound wave beside it that moves while she speaks
        let top = bounds.height - p.top - BubbleView.header + 3
        let name = NSAttributedString(string: "Iris", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.4])
        name.draw(at: NSPoint(x: p.left, y: top))
        let wx = p.left + name.size().width + 6
        NSColor.secondaryLabelColor.setFill()
        for i in 0..<4 {
            let k = speaking ? (0.35 + 0.65 * abs(sin(phase + CGFloat(i) * 1.1))) : 0.3
            let h = 9 * k
            let bar = NSRect(x: wx + CGFloat(i) * 3.5, y: top + 6.5 - h / 2, width: 2, height: h)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
        (text as NSString).draw(with: NSRect(x: p.left, y: BubbleView.tailH + p.bottom - 3,
                                             width: bounds.width - p.left - p.right,
                                             height: bounds.height - p.top - p.bottom - BubbleView.header - BubbleView.tailH + 3),
                                options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}
