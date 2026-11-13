import AppKit

// Iris's body — Friday through her (out of Body.swift): listening, waiting for and speaking Friday's
// answers, what Friday's mind asks of her body, his shoos and calls, held poses and clips.
extension Body {
    // MARK: Friday through her

    func setListening(_ on: Bool) {
        listening = on
        if on {
            _ = soul.feel(.heardName)
            // woken by her name she sits up and listens sitting (standing straight out of
            // sleep flashed a sitting frame for 0.08 s on the way up, the sim's 40_talking_to_her)
            listenSeated = sleeping
            if sleeping { wakeWhy = "he said her name"; sleeping = false; wideT = 0.4 }
            targetX = nil
            show("!")
        } else {
            // waiting on Friday's answer: she stays put, thinking, until it comes (or 8 s pass)
            think(soon: world.now < awaitingUntil ? awaitingUntil.timeIntervalSince(world.now) : Double.rnd(1.5...4))
        }
    }

    func awaitingAnswer() {
        awaitingUntil = world.now.addingTimeInterval(8)
        awaitingSince = world.now
        if sleeping { wakeWhy = "he asked \(Config.agentName) something"; sleeping = false; wideT = 0.4 }
        targetX = nil
        perform("think", seconds: 8, own: true, why: "waiting for \(Config.agentName)'s answer")
        trace?("awaiting", ["seconds": 8.0])
    }

    private func answerCame() {
        // her thinking pose gives way to her voice whenever it comes, not only inside her own 8 s wait. Core
        // keeps the pose on while a slow answer comes (core/iris_brains since, core/iris_answer._think_while), and
        // past 8 s she spoke through pursed lips with her eyes away (SpriteView's "think" sets her mouth after her
        // visemes) for as long as the pose had left.
        let waiting = world.now < awaitingUntil
        awaitingUntil = .distantPast
        if performing == "think" || (waiting && performing == "tap_foot") { performUntil = world.now }   // her pose gives way to talking
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
        if sleeping { wakeWhy = "\(Config.agentName) had something to tell him"; sleeping = false; sit.target = 1; wideT = 0.3 }
        lookAtHim()
        lookUntil = .distantPast            // she keeps looking at him while she talks (attend)
        turn.kick(turn.target * 6)
        gazeMode = "him"
    }

    /// A reminder or push from Friday just appeared (top right of his main screen): a glance up there,
    /// and if he isn't busy, a tiny wave — never a fuss while he types or watches, nothing while asleep.
    func notified(_ title: String) {
        notice("a notification came: " + title)
        toldTitles.append((title, world.now))                // a to-do it named is told already (dayCard)
        if toldTitles.count > 20 { toldTitles.removeFirst(toldTitles.count - 20) }
        guard !sleeping, !held else { return }
        let main = world.screens.first { $0.frame.origin == .zero } ?? world.screens[0]
        lookToward(CGPoint(x: main.visibleFrame.maxX - 160, y: main.visibleFrame.maxY - 40), snap: 1)
        let busy = deepFocus || watchingVideo || world.now.timeIntervalSince(lastTyped) < 4
        curiousT = busy ? 0.8 : 1.4; if !busy { show("!") }     // a look up there; waves are for his return
        trace?("notified", ["busy": busy])
    }

    /// Her bubble: shown text, and when it's up (the simulator checks where it lands).
    func say(_ text: String, for seconds: Double) {
        bubble?.say(text, for: seconds)
        bubbleText = text
        bubbleUntil = world.now.addingTimeInterval(seconds + Double(text.count) * 0.03)
    }

    /// What her bubble must not cover: his field and the area around his caret.
    func bubbleAvoid() -> [CGRect] {
        [focusField?.insetBy(dx: -8, dy: -8), focusCaret?.insetBy(dx: -60, dy: -30)].compactMap { $0 }
    }

