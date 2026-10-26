import AppKit
import ApplicationServices

/// A damped spring: everything she does eases, overshoots a little and settles.
struct Spring {
    var value: CGFloat
    var vel: CGFloat = 0
    var target: CGFloat
    init(_ v: CGFloat) { value = v; target = v }
    mutating func step(_ dt: CGFloat, k: CGFloat = 120, d: CGFloat = 14) {
        let a = k * (target - value) - d * vel
        vel += a * dt
        value += vel * dt
    }
    mutating func kick(_ v: CGFloat) { vel += v }
}

/// Iris on his screens. Reactions happen inside the event that caused them
/// (a key, a scroll, an app switch), so she answers within a frame; what she
/// wants to do next comes from her feelings, at irregular moments.
final class Body {
    let soul = Soul()
    let view: SpriteView?
    let window: NSPanel?
    let bubble: Bubble?
    weak var eyes: Eyes?
    var onTalk: (() -> Void)?
    var onAsk: (() -> Void)?

    static let size = CGSize(width: 150, height: 196)

    // motion
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var vy: CGFloat = 0
    private var targetX: CGFloat?
    private var speed: CGFloat = 70
    private var perchTop: CGFloat?
    private var held = false

    // face springs
    private var turn = Spring(0), tilt = Spring(0), lean = Spring(0), squash = Spring(0)
    private var armL = Spring(0.15), armR = Spring(0.15), sit = Spring(0), hairSway = Spring(0)
    private var gx = Spring(0), gy = Spring(0)
    private var smile = Spring(0.3), brow = Spring(0), blush = Spring(0.15), lid = Spring(0)

    // momentary feelings shown on her face, seconds left
    private var happyT: CGFloat = 0, wideT: CGFloat = 0, winceT: CGFloat = 0, dizzyT: CGFloat = 0
    private var giggleT: CGFloat = 0, waveT: CGFloat = 0, typeT: CGFloat = 0, catT: CGFloat = 0, poutT: CGFloat = 0
    private var sparkleT: CGFloat = 0, sweatT: CGFloat = 0, curiousT: CGFloat = 0
    private var emote: String?
    private var emoteAge: CGFloat = 9
    private var talkUntil = Date.distantPast
    private var listening = false
    private var listenSeated = false              // she was asleep when he said her name: listens sitting up
    private var sleeping = false
    private var hovering = false

    // his hand on her: each touch plays the catalog
    // clip whose "when" is that touch — giggle "he petted her", blow_kiss "affection",
    // bow "thank you, greeting", shy "he looked at her for a long time", blush_hide
    // "very embarrassed", getup "after falling", chase/pounce "chasing/catching his cursor"
    private var petTimes: [Date] = []              // pets in the last 20 s
    private var hoverSince: Date?                  // his cursor resting on her since (once per hover)
    private var hoverShyTimes: [Date] = []         // long hovers in the last minute
    private var flickTimes: [Date] = []            // fast passes of his cursor near her, last 8 s
    private var lastFlickAt = Date.distantPast
    private var lastChaseAt = Date.distantPast
    private var cursorMovedAt = Date.distantPast   // his hand last moved the mouse
    private var touchUntil = Date.distantPast      // a touch clip plays until then (a long look doesn't cut it)
    private var fall: (fromY: CGFloat, at: Date)?  // let go of high up: where she fell from

    // what she knows about him right now
    // from his real last touch, not her launch. Started at launch, her 20:40 install made his 02:10
    // return "he came back after 330 min away" when his hands had been idle since ~14:00.
    private var lastInput = world.now.addingTimeInterval(-min(max(world.handsIdle, 0), 86_400))
    private var keyTimes: [Date] = []
    private var backspaces: [Date] = []
    private var scrollEnergy: CGFloat = 0
    private var typingHand = false
    private var lastCursor = world.mouse
    private var cursorSpeed: CGFloat = 0
    private var keyCounter: UInt32 = 0
    private var use: [String: Double] = [:], useDay = "", useCountedAt = Date.distantPast, useSavedAt = Date.distantPast
    private var work: [String: [String: Double]] = [:]   // hour "09" → "app\ttitle" → active seconds
    private var musicOn = false, musicCheckedAt = Date.distantPast, nextDanceAt = Date.distantFuture
    private var lastSway = 0
    private var titleCheckedAt = Date.distantPast
    private var lastPage: (app: String, title: String) = ("", "")
    private var monitorKeys = 0, monitorKeysSince = 0, countedKeys = 0   // what each way of hearing keys has heard
    private var appsToday = Set<String>()
    private var activeSince = world.now
    private var watchingVideo = false
    private var lastFace = Face()
    /// How she looks this instant (the view draws it; the simulator logs it).
    private(set) var face = Face()

    private var nextThought = world.now
    private var lastTick = world.now
    private var blinkAt = world.now.addingTimeInterval(2)
    private var blinkT: CGFloat = 0
    private var walkPhase: CGFloat = 0
    private var clock: CGFloat = 0
    private var monitors: [Any] = []
    private var timer: Timer?

