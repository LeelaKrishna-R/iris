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
// (strict concurrency): her body is her main thread's — AppKit, her timer, and the simulator's headless runs,
// which are on the main thread too (main.swift's top level, before her app starts).
@MainActor
final class Body {
    let soul = Soul()
    let noteCue = NoteCue()                         // what waits for him, for her still note (BodyNote.swift)
    let view: SpriteView?
    let window: NSPanel?
    let bubble: Bubble?
    weak var eyes: Eyes?
    var onTalk: (() -> Void)?
    var onAsk: (() -> Void)?
    var onPetted: (() -> Void)?             // his click on her refreshes the day card (DayCard); peeks at it
    var onDoublePetted: (() -> Void)?       // a double-click is a bow: the peek its first click opened goes
    var onHoverHint: (() -> String?)?       // his pointer resting on her: her one line of his day (DayCard.hint)
    var onDayCard: (() -> Void)?            // her menu's Show / Hide My Day

    static let size = CGSize(width: 150, height: 196)

    // motion
    var x: CGFloat = 0
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var targetX: CGFloat?
    var speed: CGFloat = 70
    var perchTop: CGFloat?
    var held = false

    // face springs
    var turn = Spring(0), tilt = Spring(0), lean = Spring(0), squash = Spring(0)
    var armL = Spring(0.15), armR = Spring(0.15), sit = Spring(0), hairSway = Spring(0)
    var gx = Spring(0), gy = Spring(0)
    var smile = Spring(0.3), brow = Spring(0), blush = Spring(0.15), lid = Spring(0)

    // momentary feelings shown on her face, seconds left
    var happyT: CGFloat = 0, wideT: CGFloat = 0, winceT: CGFloat = 0, dizzyT: CGFloat = 0
    var giggleT: CGFloat = 0, waveT: CGFloat = 0, typeT: CGFloat = 0, catT: CGFloat = 0, poutT: CGFloat = 0
    var sparkleT: CGFloat = 0, sweatT: CGFloat = 0, curiousT: CGFloat = 0
    var emote: String?
    var emoteAge: CGFloat = 9
    var talkUntil = Date.distantPast
    var listening = false
    var listenSeated = false              // she was asleep when he said her name: listens sitting up
    var sleeping = false
    var hovering = false

    // his hand on her: each touch plays the catalog
    // clip whose "when" is that touch — giggle "he petted her", blow_kiss "affection",
    // bow "thank you, greeting", shy "he looked at her for a long time", blush_hide
    // "very embarrassed", getup "after falling", chase/pounce "chasing/catching his cursor"
    var petTimes: [Date] = []              // pets in the last 20 s
    var hoverSince: Date?                  // his cursor resting on her since (once per hover)
    var flickTimes: [Date] = []            // fast passes of his cursor near her, last 8 s
    var lastFlickAt = Date.distantPast
    var lastChaseAt = Date.distantPast
    var cursorMovedAt = Date.distantPast   // his hand last moved the mouse
    var cursorNearMovedAt = Date.distantPast   // ... within her reach (a shake across her, sim 37)
    var touchUntil = Date.distantPast      // a touch clip plays until then (a long look doesn't cut it)
    var fall: (fromY: CGFloat, at: Date)?  // let go of high up: where she fell from

    // what she knows about him right now
    // from his real last touch, not her launch. Started at launch, her 20:40 install made his 02:10
    // return "he came back after 330 min away" when his hands had been idle since ~14:00.
    var lastInput = world.now.addingTimeInterval(-min(max(world.handsIdle, 0), 86_400))
    var keyTimes: [Date] = []
    var backspaces: [Date] = []
    var scrollEnergy: CGFloat = 0
    var typingHand = false
    private var lastCursor = world.mouse
    var cursorSpeed: CGFloat = 0
    var keyCounter: UInt32 = 0
    var use: [String: Double] = [:], useDay = "", useCountedAt = Date.distantPast, useSavedAt = Date.distantPast
    var work: [String: [String: Double]] = [:]   // hour "09" → "app\ttitle" → active seconds
    var musicOn = false, musicCheckedAt = Date.distantPast
    var lastSway = 0
    private var titleCheckedAt = Date.distantPast
    var lastPage: (app: String, title: String) = ("", "")
    var monitorKeys = 0, monitorKeysSince = 0, countedKeys = 0   // what each way of hearing keys has heard
    var appsToday = Set<String>()
    var activeSince = world.now
    var watchingVideo = false
    private var lastFace = Face()
    /// How she looks this instant (the view draws it; the simulator logs it).
    var face = Face()