    var wanting: (want: String, k: Double) { world.now < wantUntil ? (want, wantStrength) : ("", 0) }

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
        // (UX audit #9): shooed while he works, she was in the way of his work
        if world.now.timeIntervalSince(lastTyped) < Body.workingS { soul.interrupted(1) }
        // where he shooed her from is a spot she learns to keep off, as where he picked her up from (82 shoos
        // lifetime, and only reactions within 20 s taught her anything; she went back to the same place)
        soul.feelPlace(x + Body.size.width / 2, y, -0.45)
        // QA: "go away" while she napped slid her 300 pt along the floor still lying asleep
        if sleeping { wakeWhy = "he shooed her"; sleeping = false; sit.target = 0 }   // she gets up first, then walks off
        poutT = 2
        // she walks off sadly ("sad_walk", "sad, ignored") and sulks where she stops ("sulk", in
        // bodyClips); which way is away from his cursor, or toward the room when that side has none (it was
        // a coin toss)
        let scr = screenAt(x + Body.size.width / 2).visibleFrame
        let way = Stages.shooDirection(me: Double(x), cursor: Double(world.mouse.x), minX: Double(scr.minX),
                                       maxX: Double(scr.maxX - Body.size.width), width: Double(Body.size.width))
        performing = ""; performMoves = false; sit.target = 0; workingAlong = false; alongSince = nil
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