    /// `headless`: no window, picture or bubble — her mind and body only, for
    /// `Iris --simulate` (everything she reads comes from `world`).
    init(headless: Bool = false) {
        if headless {
            view = nil; window = nil; bubble = nil
        } else {
            let v = SpriteView(frame: NSRect(origin: .zero, size: Body.size))
            let w = NSPanel(contentRect: NSRect(origin: .zero, size: Body.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.hidesOnDeactivate = false
            w.contentView = v
            w.sharingType = .none
            view = v; window = w; bubble = Bubble()
        }
        view?.onPet = { [weak self] in self?.petted() }
        view?.onDoublePet = { [weak self] in self?.doublePetted() }
        view?.onDrag = { [weak self] p in self?.dragged(p) }
        view?.onDrop = { [weak self] in self?.dropped() }
        view?.onMenu = { [weak self] e in self?.menu(e) }
        view?.onHover = { [weak self] on in self?.hover(on) }
        let s = world.screens.first(where: { $0.frame.origin == .zero }) ?? world.screens[0]
        x = s.visibleFrame.midX
        y = s.visibleFrame.minY
        window?.setFrameOrigin(CGPoint(x: x, y: y))
        window?.orderFrontRegardless()
        keyCounter = world.keyCounter
        if let a = world.frontApp { appsToday.insert(a) }
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown, .mouseMoved,
                                           .leftMouseDragged, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.event(e) }) {
            monitors.append(m)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            self?.appSwitched(app)
        }
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: him, instantly

    private func event(_ e: NSEvent) {
        touched()
        switch e.type {
        case .keyDown: monitorKeys &+= 1; monitorKeysSince += 1; key(code: e.keyCode, cmd: e.modifierFlags.contains(.command))
        case .scrollWheel: scrolled(e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
        case .leftMouseDown, .rightMouseDown: clicked(at: world.mouse)
        default: break
        }
    }

    /// Without Accessibility the global key monitor is silent; the system
    /// key counter still says a key went down (no code), checked every frame.
    /// He touched a key, the wheel or a button: after two minutes away, that's him coming back.
    func touched() {
        // a key, scroll or click no hand made (another app posting events) is not him
        guard world.handsIdle < 5 else { return }
        let now = world.now
        let away = now.timeIntervalSince(lastInput)
        lastInput = now
        if performing == "doze" { performUntil = now }      // nodding off, his touch rouses her (no sleep after)
        if away > 120 { bossBack(away: away); activeSince = now }
    }

    /// The system's own key counter, every frame, as the backstop for the key
    /// monitor: after a rebuild macOS can keep reporting Accessibility while the
    /// global monitor silently stops delivering keys (10-11: "iris isn't being
    /// responsive to me typing"). Any key the counter saw that the monitor didn't
    /// is counted here, so his typing always reaches her.
    private func keysFromCounter() {
        let k = world.keyCounter
        if k != keyCounter {
            let n = Int(k &- keyCounter)
            keyCounter = k
            countedKeys &+= n
            let missed = n - monitorKeysSince
            if missed > 0 { touched(); for _ in 0..<min(missed, 4) { key(code: nil) } }
        }
        monitorKeysSince = 0
    }

    func key(code: UInt16?, cmd: Bool = false) {
        let now = world.now
        // his own shortcuts are moments of hers.
        // ⌘S: he saved — a nod and a sparkle. ⌘Z three times in a few seconds: undo, undo, undo — a
        // little shake of her head. Each at most every 20 s, never asleep, held or mid-clip.
        if cmd, !sleeping, !held, performing.isEmpty, now.timeIntervalSince(shortcutAt) > 20 {
            if code == 1 {
                shortcutAt = now; sparkleT = 1.0
                perform("nod", seconds: 1.6, own: true, why: "he saved")
            } else if code == 6 {
                undos.append(now); undos.removeAll { now.timeIntervalSince($0) > 4 }
                if undos.count >= 3 { shortcutAt = now; undos.removeAll(); perform("shake_head", seconds: 1.8, own: true, why: "undo, undo, undo") }
            }
        }
        // a new burst of typing: she notices it soon (not every key, not on a fixed beat)
        if now.timeIntervalSince(lastTyped) > 6 {
            typingSince = now
            typeAlongAfter = Body.typeAlongAfterS
            if !sleeping && targetX == nil && performing.isEmpty { think(soon: Double.rnd(1.5...4)) }
        }
        lastTyped = now
        keyCount &+= 1
        if now.timeIntervalSince(lastFocusRead) > 0.3 { readFocus() }
        readInto(now)
        keyTimes.append(now)
        keyTimes.removeAll { now.timeIntervalSince($0) > 3 }
        // her hands type along with his, one tap per key
        typingHand.toggle()
        if typingHand { armL.kick(7); armR.kick(-3) } else { armR.kick(7); armL.kick(-3) }
        tilt.kick(CGFloat.rnd(-0.4...0.4))
        _ = soul.feel(.key, 0.3)
        if sleeping { maybeWake(0.08) }
        let rate = Double(keyTimes.count) / 3 * 60
        if rate > 300 && soul.feel(.fastTyping, 0.6) > 0.35 {
            sparkleT = 1.2
        }
        if code == 51 {
            backspaces.append(now)
            backspaces.removeAll { now.timeIntervalSince($0) > 1.6 }
            if backspaces.count >= 5 && soul.feel(.backspaceBurst) > 0.3 {
                // her wince only; a "…" bubble on half his backspace bursts (a coin) was a reaction to nothing he'd want noticed
                winceT = 0.5; sweatT = 1.6; backspaces.removeAll()
            }
        } else if code == 36 {
            if soul.feel(.enter, 0.5) > 0.25 { squash.kick(-1.2); tilt.kick(0.6) }
        }
    }

    func scrolled(_ dy: CGFloat, precise: Bool) {
        let d = precise ? dy / 10 : dy
        gy.value = max(-1, min(1, gy.value + (d > 0 ? 0.25 : -0.25)))
        gy.kick(d > 0 ? 3 : -3)
        scrollEnergy += abs(d)
        lean.kick(d > 0 ? -0.3 : 0.3)
        if scrollEnergy > 260 {
            // at most once in Body.dizzyEveryS (Soul.feel's fading came back after any rest)
            if soul.feel(.fastScroll) > 0.3 && world.now.timeIntervalSince(dizzyAt) > Body.dizzyEveryS {
                dizzyAt = world.now; dizzyT = 1.4; show("@_@")
            }
            scrollEnergy = 0
        } else {
            _ = soul.feel(.scroll, 0.2)
        }
    }

    func clicked(at p: CGPoint) {
        guard !CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height).contains(p) else { return }
        _ = soul.feel(.click, 0.3)
        warm(p, by: 3)
        blinkT = 0.12
        lookToward(p, snap: 0.6)
    }

    private func appSwitched(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        appSwitched(name: app.localizedName ?? "")
    }

    /// How he spends his day at the Mac: active seconds per front app (he typed,
    /// clicked or moved the mouse in the last 2 minutes), saved under her own
    /// folder by day ("use-2026-10-11.json"), never leaving this Mac.
    private func countUse(_ now: Date) {
        guard now.timeIntervalSince(useCountedAt) >= 5 else { return }
        let step = min(10, now.timeIntervalSince(useCountedAt))
        useCountedAt = now
        // the system's own idle clock (any key, click, scroll or mouse move): lastInput starts at
        // launch, so the two minutes after every launch were counted as his
        let idle = world is RealWorld
            ? CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            : now.timeIntervalSince(lastInput)
        guard idle < 120, let app = world.frontApp, !app.isEmpty,
              app != (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Iris") else { return }
        let day = Body.dayKey(now)
        if day != useDay {
            useDay = day
            use = Store.load([String: Double].self, "use-\(day).json") ?? [:]
            work = Store.load([String: [String: Double]].self, "work-\(day).json") ?? [:]
            Body.pruneUse(before: Body.dayKey(now.addingTimeInterval(-60 * 86400)))
        }
        use[app, default: 0] += step
        // what he was on, by the hour: the window's title with its app, so "what was I
        // working on this afternoon" is the file or page, not just "Code"
        let hour = String(format: "%02d", Calendar.current.component(.hour, from: now))
        let title = String((world.frontTitle ?? "").prefix(120))
        var h = work[hour] ?? [:]
        h["\(app)\t\(title)", default: 0] += step
        if h.count > 40, let least = h.min(by: { $0.value < $1.value }) { h[least.key] = nil }
        work[hour] = h
        if now.timeIntervalSince(useSavedAt) >= 60 {
            useSavedAt = now; Store.save(use, "use-\(day).json"); Store.save(work, "work-\(day).json")
        }
    }

    /// The day files older than 60 days go: his windows aren't kept forever.
    static func pruneUse(before cutoff: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Store.dir.path)) ?? []
        for n in names where n.hasPrefix("use-") || n.hasPrefix("work-") {
            let day = n.replacingOccurrences(of: "use-", with: "").replacingOccurrences(of: "work-", with: "")
                .replacingOccurrences(of: ".json", with: "")
            if day.count == 10 && day < cutoff { try? FileManager.default.removeItem(at: Store.url(n)) }
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    /// Today's (or a given day's) active seconds per app.
    func usage(day: String? = nil) -> [String: Double] {
        let d = day ?? Body.dayKey(world.now)
        return d == useDay ? use : (Store.load([String: Double].self, "use-\(d).json") ?? [:])
    }

    /// A day's active seconds by hour, then by "app\ttitle".
    func workHours(day: String? = nil) -> [String: [String: Int]] {
        let d = day ?? Body.dayKey(world.now)
        let w = d == useDay ? work : (Store.load([String: [String: Double]].self, "work-\(d).json") ?? [:])
        return w.mapValues { $0.mapValues { Int($0) } }
    }

    /// Music playing (a music app and the speakers in use, checked every 2 s): she
    /// sways a little to it, and now and then, when he isn't typing, she dances.
    /// Never over a video, never asleep.
    private func listenToMusic(_ now: Date) {
        if now.timeIntervalSince(musicCheckedAt) > 2 {
            musicCheckedAt = now
            // her own voice uses the same speakers: not music (2 s after she stops, for the tail)
            let on = world.musicPlaying && now.timeIntervalSince(talkUntil) > 2
            if on && !musicOn {
                events.append("music started playing")
                nextDanceAt = now.addingTimeInterval(30)
            }
            musicOn = on
        }
        guard musicOn, !watchingVideo, !sleeping, !held, performing.isEmpty else { return }
        let half = Int(clock * 2)                       // a sway each half second, about a beat
        if half != lastSway { lastSway = half; lean.kick(half % 2 == 0 ? 0.12 : -0.12) }
        // and only while he's at the Mac (no antics to an empty room, 10-15)
        if now >= nextDanceAt && now.timeIntervalSince(lastTyped) > 10 && now.timeIntervalSince(lastInput) < 300 {
            perform("dance", seconds: 4, own: true, why: "music playing")
            // every 60-150 s by dice was ~30 dances in an hour of music
            nextDanceAt = now.addingTimeInterval(Body.danceEveryS)
        }
    }

    /// A new page or tab in the same app (his browsing): she glances up at it,
    /// her mind hears what he opened, and a video tab is noticed at once.
    private func pageChanged() {
        let app = world.frontApp ?? "", title = world.frontTitle ?? ""
        defer { lastPage = (app, title) }
        guard app == lastPage.app, !title.isEmpty, title != lastPage.title,
              app != (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Iris") else { return }
        if let w = world.frontWindow() { lookToward(CGPoint(x: w.midX, y: w.maxY - 60), snap: 0.7) }
        if soul.feel(.appSwitch, 0.4) > 0.5 { wideT = 0.25 }
        events.append("he opened \"\(String(title.prefix(60)))\" in \(app)")
        think(soon: 0.5)
    }

    func appSwitched(name: String) {
        let fresh = appsToday.insert(name).inserted
        let k = soul.feel(fresh ? .newApp : .appSwitch)
        if let w = world.frontWindow() ?? world.windows(maxAge: 0).first?.frame {
            lookToward(CGPoint(x: w.midX, y: w.midY), snap: 1)
            trace?("glance", ["why": "app", "at": [Double(w.midX), Double(w.midY)]])
        } else { turn.kick(CGFloat.rnd(-6...6)) }
        // her face only. A "?" or "!" bubble on any switch she wasn't used to yet was the Code <-> Discord
        // back-and-forth the owner called dumb; the app moments are core/iris_reflex's glance, an hour apart
        if k > 0.4 { if fresh { curiousT = 1.6 } else { wideT = 0.3 } }
        let was = watchingVideo
        watchingVideo = Body.isVideo(app: name, title: world.frontTitle) && screenMoving
        if watchingVideo && !was { _ = soul.feel(.video); think(soon: 0.2) }
    }

    private func bossBack(away: Double) {
        events.append("he just came back to the Mac")
        let k = soul.feel(.bossBack)
        // the hop and the wave are for him really coming back; two or three minutes of reading
        // without a touch is him still there, and gets only her eyes and a smile (10-15: a wave on
        // nearly every wake)
        let greets = k > 0.25 && away >= Body.trulyAway
        trace?("boss_back", ["k": k, "was_sleeping": sleeping, "away": away, "greets": greets])
        if sleeping { sleeping = false; wideT = 0.6; sit.target = 1 }       // waking, she sits up (standing comes after)
        guard k > 0.25 else { return }
        happyT = 1.6
        lookToward(world.mouse, snap: 0.6)               // a look at where his hand came back
        targetX = nil
        think(soon: 1.5)
        guard greets else { return }
        hop(380 * CGFloat(min(1, k + 0.3)))
        waveT = 1.8
        waveWhy = String(format: "he came back after %.0f min away", away / 60)
        trace?("act", ["what": "wave", "why": waveWhy])
        show("♪")                                        // 10-22: was "!" or "♪" by a coin
    }

    func hover(_ on: Bool) {
        hovering = on
        // his look counts when he brought the cursor to her, not when she walked under a still one
        hoverSince = on && world.now.timeIntervalSince(cursorMovedAt) < 0.5 ? world.now : nil
        if on { notice("he hovered his cursor over you") }
        if on && soul.feel(.hover) > 0.2 {
            catT = 1.2
            tilt.kick(Double.rnd(0...1) < 0.5 ? 1.2 : -1.2)
        }
    }

    func petted() {
        touch("pet")
        _ = soul.feel(.petted)
        soul.reward(1)
        notice("he petted you")
        soul.feelPlace(x + Body.size.width / 2, y, 0.3)
        if sleeping { sleeping = false; sit.target = 1; wideT = 0.3 }
        happyT = 1.4; giggleT = 0.9
        show("♥")
        blush.kick(4)
        if hovering { hoverSince = world.now }   // a pet isn't a long look: the 2 s start again
        let now = world.now
        petTimes = petTimes.filter { now.timeIntervalSince($0) < 20 } + [now]
        if performing == "blow_kiss" && now < performUntil { return }   // her kiss plays out; more pets only warm her
        if petTimes.count >= 3 {
            // petted again and again: affection back — a kiss with a heart
            petTimes.removeAll()
            touchClip("blow_kiss", 2.6, "pets")
        } else {
            hop(260)
            touchClip("giggle", 1.6, "pet")
        }
    }

    /// A double-click on her: a polite bow, coming up smiling (the first click was a pet already).
    func doublePetted() {
        notice("he double-clicked you")
        if sleeping { sleeping = false; sit.target = 1 }
        happyT = 2.2; giggleT = 0
        petTimes.removeAll()
        if hovering { hoverSince = world.now }
        touchClip("bow", 2.4, "double_click")
    }

    /// Her reaction to his touch: the clip, at once, traced for the simulator.
    private func touchClip(_ id: String, _ seconds: Double, _ why: String) {
        trace?("touch", ["what": why, "clip": id])
        perform(id, seconds: seconds, own: true, why: Body.touchWhy[why] ?? why)
        touchUntil = performUntil
    }

    func dragged(_ p: CGPoint) {
        if !held {
            notice("he picked you up and moved you")
            touch("drag")
            performing = ""; performMoves = false; fall = nil     // a clip stops when he picks her up
            held = true; _ = soul.feel(.dragged); wideT = 0.4; targetX = nil; perchTop = nil
            standingOn = nil; standingID = nil; perchID = nil; launch = nil; vx = 0; leapTo = nil
            jumpDown = nil; shooWalkTo = nil; dozeWhy = nil
            pickedUpAt = CGPoint(x: x + Body.size.width / 2, y: y)
        }
        x = p.x - Body.size.width / 2
        y = p.y - Body.size.height * 0.8
    }

    func dropped() {
        held = false
        vy = 0
        sit.target = 0; sit.value = 0; sit.vel = 0; workingAlong = false     // carried, she's on her feet when let go
        _ = soul.feel(.dropped)
        soul.reward(-0.5)
        // he moved her: where she was was wrong, where he put her is fine
        if let p = pickedUpAt { soul.feelPlace(p.x, p.y, -0.45) }
        soul.feelPlace(x + Body.size.width / 2, screenAt(x + Body.size.width / 2).visibleFrame.minY, 0.15)
        pickedUpAt = nil
        poutT = 1.5
        // let go of high up: she falls, and gets up from it when she lands (getup, "after falling")
        fall = y - groundBelow() > 200 ? (y, world.now) : nil
        if hovering { hoverSince = world.now }
        hisScreenSince = world.now          // where he put her is her place for a while, wherever he works
        placedAt = world.now
    }

    /// Every frame: his cursor resting on her, or darting about near her.
    private func touchReactions(_ now: Date, cursor c: CGPoint, me: CGPoint, dist: CGFloat) {
        // resting on her 2 s: shy (her rig's own "shy"); the third time in a minute, she hides her red face
        if let hs = hoverSince, now.timeIntervalSince(hs) >= 2, now >= touchUntil {
            hoverSince = nil                                    // once per hover
            if !held && !sleeping {
                hoverShyTimes = hoverShyTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
                notice("he rested his cursor on you")
                if hoverShyTimes.count >= 3 {
                    hoverShyTimes.removeAll()
                    touchClip("blush_hide", 2.8, "hover_again")
                } else {
                    blush.kick(3)
                    touchClip("shy", 2.5, "hover")
                }
            }
        }
        // his cursor darting past her, again and again, while he isn't typing: she plays —
        // chases it, or pounces when it's right by her. At most every 2 minutes.
        if let first = flickTimes.first, now.timeIntervalSince(first) >= 8 { flickTimes.removeFirst() }   // only passes of the last 8 s
        if cursorSpeed > 1800 && dist < 320 && !held && now.timeIntervalSince(lastFlickAt) > 0.6 {
            lastFlickAt = now
            flickTimes.append(now)
        }
        if flickTimes.count >= 3 && now.timeIntervalSince(lastChaseAt) >= 120 && !held && !sleeping
            && now.timeIntervalSince(lastTyped) > 4 && !deepFocus && !watchingVideo {
            lastChaseAt = now
            flickTimes.removeAll()
            face.flip = c.x < me.x                              // toward his cursor
            notice("he played with you with his cursor")
            touchClip(dist < 140 ? "pounce" : "chase", 2.6, "cursor_play")
        }
    }

    // MARK: thinking — irregular, from feelings
    //
    // There is no list of things to do. At irregular moments she weighs the
    // places she could be — close to him without being in his way, toward
    // what's moving on his screens, spots she has come to like or avoid, how
    // far it is for how tired she is — with her mood as the temperature of
    // the choice. Where she goes, how fast, and whether she sits, sleeps or
    // fools around fall out of how she feels, and change as she learns.

    /// A video he's watching: a player app, or a page whose title says so (YouTube in Safari has
    /// the app name "Safari"; only its title tells).
    /// A video plays: his screen keeps changing (her eyes see it). A "YouTube" title alone is only the site.
    private var screenMoving: Bool { eyes?.changingRecently ?? world.screenChanging }

    static func isVideo(app: String, title: String?) -> Bool {
        let a = app.lowercased(), t = (title ?? "").lowercased()
        return ["youtube", "netflix", "tv", "quicktime", "vlc", "iina", "plex", "prime"].contains { a.contains($0) }
            || ["youtube", "netflix", "prime video", "disney+", "twitch", "hulu", "vimeo", "plex", "crunchyroll"].contains { t.contains($0) }
    }

    private func think(soon: Double? = nil) {
        if let s = soon { nextThought = world.now.addingTimeInterval(s); return }
        // what's on his screen now (a tab can turn into a video without an app switch)
        let wasVideo = watchingVideo
        watchingVideo = Body.isVideo(app: world.frontApp ?? "", title: world.frontTitle) && screenMoving
        if watchingVideo && !wasVideo { _ = soul.feel(.video) }
        // a long stretch of his focused typing calms her
        let focusedFor = world.now.timeIntervalSince(lastTyped) < 20 ? world.now.timeIntervalSince(focusSince) : 0
        if world.now.timeIntervalSince(lastTyped) >= 20 { focusSince = world.now }
        deepFocus = focusedFor > 120
        if deepFocus { _ = soul.feel(.longFocus, 0.5) }
        let idle = world.now.timeIntervalSince(lastInput)
        let typing = world.now.timeIntervalSince(lastTyped) < 4
        nextThought = world.now.addingTimeInterval(-log(Double.rnd(0.05...1)) * (typing ? 12 : 7) + 1)
        if listening || held { return }
        let s = soul
        let now = world.now
        if sleeping {
            if idle < 3 { maybeWake(0.3) }
            // something happening on a screen wakes her too, him there or not —
            // when it keeps happening; a few seconds of change is a flicker
            else if let since = screenMovingSince, now.timeIntervalSince(since) >= Body.screenWakeAfter { maybeWake(0.12) }
            return
        }
        // where the action is : his full-screen film or a call sends her to a quiet
        // corner; ten minutes with nothing happening send her to her favourite spot first
        let corner = watchCorner()
        let nothing = idle >= Body.homeAfter && !screenMoving && !world.callOn && !world.soundOn && !watchingVideo
        // late at night she dozes off after two quiet minutes instead of five — only
        // when the screens are still too: a movie, a chat or code being written
        // without his hands is still something to watch 
        //
        let dozy = idle > (watchingVideo ? 900 : Soul.lateNight ? 120 : 300)
            && now.timeIntervalSince(screenMovedAt) > Body.screenStillToDoze && now.timeIntervalSince(wokeAt) > Body.wakeHolds
            && s.sleepiness > (Soul.lateNight ? 0.4 : 0.55)
        // (sleepy before the ten minutes are up, she goes home to doze off there)
        let home = corner == nil && (nothing || dozy) ? favouriteSpot() : nil
        let goingHome = home.map { abs($0 - x) > 40 || standingOn != nil } ?? false
        // falling asleep has a stage he can see. Standing,
        // she dozes on her feet first ("doze": head drooping, snapping up, drooping) and falls asleep when
        // it ends, unless he touched the Mac meanwhile; seated, she falls asleep where she sits. Both only
        // when everything above says dozy (it was also a draw against her sleepiness: no dice, 10-15 rule).
        if !goingHome && dozy && performing != "doze" {
            let why = String(format: "dozed: no input %.0f s, screens still %.0f s, sleepy %.2f", idle, min(3600, now.timeIntervalSince(screenMovedAt)), s.sleepiness)
            if Stages.dozeFirst(dozy: dozy, goingHome: goingHome, seated: sit.target > 0.5) && performing.isEmpty {
                dozeWhy = why; dozeInputAt = lastInput
                perform("doze", seconds: Stages.dozeSeconds, own: true, why: "nodding off: " + why.dropFirst(7))
            } else if performing.isEmpty || sit.target > 0.5 {
                fallAsleep(why)
            }
            return
        }
        if performing == "doze" { return }          // nodding off: the doze decides what comes next

        let pick = corner.map { Spot(x: $0, perch: nil, nearHim: false, why: world.callOn ? "corner: a call" : "corner: his film") }
            ?? home.map { Spot(x: $0, perch: nil, nearHim: false, why: "home: nothing happening") }
            ?? choosePlace(typing: typing, idle: idle)
        let far = abs(pick.x - x)
        let atPerch = pick.perch != nil ? (pick.perchID == standingID && standingOn != nil) : (standingOn == nil)
        trace?("think", ["to": Double(pick.x), "perch": pick.perch.map { Double($0) } as Any, "near_him": pick.nearHim,
                         "moving": far > 40 || (!atPerch && far > 0.5), "why": pick.why, "typing": typing, "idle": idle, "want": wanting.want])
        perchTop = pick.perch
        perchID = pick.perchID
        // a few points is not worth a step (tiny shuffles read as twitching); up or down a level always is.
        // Seated, she stays a minute at least, and gets up only for somewhere a real walk away — unless
        // she's in his way, his call or film or nothing-happening sends her off, or it's his other screen
        //
        let seated = sit.target > 0.5 && !hurry && corner == nil && home == nil
            && screenAt(pick.x + Body.size.width / 2).frame == screenAt(x + Body.size.width / 2).frame
        let stay = seated && (now.timeIntervalSince(satSince) < Body.sitHolds || far <= Body.seatedStep)
        // and a walk needs a reason in the world ("her actions are so random for no
        // reason"): his call, film or an empty room; out of his way; closer to him; beside his front
        // window; the screen he's working on; her mind's want; or the walk she's already on
        let meNow = CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)
        let otherScreen = screenAt(pick.x + Body.size.width / 2).frame != screenAt(x + Body.size.width / 2).frame
        // (10-17 poses.jsonl 13:40-23:18, him away for hours: woken by a chat moving on a screen, she
        // walked "to the screen he's working on", sat, walked "home", sat, walked off toward his
        // cursor and home again, 44 home walks since noon. Away, his cursor is where he left it, not
        // him, and no screen is one he's working on: neither is a reason to walk.)
        let here = idle < Body.trulyAway
        let pull: String? = corner != nil || home != nil ? pick.why
            : hurry || inTheWay(meNow) > 0.3 ? "out of his way"
            : targetX.map({ abs($0 - pick.x) < 1 }) == true ? walkWhy
            : otherScreen && here ? "to the screen he's working on"
            : attendX.map({ abs($0 - pick.x) < 60 }) == true ? "beside his front window"
            : pick.nearHim && here && abs(meNow.midX - world.mouse.x) > 450 ? "closer to him"
            : ["explore", "give_space", "be_close"].contains(wanting.want) && wanting.k > 0.3 ? "her mind: \(wanting.want)"
            : nil
        if !stay, let pull, (far > 40 || (!atPerch && far > 0.5) || (pick.x == targetX && targetX != nil)) {
            walkWhy = pull
            let same = targetX.map { abs($0 - pick.x) < 1 } ?? false
            targetX = pick.x
            if !same { speed = 34 + CGFloat(s.arousal) * 46 + (s.arousal > 0.8 && far > 500 ? 60 : 0); walkSince = world.now }   // a walk keeps its pace
            if !same { trace?("walk", ["why": pull, "idle": idle, "to": Double(pick.x)]) }
            if hurry { speed = max(speed, 240); hurry = false }    // in his way while he types: she scurries
            // 10-24 poses.jsonl: 8 crossings to the screen he's working on took 13.4 of 60 min (a stroll across a
            // whole display); she runs there, a short trip, then she's with him
            if pull == "to the screen he's working on" { speed = max(speed, Body.crossSpeed) }
            // the action's pull is a stroll, never a dash: home and beside his window slowly,
            // out of a call's way a little quicker
            if corner != nil { speed = min(max(speed, 70), 110) }
            else if home != nil { speed = min(speed, 45) }
            else if let ax = attendX, abs(ax - pick.x) < 60, screenAt(pick.x + Body.size.width / 2).frame == screenAt(x + Body.size.width / 2).frame {
                speed = min(speed, 55)
            }
            sit.target = 0
            workingAlong = false
            // arrived, she stands a little before she thinks about sitting (sitting down the moment she
            // got there, then up again for the next walk, was the stand-sit-stand thrash, 10-15)
            postureUntil = now.addingTimeInterval(Double(far / max(speed, 30)) + (typing ? Double.rnd(3...8) : Double.rnd(15...40)))
            soul.did(pick.nearHim ? "approach" : "roam")
            restWhy = "where she walked: " + pull
        } else {
            targetX = nil
            // staying: she changes how she rests only now and then — a body that's
            // comfortable stays put — and how is her mood, never his keystrokes
            if world.now >= postureUntil {
                let w = wanting
                let settle = (1 - s.arousal) * 0.6 + s.sleepiness * 0.3 + (watchingVideo ? 0.5 : 0) + (deepFocus ? 0.5 : 0)
                    + (["watch", "rest", "work_along", "nap"].contains(w.want) ? 0.5 * w.k : 0)
                let wasSitting = sit.target > 0.5
                let typedFor = world.now.timeIntervalSince(lastTyped) < 6 ? world.now.timeIntervalSince(typingSince) : 0
                // she sits down for a reason, and stays sitting until a walk with a reason gets her up
                //
                _ = settle
                let sitFor: String? = typedFor > 0 ? "keeping him company while he types"
                    : watchingVideo ? "watching his video with him"
                    : deepFocus ? "keeping him company while he focuses"
                    : s.sleepiness > 0.45 ? String(format: "sleepy %.2f", s.sleepiness)
                    : ["watch", "rest", "work_along", "nap"].contains(w.want) && w.k > 0.3 ? "her mind: \(w.want)"
                    // near him a few
                    // minutes with no walk, she settles down beside him while he reads or browses
                    : idle < 120 && world.now.timeIntervalSince(walkSince) >= Body.settleAfter
                        && Double(abs(x + Body.size.width / 2 - world.mouse.x)) < Body.withinReach ? "settled beside him"
                    : nil
                sit.target = wasSitting || sitFor != nil ? 1 : 0
                if sit.target > 0.5 && !wasSitting { satSince = world.now; restWhy = sitFor ?? "" }
                // a few seconds into his typing
                // she gets her own laptop out and types along, key for key, every time (it was by dice,
                // 8-20 s in, "never certain"); 20 s after he stops it goes away
                let along = typedFor > typeAlongAfter
                if along && !wasSitting { sit.target = 1; satSince = world.now; restWhy = "typing along with him" }
                workingAlong = sit.target > 0.5 && (along || workingAlong && world.now.timeIntervalSince(lastTyped) < Body.typeAlongHoldS
                    || w.want == "work_along" && w.k > 0.5 && idle < 60)
                // while he keeps typing she checks in again sooner; once he stops, the laptop goes away in time
                if typedFor > 0 && !workingAlong { postureUntil = world.now.addingTimeInterval(Double.rnd(6...15)) }
                if workingAlong && world.now.timeIntervalSince(lastTyped) > Body.typeAlongHoldS && w.want != "work_along" { workingAlong = false }
                if w.want == "watch", let fw = world.frontWindow() { lookToward(CGPoint(x: fw.midX, y: fw.midY), snap: 0.6) }
                if world.now > postureUntil { postureUntil = world.now.addingTimeInterval(Double.rnd(25...140)) }
            }
            // in her corner she sits and watches (his film, or quietly through his call)
            if corner != nil {
                if sit.target < 0.5 { satSince = world.now }
                restWhy = pick.why
                sit.target = 1; workingAlong = false
                if let fw = world.frontWindow() { lookToward(CGPoint(x: fw.midX, y: fw.midY), snap: 0.3) }
            }
        }
        if wanting.want == "nap" { soul.sleepiness = min(1, soul.sleepiness + 0.15 * wanting.k) }
        // : nothing of her own by dice. Each
        // move has a cause in the world — his typing stopping (a nod, frame()), his cursor resting on
        // her (shy), his hand on her, music (sway, dance), his return after 5 min (one wave) — and
        // here, late and sleepy, a yawn now and then. Otherwise she breathes, blinks, and her eyes
        // follow what he's doing (attend()). Long stretches at the Mac are Core's to mention, with
        // the measured fact (her old "Stretch with me?" line and its wave are gone).
        if Soul.lateNight && s.sleepiness > 0.6 && !typing && corner == nil && targetX == nil && performing.isEmpty
            && now.timeIntervalSince(lastYawnAt) > Body.yawnEveryS && now.timeIntervalSince(lastInput) < 300 {
            // every 5 min was up to 12 yawns an hour, him there or not; at most every half hour, while he's at the Mac
            lastYawnAt = now
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            perform("yawn", seconds: 2.6, own: true,
                    why: String(format: "%d:%02d at night, sleepy %.2f", c.hour ?? 0, c.minute ?? 0, s.sleepiness))
        }
    }

    private struct Spot { var x: CGFloat; var perch: CGFloat?; var nearHim: Bool; var why = ""; var perchID: Int? = nil }

    /// The simulator listens here (Sim.swift): what she decided and why. Nil live.
    var trace: ((String, [String: Any]) -> Void)?

    private func choosePlace(typing: Bool, idle: Double) -> Spot {
        let s = soul
        // where he is: his caret while he types, else his cursor
        let c = (typing ? focusCaret.map { CGPoint(x: $0.midX, y: $0.midY) } : nil) ?? world.mouse
        var spots: [Spot] = []
        // the other screen is his to invite her to: only once he's been working there a while
        // (never a wander of her own), or to get out of his way when this one has no room (below)
        let screens = world.screens
        let mineIdx = screens.firstIndex { $0.frame.minX <= x + Body.size.width / 2 && x + Body.size.width / 2 < $0.frame.maxX }
        // he's away (Body.trulyAway): his cursor and the screen it was last on are where he left them,
        // not him; nothing of his draws her
        let himHere = idle < Body.trulyAway
        let invited = !himHere ? nil : hisScreen.flatMap { h in h != mineIdx && world.now.timeIntervalSince(hisScreenSince) >= Body.screenStay ? h : nil }
            ?? frontInvite          // or his front window has settled over there (Body.frontStay, 2 min) with him
        // beside his front window: a pull while he's around (gentle while he types — she keeps him company where she is)
        // (up on one of his windows she's already among his things: that seat is hers to keep)
        let attend = idle < 180 && standingOn == nil ? attendX : nil
        func screenOf(_ px: CGFloat) -> Int? { screens.firstIndex { $0.frame.minX <= px + Body.size.width / 2 && px + Body.size.width / 2 < $0.frame.maxX } }
        for (i, scr) in screens.enumerated() where scr.frame != fullScreenFrame {
            let f = scr.visibleFrame
            // evenly spaced across the floor, not random positions
            let n = i == mineIdx ? 22 : 6
            let span = max(0, f.width - Body.size.width)
            for k in 0..<n { spots.append(Spot(x: f.minX + span * (CGFloat(k) + 0.5) / CGFloat(n), perch: nil, nearHim: false)) }
        }
        // where she is — unless that's half on two screens; and where she's already going
        let me0 = CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)
        if world.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(me0) }) {
            spots.append(Spot(x: x, perch: standingOn?.maxY, nearHim: false, perchID: standingID))
        }
        if let t = targetX { spots.append(Spot(x: t, perch: perchTop, nearHim: false, perchID: perchID)) }
        if let ax = attend { spots.append(Spot(x: ax, perch: nil, nearHim: false)) }
        // window tops she can jump up to — any of his windows whose top is showing there, not
        // more than maxClimb above the floor beneath, with room above for her
        let ws = world.windows(maxAge: 1)
        for (i, w) in ws.prefix(10).enumerated() {
            let f = w.frame
            guard f.width > Body.size.width * 1.6,
                  let scr = screens.first(where: { $0.frame.contains(CGPoint(x: f.midX, y: f.maxY - 1)) }),
                  f.maxY + Body.size.height <= scr.visibleFrame.maxY,
                  f.maxY - scr.visibleFrame.minY <= Body.maxClimb || standingID == w.id else { continue }
            // its left, middle and right of the top she can stand on
            let lo = max(f.minX, scr.visibleFrame.minX), hi = max(lo, min(f.maxX, scr.visibleFrame.maxX) - Body.size.width)
            for sx in [lo + (hi - lo) * 0.15, (lo + hi) / 2, lo + (hi - lo) * 0.85] {
                if Body.topVisible(ws, i, sx) { spots.append(Spot(x: sx, perch: f.maxY, nearHim: false, perchID: w.id)) }
            }
        }
        let video = watchingVideo ? world.frontWindow() : nil
        // how long his hand has stayed out of her reach (a glance across the screen isn't him moving away)
        let outOfReach = himHere && !typing && !deepFocus && !watchingVideo
            && Double(abs(x + Body.size.width / 2 - c.x)) + Double(max(0, abs(y - c.y) - 350)) * 0.5 > Body.withinReach
        if outOfReach { farSince = farSince ?? world.now } else { farSince = nil }
        let farFor = farSince.map { world.now.timeIntervalSince($0) } ?? 0
        var scored: [(Spot, Double)] = []
        var clear: [Bool] = []
        var crossings: [Double] = []
        for var sp in spots {
            let y = sp.perch ?? screenAt(sp.x + Body.size.width / 2).visibleFrame.minY
            let me = CGRect(x: sp.x, y: y, width: Body.size.width, height: Body.size.height)
            var v = 0.0
            // near him: a comfortable distance from where his hand is
            // (she lives on floors and window tops: his hand high on the screen above her is still
            // near; only height beyond a screen-third counts)
            let d = Double(abs(me.midX - c.x)) + Double(max(0, abs(me.midY - c.y) - 350)) * 0.5
            let near = exp(-pow((d - 230) / 160, 2))
            // (while he works her fondness fading — Soul.drift lowers affection when he's busy — must not
            // make her drift away: she keeps him company)
            var nearW = !himHere ? 0 : (typing ? max(s.affection, 0.5) : s.affection) * (0.4 + s.memory.cling) * (typing ? 0.6 : 1.2)
            let w = wanting
            switch w.want {
            case "be_close": nearW *= 1 + 2 * w.k
            case "get_attention": nearW *= 1 + 3 * w.k
            case "give_space": nearW *= 1 - 0.85 * w.k; v += w.k * min(1, d / 500) * 0.8   // room enough by ~500 pt: no reason to cross the screen
            case "explore": v += w.k * 0.7 * Double(min(1, abs(sp.x - x) / 900))
            case "watch", "rest", "nap", "work_along": if abs(sp.x - x) < 5 { v += 0.8 * w.k }
            default: break
            }
            v += near * nearW
            if typing { v += 0.6 * exp(-d / 600) }      // keeping him company while he works: a little closer is nicer
            sp.nearHim = near > 0.5
            // never on what he's working on: it feels bad, and worse the more she's learned it does
            let way = inTheWay(me)
            v -= way * (1.5 + s.memory.aversion * 2)
            // and getting there shouldn't mean walking across what he's typing in
            var crossed = 0.0
            if (typing || focusCaret != nil || video != nil) && abs(sp.x - x) > 80 {
                var px = x
                let stepX: CGFloat = sp.x > x ? 80 : -80
                while abs(sp.x - px) > 80 {
                    px += stepX
                    let at = CGRect(x: px, y: screenAt(px + Body.size.width / 2).visibleFrame.minY, width: Body.size.width, height: Body.size.height)
                    crossed += inTheWayAt(px) || (video?.intersects(at.insetBy(dx: 30, dy: 0)) ?? false) ? 1 : 0
                }
                v -= min(1.5, crossed * 0.25)
            }
            v -= (me.contains(c) || me.insetBy(dx: -30, dy: -30).contains(c) ? 0.6 : 0)
            v -= attentionUnder(me) * (0.6 + s.memory.aversion * 0.5)     // where his hand has been busy
            // what she has learned about this spot
            v += s.place(me.midX, me.minY) * 1.3
            // curiosity: the screen where things are happening
            if let e = eyes, e.changingRecently, world.screens.first(where: { $0.frame.intersects(me) })?.frame.contains(c) == true {
                v += s.curiosity * 0.25
            }
            // effort, for how tired she is — a jump up is work, a hop down less so; staying put
            // is easy when settled, and a walk she's begun is easy to keep going
            v -= Double(abs(sp.x - x)) / 1500 * (1.2 - s.arousal)
            v -= Double(max(0, y - self.y)) / 900 * (1.2 - s.arousal) + Double(max(0, self.y - y)) / 2500
            let isHere = abs(sp.x - x) < 5 && (sp.perch != nil) == (standingOn != nil)
            // staying put is easy only within reach of him (or while he types, focuses or watches); with
            // him clearly elsewhere and moving, her place pulls little and she goes to him. (The pull to follow
            // used to come from dice: noise on every score and a 4% whim, removed by the no-dice rule.)
            let farFromHim = farFor >= Body.farFor
            if isHere && targetX == nil { v += (0.35 + 0.6 * (1 - s.boredom) + (deepFocus || watchingVideo ? 0.6 : 0)) * (farFromHim ? 0.2 : 1) }
            // while he types and she's out of his way, she stays where she is and keeps him company
            // there
            if isHere && typing && inTheWay(me) < 0.3 { v += 1.4 }   // in his deep focus, or watching with him, stay put       // a comfortable spot is hard to leave
            if let t = targetX, abs(sp.x - t) < 1, sp.perch == perchTop { v += 0.45 }
            if let inv = invited, screenOf(sp.x) == inv { v += 0.8 }
            if let ax = attend, screenOf(sp.x) == screenOf(ax) {
                v += (typing ? 0.25 : 0.9) * exp(-pow(Double(abs(sp.x - ax)) / 280, 2))
            }
            if hurry { v -= Double(abs(sp.x - x)) / 500 }      // getting out of his way: the nearest clear spot        // he's over there: she'd like to be too
            // watching something: never in front of it
            if let fw = video, me.intersects(fw) {
                let i = me.intersection(fw)
                v -= 1.2 * Double(i.width * i.height / (me.width * me.height))
            }
            // she likes a window top beside him, as a trait, not by chance: with the dice gone (136e20bd) she
            // never chose one (sims 21/22: 0 s perched); within reach of him and him not typing, a small fixed liking
            if sp.perch != nil { v += s.curiosity * 0.2 - (typing ? 0.2 : 0) + (!typing && near > 0.3 ? Body.likesPerch : 0) }
            if trace != nil {
                sp.why = String(format: "near %.2f×%.2f way %.2f heat %.2f place %.2f dist %.0f%@ total %.2f",
                                near, nearW, inTheWay(me), attentionUnder(me), s.place(me.midX, me.minY),
                                abs(sp.x - x), sp.perch != nil ? " perch" : "", v)
            }
            scored.append((sp, v))
            // on what he's watching counts like being on what he's typing in
            let onVideo = video.map { fw in me.intersects(fw) && me.intersection(fw).width * me.intersection(fw).height > 0.1 * me.width * me.height } ?? false
            clear.append(way <= 0.3 && !onVideo)
            crossings.append(crossed)
        }
        guard !scored.isEmpty else { return Spot(x: x, perch: standingOn?.maxY, nearHim: false, perchID: standingID) }
        // another screen: only where he has invited her, or when this screen has no spot out of his way
        // (room here = a clear spot she can reach without walking across his work; failing that,
        // the other screen is allowed when getting there crosses less of his work than any clear spot here)
        let here = scored.indices.filter { clear[$0] && screenOf(scored[$0].0.x) == mineIdx }
        let bestHere = here.map { crossings[$0] }.min() ?? .infinity
        let keep = scored.indices.filter { i in
            let si = screenOf(scored[i].0.x)
            return si == mineIdx || si == invited || (typing && bestHere > 0 && clear[i] && crossings[i] < bestHere)
        }
        if !keep.isEmpty && keep.count < scored.count {
            scored = keep.map { scored[$0] }; clear = keep.map { clear[$0] }
        }
        // while he types, a spot on his work is not a choice at all (when there is any other)
        if (typing || video != nil) && clear.contains(true) && clear.contains(false) {
            scored = zip(scored, clear).filter { $0.1 }.map(\.0)
        }
        let mx = scored.map(\.1).max() ?? 0
        // on her way somewhere, she keeps going unless something clearly better turns up
        // (a soft choice among thirty spots turned her back and forth mid-walk)
        if let t = targetX, let inc = scored.first(where: { abs($0.0.x - t) < 1 && $0.0.perch == perchTop }) {
            // (a walk only just begun is harder to give up: turning straight back reads as a twitch)
            if mx - inc.1 < (world.now.timeIntervalSince(walkSince) < 4 ? 0.7 : 0.35) { return inc.0 }
            return scored.max { $0.1 < $1.1 }!.0
        }
        // settled beside him in his deep focus: she stays unless somewhere is clearly better
        if deepFocus && targetX == nil, let here = scored.first(where: { abs($0.0.x - x) < 5 && ($0.0.perch != nil) == (standingOn != nil) }),
           mx - here.1 < 0.5 {
            return here.0
        }
        // the best spot . It was a weighted draw, "the best
        // most of the time, never always", plus random noise on each score and a 4% whim: walks to spots that
        // weren't the best, part of 17 minutes walking in an hour (poses.jsonl 12:54-13:54)
        return scored.max { $0.1 < $1.1 }!.0
    }

    /// How much a rect of hers covers his work: the caret most, the field he's typing in less.
    private func inTheWay(_ me: CGRect) -> Double {
        var bad = 0.0
        if let caret = focusCaret {
            let zone = caret.insetBy(dx: -170, dy: -90)
            if me.intersects(zone) { bad += 1.0 }
        }
        if let field = focusField {
            let z = field.insetBy(dx: -20, dy: -20)
            if me.intersects(z) {
                let i = me.intersection(z)
                bad += 0.8 * Double(i.width * i.height / (me.width * me.height))
                    + (field.width * field.height < 400_000 ? 0.5 : 0)     // a small box: she'd be covering it
            }
        }
        return bad
    }

    private func inTheWayAt(_ px: CGFloat) -> Bool {
        let y = screenAt(px + Body.size.width / 2).visibleFrame.minY
        return inTheWay(CGRect(x: px, y: y, width: Body.size.width, height: Body.size.height)) > 0.3
    }

    private func fallAsleep(_ why: String) {
        if !sleeping { sleepWhy = why }
        if !sleeping { sleptAt = world.now; trace?("fell_asleep", ["sleepiness": soul.sleepiness]) }
        sleeping = true
        targetX = nil
        sit.target = 1
    }

    private func maybeWake(_ p: Double) {
        guard Double.rnd(0...1) < p else { return }
        sleeping = false
        sit.target = 1                          // she sits up; standing is a choice for later
        wideT = 0.3
        armL.kick(-10); armR.kick(-10)          // a stretch
        soul.sleepiness = max(0, soul.sleepiness - 0.4)
    }

    // MARK: the frame — 60 a second

    func frame() {
        let now = world.now
        let dt = CGFloat(min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now
        clock += dt
        // when she last woke (by any path), and how long his screens have kept changing or been still
        if wasAsleep && !sleeping { wokeAt = now; restWhy = "just woke" }
        wasAsleep = sleeping
        if screenMoving { screenMovedAt = now; if screenMovingSince == nil { screenMovingSince = now } } else { screenMovingSince = nil }
        // he stopped after a real stretch of typing (20 s or more, quiet 3 s): she nods, once per stretch
        let burst = lastTyped.timeIntervalSince(typingSince)
        // 30 of these nods in 3 h, then one each half hour; 10-24 (owner: "no
        // reactions"): at most one each Body.nodEveryS (10 min), once per stretch of his typing
        if burst > 20 && now.timeIntervalSince(lastTyped) > 3 && noddedFor != typingSince && !sleeping && !held && !listening
            && performing.isEmpty && targetX == nil && now.timeIntervalSince(noddedAt) > Body.nodEveryS {
            noddedFor = typingSince
            noddedAt = now
            perform("nod", seconds: 1.4, own: true, why: String(format: "his typing stopped after %.0f s", burst))
        }
        keysFromCounter()
        if now.timeIntervalSince(titleCheckedAt) > 1 { titleCheckedAt = now; pageChanged() }
        listenToMusic(now)
        countUse(now)

        // cursor: her eyes are always on it; a sudden flick nearby startles her
        let c = world.mouse
        let moved = hypot(c.x - lastCursor.x, c.y - lastCursor.y)
        cursorSpeed = cursorSpeed * 0.8 + (moved / max(dt, 0.001)) * 0.2
        if moved > 0.5 { touched(); cursorMovedAt = now }   // his hand back on the mouse after a while is him coming back too
        let me = CGPoint(x: x + Body.size.width / 2, y: y + Body.size.height * 0.68)
        let dist = hypot(c.x - me.x, c.y - me.y)
        if cursorSpeed > 3000 && dist < 160 && soul.feel(.cursorFlick, 0.8) > 0.4 && !held {
            wideT = 0.4; if vy == 0 { hop(200) }; lean.kick(c.x > me.x ? -4 : 4)
        }
        touchReactions(now, cursor: c, me: me, dist: dist)
        lastCursor = c
        // which screen he's working on (the caret while he types), and since when
        let his = (now.timeIntervalSince(lastTyped) < 4 ? focusCaret.map { CGPoint(x: $0.midX, y: $0.midY) } : nil) ?? c
        let hs = world.screens.firstIndex { $0.frame.contains(his) }
        if hs != hisScreen { hisScreen = hs; hisScreenSince = now }
        watchAction(now)
        noticeWindows(now)
        if !sleeping && !lookingElsewhere(now) { attend(now, cursor: c, dist: dist) } else { gazeMode = sleeping ? "" : "glance" }
        warm(c, by: dt)
        if now.timeIntervalSince(heatDecayAt) > 2 {
            heatDecayAt = now
            heat = heat.compactMapValues { v in v * 0.97 > 0.05 ? v * 0.97 : nil }   // ~1 min half-life
        }

        // his caret and field (an Accessibility read on this thread) only while he's at the Mac: it
        // keeps her off his work, and every 1.5 s to an empty room it fed nothing
        if now.timeIntervalSince(lastFocusRead) > 1.5 && now.timeIntervalSince(lastInput) < 60 { readFocus() }
        feelInTheWay(dt, now)
        soul.drift(Double(dt), active: now.timeIntervalSince(lastInput) < 30 || watchingVideo || screenMoving,   // a busy screen is not an empty room
                   typingRate: Double(keyTimes.count) / 3 * 60)
        if now >= nextThought { think() }

        checkFullScreen(now, dt)
        if !held { move(dt) }
        bodyClips(now)
        settle(dt, now)
        // sitting with her legs over a window's edge, her picture sits lower: its drawn edge on the window's top
        let at = CGPoint(x: x, y: y - (view?.ledge ?? 0))
        if let w = window, w.frame.origin != at { w.setFrameOrigin(at) }
        bubble?.follow(CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height), avoid: bubbleAvoid())
    }

    /// Her body's own clips that start from what just happened to her body, each with its cause:
    /// the window she stands on moving under her ("teeter"), arriving where she walked off to after he told
    /// her to go away ("sulk"), and Friday's answer to him taking a while ("tap_foot").
    private func bodyClips(_ now: Date) {
        // how long she has sat awake (her sleep, and sitting up from it, don't count toward a long quiet sit)
        let seatedAwake = sit.target > 0.5 && !sleeping
        if seatedAwake && seatedAwakeSince == nil { seatedAwakeSince = now } else if !seatedAwake { seatedAwakeSince = nil }
        if riding && standingOn != nil && !held && !listening {
            if performing == "teeter" { performUntil = max(performUntil, now.addingTimeInterval(1)) }   // still moving: still wobbling
            else if performing.isEmpty || Body.catalog[performing]?["rig"] == "yes" {
                perform("teeter", seconds: 1.6, own: true, why: "his window moved under her feet")
            }
        }
        if let to = shooWalkTo {
            if targetX.map({ abs($0 - to) >= 1 }) == true || held { shooWalkTo = nil }      // another walk, or he picked her up
            else if targetX == nil && vy == 0 && launch == nil {
                shooWalkTo = nil
                perform("sulk", seconds: 4, own: true, why: "he told her to go away")
            }
        }
        if now < awaitingUntil && performing == "think"
            && Stages.impatient(waiting: true, waitedFor: now.timeIntervalSince(awaitingSince), seated: sit.target > 0.5) {
            perform("tap_foot", seconds: awaitingUntil.timeIntervalSince(now), own: true,
                    why: "\(Config.agentName)'s answer is taking over \(Int(Stages.impatientAfter)) s")
        }
    }

    private var lookUntil = Date.distantPast
    private func lookingElsewhere(_ now: Date) -> Bool { now < lookUntil }

    /// `head`: how far her head turns with her eyes (1 for a real look at something, less while she
    /// just keeps an eye on things). Close to her the eyes move less, so his cursor crossing her
    /// face is a smooth sweep, not a flip from one side to the other.
    private func lookToward(_ p: CGPoint, snap: CGFloat, head: CGFloat = 1) {
        let me = CGPoint(x: x + Body.size.width / 2, y: y + Body.size.height * 0.68)
        let dx = p.x - me.x, dy = p.y - me.y
        let d = max(1, hypot(dx, dy))
        gx.target = dx / max(d, 160)
        gy.target = max(-1, min(1, dy / max(d, 200)))
        turn.target = max(-1, min(1, dx / 500)) * head
        if snap >= 0.5 { lookUntil = world.now.addingTimeInterval(Double(snap) * 1.5); gx.kick(dx / d * 8) }
    }

    // MARK: paying attention — between her bigger reactions her eyes are always somewhere
    //
    // . In order: Friday speaking through her, or him
    // talking (the mic heard words): she looks at him, out of the screen, her head toward where he
    // works. His caret while he types. His cursor when it's near her (600 pt). Otherwise where his
    // screen last changed (her eyes' glance, the last 6 s), else his front window. A new window, a
    // new app, a click, a notification are quick glances that hold her eyes a moment (lookToward
    // with snap ≥ 0.5) before this resumes. Her rig moves the eyes and turns, nods and tilts the
    // head (Live: gaze, turn, nod, tilt), so every look is her eyes first and her head a little.

    static let followRange: CGFloat = 600
    /// What her eyes are on (the simulator logs it): him, caret, cursor, change, front, glance.
    private(set) var gazeMode = ""
    private var heardAt = Date.distantPast
    private var frontSeen: CGRect?                       // his front window, as watchAction last read it
    private var changeSeen: (at: Date, point: CGPoint)?   // where his screen last changed, read with it
    private var knownWins: Set<Int>?
    private var winCheckAt = Date.distantPast

    /// He is talking (her ears heard words, to her or not): she looks at him for a moment.
    func heardVoice() {
        heardAt = world.now
        trace?("heard_voice", ["asleep": sleeping])
    }

    private func attend(_ now: Date, cursor c: CGPoint, dist: CGFloat) {
        if now < talkUntil || now.timeIntervalSince(heardAt) < 2.5 { lookAtHim(); gazeMode = "him"; return }
        if now.timeIntervalSince(lastTyped) < 2, let k = focusCaret {
            lookToward(CGPoint(x: k.midX, y: k.midY), snap: 0.25, head: 0.7); gazeMode = "caret"; return
        }
        if dist < Body.followRange { lookToward(c, snap: 0.25, head: 0.6); gazeMode = "cursor"; return }
        if let ch = changeSeen, now.timeIntervalSince(ch.at) < 6 { lookToward(ch.point, snap: 0.2, head: 0.5); gazeMode = "change"; return }
        if let fw = frontSeen { lookToward(CGPoint(x: fw.midX, y: fw.midY), snap: 0.2, head: 0.5); gazeMode = "front"; return }
        lookToward(c, snap: 0.2, head: 0.5); gazeMode = "cursor"
    }

    /// Eye contact: he sits in front of his screen, so her eyes come nearly to the middle (looking
    /// out at him) and her head turns a little toward where he works (his caret or cursor).
    private func lookAtHim() {
        let me = CGPoint(x: x + Body.size.width / 2, y: y + Body.size.height * 0.68)
        let his = (world.now.timeIntervalSince(lastTyped) < 4 ? focusCaret.map { CGPoint(x: $0.midX, y: $0.midY) } : nil) ?? world.mouse
        let dx = his.x - me.x
        gx.target = max(-0.25, min(0.25, dx / 1600))
        gy.target = 0.08
        turn.target = (dx >= 0 ? 1 : -1) * max(0.14, min(0.3, abs(dx) / 1500))
    }

    /// Four times a second: a window that wasn't there a moment ago gets a quick look first.
    private func noticeWindows(_ now: Date) {
        guard now.timeIntervalSince(winCheckAt) >= 0.25 else { return }
        winCheckAt = now
        let wins = world.windows(maxAge: 0.2)
        let ids = Set(wins.map(\.id))
        defer { knownWins = ids }
        guard let known = knownWins, !held, !sleeping,
              let fresh = wins.prefix(3).first(where: { !known.contains($0.id) }) else { return }
        lookToward(CGPoint(x: fresh.frame.midX, y: fresh.frame.midY), snap: 0.8)
        blinkT = max(blinkT, 0.1)
        trace?("glance", ["why": "new_window", "at": [Double(fresh.frame.midX), Double(fresh.frame.midY)]])
    }

    // MARK: getting around — floors, window tops, the seam between his screens
    //
    // Each screen's floor is the bottom of its visible frame, and his screens'
    // floors are not level (the portrait KG241Y's is 520 pt below the Dell's).
    // She never changes height in one frame: she stands on a floor, or on the
    // top of the front window once she has landed on it from above, and gets
    // anywhere higher or lower by a jump she can be seen to make — a crouch,
    // an arc, a landing. To reach another screen she walks to the edge of the
    // one she's on and hops across; she never stops half on two screens.

    static let gravity: CGFloat = 1500
    /// The highest window top she'll jump up to from the floor (2.4× her height).
    static let maxClimb: CGFloat = 470

    private func floorAt(_ px: CGFloat) -> CGFloat { screenAt(px + Body.size.width / 2).visibleFrame.minY }

    /// Where she can stand on a window: its top, her feet within it.
    private func spans(_ w: CGRect, _ px: CGFloat) -> Bool { w.minX - 20 < px && px < w.maxX - Body.size.width + 20 }

    /// The screen she can stand on whole: her x kept inside it.
    private func clampIn(_ d: Display, _ px: CGFloat) -> CGFloat {
        min(d.visibleFrame.maxX - Body.size.width, max(d.visibleFrame.minX, px))
    }

    /// A jump to (tx, ty) along a real arc: a short crouch, then off.
    /// `fromWindow`: why she is hopping off one of his windows (a drop of Stages.jumpDownAtLeast or more
    /// lands as "fall_land", 10-21).
    private func leap(toX tx: CGFloat, toY ty: CGFloat, crouch: Double = 0.16, fromWindow: String? = nil) {
        let g = Body.gravity
        let rise = ty - y
        let apex = max(rise, 0) + 34 + min(50, abs(tx - x) * 0.12)
        let v0 = sqrt(2 * g * apex)
        let flight = (v0 + sqrt(max(0, v0 * v0 - 2 * g * rise))) / g
        launch = (v0, (tx - x) / flight, world.now.addingTimeInterval(crouch))
        jumpDown = fromWindow.flatMap { Stages.jumpsDown(fromWindow: true, drop: Double(-rise)) ? ($0, Double(flight)) : nil }
        leapTo = CGPoint(x: tx, y: ty)
        if tx != x { face.flip = tx < x }
        standingOn = nil; standingID = nil
        // she jumps on her feet: seated on a window that went from under her, she flew down still sitting
        // (sim 21 once she settled beside him, 10-24)
        sit.target = 0; sit.value = 0; sit.vel = 0; workingAlong = false
        trace?("leap", ["from": [Double(x), Double(y)], "to": [Double(tx), Double(ty)], "height": Double(rise)])
    }

    private func move(_ dt: CGFloat) {
        let w = Body.size.width
        // his windows, front to back: asked only when she's on one, in the air, or about to jump up
        var asked = false, cached: [SeenWindow] = []
        var wins: [SeenWindow] { if !asked { asked = true; cached = world.windows(maxAge: 0.1) }; return cached }
        var walking: CGFloat = 0
        riding = false

        // the window she stands on: moved, she goes with it; closed, or its top hidden under another
        // window where she stands, she's on nothing
        if let on = standingOn, vy == 0, launch == nil {
            let ws = wins
            var still: CGRect?
            if let i = ws.firstIndex(where: { $0.id == standingID }) {
                var fw = ws[i].frame
                if fw.size == on.size && fw.minX != on.minX { x += fw.minX - on.minX; riding = true }   // dragged: she rides along
                fw = ws[i].frame
                if spans(fw, x) && Body.topVisible(ws, i, x) { still = fw }
            }
            if let fw = still {
                y = fw.maxY
                riding = riding || fw != on
                standingOn = fw
            } else {
                // the window went or moved out from under her: she notices and hops down beside, never just drops
                trace?("window_left_her", ["x": Double(x), "y": Double(y)])
                standingOn = nil; standingID = nil
                if soul.feel(.dropped, 0.3) > 0.2 { wideT = 0.5 }
                let scr = screenAt(x + w / 2)
                let land = clampIn(scr, x + (x + w / 2 < scr.frame.midX ? 1 : -1) * 60)
                leap(toX: land, toY: floorAt(land), crouch: 0.25, fromWindow: "his window went from under her")
            }
        }
        moved = false
        // her display was rearranged (same monitor, new place in the layout): she stays where she was on it
        if let id = myScreen?.id, id != 0, let d = world.screens.first(where: { $0.id == id }), let old = myScreen?.frame,
           d.frame.origin != old.origin, !held {
            x += d.frame.minX - old.minX; y += d.frame.minY - old.minY
            targetX = nil; perchTop = nil; perchID = nil; standingOn = nil; standingID = nil; launch = nil; leapTo = nil; vx = 0
            trace?("display_moved", ["dx": Double(d.frame.minX - old.minX), "dy": Double(d.frame.minY - old.minY)])
            moved = true
        }
        // the floor dropped away under her feet (the Dock hid itself): she hops down, she doesn't fall
        if vy == 0 && launch == nil && standingOn == nil && !held, let lf = lastFloor, abs(y - lf) < 0.5 {
            let f = floorAt(x)
            if f < lf - 2 && f > lf - 400 { leap(toX: x, toY: f, crouch: 0.08) }
        }
        // a screen went away or moved: back onto one
        let here = screenAt(x + w / 2)
        if !(here.frame.minX <= x + w / 2 && x + w / 2 < here.frame.maxX) || x < here.visibleFrame.minX - w || x > here.visibleFrame.maxX {
            x = clampIn(here, x)
            if y < here.visibleFrame.minY || y > here.visibleFrame.maxY { y = here.visibleFrame.minY; vy = 0 }
            targetX = nil; perchTop = nil; perchID = nil; standingOn = nil; standingID = nil; launch = nil; leapTo = nil; vx = 0
            trace?("relocated", ["x": Double(x), "y": Double(y)])
        }

        if let l = launch {
            // crouching, about to jump
            if world.now >= l.at {
                vy = l.vy; vx = l.vx; launch = nil
                squash.kick(2.5)
                // off his window and down: the falling frames in the air, the landing when her feet touch
                // (SpriteView "@fall_land"); she stays where she lands until it's done, then walks on
                if let j = jumpDown, !held, performing.isEmpty || Body.catalog[performing]?["rig"] == "yes" {
                    trace?("act", ["what": "fall_land", "why": j.why])
                    actWhy = j.why; performing = "fall_land"; performMoves = false
                    performUntil = world.now.addingTimeInterval(j.flight + 0.9)
                }
                jumpDown = nil
            }
        } else if vy != 0 || y > groundBelow() + 0.5 {
            // in the air: the arc carries her; she lands on what's under her when coming down
            let prevY = y
            vy -= Body.gravity * dt
            x += vx * dt
            y += vy * dt
            if vx != 0 { face.flip = vx < 0 }
            if vy <= 0 {
                // a leap lands where it was aimed: nothing higher on the way counts (a hop down
                // off the Dell's edge came down on the Dell's floor, short of the seam)
                let aim = leapTo?.y ?? .greatestFiniteMagnitude          // a plain hop lands on anything
                let ws = wins
                if let i = ws.indices.filter({ i in let f = ws[i].frame
                        return f.maxY <= aim + 1 && spans(f, x) && prevY >= f.maxY - 1 && y <= f.maxY && Body.topVisible(ws, i, x) })
                    .max(by: { ws[$0].frame.maxY < ws[$1].frame.maxY }) {
                    land(ws[i].frame.maxY); standingOn = ws[i].frame; standingID = ws[i].id
                } else {
                    let floor = floorAt(x)
                    if y <= floor && (floor <= aim + 1 || y <= aim) { land(floor) }
                }
            }
        } else if performing == "fall_land" && world.now < performUntil {
            // landed from his window: feet planted while the landing plays
        } else if var t = targetX {
            let cur = screenAt(x + w / 2)
            let dest = screenAt(t + w / 2)
            if clampIn(dest, t) != t { t = clampIn(dest, t); targetX = t }     // never aimed off a screen
            let onWindow = standingOn != nil
            if onWindow, let on = standingOn, !(perchTop != nil && perchID == standingID && spans(on, t)) {
                // leaving the window top: a hop down toward where she's going
                let land = clampIn(cur, x + (t > x ? 1 : -1) * min(150, abs(t - x)))
                leap(toX: land, toY: floorAt(land), crouch: 0.12, fromWindow: "jumping down from his window: " + walkWhy)
            } else if !onWindow && dest.frame != cur.frame {
                // another screen: to the edge of this one, whole, then across
                let left = dest.frame.midX < cur.frame.midX
                let edge = left ? cur.visibleFrame.minX : cur.visibleFrame.maxX - w
                let floorThere = dest.visibleFrame.minY
                let touching = left ? abs(dest.frame.maxX - cur.frame.minX) < 1 : abs(dest.frame.minX - cur.frame.maxX) < 1
                if touching && abs(floorThere - y) < 6 {
                    walking = step(toward: t, dt)                  // level floors: she just walks on
                } else if abs(edge - x) > 2 {
                    walking = step(toward: edge, dt)
                } else {
                    let land = left ? max(t, dest.visibleFrame.maxX - w - 130) : min(t, dest.visibleFrame.minX + 130)
                    leap(toX: land, toY: floorThere)
                }
            } else if let top = perchTop, !onWindow, abs(t - x) <= 170 {
                // up onto the window, from a few steps away — if it's still there with its top showing
                let ws = wins
                if let i = ws.firstIndex(where: { $0.id == perchID }), abs(ws[i].frame.maxY - top) < 2,
                   spans(ws[i].frame, t), Body.topVisible(ws, i, t) {
                    leap(toX: t, toY: top)
                } else { perchTop = nil; perchID = nil; think(soon: 0.3) }
            } else if abs(t - x) < 3 {
                targetX = nil
            } else {
                walking = step(toward: t, dt)
            }
        }
        if targetX == nil { lean.target = 0 }
        // the floor rose under her (a Dock appeared): she steps up, never sinks into it
        if vy == 0 && launch == nil && standingOn == nil {
            let floor = floorAt(x)
            if y < floor - 0.5 { if floor - y < 30 { y = floor } else { leap(toX: x, toY: floor, crouch: 0) } }
        }
        // standing half on two screens (he set her down on the seam): a few steps onto one
        if vy == 0 && launch == nil && targetX == nil && standingOn == nil
            && !world.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(CGRect(x: x, y: y, width: w, height: Body.size.height)) }) {
            let scr = screenAt(x + w / 2)
            let tx = clampIn(scr, x)
            if abs(tx - x) > 1 { targetX = tx; perchTop = nil; speed = max(speed, 60) }
        }
        currentWalk += (walking - currentWalk) * min(1, dt * 10)
        let mine = screenAt(x + w / 2)
        myScreen = (mine.id, mine.frame)
        lastFloor = vy == 0 && launch == nil && standingOn == nil ? floorAt(x) : nil
    }
    private var myScreen: (id: UInt32, frame: CGRect)?
    private var lastFloor: CGFloat?
    private var moved = false

    // MARK: his full-screen picture
    //
    // A full-screen app (a film, a game, a full-screen editor) is his whole screen: she steps out of
    // it — fades, and reappears on his other screen near the seam — or, with one screen, stays out
    // of sight until it ends. `defaults write app.iris.companion IrisOverFullScreen -bool YES` lets
    // her stay over it. (Her window keeps .fullScreenAuxiliary so she can live on his other screen
    // while one is full screen, and so this opt-in works.)

    private var fsCheckAt = Date.distantPast
    private(set) var fullScreenFrame: CGRect?
    private var alpha: CGFloat = 1
    private var fade: (to: CGFloat, then: (() -> Void)?)?

    private func checkFullScreen(_ now: Date, _ dt: CGFloat) {
        // fading: 0.25 s either way, then whatever comes next
        if let f = fade {
            alpha += (f.to > alpha ? 1 : -1) * dt / 0.25
            if (f.to > 0.5 && alpha >= f.to) || (f.to < 0.5 && alpha <= f.to) { alpha = f.to; fade = nil; f.then?() }
        }
        window?.alphaValue = alpha
        guard now.timeIntervalSince(fsCheckAt) > 1 else { return }
        fsCheckAt = now
        if UserDefaults.standard.bool(forKey: "IrisOverFullScreen") { fullScreenFrame = nil; return }
        let fs = world.frontWindow().flatMap { w in
            world.screens.first { abs($0.frame.minX - w.minX) < 2 && abs($0.frame.maxX - w.maxX) < 2
                && abs($0.frame.minY - w.minY) < 2 && abs($0.frame.maxY - w.maxY) < 2 }
        }
        let was = fullScreenFrame
        fullScreenFrame = fs?.frame
        let mine = screenAt(x + Body.size.width / 2)
        if let fs, fs.frame == mine.frame, !held, fade == nil, alpha > 0.5 {
            trace?("full_screen", ["stepping_out": true])
            fade = (0, { [weak self] in
                guard let self else { return }
                if let other = world.screens.first(where: { $0.frame != fs.frame }) {
                    // reappear on his other screen, near where it meets this one
                    let nearRight = other.frame.midX > fs.frame.midX
                    self.x = self.clampIn(other, nearRight ? other.visibleFrame.minX + 60 : other.visibleFrame.maxX - Body.size.width - 60)
                    self.y = other.visibleFrame.minY
                    self.targetX = nil; self.perchTop = nil; self.perchID = nil; self.standingOn = nil; self.standingID = nil
                    self.vy = 0; self.vx = 0; self.launch = nil; self.leapTo = nil
                    self.hisScreenSince = world.now          // she's here now; no hurry back
                    self.placedAt = world.now
                    self.fade = (1, nil)
                }
                // one screen: she stays out of sight until it ends
            })
        } else if was != nil && fs == nil && alpha < 0.5 && fade == nil {
            fade = (1, nil)                               // his full-screen picture ended: back
        }
    }

    /// What she'd land on straight below her now.
    private func groundBelow() -> CGFloat {
        if standingOn != nil { return y }
        return floorAt(x)
    }

    /// A little jump for joy or fright where she stands; sitting (or about to), she
    /// bounces in her seat instead — a hop would stand her up and sit her down again.
    private func hop(_ v: CGFloat) {
        guard launch == nil, !held else { return }
        if sit.target > 0.5 || sit.value > 0.3 || sleeping { squash.kick(v / 110); tilt.kick(Bool.rnd() ? 0.5 : -0.5); return }
        if vy == 0 { vy = v }
    }

    private func land(_ g: CGFloat) {
        if vy < -300 { squash.kick(-CGFloat(min(3, -vy / 300))) }
        y = g; vy = 0; vx = 0; leapTo = nil
        if let f = fall {
            fall = nil
            if f.fromY - g > 200 && world.now.timeIntervalSince(f.at) < 5 { poutT = 0; touchClip("getup", 2.4, "fell") }
        }
    }

    /// One frame of walking toward px; 1 while her feet are moving.
    private func step(toward px: CGFloat, _ dt: CGFloat) -> CGFloat {
        let dx = px - x
        guard abs(dx) >= 1 else { x = px; return 0 }
        let stepX = min(abs(dx), speed * dt)
        x += (dx > 0 ? 1 : -1) * stepX
        walkPhase += stepX / 105 * 2 * .pi         // one full stride cycle per 105 points: feet don't slide
        face.flip = dx < 0
        if speed > 250 { lean.target = dx > 0 ? -0.18 : 0.18 }
        return 1
    }
    private var vx: CGFloat = 0
    private var leapTo: CGPoint?
    private var launch: (vy: CGFloat, vx: CGFloat, at: Date)?
    private var standingOn: CGRect?             // the window top she's on
    private var standingID: Int?                // … which window (the window server's id)
    private var perchID: Int?                   // the window whose top she's heading for

    /// Whether window i's top edge is showing where her feet would be at px: no window in
    /// front of it covers that stretch of its top.
    static func topVisible(_ ws: [SeenWindow], _ i: Int, _ px: CGFloat) -> Bool {
        let top = ws[i].frame.maxY - 2
        let feet = [px + 35, px + size.width / 2, px + size.width - 35]
        return !ws[..<i].contains { w in feet.contains { w.frame.contains(CGPoint(x: $0, y: top)) } }
    }

    /// Which screen he is working on now and since when (the caret while he types, else his cursor).
    private var hisScreen: Int?
    private var hisScreenSince = Date.distantPast
    /// She changes screens on her own only once he has been working on the other one this long.
    static let screenStay: Double = 120

    // MARK: where the action is 
    //
    // His front window is where his day is happening. Once it has settled on his other screen
    // (moved there, or he clicked into a window there) for 20 s with him there too, she notices
    // and crosses over to sit near it — walking to the edge and hopping across as always. On her
    // own screen she drifts, slowly, to a spot beside it (never under his caret or field: the
    // bubble's avoid list). A call (another app has the mic) or his full-screen film sends her
    // to a corner to sit and watch, quietly; ten minutes with nothing happening, home.

    /// The front window has to stay on the other screen this long before she goes to it.
    static let withinReach: Double = 500       // pt from his hand: farther for farFor, and him busy elsewhere, her place pulls little
    static let settleAfter: Double = 180       // s standing near him with no walk, then she sits beside him (10-24)
    static let likesPerch: Double = 0.25       // her liking for a window top beside him (a trait, 10-24)
    static let farFor: Double = 20             // s his hand stays out of reach before she goes to him
    static let crossSpeed: CGFloat = 320       // pt/s on her way to the screen he's working on (a run)
    static let frontStay: Double = 60          // 10-24: was 20 s (owner 10-14 "super responsive"); 8 crossings in 45 min (owner 10-24 "walks from one screen to another"); with her run across (08382125) a minute balances both
    /// Nothing happening for this long and she goes to her favourite spot.
    static let homeAfter: Double = 600
    // 10-21 pose log: "typing along with him" 74 times in 3 h, in and out with every burst of keys
    static let typeAlongAfterS: Double = 15     // his typing this long: her laptop comes out (was 4)
    static let typeAlongHoldS: Double = 90      // and goes away this long after his last key (was 20)
    static let yawnEveryS: Double = 1800        // her late-night yawn, at most this often
    static let dizzyEveryS: Double = 1800       // her "@_@" at his fast scrolling, at most this often
    static let danceEveryS: Double = 1200       // her dance to music: 30 s after it starts, then at most this often
    static let nodEveryS: Double = 600          // her nod when a stretch of his typing stops, at most this often (10-24: was 30 min; owner "no reactions")

    // MARK: awake with him ("she mostly sleeps and waves when I'm at my pc, sits and
    // blinks"; her poses.jsonl that night: woken and asleep again within a minute 21 times, 40 waves,
    // 33 stand-sit-stand flips inside a minute, asleep 58% of the hours he was at the Mac)

    /// Once woken she stays up at least this long (a wake that lasts 2-30 s reads as a flicker).
    static let wakeHolds: Double = 150
    /// Only a screen that keeps changing this long wakes her — a few seconds of terminal output is a flicker.
    static let screenWakeAfter: Double = 20
    /// She dozes only once his screens have been still this long: a chat he's reading that moves every
    /// half minute is him there, not an empty room (her eyes' "changing" lasts only 8 s after a change).
    static let screenStillToDoze: Double = 60
    /// Away this long, his return gets the hop and the wave; a shorter pause (reading) only a look.
    static let trulyAway: Double = 300
    /// Seated, she stays seated at least this long, and gets up only to go somewhere worth it.
    static let sitHolds: Double = 60
    static let seatedStep: CGFloat = 160
    private var wokeAt = Date.distantPast
    private var wasAsleep = false
    private var screenMovedAt = Date.distantPast        // his screens last changed (her eyes, or the sim)
    private var screenMovingSince: Date?                // and have kept changing since
    private var lastYawnAt = Date.distantPast
    // her body's own clips: the doze before sleep, the walk-off when he shoos her, the jump
    // down from his window, and when Friday's answer is taking a while
    private var dozeWhy: String?                        // nodding off: falls asleep with this cause when the doze ends
    private var dozeInputAt = Date.distantPast          // his last input when the doze began (any newer wakes her)
    private var shooWalkTo: CGFloat?                    // where she is walking off to after "go away"
    private var jumpDown: (why: String, flight: Double)?   // a hop off his window, about to launch
    private var awaitingSince = Date.distantPast
    private var seatedAwakeSince: Date?
    private var noddedFor = Date.distantPast            // the burst of his typing she last nodded at
    private var noddedAt = Date.distantPast             // when she last nodded at one (Body.nodEveryS apart)
    // what each of her bodies is for, this moment — the cause in the world (Face.why, poses.jsonl)
    private var actWhy = "", sleepWhy = "", waveWhy = "", walkWhy = "", restWhy = ""
    /// The cause of each touch clip, in his terms.
    static let touchWhy = ["pet": "he petted her", "pets": "he petted her again and again", "double_click": "he double-clicked her",
                           "hover": "his cursor rested on her", "hover_again": "his cursor rested on her a third time in a minute",
                           "cursor_play": "his cursor darted past her again and again", "fall": "she fell when he let go of her"]
    private var frontScreen: Int?                       // which screen his front window is on
    private var frontScreenSince = Date.distantPast
    private var frontNoticed = false
    private var placedAt = Date.distantPast             // he carried her, or she stepped out of his full screen
    private var actionCheckAt = Date.distantPast
    private var attendAt = Date.distantPast
    private var attendX: CGFloat?                       // beside his front window, re-picked every ~10 s
    private var callSince: Date?
    private var callCorner: CGFloat?           // her corner for this call, chosen at its start

    private var myScreenIndex: Int? {
        let mid = x + Body.size.width / 2
        return world.screens.firstIndex { $0.frame.minX <= mid && mid < $0.frame.maxX }
    }

    /// His other screen, when his front window has settled there for Body.frontStay (2 min) and he's working there
    /// too (his caret or cursor) — and not just after he carried her here, unless he moved it since.
    private var frontInvite: Int? {
        guard let f = frontScreen, f < world.screens.count, f != myScreenIndex, hisScreen == f,
              world.now.timeIntervalSince(frontScreenSince) >= Body.frontStay,
              frontScreenSince > placedAt || world.now.timeIntervalSince(placedAt) >= Body.screenStay,
              world.screens[f].frame != fullScreenFrame else { return nil }
        return f
    }

    /// Twice a second: where his front window is, whether a call is on, and the spot beside his window.
    private func watchAction(_ now: Date) {
        guard now.timeIntervalSince(actionCheckAt) >= 0.5 else { return }
        actionCheckAt = now
        if world.callOn {
            if callSince == nil { callSince = now; trace?("call", ["on": true]); think(soon: 3.2) }
        } else if callSince != nil {
            callSince = nil; callCorner = nil; trace?("call", ["on": false]); think(soon: 2)
        }
        let fw = world.frontWindow()
        frontSeen = fw
        changeSeen = eyes?.changeSpot ?? world.screenChange
        let fs = fw.flatMap { f in world.screens.firstIndex { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) } }
        if fs != frontScreen { frontScreen = fs; frontScreenSince = now; frontNoticed = false; attendAt = .distantPast }
        // noticing: a look at it, a curious face, and soon she's on her way
        if !frontNoticed, frontInvite != nil, let fw, !held, !sleeping {
            frontNoticed = true
            lookToward(CGPoint(x: fw.midX, y: fw.midY), snap: 0.8)
            curiousT = 0.8
            trace?("noticed_front", ["screen": fs ?? -1])
            think(soon: 0.8)
        }
        if now >= attendAt {
            attendAt = now.addingTimeInterval(10)
            let was = attendX
            attendX = fw.flatMap { besideFront($0) }
            // it moved well away from her: she reconsiders soon (not while he types — she stays with him)
            if let ax = attendX, abs(ax - x) > 250, was.map({ abs($0 - ax) > 200 }) ?? true,
               now.timeIntervalSince(lastTyped) > 4, targetX == nil, standingOn == nil, !sleeping {
                think(soon: 1.5)
            }
        }
    }

    /// A spot on the floor beside his front window, on the screen it's on: just outside one of its
    /// sides, or failing that just inside an edge (a maximized window), nearest her — never in his way,
    /// under his caret, field or cursor. Nil when no spot is clear.
    private func besideFront(_ fw: CGRect) -> CGFloat? {
        guard let d = world.screens.first(where: { $0.frame.contains(CGPoint(x: fw.midX, y: fw.midY)) }),
              d.frame != fullScreenFrame else { return nil }
        let w = Body.size.width, vf = d.visibleFrame
        let avoid = bubbleAvoid()
        func ok(_ cx: CGFloat) -> Bool {
            let r = CGRect(x: cx, y: vf.minY, width: w, height: Body.size.height)
            return inTheWay(r) <= 0.3 && !avoid.contains { $0.intersects(r) } && !r.insetBy(dx: -30, dy: -30).contains(world.mouse)
        }
        let tiers: [[CGFloat]] = [
            [fw.minX - w - 12, fw.maxX + 12].filter { $0 >= vf.minX && $0 <= vf.maxX - w },
            [fw.minX + 24, fw.maxX - w - 24].map { clampIn(d, $0) },
            [clampIn(d, fw.midX - w / 2)],
        ]
        for t in tiers {
            if let best = t.filter(ok).min(by: { abs($0 - x) < abs($1 - x) }) { return best }
        }
        return nil
    }

    /// Where she sits while a call is on or his film fills a screen, or nil. A call: out of its
    /// way — on the screen without the call, in the corner farthest from it (one screen: the corner
    /// farthest from the call's window). His film: the corner of his other screen nearest it, to watch.
    private func watchCorner() -> CGFloat? {
        let w = Body.size.width, screens = world.screens
        guard !screens.isEmpty else { return nil }
        if let since = callSince, world.now.timeIntervalSince(since) >= 3 {
            // 10-24 poses.jsonl (his 10:41-11:35 call): she walked to a new corner six times, because the corner
            // was worked out from whatever he had in front, and he clicked between apps during the call. The
            // corner chosen at the call's start is hers for the call, unless it's in his way or the screens changed.
            if let c = callCorner, screens.contains(where: { $0.visibleFrame.minX <= c && c + w <= $0.visibleFrame.maxX }),
               !inTheWayAt(c) { return c }
            let fw = world.frontWindow()
            let at = fw.map { CGPoint(x: $0.midX, y: $0.midY) } ?? world.mouse
            let callScr = screens.first { $0.frame.contains(at) } ?? screenAt(at.x)
            let d = screens.filter { $0.frame != callScr.frame && $0.frame != fullScreenFrame }
                .min { abs($0.frame.midX - at.x) < abs($1.frame.midX - at.x) } ?? callScr
            let left = d.visibleFrame.minX + 24, right = d.visibleFrame.maxX - w - 24
            callCorner = abs(left + w / 2 - at.x) > abs(right + w / 2 - at.x) ? left : right
            return callCorner
        }
        if let fs = fullScreenFrame, Body.isVideo(app: world.frontApp ?? "", title: world.frontTitle) || world.soundOn,
           let other = screens.filter({ $0.frame != fs }).min(by: { abs($0.frame.midX - fs.midX) < abs($1.frame.midX - fs.midX) }) {
            return other.frame.midX < fs.midX ? other.visibleFrame.maxX - w - 24 : other.visibleFrame.minX + 24
        }
        return nil
    }

    /// Her favourite spot: the floor place she has come to like best (petted there, set down
    /// there), on a screen that's here now. Nil until she has one.
    private func favouriteSpot() -> CGFloat? {
        var best: (x: CGFloat, v: Double)?
        for (k, v) in soul.memory.places where v >= 0.25 {
            let p = k.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2 else { continue }
            let mid = CGFloat(p[0]) * 70 + 35
            guard let d = world.screens.first(where: { $0.frame.minX <= mid && mid < $0.frame.maxX && $0.frame != fullScreenFrame }),
                  Int((d.visibleFrame.minY / 140).rounded(.down)) == p[1] else { continue }
            let hx = clampIn(d, mid - Body.size.width / 2)
            if inTheWayAt(hx) { continue }
            if best == nil || v > best!.v || (v == best!.v && hx < best!.x) { best = (hx, v) }
        }
        return best?.x
    }

    private var riding = false
    private var hurry = false
    private var focusSince = Date.distantPast      // when his current stretch of typing began
    private var deepFocus = false                  // he's been typing steadily a couple of minutes
    private var satSince = Date.distantPast
    private var walkSince = Date.distantPast       // when she set off for where she's going
    private var wayThoughtAt = Date.distantPast
    private var currentWalk: CGFloat = 0
    private var lastX: CGFloat = 0
    private var focusCaret: CGRect?
    private var focusField: CGRect?
    private var lastTyped = Date.distantPast
    private var typingSince = Date.distantPast
    private var typeAlongAfter = 12.0
    private var shortcutAt = Date.distantPast, undos: [Date] = []
    private var lastFocusRead = Date.distantPast
    private var wayT: CGFloat = 0
    private var pickedUpAt: CGPoint?
    private var keyCount = 0
    private var saccade = CGPoint.zero
    private var nextSaccade = world.now
    private var lastFaceX: CGFloat = 0
    private var sleptAt = world.now
    private var performing = ""                 // a library animation (Resources/anim/<id>)
    private var performUntil = Date.distantPast
    private var performMoves = false
    private var noticedAt = world.now             // when he last paid her any attention
    private var events: [String] = []          // what happened since her mind last thought
    // His pets, shoos and drags with their times (/iris/health "touches"), kept, not taken:
    // Core's reflex reads them every tick to learn which of her reactions he likes.
    private var touches: [(what: String, at: Date)] = []
    static let catalog: [String: [String: String]] = {
        // in the app bundle; run from .build/ (the simulator), from the package's Resources
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let dev = ["../../Resources/catalog.json", "../../../Resources/catalog.json"]      // .build/release or .build/<arch>/release
            .map { exe.appendingPathComponent($0).standardizedFileURL }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let u = Bundle.main.url(forResource: "catalog", withExtension: "json") ?? dev,
              let d = try? Data(contentsOf: u), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return [:] }
        return Dictionary(a.compactMap { e in e["id"].map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
    }()
    private var workingAlong = false
    private var dizzyAt = Date.distantPast
    private var farSince: Date?
    private var want = ""                         // what her mind feels like doing (core/iris), a leaning
    private var wantStrength = 0.0
    private var wantUntil = Date.distantPast
    private var postureUntil = world.now
    private var heat: [Int: CGFloat] = [:]      // where his hand has been lately (80-pt cells), fading
    private var heatDecayAt = world.now

    private func settle(_ dt: CGFloat, _ now: Date) {
        for t in [\Body.happyT, \Body.wideT, \Body.winceT, \Body.dizzyT, \Body.giggleT, \Body.waveT, \Body.typeT,
                  \Body.catT, \Body.poutT, \Body.sparkleT, \Body.sweatT, \Body.blinkT, \Body.curiousT] {
            self[keyPath: t] = max(0, self[keyPath: t] - dt)
        }
        emoteAge += dt
        scrollEnergy = max(0, scrollEnergy - dt * 120)
        if now >= blinkAt && !sleeping {
            blinkT = 0.13
            blinkAt = now.addingTimeInterval(-log(Double.rnd(0.05...1)) * 3.2 + 0.6)
            if Double.rnd(0...1) < 0.12 { blinkAt = now.addingTimeInterval(0.25) }   // a double blink
        }
        let s = soul
        // arms: typing along, waving, flailing when held, at rest otherwise
        if held {
            wideT = max(wideT, 0.1)                            // surprised the whole time she's carried
            armL.target = 2.6 + sin(clock * 22) * 0.4; armR.target = 2.6 + cos(clock * 22) * 0.4
        } else if waveT > 0 {
            armR.target = 2.5 + sin(clock * 14) * 0.45; armL.target = 0.2
        } else if typeT > 0 {
            armL.target = -0.62; armR.target = -0.62           // hands forward, on a keyboard only she can see
        } else if sleeping {
            armL.target = -0.35; armR.target = -0.35
        } else {
            armL.target = 0.15 + sin(clock * 1.3) * 0.04; armR.target = 0.15 + cos(clock * 1.1) * 0.04
        }
        if sleeping { tilt.target = 0.32; sit.target = 1 } else if !listening { tilt.target = CGFloat(s.curiosity - 0.5) * 0.12 }
        if listening { sit.target = listenSeated ? 1 : 0; tilt.target = 0.12; turn.target = 0; gx.target = 0; gy.target = 0.3 }

        smile.target = CGFloat(s.valence) * 0.8 + (happyT > 0 ? 0.6 : 0)
        brow.target = s.valence < -0.2 ? -0.6 : (s.curiosity > 0.7 ? 0.5 : 0) + (wideT > 0 ? 1 : 0)
        blush.target = 0.1 + CGFloat(s.affection) * 0.35 + (hovering ? 0.4 : 0)
        lid.target = sleeping ? 1 : CGFloat(s.sleepiness) * 0.55 + (watchingVideo ? 0.1 : 0)

        turn.step(dt); tilt.step(dt); lean.step(dt); armL.step(dt, k: 220, d: 16); armR.step(dt, k: 220, d: 16)
        sit.step(dt); gx.step(dt, k: 300, d: 26); gy.step(dt, k: 300, d: 26)
        smile.step(dt); brow.step(dt); blush.step(dt); lid.step(dt, k: 200, d: 24)
        squash.target = launch != nil ? -1.4 : 0          // crouched before a jump
        squash.step(dt, k: 260, d: 12)
        // hair follows the head late
        // hair trails behind her movement and flies on a jump, then settles
        let vx = (x - lastX) / max(dt, 0.001)
        lastX = x
        hairSway.target = max(-0.12, min(0.12, -vx * 0.00035 - turn.vel * 0.01 - lean.value * 0.4))
        if vy != 0 { hairSway.kick(CGFloat.rnd(-0.4...0.4)) }
        hairSway.step(dt, k: 60, d: 6)

        var f = face
        f.turn = turn.value; f.tilt = tilt.value; f.lean = lean.value
        f.hop = vy == 0 ? currentWalk * abs(sin(walkPhase)) * 3 : min(40, abs(vy) / 20)
        f.squash = squash.value * 0.08
        f.walk = currentWalk; f.walkPhase = walkPhase
        f.sit = max(0, min(1, sit.value))
        // a blink closes fast and opens a little slower, through every lid depth; or heavy eyes when sleepy
        let blinkP = 1 - blinkT / 0.13
        let blinkLid = blinkT > 0 ? (blinkP < 0.4 ? blinkP / 0.4 : (1 - blinkP) / 0.6) : 0
        f.lid = max(blinkLid, max(0, min(0.8, lid.value)))
        f.mood = smile.value
        f.held = held
        f.happyEyes = happyT > 0 || giggleT > 0 ? 1 : 0
        f.wide = wideT > 0 ? 1 : 0
        f.dizzy = dizzyT > 0 ? 1 : 0
        f.wince = winceT > 0 || sweatT > 0.8 ? 1 : 0
        f.cat = catT > 0 ? 1 : 0
        f.pout = poutT > 0 ? 1 : 0
        f.blush = max(0, blush.value)
        f.breathe = CGFloat(sin(Double(clock) * (sleeping ? 1.4 : 2.2)))
        f.emote = emote; f.emoteAge = emoteAge
        f.sleeping = sleeping
        f.listening = listening
        f.talking = now < talkUntil
        // lips at a speaking rhythm, irregular like real speech
        f.mouthOpen = f.talking ? (sin(Double(clock) * 9 + sin(Double(clock) * 2.3) * 2) > -0.1 ? 1 : 0) : 0
        f.hint = waveT > 0 ? "wave" : workingAlong ? "typing" :
            (watchingVideo && sit.target > 0.5 ? "watching" : (curiousT > 0 ? "curious" : ""))
        // the cause of what she's doing, in the world (poses.jsonl's why, 10-15)
        // 10-20 pose log: chase (his cursor flicking past her), sunset_watch, syntax_sparkles were logged
        // "\(Config.agentName) speaking through her" because talking outranked the clip's own cause; a clip she is
        // performing keeps its own cause.
        f.why = held ? "he's carrying her" : listening ? "he's talking to her" : !performing.isEmpty ? actWhy
            : now < talkUntil ? "\(Config.agentName) speaking through her" : sleeping ? sleepWhy : waveT > 0 ? waveWhy
            : currentWalk > 0.05 ? walkWhy : workingAlong ? "typing along with him" : restWhy
        f.hairSway = hairSway.value
        f.keys = keyCount
        // eyes: where she's looking, with the tiny darting movements real eyes make
        if now >= nextSaccade {
            saccade = CGPoint(x: CGFloat.rnd(-0.18...0.18), y: CGFloat.rnd(-0.12...0.12))
            nextSaccade = now.addingTimeInterval(Double.rnd(0.35...2.2))
        }
        // following his moving cursor the eyes pursue smoothly; looking at him they hold steady
        let jit: CGFloat = gazeMode == "him" ? 0.35 : (gazeMode == "cursor" && cursorSpeed > 60) ? 0.3 : 1
        f.gaze = CGPoint(x: max(-1, min(1, gx.value + saccade.x * jit)), y: max(-1, min(1, gy.value + saccade.y * jit)))
        f.vx = (x - lastFaceX) / max(dt, 0.001)
        lastFaceX = x
        f.clock = clock
        if !performing.isEmpty && now >= performUntil {
            let ended = performing
            performing = ""; performMoves = false; think(soon: Double.rnd(1...4))
            // the doze ran its course with nothing waking her: asleep
            if ended == "doze", let why = dozeWhy {
                dozeWhy = nil
                if Stages.dozeEndsInSleep(inputSinceDozeBegan: lastInput != dozeInputAt, held: held, listening: listening) {
                    fallAsleep(why); f.sleeping = true
                }
            }
        }
        // deep asleep (Stages.deepSleepAfter): she snores, sitting up, instead of her sleep pose
        let snoring = performing.isEmpty && Stages.snoring(asleep: sleeping, asleepFor: now.timeIntervalSince(sleptAt))
        f.act = snoring ? "snore" : performing
        if snoring { f.why = String(format: "deep asleep: asleep %.0f min or more (%@)", Stages.deepSleepAfter / 60, sleepWhy) }
        // how she walks when her walk's cause changes it, and what she does seated when a drawn clip says
        // it better than her sit pose — each from her state (Stages), its why in poses.jsonl
        let walkingNow = currentWalk > 0.05 && !held && !listening
        f.gait = Stages.gait(walking: walkingNow, inAir: vy != 0 || launch != nil,
                             shooed: shooWalkTo != nil && targetX.map { abs($0 - shooWalkTo!) < 1 } == true, walkWhy: walkWhy)
        let seat = Stages.seat(seated: sit.target > 0.5 && performing.isEmpty, onWindow: standingOn != nil && vy == 0,
                               typingAlong: workingAlong, watchingVideo: watchingVideo, asleep: sleeping, listening: listening,
                               talking: now < talkUntil, seatedFor: seatedAwakeSince.map { now.timeIntervalSince($0) } ?? 0,
                               hisIdle: now.timeIntervalSince(lastInput), sinceKeys: now.timeIntervalSince(lastTyped),
                               sleepiness: soul.sleepiness, screenMoving: screenMoving, callOn: callSince != nil, music: musicOn,
                               fishing: face.seat == "fishing")
        f.seat = seat?.clip ?? ""
        if let seat, performing.isEmpty, !sleeping, !held, now >= talkUntil, waveT <= 0, currentWalk <= 0.05 { f.why = seat.why }
        f.snug = sleeping && now.timeIntervalSince(sleptAt) > 150
        f.actMoves = performMoves
        f.vy = vy
        face = f
        view?.face = f
    }

    private func show(_ e: String) { emote = e; emoteAge = 0 }

    private static func cell(_ p: CGPoint) -> Int { Int((p.x / 80).rounded(.down)) * 100_000 + Int((p.y / 80).rounded(.down)) }

    private func warm(_ p: CGPoint, by v: CGFloat) {
        let k = Body.cell(p)
        heat[k] = min(30, (heat[k] ?? 0) + v)
    }

    /// How much of his recent attention a rect of hers would cover (0…~1).
    private func attentionUnder(_ me: CGRect) -> Double {
        var total: CGFloat = 0
        var cx = (me.minX / 80).rounded(.down) * 80
        while cx < me.maxX {
            var cy = (me.minY / 80).rounded(.down) * 80
            while cy < me.maxY {
                total += heat[Body.cell(CGPoint(x: cx + 1, y: cy + 1))] ?? 0
                cy += 80
            }
            cx += 80
        }
        return Double(min(1, total / 12))
    }

    /// Where his keys went, read off the main thread at most once a second while he types
    /// (finding a web view's focused field can take a second): Core counts the words that follow
    /// as his only after keys into a terminal or an editor (/health typed_into).
    private var typedInto: (kind: String, why: String, at: Date) = ("unknown", "no keys yet", .distantPast)
    private var intoAskedAt = Date.distantPast, intoBusy = false, intoApp = ""
    private func readInto(_ now: Date) {
        // every 2 s while the front app stays the same (once a second, it was her top own cost in a
        // sample with him typing); at once when he's moved to another app
        let app = world.frontApp ?? ""
        guard !intoBusy, now.timeIntervalSince(intoAskedAt) >= (app == intoApp ? 2 : 0) else { return }
        intoBusy = true; intoAskedAt = now; intoApp = app
        let w = world
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = w.keysInto()
            DispatchQueue.main.async { self?.typedInto = (r.kind, r.why, now); self?.intoBusy = false }
        }
    }

    private func readFocus() {
        lastFocusRead = world.now
        let f = world.focus()
        focusCaret = f.caret
        focusField = f.field
    }

    /// He's typing and she's on top of it: it feels wrong right away, the spot
    /// is remembered as a bad one, and it bothers her more the next time.
    private func feelInTheWay(_ dt: CGFloat, _ now: Date) {
        guard !held, now.timeIntervalSince(lastTyped) < 2 else { wayT = max(0, wayT - dt); return }
        let me = CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)
        let bad = inTheWay(me)
        guard bad > 0.3 else { wayT = max(0, wayT - dt); return }
        wayT += dt
        if sleeping { maybeWake(1) }        // asleep on what he's typing in: she wakes and moves
        soul.feelPlace(me.midX, me.minY, -0.6 * Double(dt) * bad)
        if wayT > 0.12 && targetX != nil && !inTheWayAt(targetX!) { speed = max(speed, 240) }   // crossing it: quickly
        if wayT > 0.12 && (targetX == nil || inTheWayAt(targetX!)) && now.timeIntervalSince(wayThoughtAt) > 1 {
            wayThoughtAt = now
            wayT = 0
            hurry = true
            soul.inTheWay()
            if soul.feel(.dropped, 0.4) > 0.3 { wideT = 0.25 }
            targetX = nil
            think(soon: 0)
        }
    }

    // MARK: geometry

    private func screenAt(_ px: CGFloat) -> Display {
        world.screens.first { $0.frame.minX <= px && px < $0.frame.maxX }
            ?? world.screens.min { abs($0.frame.midX - px) < abs($1.frame.midX - px) } ?? world.screens[0]
    }

    private func clampX(_ v: CGFloat) -> CGFloat {
        let lo = world.screens.map(\.frame.minX).min() ?? 0
        let hi = (world.screens.map(\.frame.maxX).max() ?? 1000) - Body.size.width
        return min(hi, max(lo, v))
    }

    // MARK: Friday through her

    func setListening(_ on: Bool) {
        listening = on
        if on {
            _ = soul.feel(.heardName)
            // woken by her name she sits up and listens sitting (10-14: standing straight out of
            // sleep flashed a sitting frame for 0.08 s on the way up, the sim's 40_talking_to_her)
            listenSeated = sleeping
            if sleeping { sleeping = false; wideT = 0.4 }
            targetX = nil
            show("!")
        } else {
            // waiting on Friday's answer: she stays put, thinking, until it comes (or 8 s pass)
            think(soon: world.now < awaitingUntil ? awaitingUntil.timeIntervalSince(world.now) : Double.rnd(1.5...4))
        }
    }

    /// what he said to her is on its way to
    /// Friday. Her thinking pose the moment her ears finish hearing it, here on the Mac, until
    /// Friday's first words come back (speaking/showing end it) or 8 seconds pass.
    private var awaitingUntil = Date.distantPast
    func awaitingAnswer() {
        awaitingUntil = world.now.addingTimeInterval(8)
        awaitingSince = world.now
        if sleeping { sleeping = false; wideT = 0.4 }
        targetX = nil
        perform("think", seconds: 8, own: true, why: "waiting for \(Config.agentName)'s answer")
        trace?("awaiting", ["seconds": 8.0])
    }

    private func answerCame() {
        guard world.now < awaitingUntil else { return }
        awaitingUntil = .distantPast
        if performing == "think" || performing == "tap_foot" { performUntil = world.now }   // her pose gives way to talking
    }

    /// Friday's voice through her mouth (/mouth/play): she wakes if asleep, turns to him, and talks.
    func speaking(_ text: String, seconds: Double) {
        answerCame()
        _ = soul.feel(.fridaySpoke)
        turnToHim()
        talkUntil = world.now.addingTimeInterval(seconds)
        if !text.isEmpty { say(text, for: max(4, seconds + 1.5)) }
        trace?("speaking", ["seconds": seconds, "voiced": true])
    }

    /// Friday's words shown without a voice (/mouth/show): the bubble, her face to him, and her lips
    /// moving for about as long as the words take to say (never the whole time the bubble stays up).
    func showing(_ text: String, seconds: Double) {
        answerCame()
        turnToHim()
        say(text, for: seconds)
        talkUntil = world.now.addingTimeInterval(min(seconds, max(0.8, min(3.5, Double(text.count) / 14))))
        trace?("speaking", ["seconds": seconds, "voiced": false])
    }

    private func turnToHim() {
        if sleeping { sleeping = false; sit.target = 1; wideT = 0.3 }
        lookAtHim()
        lookUntil = .distantPast            // she keeps looking at him while she talks (attend)
        turn.kick(turn.target * 6)
        gazeMode = "him"
    }

    /// A reminder or push from Friday just appeared (top right of his main screen): a glance up there,
    /// and if he isn't busy, a tiny wave — never a fuss while he types or watches, nothing while asleep.
    func notified(_ title: String) {
        notice("a notification came: " + title)
        guard !sleeping, !held else { return }
        let main = world.screens.first { $0.frame.origin == .zero } ?? world.screens[0]
        lookToward(CGPoint(x: main.visibleFrame.maxX - 160, y: main.visibleFrame.maxY - 40), snap: 1)
        let busy = deepFocus || watchingVideo || world.now.timeIntervalSince(lastTyped) < 4
        curiousT = busy ? 0.8 : 1.4; if !busy { show("!") }     // a look up there; waves are for his return (10-15)
        trace?("notified", ["busy": busy])
    }

    /// Her bubble: shown text, and when it's up (the simulator checks where it lands).
    private func say(_ text: String, for seconds: Double) {
        bubble?.say(text, for: seconds)
        bubbleText = text
        bubbleUntil = world.now.addingTimeInterval(seconds + Double(text.count) * 0.03)
    }

    /// What her bubble must not cover: his field and the area around his caret.
    private func bubbleAvoid() -> [CGRect] {
        [focusField?.insetBy(dx: -8, dy: -8), focusCaret?.insetBy(dx: -60, dy: -30)].compactMap { $0 }
    }
    private var bubbleText = ""
    private var bubbleUntil = Date.distantPast

    private var wanting: (want: String, k: Double) { world.now < wantUntil ? (want, wantStrength) : ("", 0) }

    /// Her mind's latest leaning (core/iris): blended with her feelings, acted
    /// on in her own time — never an order executed on the spot.
    func mind(want w: String, strength: Double, mood: [String: Double], say: String, face: String = "") {
        // Her body has the last word on safety, whatever her mind says (core already filters too):
        // asleep, only a sleepy face; while he types, no words over his typing.
        let typingNow = world.now.timeIntervalSince(lastTyped) < 4
        let face = sleeping && face != "sleepy" ? "" : face
        let say = typingNow || sleeping || callSince != nil ? "" : say      // and never a word over his call
        trace?("mind", ["want": w, "face": face, "said": !say.isEmpty, "typing": typingNow])
        // what her mind feels shows on her face for a few seconds, on whatever pose she's in
        let hold = CGFloat.rnd(2.5...4.5)
        if !face.isEmpty { happyT = 0; giggleT = 0; poutT = 0; wideT = 0; curiousT = 0; winceT = 0; catT = 0 }   // a new feeling replaces the last
        switch face {
        case "happy": happyT = hold
        case "love": happyT = hold; blush.kick(4)
        case "pout": poutT = hold
        case "surprised": wideT = min(hold, 1.6)
        case "curious": curiousT = hold
        case "worried": winceT = min(hold, 2.5)
        case "sleepy": soul.sleepiness = min(1, soul.sleepiness + 0.25)
        default: break
        }
        want = w
        wantStrength = min(1, max(0, strength))
        wantUntil = world.now.addingTimeInterval(Double.rnd(90...180))
        soul.valence = min(1, max(-1, soul.valence + (mood["valence"] ?? 0)))
        soul.arousal = min(1, max(0, soul.arousal + (mood["arousal"] ?? 0)))
        if !say.isEmpty {
            self.say(say, for: 6)
            talkUntil = world.now.addingTimeInterval(min(3, Double(say.count) / 14))
        }
        think(soon: Double.rnd(0.6...4))
    }

    func shooed() {
        touch("shoo")
        soul.reward(-1)
        // 10-14 QA: "go away" while she napped slid her 300 pt along the floor still lying asleep
        if sleeping { sleeping = false; sit.target = 0 }   // she gets up first, then walks off
        poutT = 2
        // she walks off sadly ("sad_walk", "sad, ignored") and sulks where she stops ("sulk", in
        // bodyClips); which way is away from his cursor, or toward the room when that side has none (it was
        // a coin toss)
        let scr = screenAt(x + Body.size.width / 2).visibleFrame
        let way = Stages.shooDirection(me: Double(x), cursor: Double(world.mouse.x), minX: Double(scr.minX),
                                       maxX: Double(scr.maxX - Body.size.width), width: Double(Body.size.width))
        performing = ""; performMoves = false; sit.target = 0; workingAlong = false
        let to = clampIn(screenAt(x + Body.size.width / 2), x + CGFloat(way.dir) * 300)
        targetX = to
        shooWalkTo = abs(to - x) >= 3 ? to : nil
        walkWhy = "he told her to go away (" + way.why + ")"; walkSince = world.now
        trace?("walk", ["why": walkWhy, "to": Double(to)])
        if shooWalkTo == nil { perform("sulk", seconds: 4, own: true, why: "he told her to go away") }   // nowhere to go: sulks here
        perchTop = nil
        speed = 45
        think(soon: Double(abs(to - x)) / 45 + 3)    // she finishes walking off (and sulks) before her next thought picks a place
    }

    /// He called her over (core/iris_talk, 10-14): "cursor" — beside his pointer — or
    /// "other_screen" — the middle of his nearest other screen. She sets off at once, and
    /// her next thought waits until she has had time to get there. nil when she went;
    /// else why not ("held", "one_screen", "unknown_place").
    func come(_ to: String) -> String? {
        guard !held else { return "held" }
        let w = Body.size.width
        let mid = x + w / 2
        let tx: CGFloat
        switch to {
        case "cursor":
            let c = world.mouse
            let side: CGFloat = c.x > mid ? -1 : 1                       // stop beside it, not under it
            tx = clampIn(screenAt(c.x), c.x - w / 2 + side * (w / 2 + 20))
        case "other_screen":
            let here = screenAt(mid)
            guard let there = world.screens.filter({ $0.frame != here.frame })
                .min(by: { abs($0.frame.midX - here.frame.midX) < abs($1.frame.midX - here.frame.midX) })
            else { return "one_screen" }
            tx = clampIn(there, there.visibleFrame.midX - w / 2)
            hisScreenSince = world.now          // where he sent her is her place for a while
            placedAt = world.now
        default:
            return "unknown_place"
        }
        if sleeping { sleeping = false; wideT = 0.4 }
        performing = ""; performMoves = false; sit.target = 0; workingAlong = false
        perchTop = nil; perchID = nil
        happyT = 1.2
        if abs(tx - x) > 3 { targetX = tx; speed = 150; walkSince = world.now }
        nextThought = world.now.addingTimeInterval(max(12, Double(abs(tx - x)) / 150 + 5))   // time to get there
        postureUntil = nextThought
        trace?("come", ["to": to, "x": Double(tx)])
        return nil
    }

    private func menu(_ e: NSEvent) {
        let m = NSMenu()
        let ask = m.addItem(withTitle: "Ask \(Config.agentName)…  ⌃⌥Space", action: #selector(Menu.ask), keyEquivalent: "")
        ask.target = Menu.shared
        m.addItem(withTitle: "Talk to \(Config.agentName)  ⌃⌥⇧Space", action: #selector(Menu.talk), keyEquivalent: "").target = Menu.shared
        m.addItem(withTitle: sleeping ? "Wake Up" : "Nap", action: #selector(Menu.nap), keyEquivalent: "").target = Menu.shared
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Iris", action: #selector(Menu.quit), keyEquivalent: "").target = Menu.shared
        Menu.shared.body = self
        if let view { NSMenu.popUpContextMenu(m, with: e, for: view) }
    }

    /// For looking at her: stand still for a while (she resumes her own life after).
    /// Keep her in one state for a while (to check how she looks): standing, or
    /// a pose — "sit", "work" (her laptop), "wave", "sleep", "carry" (as if held by the mouse).
    func hold(_ seconds: Double, talk: Bool, pose: String = "") {
        targetX = nil
        waveT = 0; held = false                 // a hold starts clean: no wave or carry left from the last one
        performing = ""
        performMoves = false
        sit.target = 0
        workingAlong = false
        sleeping = false
        nextThought = world.now.addingTimeInterval(seconds)
        postureUntil = nextThought
        if talk { talkUntil = world.now.addingTimeInterval(seconds) }
        switch pose {
        case "sit": sit.target = 1
        case "work": workingAlong = true; sit.target = 1
        case "wave": waveT = CGFloat(seconds); waveWhy = "\(Config.agentName) asked her to wave"
        case "sleep": fallAsleep("\(Config.agentName) asked her to nap"); sleptAt = world.now.addingTimeInterval(-200)
        case "carry":
            held = true
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.held = false }
        default: break
        }
    }

    private func touch(_ what: String) {
        touches.append((what, world.now))
        if touches.count > 12 { touches.removeFirst(touches.count - 12) }
    }

    private func notice(_ what: String) {
        noticedAt = world.now
        events.append(what)
        if events.count > 8 { events.removeFirst(events.count - 8) }
    }

    /// Perform a library animation for a while; the moving ones travel as they play.
    /// `own`: one of her own impulses (Body); otherwise asked from outside (her mind, /iris/act).
    /// Friday just pressed or clicked something on his screen through her hands:
    /// she glances at it and nods, so he can see who moved his mouse.
    func usedHands(at p: CGPoint) {
        lookToward(p, snap: 0.9)
        perform("nod", seconds: 1.4, own: true, why: "\(Config.agentName) used the mouse through her hands")
    }

    /// `why`: the cause in the world, for her own moves (traced, and in poses.jsonl).
    func perform(_ id: String, seconds: Double, own: Bool = false, why: String = "") {
        guard let e = Body.catalog[id] else { return }
        let rig = e["rig"] == "yes"
        if !own {
            // her mind's moves never wake her, and never bounce about while he types, focuses or watches
            let quiet = deepFocus || watchingVideo || world.now.timeIntervalSince(lastTyped) < 4
            let refused = rig && (sleeping || (quiet && ["dance", "giggle"].contains(id)))
            trace?("mind_act", ["what": id, "refused": refused, "quiet": quiet, "asleep": sleeping])
            if refused { return }
        }
        if own { trace?("act", ["what": id, "why": why]) }
        actWhy = own ? why : "\(Config.agentName) asked for it"        // /iris/act: her mind's or his own ask, with Core's reason
        performing = id
        performUntil = world.now.addingTimeInterval(max(1.5, min(20, seconds)))
        performMoves = e["moves"] == "yes"      // only clips whose feet really move travel (catalog.json)
        sleeping = false
        if e["rig"] != "yes" { sit.target = 0 }   // her rig's little actions work sitting too
        if performMoves {
            let scr = screenAt(x + Body.size.width / 2).visibleFrame
            let dir: CGFloat = x + Body.size.width / 2 > scr.midX ? -1 : 1
            targetX = clampX(min(scr.maxX - Body.size.width, max(scr.minX, x + dir * CGFloat.rnd(160...360))))
            perchTop = standingOn?.maxY; perchID = standingID
            speed = id.contains("run") || id.contains("sprint") || id.contains("chase") ? 150 : 45
        } else if !rig {
            targetX = nil                         // a drawn clip plays where she is; a rig move never stops a walk
        }
        nextThought = performUntil.addingTimeInterval(2)
    }

    /// What happened since her mind last asked (it asks with every thought).
    func takeEvents() -> [String] { defer { events.removeAll() }; return events }

    func toggleNap() { if sleeping { maybeWake(1) } else { fallAsleep("he chose Nap") } }

    /// The simulator puts her somewhere to start (on that screen's floor unless told).
    func simPlace(x px: CGFloat, y py: Double?) {
        x = px
        y = py.map { CGFloat($0) } ?? screenAt(px + Body.size.width / 2).visibleFrame.minY
    }

    static func bubbleRect(_ text: String, _ pet: CGRect, _ avoid: [CGRect]) -> [Double] {
        let size = BubbleView().fit(text)
        let o = Bubble.place(size: size, pet: pet, screens: world.screens, avoid: avoid)
        return [Double(o.x), Double(o.y), Double(size.width), Double(size.height)]
    }

    /// Everything the simulator logs each frame.
    func simState() -> [String: Any] {
        ["x": Double(x), "y": Double(y), "vy": Double(vy), "target": targetX.map { Double($0) } as Any,
         "perch": perchTop.map { Double($0) } as Any, "riding": riding,
         "on_window": standingOn != nil, "on_front_window": standingOn != nil && standingOn == world.frontWindow(), "crouching": launch != nil, "speed": Double(speed), "sit": Double(sit.value),
         "sleeping": sleeping, "held": held, "walk": Double(currentWalk), "flip": face.flip, "turn": Double(turn.value),
         "lean": Double(lean.value), "hint": face.hint, "act": performing, "working_along": workingAlong,
         "emote": emoteAge < 1 ? (emote ?? "") : "", "in_the_way": inTheWay(CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)),
         "want": wanting.want, "watching_video": watchingVideo, "alpha": Double(alpha), "display_moved": moved, "talking": world.now < talkUntil, "gaze_mode": gazeMode, "listening": listening,
         "bubble": world.now < bubbleUntil ? Body.bubbleRect(bubbleText, CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height), bubbleAvoid()) : [Double](), "lid": Double(lid.value), "valence": soul.valence, "arousal": soul.arousal, "sleepiness": soul.sleepiness,
         "boredom": soul.boredom, "affection": soul.affection, "his_idle": world.now.timeIntervalSince(lastInput)]
    }

    func state() -> [String: Any] {
        ["x": Double(x), "y": Double(y), "sleeping": sleeping, "listening": listening,
         "clip": view?.showing ?? "", "speed": targetX == nil ? 0 : Double(speed), "sit": Double(sit.target),
         "working_along": workingAlong, "performing": performing,
         "noticed_ago_s": Int(world.now.timeIntervalSince(noticedAt)), "want": wanting.want, "want_strength": wanting.k, "typing_recent": world.now.timeIntervalSince(lastTyped) < 4,
         "typed_into": typedInto.kind, "typed_into_why": typedInto.why, "typed_into_ago_s": typedInto.at == .distantPast ? NSNull() : world.now.timeIntervalSince(typedInto.at) as Any,
         "keys_heard": ["monitor": monitorKeys, "counter": countedKeys], "music": musicOn,
         "feelings": soul.feelings(), "pets": soul.memory.pets, "shooed": soul.memory.shooed,
         "touches": touches.map { ["what": $0.what, "at": $0.at.timeIntervalSince1970] }]
    }
}

final class Menu: NSObject {
    static let shared = Menu()
    weak var body: Body?
    @objc func talk() { body?.onTalk?() }
    @objc func ask() { body?.onAsk?() }
    @objc func nap() { body?.toggleNap() }
    @objc func quit() { body?.soul.save(); NSApp.terminate(nil) }
}
