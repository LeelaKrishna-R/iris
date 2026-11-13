import AppKit

// Iris's body — her mind (out of Body.swift): what she wants to do next, from her feelings at irregular
// moments (think), where she goes (choosePlace), keeping out of his way, sleeping and waking, and being awake with him.
extension Body {
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
    var screenMoving: Bool { eyes?.changingRecently ?? world.screenChanging }

    static func isVideo(app: String, title: String?) -> Bool {
        let a = app.lowercased(), t = (title ?? "").lowercased()
        return ["youtube", "netflix", "tv", "quicktime", "vlc", "iina", "plex", "prime"].contains { a.contains($0) }
            || ["youtube", "netflix", "prime video", "disney+", "twitch", "hulu", "vimeo", "plex", "crunchyroll"].contains { t.contains($0) }
    }

    func think(soon: Double? = nil) {
        if let s = soon { nextThought = world.now.addingTimeInterval(s); return }
        // what's on his screen now (a tab can turn into a video without an app switch)
        let wasVideo = watchingVideo
        watchingVideo = Body.isVideo(app: world.frontApp ?? "", title: world.frontTitle) && screenMoving
        if watchingVideo != wasVideo { Senses.set(music: musicOn, video: watchingVideo) }
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
            if now < napUntil { return }            // the nap he asked for (hold "sleep")
            if idle < 3 { wake("their hands on the Mac") }
            // something happening on a screen wakes her too, him there or not —
            // when it keeps happening; a few seconds of change is a flicker. poses.jsonl
            // 06:01-12:31: away all morning, a busy Discord woke her 26 times, each a sit, a fishing stint
            // and asleep again. Each time the screen woke her and he didn't come, the next takes twice as
            // long a stretch of it (20 s, 40, 80 …); his own touch starts it over (touched()).
            else if let since = screenMovingSince {
                let needs = Body.screenWakeAfter * pow(2, Double(min(screenWokeHer, 6)))
                if now.timeIntervalSince(since) >= needs {
                    screenWokeHer += 1
                    wake(String(format: "their screen kept changing %.0f s (%@)", now.timeIntervalSince(since), world.frontApp ?? "a screen"))
                }
            }
            return
        }
        // where the action is: his full-screen film or a call sends her to a quiet
        // corner; ten minutes with nothing happening send her to her favourite spot first
        let corner = watchCorner()
        let nothing = idle >= Body.homeAfter && !screenMoving && !world.callOn && !world.soundOn && !watchingVideo
        // late at night she dozes off after two quiet minutes instead of five — only
        // when the screens are still too: a movie, a chat or code being written
        // without his hands is still something to watch
        // (and not straight after waking, and only once the screens have been still a minute)
        let dozy = idle > (watchingVideo ? 900 : Soul.lateNight ? 120 : 300)
            && now.timeIntervalSince(screenMovedAt) > Body.screenStillToDoze && now.timeIntervalSince(wokeAt) > Body.wakeHolds
            && s.sleepiness > (Soul.lateNight ? 0.4 : 0.55)
        // (sleepy before the ten minutes are up, she goes home to doze off there)
        let home = corner == nil && (nothing || dozy) ? favouriteSpot() : nil
        let goingHome = home.map { abs($0 - x) > 40 || standingOn != nil } ?? false
        // (owner: why aren't her animations used?): falling asleep has a stage he can see. Standing,
        // she dozes on her feet first ("doze": head drooping, snapping up, drooping) and falls asleep when
        // it ends, unless he touched the Mac meanwhile; seated, she falls asleep where she sits. Both only
        // when everything above says dozy (it was also a draw against her sleepiness: no dice, rule).
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

