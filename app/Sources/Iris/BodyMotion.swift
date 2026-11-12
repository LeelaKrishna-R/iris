import AppKit

// Iris's body — getting around (out of Body.swift): floors, window tops, the seam between his screens,
// her walk, hops and falls, and stepping out of his full-screen picture.
extension Body {
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
    func clampIn(_ d: Display, _ px: CGFloat) -> CGFloat {
        min(d.visibleFrame.maxX - Body.size.width, max(d.visibleFrame.minX, px))
    }

    /// A jump to (tx, ty) along a real arc: a short crouch, then off.
    /// `fromWindow`: why she is hopping off one of his windows (a drop of Stages.jumpDownAtLeast or more
    /// lands as "fall_land").
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
        // (sim 21 once she settled beside him)
        sit.target = 0; sit.value = 0; sit.vel = 0; workingAlong = false
        trace?("leap", ["from": [Double(x), Double(y)], "to": [Double(tx), Double(ty)], "height": Double(rise)])
    }

    func move(_ dt: CGFloat) {
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
                    walking = step(toward: t, dt); legLeft = abs(t - x)   // level floors: she just walks on
                } else if abs(edge - x) > 2 {
                    walking = step(toward: edge, dt); legLeft = abs(edge - x)   // this leg ends at the edge, in a hop down
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
                walking = step(toward: t, dt); legLeft = abs(t - x)
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
        if let was = myScreen?.id, was != mine.id { crossedAt = world.now }
        myScreen = (mine.id, mine.frame)
        lastFloor = vy == 0 && launch == nil && standingOn == nil ? floorAt(x) : nil
    }

    static let crossGap: TimeInterval = 300

    func checkFullScreen(_ now: Date, _ dt: CGFloat) {
        // fading: 0.25 s either way, then whatever comes next
        if let f = fade {
            alpha += (f.to > alpha ? 1 : -1) * dt / 0.25
            if (f.to > 0.5 && alpha >= f.to) || (f.to < 0.5 && alpha <= f.to) { alpha = f.to; fade = nil; f.then?() }
        }
        // only when it changes (it was set every frame), and faded out she isn't drawn (updateDrawing)
        if window?.alphaValue != alpha {
            window?.alphaValue = alpha
            updateDrawing()
        }
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
    func groundBelow() -> CGFloat {
        if standingOn != nil { return y }
        return floorAt(x)
    }

    /// A little jump for joy or fright where she stands; sitting (or about to), she
    /// bounces in her seat instead — a hop would stand her up and sit her down again.
    func hop(_ v: CGFloat) {
        guard launch == nil, !held else { return }
        // poses.jsonl 23:28:37: typing -> idle -> typing -> idle -> typing in 0.25 s, a startle hop on her laptop
        // (a chase just before had left sit at 0 while she still typed along): on her laptop she is seated too
        if sit.target > 0.5 || sit.value > 0.3 || sleeping || workingAlong { squash.kick(v / 110); tilt.kick(Bool.rnd() ? 0.5 : -0.5); return }
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

    /// Whether window i's top edge is showing where her feet would be at px: no window in
    /// front of it covers that stretch of its top.
    static func topVisible(_ ws: [SeenWindow], _ i: Int, _ px: CGFloat) -> Bool {
        let top = ws[i].frame.maxY - 2
        let feet = [px + 35, px + size.width / 2, px + size.width - 35]
        return !ws[..<i].contains { w in feet.contains { w.frame.contains(CGPoint(x: $0, y: top)) } }
    }

    /// She changes screens on her own only once he has been working on the other one this long.
    static let screenStay: Double = 120
}
