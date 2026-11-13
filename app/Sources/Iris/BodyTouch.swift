import AppKit

// Iris's body — their touch (out of Body.swift): their pointer resting on her, a click, a double-click, being
// carried and dropped, and the cursor's quick passes near her.
extension Body {
    func hover(_ on: Bool) {
        hovering = on
        // their look counts when the person brought the cursor to her, not when she walked under a still one
        hoverSince = on && world.now.timeIntervalSince(cursorMovedAt) < 0.5 ? world.now : nil
        if on { notice("the person hovered their cursor over you") }
        if on && soul.feel(.hover) > 0.2 {
            catT = 1.2
            tilt.kick(Double.rnd(0...1) < 0.5 ? 1.2 : -1.2)
        }
    }

    func petted() {
        touch("pet")
        _ = soul.feel(.petted)
        soul.reward(1)
        notice("the person petted you")
        soul.feelPlace(x + Body.size.width / 2, y, 0.3)
        if sleeping { wakeWhy = "the person petted her"; sleeping = false; sit.target = 1; wideT = 0.3 }
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
        notice("the person double-clicked you")
        if sleeping { wakeWhy = "the person double-clicked her"; sleeping = false; sit.target = 1 }
        happyT = 2.2; giggleT = 0
        petTimes.removeAll()
        if hovering { hoverSince = world.now }
        onDoublePetted?()
        touchClip("bow", 2.4, "double_click")
    }

    /// Her reaction to their touch: the clip, at once, traced for the simulator.
    func touchClip(_ id: String, _ seconds: Double, _ why: String) {
        trace?("touch", ["what": why, "clip": id, "air": vy != 0])
        perform(id, seconds: seconds, own: true, why: Body.touchWhy[why] ?? why)
        touchUntil = performUntil
    }

    func dragged(_ p: CGPoint) {
        if !held {
            notice("the person picked you up and moved you")
            touch("drag")
            performing = ""; performMoves = false; fall = nil     // a clip stops when the person picks her up
            flickTimes.removeAll()                                 // their cursor darting to grab her isn't play
            held = true; _ = soul.feel(.dragged); wideT = 0.4; targetX = nil; perchTop = nil
            standingOn = nil; standingID = nil; perchID = nil; launch = nil; vx = 0; leapTo = nil
            jumpDown = nil; shooWalkTo = nil; dozeWhy = nil; alongSince = nil   // carried, no stretch after
            pickedUpAt = CGPoint(x: x + Body.size.width / 2, y: y)
        }
        x = p.x - Body.size.width / 2
        y = p.y - Body.size.height * 0.8
    }

    func dropped() {
        defer { logTouch("drag_to") }            // where the person set her down
        held = false
        vy = 0
        sit.target = 0; sit.value = 0; sit.vel = 0; workingAlong = false     // carried, she's on her feet when let go
        _ = soul.feel(.dropped)
        soul.reward(-0.5)
        // the person moved her: where she was was wrong, where the person put her is fine
        if let p = pickedUpAt { soul.feelPlace(p.x, p.y, -0.45) }
        // (UX audit #9): carried away (not set down where she was) while the person works: she was in their way
        if let p = pickedUpAt, abs(x + Body.size.width / 2 - p.x) > Body.size.width,
           world.now.timeIntervalSince(lastTyped) < Body.workingS { soul.interrupted(0.5) }
        soul.feelPlace(x + Body.size.width / 2, screenAt(x + Body.size.width / 2).visibleFrame.minY, 0.15)
        pickedUpAt = nil
        poutT = 1.5
        // let go of high up: she falls, and gets up from it when she lands (getup, "after falling")
        fall = y - groundBelow() > 200 ? (y, world.now) : nil
        if hovering { hoverSince = world.now }
        hisScreenSince = world.now          // where the person put her is her place for a while, wherever the person works
        placedAt = world.now
    }

    /// Every frame: their cursor resting on her, or darting about near her.
    func touchReactions(_ now: Date, cursor c: CGPoint, me: CGPoint, dist: CGFloat) {
        // resting on her 2 s: one line of their day in her bubble, from their day card's rows (DayCard.hint:
        // "Next: Dentist at 2:00 PM", "3 kept for you"), never spoken; a curious look up at them. (owner: "iris
        // needs improvement"): her shy and blush-hide here were a reaction with nothing for them in it
        if let hs = hoverSince, now.timeIntervalSince(hs) >= 2, now >= touchUntil {
            hoverSince = nil                                    // once per hover
            if !held && !sleeping {
                notice("the person rested their cursor on you")
                let line = onHoverHint?()
                trace?("touch", ["what": "hover", "clip": "hint", "said": line != nil, "air": vy != 0])
                curiousT = max(curiousT, 1.2)
                if let line { say(line, for: 4) }
            }
        }
        // their cursor darting past her, again and again, while the person isn't typing: she plays —
        // chases it, or pounces when it's right by her. At most every 2 minutes.
        if let first = flickTimes.first, now.timeIntervalSince(first) >= 8 { flickTimes.removeFirst() }   // only passes of the last 8 s
        if cursorSpeed > 1800 && dist < 320 && !held && now.timeIntervalSince(lastFlickAt) > 0.6 {
            lastFlickAt = now
            flickTimes.append(now)
        }
        // poses.jsonl 23:23:25: let go of high up, a chase began in mid-fall and the landing's getup cut it
        // off 0.2 s in: she plays with their cursor with her feet on the ground, once what the person did to her has played out
        if flickTimes.count >= 3 && now.timeIntervalSince(lastChaseAt) >= Body.chaseEveryS(soul.memory.playfulness)
            && !held && !sleeping && vy == 0 && fall == nil
            && now >= touchUntil
            && now.timeIntervalSince(lastTyped) > 4 && !deepFocus && !watchingVideo {
            lastChaseAt = now
            flickTimes.removeAll()
            face.flip = c.x < me.x                              // toward their cursor
            notice("the person played with you with their cursor")
            soul.did("play")                      // a shoo or drag in the minute after teaches her playfulness
            touchClip(dist < 140 ? "pounce" : "chase", 2.6, "cursor_play")
        }
    }
}