        let pick = corner.map { Spot(x: $0, perch: nil, nearHim: false, why: world.callOn ? "corner: a call" : "corner: their film") }
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
        // (33 stand-sit-stand flips inside a minute, from 1-2 s walks between two seats)
        let seated = sit.target > 0.5 && !hurry && corner == nil && home == nil
            && screenAt(pick.x + Body.size.width / 2).frame == screenAt(x + Body.size.width / 2).frame
        let stay = seated && (now.timeIntervalSince(satSince) < Body.sitHolds || far <= Body.seatedStep)
        // and a walk needs a reason in the world ("her actions are so random for no
        // reason"): his call, film or an empty room; out of his way; closer to him; beside his front
        // window; the screen he's working on; her mind's want; or the walk she's already on
        let meNow = CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)
        let otherScreen = screenAt(pick.x + Body.size.width / 2).frame != screenAt(x + Body.size.width / 2).frame
        // ( poses.jsonl 13:40-23:18, him away for hours: woken by a chat moving on a screen, she
        // walked "to the screen they're working on", sat, walked "home", sat, walked off toward his
        // cursor and home again, 44 home walks since noon. Away, his cursor is where he left it, not
        // him, and no screen is one he's working on: neither is a reason to walk.)
        let here = idle < Body.trulyAway
        let pull: String? = corner != nil || home != nil ? pick.why
            : hurry || inTheWay(meNow) > 0.3 ? "out of their way"
            : targetX.map({ abs($0 - pick.x) < 1 }) == true ? walkWhy
            : otherScreen && here ? "to the screen they're working on"
            : attendX.map({ abs($0 - pick.x) < 60 }) == true ? "beside their front window"
            : pick.nearHim && here && abs(meNow.midX - world.mouse.x) > 450 ? "closer to them"
            : ["explore", "give_space", "be_close"].contains(wanting.want) && wanting.k > 0.3 ? "her mind: \(wanting.want)"
            : nil
        if !stay, let pull, (far > 40 || (!atPerch && far > 0.5) || (pick.x == targetX && targetX != nil)) {
            walkWhy = pull
            let same = targetX.map { abs($0 - pick.x) < 1 } ?? false
            targetX = pick.x
            if !same { speed = 34 + CGFloat(s.arousal) * 46 + (s.arousal > 0.8 && far > 500 ? 60 : 0); walkSince = world.now }   // a walk keeps its pace
            if !same { trace?("walk", ["why": pull, "idle": idle, "to": Double(pick.x)]) }
            if hurry { speed = max(speed, 240); hurry = false }    // in his way while he types: she scurries
            // poses.jsonl: 8 crossings to the screen he's working on took 13.4 of 60 min (a stroll across a
            // whole display); she runs there, a short trip, then she's with him
            if pull == "to the screen they're working on" { speed = max(speed, Body.crossSpeed) }
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
            // got there, then up again for the next walk, was the stand-sit-stand thrash)
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
                // (getting up or sitting down by dice was the random posture he sees)
                _ = settle
                // all a settle needs but a calm cursor (review with only that missing, her next look was
                // 25-140 s away, so while he mouses steadily she could stand for minutes)
                let settleReady = idle < Stages.awayFor && world.now.timeIntervalSince(walkSince) >= Body.settleAfter
                    && inTheWay(CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)) <= 0.3
                    && (!Body.isVideo(app: world.frontApp ?? "", title: world.frontTitle)
                        || Double(abs(x + Body.size.width / 2 - world.mouse.x)) < Body.withinReach)
                // a calm moment, not mid-shake across her (sim 37); his mousing elsewhere is no shake (sim 54: a move
                // every 1-3 s anywhere on the screen kept her standing 545-658 s)
                let cursorCalm = world.now.timeIntervalSince(cursorNearMovedAt) > 2
                let sitFor: String? = typedFor > 0 ? "keeping them company while the person types"
                    : watchingVideo ? "watching their video with them"
                    : deepFocus ? "keeping them company while the person focuses"
                    : s.sleepiness > 0.45 ? String(format: "sleepy %.2f", s.sleepiness)
                    : ["watch", "rest", "work_along", "nap"].contains(w.want) && w.k > 0.3 ? "her mind: \(w.want)"
                    // (sim 28 lively browsing: standing 596 of 600 s): near him a few
                    // minutes with no walk, she settles down beside him while he reads or browses
                    // standing still for minutes read as staring; near
                    // him she settles after a minute with no walk (was 3), never over his work; far from his cursor
                    // (in front of his video, sim 24) she still waits for a walk with a reason
                    // (poses.jsonl 14:40-15:02: standing 595, 368 and 147 s): his cursor out of her reach,
                    // or two minutes since his last touch while he reads, held her standing with nothing to sit her
                    // down. With him at the Mac she settles wherever his hand is (sim 53); with a video in front
                    // (his front app and title say so), only near his hand, so she isn't settled in front of it (sim 24)
                    : settleReady && cursorCalm
                        ? "settled while the person works"            // never over his work or what he's watching (sim 24)
                    : nil
                sit.target = wasSitting || sitFor != nil ? 1 : 0
                if sit.target > 0.5 && !wasSitting { satSince = world.now; restWhy = sitFor ?? "" }
                // a few seconds into his typing
                // she gets her own laptop out and types along, key for key, every time (it was by dice,
                // 8-20 s in, "never certain"); 20 s after he stops it goes away
                let along = typedFor > typeAlongAfter
                if along && !wasSitting { sit.target = 1; satSince = world.now; restWhy = "typing along with them" }
                workingAlong = sit.target > 0.5 && (along || workingAlong && world.now.timeIntervalSince(lastTyped) < Body.typeAlongHoldS
                    || w.want == "work_along" && w.k > 0.5 && idle < 60)
                // while he keeps typing she checks in again sooner; once he stops, the laptop goes away in time
                if typedFor > 0 && !workingAlong { postureUntil = world.now.addingTimeInterval(Double.rnd(6...15)) }
                if workingAlong && world.now.timeIntervalSince(lastTyped) > Body.typeAlongHoldS && w.want != "work_along" { workingAlong = false }
                if w.want == "watch", let fw = world.frontWindow() { lookToward(CGPoint(x: fw.midX, y: fw.midY), snap: 0.6) }
                if world.now > postureUntil {
                    // standing, she looks again when her minute without a walk is up, not up to 140 s later (sim 53)
                    let settleIn = walkSince.addingTimeInterval(Body.settleAfter).timeIntervalSince(world.now)
                    postureUntil = world.now.addingTimeInterval(sit.target < 0.5 && settleReady && !cursorCalm ? 3
                        : sit.target < 0.5 && settleIn > 0 ? min(Double.rnd(25...140), settleIn + 1) : Double.rnd(25...140))
                }
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
        // nothing of her own by dice. Each
        // move has a cause in the world — his typing stopping (a nod, frame()), his cursor resting on
        // her (shy), his hand on her, music (sway, dance), his return after 5 min (one wave) — and
        // here, late and sleepy, a yawn now and then. Otherwise she breathes, blinks, and her eyes
        // follow what he's doing (attend()). Long stretches at the Mac are Core's to mention, with
        // the measured fact (her old "Stretch with me?" line and its wave are gone).
        if Soul.lateNight && s.sleepiness > 0.6 && !typing && corner == nil && targetX == nil && performing.isEmpty
            && now.timeIntervalSince(lastYawnAt) > Body.yawnEveryS && now.timeIntervalSince(lastInput) < 300
            && ambientFree(now) {
            // every 5 min was up to 12 yawns an hour, him there or not; at most every half hour, while he's at the Mac
            lastYawnAt = now
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            perform("yawn", seconds: 2.6, own: true,
                    why: String(format: "%d:%02d at night, sleepy %.2f", c.hour ?? 0, c.minute ?? 0, s.sleepiness))
            ownMoment("yawn")
        }
    }

    private struct Spot { var x: CGFloat; var perch: CGFloat?; var nearHim: Bool; var why = ""; var perchID: Int? = nil }

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
        // not him; nothing of his draws her (see think)
        let himHere = idle < Body.trulyAway
        let mayCross = world.now.timeIntervalSince(crossedAt) >= Body.crossGap
        let invited = !himHere || !mayCross ? nil
            : hisScreen.flatMap { h in h != mineIdx && world.now.timeIntervalSince(hisScreenSince) >= Body.screenStay ? h : nil }
            ?? frontInvite          // or his front window has settled over there (Body.frontStay, 2 min) with him
        // beside his front window: a pull while he's around (gentle while he types — she keeps him company where she is)
        // (up on one of his windows she's already among his things: that seat is hers to keep)
        let attend = idle < 180 && standingOn == nil ? attendX : nil
        func screenOf(_ px: CGFloat) -> Int? { screens.firstIndex { $0.frame.minX <= px + Body.size.width / 2 && px + Body.size.width / 2 < $0.frame.maxX } }
        for (i, scr) in screens.enumerated() where scr.frame != fullScreenFrame {
            let f = scr.visibleFrame
            // (owner rule no dice): evenly spaced across the floor, not random positions
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
            // its left, middle and right of the top she can stand on (were three random points)
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
            var nearW = !himHere ? 0 : (typing ? max(s.affection, 0.5) : s.affection) * (0.4 + s.memory.cling)
                * (typing ? 0.6 * Body.focusRespectPull(s.memory.focusRespect) : 1.2)
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
            // there (boredom made her cross the screen every ~15 s while he typed)
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
            return si == mineIdx || si == invited
                || (mayCross && typing && bestHere > 0 && clear[i] && crossings[i] < bestHere)
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
        // the best spot (owner rule nothing of hers by dice). It was a weighted draw, "the best
        // most of the time, never always", plus random noise on each score and a 4% whim: walks to spots that
        // weren't the best, part of 17 minutes walking in an hour (poses.jsonl 12:54-13:54)
        return scored.max { $0.1 < $1.1 }!.0
    }

    /// How much a rect of hers covers his work: the caret most, the field he's typing in less.
    func inTheWay(_ me: CGRect) -> Double {
        var bad = 0.0
        if let caret = focusCaret {
            let zone = caret.insetBy(dx: -170, dy: -90)
            noteWay(zone)
            if me.intersects(zone) { bad += 1.0 }
        }
        if let field = focusField {
            let z = field.insetBy(dx: -20, dy: -20)
            noteWay(z)
            if me.intersects(z) {
                let i = me.intersection(z)
                bad += 0.8 * Double(i.width * i.height / (me.width * me.height))
                    + (field.width * field.height < 400_000 ? 0.5 : 0)     // a small box: she'd be covering it
            }
        }
        return bad
    }

    func inTheWayAt(_ px: CGFloat) -> Bool {
        let y = screenAt(px + Body.size.width / 2).visibleFrame.minY
        let me = CGRect(x: px, y: y, width: Body.size.width, height: Body.size.height)
        return inTheWay(me) > 0.3 || recentWays.contains { $0.0.intersects(me) }
    }

    /// A text field or caret zone he used, kept 10 min (the same spot is noted once).
    private func noteWay(_ zone: CGRect) {
        let now = world.now
        recentWays.removeAll { now.timeIntervalSince($0.1) > 600 || $0.0 == zone }
        recentWays.append((zone, now))
        if recentWays.count > 24 { recentWays.removeFirst(recentWays.count - 24) }
    }

    func fallAsleep(_ why: String) {
        if !sleeping { sleepWhy = why }
        if !sleeping { sleptAt = world.now; trace?("fell_asleep", ["sleepiness": soul.sleepiness]) }
        sleeping = true
        targetX = nil
        sit.target = 1
    }

    /// `why`: what woke her, in the world (her journal's, it said only).
    func wake(_ why: String) {
        guard sleeping else { return }
        wakeWhy = why
        sleeping = false
        sit.target = 1                          // she sits up; standing is a choice for later
        wideT = 0.3
        armL.kick(-10); armR.kick(-10)          // a stretch
        soul.sleepiness = max(0, soul.sleepiness - 0.4)
    }

    // MARK: where the action is
    //
    // His front window is where his day is happening. Once it has settled on his other screen
    // (moved there, or he clicked into a window there) for 20 s with him there too, she notices
    // and crosses over to sit near it — walking to the edge and hopping across as always. On her
    // own screen she drifts, slowly, to a spot beside it (never under his caret or field: the
    // bubble's avoid list). A call (another app has the mic) or his full-screen film sends her
    // to a corner to sit and watch, quietly; ten minutes with nothing happening, home.

    /// The front window has to stay on the other screen this long before she goes to it.
    static let calmRadius: CGFloat = 250       // his cursor moving within this of her is a shake across her (sim 37); farther is his work (sim 54)

    static let withinReach: Double = 500       // pt from his hand: farther for farFor, and him busy elsewhere, her place pulls little

    static let settleAfter: Double = 60        // s standing near him with no walk, then she sits

    static let likesPerch: Double = 0.25       // her liking for a window top beside him (a trait)

    static let farFor: Double = 20             // s his hand stays out of reach before she goes to him

    static let crossSpeed: CGFloat = 320       // pt/s on her way to the screen he's working on (a run)

    static let frontStay: Double = 60          // was 20 s; 8 crossings in 45 min; with her run across (08382125) a minute balances both

    /// Nothing happening for this long and she goes to her favourite spot.
    static let homeAfter: Double = 600

    // pose log: "typing along with them" 74 times in 3 h, in and out with every burst of keys
    static let typeAlongAfterS: Double = 15     // his typing this long: her laptop comes out (was 4)

    static let typeAlongHoldS: Double = 90      // and goes away this long after his last key (was 20)

    static let ambientGapS: Double = 1200       // one moment of her own at a time, hers or Core's (core/iris_reflex.AMBIENT_GAP_S)

    static let workingS: Double = 30            // he typed this recently: he's working, and a shoo or drag says she was in the way

    /// her pull toward him while he types, by how much she has learned to respect his focus (Soul.interrupted):
    /// 1 at the 0.5 she starts with, lower as his shoos and drags teach her, never higher than that, at least 0.4.
    static func focusRespectPull(_ respect: Double) -> Double { max(0.4, min(1, (1 - respect) / 0.5)) }

    /// her cursor chase at most every 2 minutes, longer as his shoos and drags after one teach her he isn't
    /// playing (Soul's playfulness, 0.6 at first), up to 10 minutes; never sooner.
    static func chaseEveryS(_ playfulness: Double) -> Double { min(600, 120 * max(1, 0.6 / max(0.05, playfulness))) }

    static let yawnEveryS: Double = 1800        // her late-night yawn, at most this often

    static let dizzyEveryS: Double = 1800       // her "@_@" at his fast scrolling, at most this often

    static let nodEveryS: Double = 600          // her nod when a stretch of his typing stops, at most this often (was 30 min)

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
    static let trulyAway: Double = 600         // as Stages.awayFor — a long read is no return to greet

    /// A return after this long always gets the wave; a shorter one only if she hasn't waved in `waveEvery`.
    static let longAway: Double = 1800

    static let waveEvery: Double = 3600

    /// Seated, she stays seated at least this long, and gets up only to go somewhere worth it.
    static let sitHolds: Double = 60

    static let seatedStep: CGFloat = 160

    /// Her drawn wake_up: sitting up in bed, rubbing her eyes, a yawn — 8 frames at 0.3 s (SpriteView.pace).
    static let wakeUpSeconds: Double = 2.4

    /// Seconds of her drawn stretch ("yoga", 8 frames at SpriteView.pace 0.35) and sticky note (8 at 0.13, twice).
    static let yogaSeconds: Double = 3

    static let noteSeconds: Double = 2.2

    /// The cause of each touch clip, in his terms.
    static let touchWhy = ["pet": "the person petted her", "pets": "the person petted her again and again", "double_click": "the person double-clicked her",
                           "hover": "their cursor rested on her",
                           "cursor_play": "their cursor darted past her again and again", "fall": "she fell when the person let go of her"]

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
    func watchAction(_ now: Date) {
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
            // poses.jsonl (his 10:41-11:35 call): she walked to a new corner six times, because the corner
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

    nonisolated static let catalog: [String: [String: String]] = {     // read once, then only read (any thread)
        // in the app bundle; run from .build/ (the simulator), from the package's Resources
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let dev = ["../../Resources/catalog.json", "../../../Resources/catalog.json"]      // .build/release or .build/<arch>/release
            .map { exe.appendingPathComponent($0).standardizedFileURL }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let u = Bundle.main.url(forResource: "catalog", withExtension: "json") ?? dev,
              let d = try? Data(contentsOf: u), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return [:] }
        return Dictionary(a.compactMap { e in e["id"].map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
    }()
}