    var nextThought = world.now
    private var lastTick = world.now
    var blinkAt = world.now.addingTimeInterval(2)
    var blinkT: CGFloat = 0
    var walkPhase: CGFloat = 0
    var clock: CGFloat = 0
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
        view?.onPet = { [weak self] in self?.petted(); self?.onPetted?() }
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
        // AppKit calls each of these on the main thread (the monitor, the observers on .main, a main-run-loop timer)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.event(e) }
        }) {
            monitors.append(m)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            MainActor.assumeIsolated { self?.appSwitched(app) }
        }
        tick(every: 1.0 / 60)
        // no drawing where she can't be seen (SpriteKit's "no drawables" was 5,466 of 5,992 log lines)
        if let w = window {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDrawing() }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true; self?.updateDrawing() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false; self?.updateDrawing() }
        }
    }

    /// Her body's clock: 60 Hz awake, 30 asleep (her breathing needs no more, and 1/30 s stays under
    /// frame()'s 0.05 s step, so no time is lost).
    private func tick(every interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var screensAsleep = false

    /// her picture is drawn only while her window can be seen — on a display that's awake, not covered or
    /// off every screen (macOS's occlusion state), and not faded out over a full-screen app. SpriteKit rendering
    /// into a window that can't be drawn said "no drawables available" every few seconds while he was away.
    func updateDrawing() {
        guard let view, let window else { return }
        let seen = !screensAsleep && window.occlusionState.contains(.visible) && alpha > 0
        if view.isPaused == seen {
            view.isPaused = !seen
            log("body: drawing \(seen ? "again" : "paused: her window can't be seen")")
        }
    }

    /// The simulator listens here (Sim.swift): what she decided and why. Nil live.
    var trace: ((String, [String: Any]) -> Void)?

    // MARK: the frame — 60 a second

    func frame() {
        let now = world.now
        // never below 0. A wall clock stepping back made dt negative and settle()'s max(0, t - dt)
        // brought every spent timer back for a frame: a wave "he came back after 678 min away" to an empty room.
        let dt = CGFloat(min(0.05, max(0, now.timeIntervalSince(lastTick))))
        lastTick = now
        clock += dt
        // when she last woke (by any path), and how long his screens have kept changing or been still
        if wasAsleep && !sleeping {
            wokeAt = now; restWhy = "woke: " + (wakeWhy.isEmpty ? "\(Config.agentName) asked" : wakeWhy); wakeWhy = ""
            trace?("woke", ["why": restWhy])
        }
        if sleeping != wasAsleep, timer != nil { tick(every: sleeping ? 1.0 / 30 : 1.0 / 60) }
        wasAsleep = sleeping
        if screenMoving { screenMovedAt = now; if screenMovingSince == nil { screenMovingSince = now } } else { screenMovingSince = nil }
        // he stopped after a real stretch of typing (20 s or more, quiet 3 s): she nods, once per stretch
        let burst = lastTyped.timeIntervalSince(typingSince)
        // 30 of these nods in 3 h, then one each half hour; (owner: "no
        // reactions"): at most one each Body.nodEveryS (10 min), once per stretch of his typing
        if burst > 20 && now.timeIntervalSince(lastTyped) > 3 && noddedFor != typingSince && !sleeping && !held && !listening
            && performing.isEmpty && targetX == nil && now.timeIntervalSince(noddedAt) > Body.nodEveryS && ambientFree(now)
            && dueToShow == nil {                  // a to-do come due waiting to be shown says more than a nod
            noddedFor = typingSince
            noddedAt = now
            perform("nod", seconds: 1.4, own: true, why: String(format: "his typing stopped after %.0f s", burst))
            ownMoment("typing_nod")
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
        if moved > 0.5 && dist < Body.calmRadius { cursorNearMovedAt = now }
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
        // sim 27 (him reading, a scroll every minute or so): "active" was a touch in the last 30 s, so between
        // his scrolls she grew sleepy, up to 1.0 with him right there, and sat heavy-eyed instead of with her book —
        // the stare he sees. He's here until Stages.awayFor, as for her fishing.
        soul.drift(Double(dt), active: now.timeIntervalSince(lastInput) < Stages.awayFor || watchingVideo || screenMoving,   // a busy screen is not an empty room
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
        // her laptop out, typing along with him for a long stretch of his typing,
        // goes away (Body.typeAlongHoldS after his last key): she gets up and stretches ("yoga", "stretch break,
        // calm"), at most hourly and not right after Friday's own stretch nudge. Its why is the stretch she typed.
        if workingAlong {
            if alongSince == nil { alongSince = now }
        } else if let since = alongSince {
            alongSince = nil
            let alongFor = lastTyped.timeIntervalSince(since)
            // (a walk she just set off on waits for it, unless it's out of his way or to a corner for his call or film;
            // his carrying her, calling her over or shooing her ends the stretch she typed along, alongSince = nil)
            let walkWaits = targetX == nil || (walkWhy != "out of his way" && !walkWhy.hasPrefix("corner"))
            if Stages.stretches(alongFor: alongFor, keysRested: now.timeIntervalSince(lastTyped),
                                sinceHerStretch: now.timeIntervalSince(herStretchAt), sinceFridayStretch: now.timeIntervalSince(fridayStretchAt)),
               walkWaits, !sleeping, !held, !listening, performing.isEmpty, vy == 0, launch == nil,
               now >= talkUntil, waveT <= 0, !watchingVideo, callSince == nil, now.timeIntervalSince(lastInput) < Stages.awayFor {
                herStretchAt = now
                perform("yoga", seconds: Body.yogaSeconds, own: true,
                        why: String(format: "she typed along with him %.0f min and he stopped %.0f s ago", alongFor / 60,
                                    now.timeIntervalSince(lastTyped)))
            }
        }
        // a to-do on his day card came due (dayCard): her sticky note, once he can look, within
        // Stages.showWithin of the card saying so (her eyes went to the card when it did)
        if let d = dueToShow {
            if now.timeIntervalSince(d.at) > Stages.showWithin { dueToShow = nil }
            else if Stages.canShow(awake: !sleeping, hisIdle: now.timeIntervalSince(lastInput), sinceKeys: now.timeIntervalSince(lastTyped),
                                   watching: watchingVideo, callOn: callSince != nil),
                    !held, !listening, performing.isEmpty, targetX == nil, vy == 0, now >= talkUntil, waveT <= 0 {
                dueToShow = nil
                noddedFor = typingSince              // in place of her nod at this stretch of his typing, not before it
                let c = dayCardAt(d.card)
                lookToward(CGPoint(x: c.midX, y: c.midY), snap: 1)
                perform("sticky_note", seconds: Body.noteSeconds, own: true, why: "a to-do on his day card came due: " + d.title)
            }
        }
    }

    /// Where his day card is: as DayCard placed it, or (the simulator, no panel) where it goes, left of her.
    private func dayCardAt(_ card: CGRect?) -> CGRect {
        card ?? CGRect(x: x - 288, y: y + Body.size.height - 200, width: 280, height: 200)
    }

    /// Core sent his day card (DayCard, every 10 min). A to-do on it came due
    /// since the last card (Stages.cameDue: listed with its time ahead, now past) and no push or sticky note of
    /// Friday's told him of it lately: her eyes go to the card now, and her sticky note follows once he can look.
    /// `todosBefore` / `todosAfter`: the card's "todos" row text before and after (nil: unread, "off", or no card).
    func dayCard(todosBefore: String?, todosAfter: String?, card: CGRect?) {
        let now = world.now
        toldTitles.removeAll { now.timeIntervalSince($0.at) > Stages.alreadyToldWithin }
        guard let title = Stages.cameDue(before: todosBefore, after: todosAfter, told: toldTitles.map(\.title)) else { return }
        let noted = now.timeIntervalSince(fridayNoteAt) < Stages.alreadyToldWithin    // Friday's sticky note just played
        trace?("card_due", ["noted": noted, "asleep": sleeping])
        guard !noted else { return }
        notice("a to-do on his day card came due: " + String(title.prefix(60)))
        dueToShow = (String(title.prefix(60)), now, card)
        if !sleeping && !held {
            let c = dayCardAt(card)
            lookToward(CGPoint(x: c.midX, y: c.midY), snap: 1)
            curiousT = max(curiousT, 1)
        }
    }

    /// he answered Friday's approval on the card beside her (ApprovalCard). His
    /// Allow gets her bow ("thank you"), its why the request he allowed; a Deny gets nothing of hers (Friday's
    /// "Okay, I won't" says it). Never asleep, carried or listening.
    func approvalAnswered(_ choice: String, what: String) {
        trace?("approval_answered", ["choice": choice, "asleep": sleeping])
        guard choice == "approve", !sleeping, !held, !listening, vy == 0 else { return }
        perform("bow", seconds: 2.4, own: true, why: "he allowed \(Config.agentName)'s request: " + String(what.prefix(60)))
    }

    var lookUntil = Date.distantPast

    /// What her eyes are on (the simulator logs it): him, caret, cursor, change, front, glance.
    var gazeMode = ""
    var heardAt = Date.distantPast
    var frontSeen: CGRect?                       // his front window, as watchAction last read it
    var changeSeen: (at: Date, point: CGPoint)?   // where his screen last changed, read with it
    var knownWins: Set<Int>?
    var winCheckAt = Date.distantPast

    var stillPoint: CGPoint?
    var stillSince = Date.distantPast

    var myScreen: (id: UInt32, frame: CGRect)?
    /// poses.jsonl 09:03-09:08: she crossed between his screens every 1-2 min, back and forth, each time a
    /// run "to the screen he's working on" (an invitation one way, out of his way the other). After a change of
    /// screen she stays on the new one Body.crossGap before she crosses again of her own accord; carried or
    /// called over (Body.come) she goes at once as before.
    var crossedAt = Date.distantPast
    var lastFloor: CGFloat?
    var moved = false

    // MARK: his full-screen picture
    //
    // A full-screen app (a film, a game, a full-screen editor) is his whole screen: she steps out of
    // it — fades, and reappears on his other screen near the seam — or, with one screen, stays out
    // of sight until it ends. `defaults write app.iris.companion IrisOverFullScreen -bool YES` lets
    // her stay over it. (Her window keeps .fullScreenAuxiliary so she can live on his other screen
    // while one is full screen, and so this opt-in works.)

    var fsCheckAt = Date.distantPast
    var fullScreenFrame: CGRect?
    var alpha: CGFloat = 1
    var fade: (to: CGFloat, then: (() -> Void)?)?

    var vx: CGFloat = 0
    var leapTo: CGPoint?
    var launch: (vy: CGFloat, vx: CGFloat, at: Date)?
    var standingOn: CGRect?             // the window top she's on
    var standingID: Int?                // … which window (the window server's id)
    var perchID: Int?                   // the window whose top she's heading for

    /// Which screen he is working on now and since when (the caret while he types, else his cursor).
    var hisScreen: Int?
    var hisScreenSince = Date.distantPast

    var wokeAt = Date.distantPast
    private var wasAsleep = false
    var screenMovedAt = Date.distantPast        // his screens last changed (her eyes, or the sim)
    var screenMovingSince: Date?                // and have kept changing since
    var lastYawnAt = Date.distantPast
    // her body's own clips (Stages): the doze before sleep, the walk-off when he shoos her, the jump
    // down from his window, and when Friday's answer is taking a while
    var dozeWhy: String?                        // nodding off: falls asleep with this cause when the doze ends
    var dozeInputAt = Date.distantPast          // his last input when the doze began (any newer wakes her)
    var shooWalkTo: CGFloat?                    // where she is walking off to after "go away"
    var jumpDown: (why: String, flight: Double)?   // a hop off his window, about to launch
    var awaitingSince = Date.distantPast
    var seatedAwakeSince: Date?
    private var noddedFor = Date.distantPast            // the burst of his typing she last nodded at
    private var noddedAt = Date.distantPast             // when she last nodded at one (Body.nodEveryS apart)
    // her stretch after typing along, a to-do come due on his day card, his Allow
    var alongSince: Date?                       // her laptop came out to type along with him (Stages.stretches)
    private var herStretchAt = Date.distantPast         // her last stretch (Stages.stretchEvery apart)
    var fridayStretchAt = Date.distantPast      // Friday's stretch nudge ("stretch_guide", /iris/act) last played
    var fridayNoteAt = Date.distantPast         // Friday's sticky note (his reminder going off, /iris/act) last played
    var toldTitles: [(title: String, at: Date)] = []   // pushes he got lately (notified), for Stages.cameDue
    private var dueToShow: (title: String, at: Date, card: CGRect?)?   // a to-do come due, shown once he can look
    // what each of her bodies is for, this moment — the cause in the world (Face.why, poses.jsonl)
    var actWhy = "", sleepWhy = "", waveWhy = "", walkWhy = "", restWhy = "", wakeWhy = ""
    /// times his screens woke her since he last touched the Mac, none of it him
    var screenWokeHer = 0
    var lastWaveAt = Date.distantPast        // her last wave for his return (Body.waveEvery)
    var frontScreen: Int?                       // which screen his front window is on
    var frontScreenSince = Date.distantPast
    var frontNoticed = false
    var placedAt = Date.distantPast             // he carried her, or she stepped out of his full screen
    var actionCheckAt = Date.distantPast
    var attendAt = Date.distantPast
    var attendX: CGFloat?                       // beside his front window, re-picked every ~10 s
    var callSince: Date?
    var callCorner: CGFloat?           // her corner for this call, chosen at its start

    var riding = false
    var hurry = false
    var focusSince = Date.distantPast      // when his current stretch of typing began
    var deepFocus = false                  // he's been typing steadily a couple of minutes
    var satSince = Date.distantPast
    var walkSince = Date.distantPast       // when she set off for where she's going
    var wayThoughtAt = Date.distantPast
    var currentWalk: CGFloat = 0
    /// sim 33 seed 8: what's left of this leg of her walk — to his screen's edge when a hop down comes first
    /// (a 0.18 s run, then her crouch), else to her spot; the run is judged by it (Stages.gait).
    var legLeft: CGFloat = 0
    var lastX: CGFloat = 0
    var focusCaret: CGRect?
    var focusField: CGRect?
    var lastTyped = Date.distantPast
    var typingSince = Date.distantPast
    var typeAlongAfter = 12.0
    var shortcutAt = Date.distantPast, undos: [Date] = []
    var lastFocusRead = Date.distantPast
    var wayT: CGFloat = 0
    var pickedUpAt: CGPoint?
    var keyCount = 0
    var saccade = CGPoint.zero
    var nextSaccade = world.now
    var lastFaceX: CGFloat = 0
    var sleptAt = world.now
    // a nap asked for (the agent's 60 s hold) used to end at the first touch of the mouse. A nap he
    // asked for holds until then; only his touch on her (touched) or Wake ends it sooner.
    var napUntil = Date.distantPast
    // switching between apps, each with its text field somewhere else, sent her "out of his way" every
    // minute or two: her clear spot for one field was in the way of the next.
    // Every field he used in the last 10 min counts when she picks where to be (inTheWayAt).
    var recentWays: [(CGRect, Date)] = []
    var performing = ""                 // a library animation (Resources/anim/<id>)
    var performUntil = Date.distantPast
    var performMoves = false
    var noticedAt = world.now             // when he last paid her any attention
    var events: [String] = []          // what happened since her mind last thought
    // His pets, shoos and drags with their times (/iris/health "touches"), kept, not taken:
    // Core's reflex reads them every tick to learn which of her reactions he likes.
    var touches: [(what: String, at: Date)] = []
    var workingAlong = false
    var dizzyAt = Date.distantPast
    var farSince: Date?
    var want = ""                         // what her mind feels like doing (core/iris), a leaning
    var wantStrength = 0.0
    var wantUntil = Date.distantPast
    var postureUntil = world.now
    var heat: [Int: CGFloat] = [:]      // where his hand has been lately (80-pt cells), fading
    private var heatDecayAt = world.now

    /// Where his keys went, read off the main thread at most once a second while he types
    /// (finding a web view's focused field can take a second): Core counts the words that follow
    /// as his only after keys into a terminal or an editor (/health typed_into).
    var typedInto: (kind: String, why: String, at: Date) = ("unknown", "no keys yet", .distantPast)
    var intoAskedAt = Date.distantPast, intoBusy = false, intoApp = ""

    // MARK: geometry

    func screenAt(_ px: CGFloat) -> Display {
        world.screens.first { $0.frame.minX <= px && px < $0.frame.maxX }
            ?? world.screens.min { abs($0.frame.midX - px) < abs($1.frame.midX - px) } ?? world.screens[0]
    }

    func clampX(_ v: CGFloat) -> CGFloat {
        let lo = world.screens.map(\.frame.minX).min() ?? 0
        let hi = (world.screens.map(\.frame.maxX).max() ?? 1000) - Body.size.width
        return min(hi, max(lo, v))
    }

    /// what he said to her is on its way to
    /// Friday. Her thinking pose the moment her ears finish hearing it, here on the Mac, until
    /// Friday's first words come back (speaking/showing end it) or 8 seconds pass.
    var awaitingUntil = Date.distantPast

    var bubbleText = ""
    var bubbleUntil = Date.distantPast

    /// (structure audit): the moments she starts herself, not asked and not answering his hand (a nod when his
    /// typing stops, a late yawn, "@_@" at his scrolling), kept an hour for /health: Core's one gap between her
    /// ambient moments (core/iris_reflex.AMBIENT_GAP_S) counts these too, so its next moment never follows one.
    var ownMoments: [(kind: String, at: Date)] = []
    /// When Core's last moment of its own was (its mind message's "ambient_at", core/iris_reflex), one budget
    /// both ways, so her own nod, yawn and "@_@" wait the same gap after Core's as Core's do after hers.
    var coreAmbientAt = Date.distantPast
}

