import AppKit
import QuartzCore

/// Her bubble: a thought bubble, as in a cartoon. A cloud of uneven puffs around her words with a trail of three
/// small bubbles down to her, in her own colours (cream, lavender, plum: her sprites), floating with a gentle bob.
/// Its colour says how much a line matters: calm, notice, needs you, urgent (Tone, from Core's /mouth/show "tone").
/// Her words sit in its middle, wrapped so the cloud is a cloud and not a strip. The little sound wave shows only
/// while her voice really plays; a line she says appears at her speaking pace, one she only shows appears at once.
/// It springs out of her head and shrinks back into her when done.
// (strict concurrency): her bubble is AppKit, on her main thread. @preconcurrency until Body, which makes and
// moves it, is main-actor too: its calls from there compile as before.
/// How much a line matters, from Core ("calm", "notice", "needs_you", "urgent"); anything else is calm.
enum Tone: String {
    case calm, notice, needsYou = "needs_you", urgent

    init(_ raw: String?) { self = Tone(rawValue: (raw ?? "").lowercased()) ?? .calm }

    /// Fill and outline, light and dark: her cream and lavender for calm and notice, then warm and red.
    func colors(dark: Bool) -> (fill: NSColor, edge: NSColor, ink: NSColor) {
        func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: a)
        }
        switch (self, dark) {
        case (.calm, false):     return (c(0xFFFBF0), c(0xC9B8E6), c(0x3D2E4F))
        case (.notice, false):   return (c(0xF1EAFC), c(0x8A6CB5), c(0x33254A))
        case (.needsYou, false): return (c(0xFFEBD9), c(0xE38B3D), c(0x4A2A12))
        case (.urgent, false):   return (c(0xFFE1E1), c(0xD64545), c(0x4D1414))
        case (.calm, true):      return (c(0x2B2533), c(0x8D7BAA), c(0xF4EEFF))
        case (.notice, true):    return (c(0x2F2640), c(0xA98BDA), c(0xF4EEFF))
        case (.needsYou, true):  return (c(0x3A2A1C), c(0xF0A25E), c(0xFFF2E6))
        case (.urgent, true):    return (c(0x3D1F22), c(0xF06B6B), c(0xFFECEC))
        }
    }
}

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
    private var shownAt = Date()

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

    /// `voiced`: her voice is saying it now (the wave moves and the words keep her pace); otherwise they appear at once.
    func say(_ text: String, for seconds: Double, tone: Tone = .calm, voiced: Bool = false) {
        // no words, no bubble (review an empty cloud was put up, smaller than its own puffs)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        full = text
        shown = voiced ? 0 : text.count
        shownAt = Date()
        view.tone = tone
        let size = view.fit(text)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.spoken = text
        view.text = voiced ? "" : text
        // accessibility pass: the bubble is drawn, so VoiceOver had nothing to read; it is told her words
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: "Iris: \(text)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideAt = Date().addingTimeInterval(Bubble.shownFor(text, seconds: seconds))
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
        pop(from: 0.55, to: 1, spring: true)
        // the sound wave, only while her voice plays
        view.speaking = voiced
        wave?.invalidate()
        typer?.invalidate()
        guard voiced else { return }
        let speakFor = Date().addingTimeInterval(Bubble.waveFor(text))
        // scheduled on the main run loop, so it fires on main
        wave = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            MainActor.assumeIsolated {
                self.view.phase += 0.45
                if Date() > speakFor { self.view.speaking = false; self.wave?.invalidate() }
            }
        }
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

    /// How far it floats from its place `t` seconds after it came: a slow bob, `bobReach` points each way (pure,
    /// tested).
    nonisolated static func bob(_ t: Double) -> CGFloat { bobReach * CGFloat(sin(t * 2.2)) }
    nonisolated static let bobReach: CGFloat = 2

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
        // it floats: placed with the bob's reach kept clear above and below, so floating never carries it off her
        // screen or onto their field
        let r = Bubble.bobReach
        var o = Bubble.place(size: NSSize(width: f.width, height: f.height + 2 * r), pet: pet, screens: world.screens,
                             avoid: avoid)
        o.y += r + Bubble.bob(Date().timeIntervalSince(shownAt))
        let tail = Bubble.tail(width: f.width, petMidX: pet.midX, originX: o.x)
        if abs(tail - view.tail) > 0.01 { view.tail = tail }
        if window.frame.origin != o { window.setFrameOrigin(o) }
    }
}

