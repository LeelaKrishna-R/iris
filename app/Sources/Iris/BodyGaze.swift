import AppKit

// Iris's body — her gaze and face (out of Body.swift): where her eyes are between her bigger reactions,
// and settle(): her springs, face and pose each frame, and how warm each part of his screen is to her.
extension Body {
    func lookingElsewhere(_ now: Date) -> Bool { now < lookUntil }

    /// `head`: how far her head turns with her eyes (1 for a real look at something, less while she
    /// just keeps an eye on things). Close to her the eyes move less, so his cursor crossing her
    /// face is a smooth sweep, not a flip from one side to the other.
    func lookToward(_ p: CGPoint, snap: CGFloat, head: CGFloat = 1) {
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
    // In order: Friday speaking through her, or him
    // talking (the mic heard words): she looks at him, out of the screen, her head toward where he
    // works. His caret while he types. His cursor when it's near her (600 pt). Otherwise where his
    // screen last changed (her eyes' glance, the last 6 s), else his front window. A new window, a
    // new app, a click, a notification are quick glances that hold her eyes a moment (lookToward
    // with snap ≥ 0.5) before this resumes. Her rig moves the eyes and turns, nods and tilts the
    // head (Live: gaze, turn, nod, tilt), so every look is her eyes first and her head a little.

    static let followRange: CGFloat = 600

    /// He is talking (her ears heard words, to her or not): she looks at him for a moment.
    func heardVoice() {
        heardAt = world.now
        trace?("heard_voice", ["asleep": sleeping])
    }

    func attend(_ now: Date, cursor c: CGPoint, dist: CGFloat) {
        if now < talkUntil || now.timeIntervalSince(heardAt) < 2.5 { lookAtHim(); gazeMode = "him"; return }
        if now.timeIntervalSince(lastTyped) < 2, let k = focusCaret {
            lookToward(CGPoint(x: k.midX, y: k.midY), snap: 0.25, head: 0.7); gazeMode = "caret"; return
        }
        if dist < Body.followRange { look(c, mode: "cursor", head: 0.6, now); return }
        if let ch = changeSeen, now.timeIntervalSince(ch.at) < 6 { lookToward(ch.point, snap: 0.2, head: 0.5); gazeMode = "change"; return }
        if let fw = frontSeen { look(CGPoint(x: fw.midX, y: fw.midY), mode: "front", head: 0.5, now); return }
        look(c, mode: "cursor", head: 0.5, now)
    }

    /// her eyes on a point that doesn't move — the middle of his front
    /// window (56% of sim 47's afternoon) or his parked cursor — held there for minutes, which is a stare. After
    /// Body.restEyesAfter on the same still point she rests her eyes (down and ahead, her head back toward the
    /// middle); the cursor moving, his typing or a change on his screen brings them back at once.
    static let restEyesAfter: TimeInterval = 10

    private func look(_ p: CGPoint, mode: String, head: CGFloat, _ now: Date) {
        if let s = stillPoint, hypot(s.x - p.x, s.y - p.y) < 30, gazeMode == mode || gazeMode == "rest" {
            if now.timeIntervalSince(stillSince) >= Body.restEyesAfter {
                gx.target = 0; gy.target = -0.35; turn.target = turn.target * 0.3
                gazeMode = "rest"
                return
            }
        } else {
            stillPoint = p; stillSince = now
        }
        lookToward(p, snap: 0.2, head: head); gazeMode = mode
    }

    /// Eye contact: he sits in front of his screen, so her eyes come nearly to the middle (looking
    /// out at him) and her head turns a little toward where he works (his caret or cursor).
    func lookAtHim() {
        let me = CGPoint(x: x + Body.size.width / 2, y: y + Body.size.height * 0.68)
        let his = (world.now.timeIntervalSince(lastTyped) < 4 ? focusCaret.map { CGPoint(x: $0.midX, y: $0.midY) } : nil) ?? world.mouse
        let dx = his.x - me.x
        gx.target = max(-0.25, min(0.25, dx / 1600))
        gy.target = 0.08
        turn.target = (dx >= 0 ? 1 : -1) * max(0.14, min(0.3, abs(dx) / 1500))
    }

    /// Four times a second: a window that wasn't there a moment ago gets a quick look first.
    func noticeWindows(_ now: Date) {
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

    func settle(_ dt: CGFloat, _ now: Date) {
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
        Body.lastPlace = placeNow                // for her pose journal's "where"
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
        // woken, she was lying under her blanket one frame
        // and sitting up straight the next (sim 44 at 40.1 s, every wake in poses.jsonl: sleep -> sit held 0 s between).
        // Her own drawn wake_up is that in-between: she sits up in bed, rubs her eyes and yawns, then sits. Only when
        // nothing needs her at once — not carried, called (listening), greeting him, talking, walking off or already
        // in a clip of his touch — and its why is what woke her.
        // (the face she last showed was lying asleep — her sleep pose, not her snore, which sits up already)
        if face.sleeping && face.act.isEmpty && !sleeping {
            if performing.isEmpty && !held && !listening && waveT <= 0 && vy == 0 && now >= talkUntil && sit.target > 0.5 && targetX == nil {
                // woken earlier this frame, restWhy says by what; later in it, wakeWhy still does
                let why = !wakeWhy.isEmpty ? "woke: " + wakeWhy : wokeAt == now ? restWhy : "woke: \(Config.agentName) asked"
                perform("wake_up", seconds: Body.wakeUpSeconds, own: true, why: why)
                sit.target = 1                       // she sits up out of it; standing is a choice for later
            }
        }
        // the cause of what she's doing, in the world (poses.jsonl's why)
        // pose log: chase (his cursor flicking past her), sunset_watch, syntax_sparkles were logged
        // "\(Config.agentName) speaking through her" because talking outranked the clip's own cause; a clip she is
        // performing keeps its own cause.
        // read here, once this frame's clip has ended or begun (above). Read before them, the frame her
        // wake_up began carried her last rest's cause (poses.jsonl "clip wake_up: woke: he came back
        // to the Mac", idle_s 1695: their screen had woken her; "clip wake_up: settled while he
        // works"), and her stand after a clip carried the clip's.
        // "Why did you do that" is answered from that journal (core/iris_brains.why_asked).
        f.why = held ? "they're carrying her" : listening ? "they're talking to her" : !performing.isEmpty ? actWhy
            : now < talkUntil ? "\(Config.agentName) speaking through her" : sleeping ? sleepWhy : waveT > 0 ? waveWhy
            : currentWalk > 0.05 ? walkWhy : workingAlong ? "typing along with them" : restWhy
        // deep asleep (Stages.deepSleepAfter): she snores, sitting up, instead of her sleep pose
        let snoring = performing.isEmpty && Stages.snoring(asleep: sleeping, asleepFor: now.timeIntervalSince(sleptAt))
        f.act = snoring ? "snore" : performing
        if snoring { f.why = String(format: "deep asleep: asleep %.0f min or more (%@)", Stages.deepSleepAfter / 60, sleepWhy) }
        // how she walks when her walk's cause changes it, and what she does seated when a drawn clip says
        // it better than her sit pose — each from her state (Stages), its why in poses.jsonl
        let walkingNow = currentWalk > 0.05 && !held && !listening
        f.gait = Stages.gait(walking: walkingNow, inAir: vy != 0 || launch != nil,
                             shooed: shooWalkTo != nil && targetX.map { abs($0 - shooWalkTo!) < 1 } == true, walkWhy: walkWhy,
                             left: targetX == nil ? 0 : Double(legLeft), running: face.gait == "run")
        let seat = Stages.seat(seated: sit.target > 0.5 && performing.isEmpty, onWindow: standingOn != nil && vy == 0,
                               typingAlong: workingAlong, watchingVideo: watchingVideo, asleep: sleeping, listening: listening,
                               talking: now < talkUntil, seatedFor: seatedAwakeSince.map { now.timeIntervalSince($0) } ?? 0,
                               hisIdle: now.timeIntervalSince(lastInput), sinceKeys: now.timeIntervalSince(lastTyped),
                               sleepiness: soul.sleepiness, screenMoving: screenMoving, callOn: callSince != nil, music: musicOn,
                               fishing: face.seat == "fishing", noteFor: noteShown)
        f.seat = seat?.clip ?? ""
        if let seat, performing.isEmpty, !sleeping, !held, now >= talkUntil, waveT <= 0, currentWalk <= 0.05 { f.why = seat.why }
        f.snug = sleeping && now.timeIntervalSince(sleptAt) > 150
        f.actMoves = performMoves
        f.vy = vy
        face = f
        view?.face = f
    }

    func show(_ e: String) { emote = e; emoteAge = 0 }

    private static func cell(_ p: CGPoint) -> Int { Int((p.x / 80).rounded(.down)) * 100_000 + Int((p.y / 80).rounded(.down)) }

    func warm(_ p: CGPoint, by v: CGFloat) {
        let k = Body.cell(p)
        heat[k] = min(30, (heat[k] ?? 0) + v)
    }

    /// How much of his recent attention a rect of hers would cover (0…~1).
    func attentionUnder(_ me: CGRect) -> Double {
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

    func readInto(_ now: Date) {
        // every 2 s while the front app stays the same (once a second, it was her top own cost in a
        // sample with him typing); at once when he's moved to another app
        let app = world.frontApp ?? ""
        guard !intoBusy, now.timeIntervalSince(intoAskedAt) >= (app == intoApp ? 2 : 0) else { return }
        intoBusy = true; intoAskedAt = now; intoApp = app
        let w = world
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = w.keysInto()
            DispatchQueue.main.async { [weak self] in self?.typedInto = (r.kind, r.why, now); self?.intoBusy = false }
        }
    }

    func readFocus() {
        lastFocusRead = world.now
        let f = world.focus()
        focusCaret = f.caret
        focusField = f.field
    }

    /// He's typing and she's on top of it: it feels wrong right away, the spot
    /// is remembered as a bad one, and it bothers her more the next time.
    func feelInTheWay(_ dt: CGFloat, _ now: Date) {
        guard !held, now.timeIntervalSince(lastTyped) < 2 else { wayT = max(0, wayT - dt); return }
        let me = CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)
        let bad = inTheWay(me)
        guard bad > 0.3 else { wayT = max(0, wayT - dt); return }
        wayT += dt
        if sleeping { wake("in the way of their typing") }        // asleep on what he's typing in: she wakes and moves
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
}