    /// He called her over (core/iris_talk): "cursor" — beside his pointer — or
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
        performing = ""; performMoves = false; sit.target = 0; workingAlong = false; alongSince = nil
        perchTop = nil; perchID = nil
        happyT = 1.2
        if abs(tx - x) > 3 { targetX = tx; speed = 150; walkSince = world.now }
        nextThought = world.now.addingTimeInterval(max(12, Double(abs(tx - x)) / 150 + 5))   // time to get there
        postureUntil = nextThought
        trace?("come", ["to": to, "x": Double(tx)])
        return nil
    }

    func menu(_ e: NSEvent) {
        let m = NSMenu()
        m.autoenablesItems = false              // a line of how she is is shown, not chosen; a setting can't be offered
        // "How Iris is", read now (never kept from an earlier look), then her settings as they stand
        let now = Date()
        let st = Menu.shared.readState?()
        let earsStatus = st?.earsStatus
        let head = m.addItem(withTitle: "How Iris is", action: nil, keyEquivalent: "")
        head.isEnabled = false
        for line in HowIris.lines(ears: earsStatus, screenPermitted: st?.screenPermitted ?? false,
                                  eyesOffUntil: st?.eyesOffUntil, core: CoreWord.shared.status,
                                  coreAt: CoreWord.shared.at, lastFridayContact: Link.lastVerifiedAt, now: now) {
            let i = m.addItem(withTitle: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            i.indentationLevel = 1
        }
        m.addItem(.separator())
        for t in HowIris.toggles(earsOffUntil: earsStatus?["off_until"] as? Double, eyesOffUntil: st?.eyesOffUntil,
                                 screenPermitted: st?.screenPermitted ?? false, core: CoreWord.shared.status, coreAt: CoreWord.shared.at,
                                 quietAsked: CoreWord.shared.asking, now: now) {
            let i = m.addItem(withTitle: t.title, action: t.action == nil ? nil : #selector(Menu.setting(_:)),
                              keyEquivalent: "")
            i.target = Menu.shared
            i.representedObject = t.action
            i.isEnabled = t.action != nil
            if let on = t.on { i.state = on ? .on : .off }
        }
        m.addItem(.separator())
        let ask = m.addItem(withTitle: "Ask \(Config.agentName)…  ⌃⌥Space", action: #selector(Menu.ask), keyEquivalent: "")
        ask.target = Menu.shared
        m.addItem(withTitle: "Talk to \(Config.agentName)  ⌃⌥⇧Space", action: #selector(Menu.talk), keyEquivalent: "").target = Menu.shared
        m.addItem(withTitle: sleeping ? "Wake Up" : "Nap", action: #selector(Menu.nap), keyEquivalent: "").target = Menu.shared
        if !DayCard.shared.rows.isEmpty {
            m.addItem(withTitle: DayCard.shared.hidden ? "Show My Day" : "Hide My Day", action: #selector(Menu.day),
                      keyEquivalent: "").target = Menu.shared
        }
        // she is out of screen shares unless he says so, for this launch only (Menu.screenShares)
        let shares = m.addItem(withTitle: "Show Me in Screen Shares", action: #selector(Menu.screenShares), keyEquivalent: "")
        shares.target = Menu.shared
        shares.state = Menu.shared.inScreenShares ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Welcome…", action: #selector(Menu.welcome), keyEquivalent: "").target = Menu.shared
        m.addItem(withTitle: "Quit Iris", action: #selector(Menu.quit), keyEquivalent: "").target = Menu.shared
        Menu.shared.body = self
        if let view { NSMenu.popUpContextMenu(m, with: e, for: view) }
    }

    /// For looking at her: stand still for a while (she resumes her own life after).
    /// Keep her in one state for a while (to check how she looks): standing, or
    /// a pose — "sit", "work" (her laptop), "wave", "sleep", "carry" (as if held by the mouse).
    func hold(_ seconds: Double, talk: Bool, pose: String = "") {
        targetX = nil
        napUntil = .distantPast                 // Wake (a hold of its own) ends a nap he asked for
        waveT = 0; held = false                 // a hold starts clean: no wave or carry left from the last one
        performing = ""
        performMoves = false
        sit.target = 0
        workingAlong = false; alongSince = nil   // Friday's hold is no end of a stretch to stretch after
        sleeping = false
        nextThought = world.now.addingTimeInterval(seconds)
        postureUntil = nextThought
        if talk { talkUntil = world.now.addingTimeInterval(seconds) }
        switch pose {
        case "sit": sit.target = 1
        case "work": workingAlong = true; sit.target = 1
        case "wave": waveT = CGFloat(seconds); waveWhy = "\(Config.agentName) asked her to wave"
        case "sleep": fallAsleep("\(Config.agentName) asked her to nap"); sleptAt = world.now.addingTimeInterval(-200)
            napUntil = world.now.addingTimeInterval(seconds)
        case "carry":
            held = true
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.held = false }
        default: break
        }
    }

    func touch(_ what: String) {
        touches.append((what, world.now))
        if touches.count > 12 { touches.removeFirst(touches.count - 12) }
        if what == "shoo" { logTouch("shoo") } else if what == "drag" { logTouch("drag_from") }
    }

    /// where she is (her feet's middle, her screen's index, a window top or the floor), on each line of her pose
    /// journal (SpriteView) and his touches': so a replay can show where she settles and where he moved her from.
    static var lastPlace: [String: Any] = [:]

    var placeNow: [String: Any] {
        let cx = x + Body.size.width / 2
        return ["x": Int(cx), "y": Int(y), "screen": world.screens.firstIndex { $0.frame.minX <= cx && cx < $0.frame.maxX } ?? -1,
                "on": standingOn != nil ? "window" : "floor"]
    }

    func logTouch(_ kind: String) {
        Store.append(["at": world.now.timeIntervalSince1970, "touch": kind, "where": placeNow], to: "poses.jsonl", cap: 5_000_000)
    }

    func notice(_ what: String) {
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
    /// `asked`: your agent's cause when it asked for it (/iris/act's "why").
    func perform(_ id: String, seconds: Double, own: Bool = false, why: String = "", asked: String = "") {
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
        // Friday's own stretch nudge and reminder sticky note, so hers don't repeat them (bodyClips, dayCard)
        if !own && id == "stretch_guide" { fridayStretchAt = world.now }
        if !own && id == "sticky_note" { fridayNoteAt = world.now }
        actWhy = own ? why : asked.isEmpty ? "\(Config.agentName) asked for it" : "\(Config.agentName): " + asked   // /iris/act, with Core's reason
        performing = id
        performUntil = world.now.addingTimeInterval(max(1.5, min(20, seconds)))
        performMoves = e["moves"] == "yes"      // only clips whose feet really move travel (catalog.json)
        if sleeping && wakeWhy.isEmpty { wakeWhy = !asked.isEmpty ? "\(Config.agentName) asked: " + asked : !why.isEmpty ? why : "" }
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

    func coreAmbient(at t: Date) {
        if t <= world.now.addingTimeInterval(5) { coreAmbientAt = max(coreAmbientAt, t) }   // a clock that stepped: ignored
    }

    /// Her own next moment may come: Body.ambientGapS since the last one, hers or Core's.
    func ambientFree(_ now: Date) -> Bool {
        now.timeIntervalSince(max(coreAmbientAt, ownMoments.last?.at ?? .distantPast)) >= Body.ambientGapS
    }

    func ownMoment(_ kind: String) {
        let now = world.now
        ownMoments = (ownMoments + [(kind, now)]).filter { now.timeIntervalSince($0.at) < 3600 }.suffix(8).map { $0 }
    }
}