final class BubbleView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var tail: CGFloat = 0.5 { didSet { needsDisplay = true } }
    /// The little sound wave moves while her voice plays (0 = still).
    var phase: CGFloat = 0 { didSet { needsDisplay = true } }
    var speaking = false { didSet { needsDisplay = true } }
    /// How much this line matters: her bubble's colour.
    var tone: Tone = .calm { didSet { needsDisplay = true } }
    /// Her whole line, for VoiceOver (the drawn text may type out a character at a time).
    var spoken = ""

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Iris" }
    override func accessibilityValue() -> Any? { spoken }

    // thought bubble: a cloud of puffs around her words, outlined in the tone's colour, and a trail of three
    // small bubbles down to her
    private nonisolated static let puff: CGFloat = 20           // the largest puff's radius; the cloud's edge is puffs this size
    private nonisolated static let pad = NSEdgeInsets(top: 14, left: 19, bottom: 14, right: 19)
    private nonisolated static let waveW: CGFloat = 16          // room at the top right for the wave while she speaks
    private nonisolated static let trailH: CGFloat = 34         // room under the cloud for the trail of small bubbles
    private nonisolated static let maxW: CGFloat = 320
    private nonisolated static let edge: CGFloat = 2

    static var font: NSFont {
        let base = NSFont.systemFont(ofSize: 15, weight: .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 15) { return f }
        return base
    }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private var attrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.alignment = .center                            // a thought bubble's words sit in its middle
        return [.font: BubbleView.font, .foregroundColor: tone.colors(dark: dark).ink, .paragraphStyle: p]
    }

    /// How wide her words wrap: a line `length` points long (unwrapped), in lines `lineHeight` tall, wraps into as
    /// many lines as make the block about 3.4 times as wide as it is tall, so the cloud is a cloud and not a strip.
    /// A tenth more than an even split, for where the words break; never narrower than its `longest` word (an
    /// email address was cut in two with room to spare: review); never past `most`. Pure, tested.
    nonisolated static func wrapWidth(length: CGFloat, lineHeight: CGFloat, most: CGFloat, longest: CGFloat = 0) -> CGFloat {
        guard length > 0, lineHeight > 0 else { return most }
        let lines = max(1, (length / (3.4 * lineHeight)).squareRoot().rounded())
        return min(most, max(72, longest.rounded(.up), (length / lines * 1.1).rounded(.up)))
    }

    /// The bubble's size for the whole text (so it doesn't grow while typing).
    func fit(_ text: String) -> NSSize {
        // no height cap: a long line was cut at 400 pt
        let p = BubbleView.pad
        func block(_ width: CGFloat) -> NSRect {
            (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin], attributes: attrs)
        }
        let one = block(.greatestFiniteMagnitude)
        let lineHeight = ("X" as NSString).size(withAttributes: attrs).height
        let longest = text.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).size(withAttributes: attrs).width }.max() ?? 0
        // drawn in a box as wide as the widest line this gives, they break at the same words
        let r = block(BubbleView.wrapWidth(length: one.width, lineHeight: lineHeight,
                                           most: BubbleView.maxW - BubbleView.waveW, longest: longest))
        // never smaller than its own puffs and trail, whatever the words
        return NSSize(width: max(96, ceil(r.width) + p.left + p.right + BubbleView.waveW),
                      height: max(BubbleView.trailH + 2 * BubbleView.puff + BubbleView.edge,
                                  ceil(r.height) + p.top + p.bottom + BubbleView.trailH))
    }

    /// One round piece of her bubble: a puff of the cloud's edge, or one of the small bubbles of its trail.
    struct Puff: Equatable { let center: CGPoint; let radius: CGFloat }

    /// The box her words sit in, inside the cloud: the bounds less the trail's room and one puff all round.
    nonisolated static func box(size: NSSize) -> NSRect {
        NSRect(x: edge / 2 + puff, y: trailH + puff, width: max(1, size.width - edge - 2 * puff),
               height: max(1, size.height - trailH - edge / 2 - 2 * puff))
    }

    /// The cloud's puffs for a bubble of `size`: circles centred on the edge of the box her words sit in, a puff's
    /// width apart, their sizes in a fixed order (large, small, medium…) so the edge is uneven like a drawn cloud and
    /// the same every time. All inside the bubble's bounds, above the trail. Pure, so it is tested.
    nonisolated static func cloud(size: NSSize) -> [Puff] {
        let R = puff
        let box = box(size: size)
        let sizes: [CGFloat] = [R, R - 4, R - 1.5, R - 3]
        // each side takes as many puffs as fit about 1.3 R apart: neighbours overlap deep enough that the dip
        // between two puffs stays clear of her words
        func steps(_ length: CGFloat) -> Int { max(1, Int((length / (R * 1.3)).rounded(.up))) }
        let nx = steps(box.width), ny = steps(box.height)
        var at: [CGPoint] = []
        for i in 0..<nx { at.append(CGPoint(x: box.minX + box.width * CGFloat(i) / CGFloat(nx), y: box.maxY)) }      // top
        for i in 0..<ny { at.append(CGPoint(x: box.maxX, y: box.maxY - box.height * CGFloat(i) / CGFloat(ny))) }     // right
        for i in 0..<nx { at.append(CGPoint(x: box.maxX - box.width * CGFloat(i) / CGFloat(nx), y: box.minY)) }      // bottom
        for i in 0..<ny { at.append(CGPoint(x: box.minX, y: box.minY + box.height * CGFloat(i) / CGFloat(ny))) }     // left
        return at.enumerated().map { Puff(center: $1, radius: sizes[$0 % sizes.count]) }
    }

    /// The trail of small bubbles from the cloud down to her: three, shrinking toward her, the last one over her
    /// (`tail`, a share of the width), the others leaning back toward the middle of the cloud. Pure, tested.
    nonisolated static func trail(size: NSSize, tail: CGFloat) -> [Puff] {
        let tx = max(24, min(size.width - 24, size.width * tail))
        let lean: CGFloat = tx > size.width / 2 ? -1 : 1
        return [Puff(center: CGPoint(x: tx + lean * 16, y: trailH - 9), radius: 7),
                Puff(center: CGPoint(x: tx + lean * 7, y: 13.5), radius: 5),
                Puff(center: CGPoint(x: tx, y: 4.5), radius: 3.5)]
    }

    override func draw(_ dirty: NSRect) {
        let p = BubbleView.pad
        let (fill, edgeColor, ink) = tone.colors(dark: dark)
        let cloud = BubbleView.cloud(size: bounds.size), trail = BubbleView.trail(size: bounds.size, tail: tail)
        let e = BubbleView.edge
        func disc(_ c: Puff, less: CGFloat) -> NSBezierPath {
            let r = c.radius - less
            return NSBezierPath(ovalIn: NSRect(x: c.center.x - r, y: c.center.y - r, width: 2 * r, height: 2 * r))
        }
        // the outline is every puff in the edge colour; the fill is every puff a line's width smaller, and the box
        // they sit around, painted over it: what is left of the first pass is the cloud's one outer line
        edgeColor.setFill()
        for c in cloud + trail { disc(c, less: 0).fill() }
        fill.setFill()
        BubbleView.box(size: bounds.size).fill()
        for c in cloud + trail { disc(c, less: e).fill() }
        // the sound wave at the top right, only while her voice plays
        if speaking {
            ink.withAlphaComponent(0.55).setFill()
            let top = bounds.height - p.top - 2
            let wx = bounds.width - p.right - 6             // right of her words, which sit in the middle
            for i in 0..<3 {
                let k = 0.35 + 0.65 * abs(sin(phase + CGFloat(i) * 1.1))
                let h = 10 * k
                let bar = NSRect(x: wx + CGFloat(i) * 4, y: top - 5 - h / 2, width: 2.4, height: h)
                NSBezierPath(roundedRect: bar, xRadius: 1.2, yRadius: 1.2).fill()
            }
        }
        // her whole line is laid out where it will sit and the part not yet said is left clear: typed out a letter
        // at a time, centred words slid sideways with every letter and a word jumped lines as it outgrew one
        let whole = spoken.hasPrefix(text) ? spoken : text
        let line = NSMutableAttributedString(string: whole, attributes: attrs)
        let said = (text as NSString).length
        if said < line.length {
            line.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: said, length: line.length - said))
        }
        line.draw(with: NSRect(x: p.left + BubbleView.waveW / 2, y: BubbleView.trailH + p.bottom - 2,
                               width: bounds.width - p.left - p.right - BubbleView.waveW,
                               height: bounds.height - p.top - p.bottom - BubbleView.trailH + 2),
                  options: [.usesLineFragmentOrigin])
    }
}
