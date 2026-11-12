import AppKit

// Iris's body — him, instantly (out of Body.swift): his keys, scrolls, clicks and app switches, each
// answered inside the event that caused it, and what changed on his page.
extension Body {
    // MARK: him, instantly

    func event(_ e: NSEvent) {
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
        screenWokeHer = 0                                    // he's here: his screens matter again
        if performing == "doze" { performUntil = now }      // nodding off, his touch rouses her (no sleep after)
        if away > 120 { bossBack(away: away); activeSince = now }
    }

    /// The system's own key counter, every frame, as the backstop for the key
    /// monitor: after a rebuild macOS can keep reporting Accessibility while the
    /// global monitor silently stops delivering keys ("iris isn't being
    /// responsive to me typing"). Any key the counter saw that the monitor didn't
    /// is counted here, so his typing always reaches her.
    func keysFromCounter() {
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
        if sleeping && keyTimes.count >= 3 { wake("his typing") }       // a few keys, not one brushed
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
            if soul.feel(.fastScroll) > 0.3 && world.now.timeIntervalSince(dizzyAt) > Body.dizzyEveryS
                && ambientFree(world.now) {
                dizzyAt = world.now; dizzyT = 1.4; show("@_@")
                ownMoment("dizzy")
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

    func appSwitched(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        appSwitched(name: app.localizedName ?? "")
    }

    /// A new page or tab in the same app (his browsing): she glances up at it,
    /// her mind hears what he opened, and a video tab is noticed at once.
    func pageChanged() {
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
        if watchingVideo != was { Senses.set(music: musicOn, video: watchingVideo) }
        if watchingVideo && !was { _ = soul.feel(.video); think(soon: 0.2) }
    }

    private func bossBack(away: Double) {
        events.append("he just came back to the Mac")
        let k = soul.feel(.bossBack)
        // the hop and the wave are for him really coming back; two or three minutes of reading
        // without a touch is him still there, and gets only her eyes and a smile (a wave on
        // nearly every wake)
        // real log: back after 19, 9 and 9 minutes within an hour, three waves (13 in two hours):
        // his activity acknowledged rarely. The wave is for a long absence, or his first return in an hour.
        let greets = k > 0.25 && away >= Body.trulyAway
            && (away >= Body.longAway || world.now.timeIntervalSince(lastWaveAt) >= Body.waveEvery)
        trace?("boss_back", ["k": k, "was_sleeping": sleeping, "away": away, "greets": greets])
        // what woke her is said in her journal (without it, "woke: <agent> asked" was all it said)
        if sleeping { wakeWhy = "he came back to the Mac"; sleeping = false; wideT = 0.6; sit.target = 1 }
        guard k > 0.25 else { return }
        happyT = 1.6
        lookToward(world.mouse, snap: 0.6)               // a look at where his hand came back
        targetX = nil
        think(soon: 1.5)
        guard greets else { return }
        hop(380 * CGFloat(min(1, k + 0.3)))
        waveT = 1.8
        lastWaveAt = world.now
        waveWhy = String(format: "he came back after %.0f min away", away / 60)
        trace?("act", ["what": "wave", "why": waveWhy])
        show("♪")                                        // was "!" or "♪" by a coin
    }
}
