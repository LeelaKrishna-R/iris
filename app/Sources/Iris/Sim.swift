import AppKit

/// `Iris --simulate scenario.json [out.json] [--seeds ]`: her real Body
/// and Soul, headless, against made-up screens, windows, a cursor, typing,
/// petting and dragging, on a clock stepped at 60 frames a second as fast as
/// the Mac can go. Every frame is checked for what looks wrong on his screens
/// (a jump across a monitor seam, a fall between displays, standing half on
/// two screens, sitting on his text box while he types, walking one way and
/// facing the other, turning back and forth) and a sample of frames, every
/// decision and the reasons she gave are written to JSON. Her memory lives in
/// a scratch folder, never in ~/Library/Application Support/Iris.
final class SimWorld: World {
    var musicPlaying = false
    var callOn = false
    var soundOn = false
    var now: Date
    var screens: [Display]
    var mouse = CGPoint.zero
    /// His windows, frontmost first. `window` is the front one (id 1 when a scenario names only it).
    var wins: [SeenWindow] = []
    var window: CGRect? {
        get { wins.first?.frame }
        set {
            if let r = newValue {
                if !wins.isEmpty { wins[0].frame = r } else { wins = [SeenWindow(id: 1, frame: r, app: frontApp ?? "")] }
            } else if !wins.isEmpty { wins.removeFirst() }
        }
    }
    var field: CGRect?
    var caret: CGRect?
    var frontApp: String?
    var frontTitle: String?
    var screenChanging = false
    var screenChange: (at: Date, point: CGPoint)?
    var keyCounter: UInt32 = 0
    var handsIdle: Double = 0
    var accessibility = true
    init(now: Date, screens: [Display]) { self.now = now; self.screens = screens }
    func frontWindow() -> CGRect? { wins.first?.frame }
    func windows(maxAge: Double) -> [SeenWindow] { wins }
    func focus() -> (field: CGRect?, caret: CGRect?) { (field, caret) }
    func keysInto() -> (kind: String, why: String) { ("unknown", "simulated") }
}

enum Sim {
    static let fps = 60.0

    static func rect(_ a: Any?) -> CGRect? {
        guard let v = a as? [Double], v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    static func point(_ a: Any?) -> CGPoint? {
        guard let v = a as? [Double], v.count == 2 else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }

    /// The owner's displays (measured 2026-10-10 with NSScreen): the Dell
    /// 1920×1080 is primary with a 85-pt Dock at the bottom; the KG241Y is
    /// portrait, 1080×1920, to its left, and hangs 435 pt lower.
    static let ownerScreens: [Display] = [
        Display(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 85, width: 1920, height: 970), id: 1),
        Display(frame: CGRect(x: -1080, y: -435, width: 1080, height: 1920), visibleFrame: CGRect(x: -1080, y: -435, width: 1080, height: 1920), id: 2),
    ]

    static func windows(_ a: Any?) -> [SeenWindow] {
        guard let list = a as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { i, d in
            guard let f = rect(d["frame"]) else { return nil }
            return SeenWindow(id: d["id"] as? Int ?? i + 1, frame: f, app: d["app"] as? String ?? "")
        }
    }

    static func screens(_ a: Any?) -> [Display] {
        if let s = a as? String, s == "owner" { return ownerScreens }
        guard let list = a as? [[String: Any]] else { return ownerScreens }
        return list.enumerated().compactMap { i, d in
            guard let f = rect(d["frame"]) else { return nil }
            return Display(frame: f, visibleFrame: rect(d["visible"]) ?? f, id: UInt32(d["id"] as? Int ?? i + 1))
        }
    }

    static func run(_ args: [String]) {
        let path = args[2]
        let out = args.count > 3 && !args[3].hasPrefix("--") ? args[3] : nil
        var seeds: [UInt64] = []
        if let i = args.firstIndex(of: "--seeds"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: "-").compactMap { UInt64($0) }
            if parts.count == 2 { seeds = Array(parts[0]...parts[1]) } else { seeds = parts }
        }
        guard let data = FileManager.default.contents(atPath: path),
              let sc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("can't read scenario \(path)"); exit(2)
        }
        if seeds.isEmpty { seeds = [UInt64((sc["seed"] as? Int) ?? 1)] }
        var runs: [[String: Any]] = []
        var totals: [String: Double] = [:]
        for seed in seeds {
            let r = runOnce(sc, seed: seed, keepFrames: seeds.count == 1)
            runs.append(r)
            for (k, v) in (r["findings"] as? [String: Any] ?? [:]) { if let n = v as? Double { totals[k, default: 0] += n } else if let n = v as? Int { totals[k, default: 0] += Double(n) } }
        }
        let avg = totals.mapValues { ($0 / Double(seeds.count) * 100).rounded() / 100 }
        let result: [String: Any] = ["scenario": sc["name"] ?? path, "seeds": seeds.map { Int($0) },
                                     "mean_findings": avg, "runs": runs]
        let o = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let out { try! o.write(to: URL(fileURLWithPath: out)) }
        // the summary to the terminal
        print("\(sc["name"] ?? path) — \(seeds.count) run(s)")
        for k in avg.keys.sorted() where avg[k]! != 0 { print(String(format: "  %-26@ %8.2f", k as NSString, avg[k]!)) }
        if seeds.count == 1, let notes = runs[0]["notes"] as? [String] { for n in notes.prefix(40) { print("  · " + n) } }
    }

    // MARK: one run

    static func runOnce(_ sc: [String: Any], seed: UInt64, keepFrames: Bool) -> [String: Any] {
        dice = Dice(seed: seed)
        // her memory: a fresh one, or a copy of what she has learned on his Mac (read, never written)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iris-sim-\(ProcessInfo.processInfo.processIdentifier)-\(seed)")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        if (sc["memory"] as? String) == "owner" {
            let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Iris/soul.json")
            if let d = try? Data(contentsOf: real) { try? d.write(to: tmp.appendingPathComponent("soul.json")) }
        }
        Store.dir = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let start = fmt.date(from: (sc["start"] as? String) ?? "2026-10-10T14:00:00") ?? Date()
        let w = SimWorld(now: start, screens: screens(sc["screens"]))
        w.mouse = point(sc["mouse"]) ?? CGPoint(x: 960, y: 540)
        w.frontApp = sc["app"] as? String ?? "Safari"
        w.window = rect(sc["window"])
        if let list = sc["windows"] as? [[String: Any]] {
            w.wins = windows(list); w.frontApp = w.wins.first?.app ?? w.frontApp; w.frontTitle = list.first?["title"] as? String
        }
        world = w
        defer { world = RealWorld() }

        let body = Body(headless: true)
        if let m = sc["mood"] as? [String: Double] {
            if let v = m["valence"] { body.soul.valence = v }
            if let v = m["arousal"] { body.soul.arousal = v }
            if let v = m["sleepiness"] { body.soul.sleepiness = v }
            if let v = m["boredom"] { body.soul.boredom = v }
            if let v = m["affection"] { body.soul.affection = v }
            if let v = m["curiosity"] { body.soul.curiosity = v }
        }
        if let sx = sc["start_x"] as? Double { body.simPlace(x: CGFloat(sx), y: sc["start_y"] as? Double) }
        // spots she already likes ([x, y, how much]), as if learned on earlier days
        for p in (sc["places"] as? [[Double]]) ?? [] where p.count == 3 { body.soul.feelPlace(CGFloat(p[0]), CGFloat(p[1]), p[2]) }
        let fav0 = ((sc["places"] as? [[Double]]) ?? []).first
        var frontIdx = -9, frontSince = 0.0, following = false   // where the action is: his front window's screen

        var events: [[String: Any]] = []
        var t = 0.0
        let A = Analyzer(screens: w.screens)
        var forcedHops = 0
        var acts: [(Double, String)] = []
        var asleepAt: [Double] = []          // frames' times she was asleep (sampled 1/s)
        var extra: [String: Double] = [:]
        var coming: (t: Double, x: Double)?    // "come here" / "other screen": when he asked, and where she set off for
        body.trace = { kind, info in
            var e = info; e["t"] = (t * 100).rounded() / 100; e["kind"] = kind
            if kind == "window_left_her" { forcedHops += 1 }
            if kind == "mind" {
                extra["mind_thoughts", default: 0] += 1
                if (info["said"] as? Bool) == true { extra["mind_said", default: 0] += 1 }
                if (info["said"] as? Bool) == true && (info["typing"] as? Bool) == true { extra["mind_said_while_typing", default: 0] += 1 }
            }
            if kind == "mind_act", let what = info["what"] as? String {
                if (info["refused"] as? Bool) == true { extra["mind_acts_refused", default: 0] += 1 }
                else {
                    extra["mind_acts_done", default: 0] += 1
                    acts.append((t, what))
                    if (info["quiet"] as? Bool) == true && ["dance", "giggle"].contains(what) { extra["mind_loud_while_quiet", default: 0] += 1 }
                    if (info["asleep"] as? Bool) == true { extra["mind_woke_her", default: 0] += 1 }
                }
            }
            if kind == "touch", let clip = info["clip"] as? String { extra["touch_" + clip, default: 0] += 1 }
            if kind == "come", let x = info["x"] as? Double { extra["comes", default: 0] += 1; coming = (t, x) }   // he called her over
            if kind == "notified" { extra[(info["busy"] as? Bool) == true ? "notices_busy" : "notices_cued", default: 0] += 1 }
            if kind == "act", let what = info["what"] as? String {
                acts.append((t, what))
                // every move of her own names its cause in the world
                if ((info["why"] as? String) ?? "").isEmpty { extra["acts_uncaused", default: 0] += 1 }
                if ["hop", "dash", "wave", "giggle", "dance"].contains(what) {
                    extra["loud_acts", default: 0] += 1
                    if w.callOn { extra["call_loud_acts", default: 0] += 1 }
                }
            }
            if kind == "think", let why = info["why"] as? String, why.hasPrefix("home"), (info["moving"] as? Bool) == true {
                extra["home_walks", default: 0] += 1
            }
            // a walk set off while he's been away 5 min+: only home or a corner is a reason then
            if kind == "walk", let why = info["why"] as? String, why.hasPrefix("home") { extra["walks_home", default: 0] += 1 }
            if kind == "walk", let why = info["why"] as? String, ((info["idle"] as? Double) ?? 0) >= Body.trulyAway,
               !why.hasPrefix("home"), !why.hasPrefix("corner") {
                extra["away_walks", default: 0] += 1
            }
            if kind == "fell_asleep" { extra["naps", default: 0] += 1; if extra["first_sleep_t"] == nil { extra["first_sleep_t"] = t } }
            if kind == "boss_back" {
                extra["boss_backs", default: 0] += 1
                // a hop and a wave: only when he was really away (a reading pause gets a look)
                if (info["greets"] as? Bool) ?? (((info["k"] as? Double) ?? 0) > 0.25) { extra["greeted", default: 0] += 1 }
                A.returnedAt = t
            }
            events.append(e)
        }
        let duration = (sc["duration"] as? Double) ?? 120
        let presentSpans = sc["present"] as? [[Double]]
        let timeline = ((sc["timeline"] as? [[String: Any]]) ?? []).sorted { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }
        var next = 0
        // what's going on now
        var mouseFrom = w.mouse, mouseTo = w.mouse, mouseT0 = 0.0, mouseT1 = 0.0
        var wander: (c: CGPoint, r: Double, until: Double, goal: CGPoint)?
        var typing: (until: Double, rate: Double, back: Double, caretStep: Double)?
        var keyAcc = 0.0
        var dragPath: [CGPoint] = [], dragT0 = 0.0, dragT1 = 0.0
        var scrolling: (until: Double, dy: Double)?
        var hovering = false
        var windowMove: (id: Int, from: CGRect, to: CGRect, t0: Double, t1: Double)?

        // her mind, faked: every 40-70 s a want, maybe a face, maybe one of her rig moves, rarely words —
        // by core/iris's own rules, or (adversarial) ignoring them to prove her body holds its ground
        let mindCfg = sc["mind"] as? [String: Any]
        let mindEvery = (mindCfg?["every"] as? [Double]) ?? [40, 70]
        let adversarial = (mindCfg?["adversarial"] as? Bool) ?? false
        var nextMind = mindCfg == nil ? Double.infinity : Double.rnd(5...mindEvery[1])
        var lastMindAct = "", lastMindActT = -999.0, lastSayT = -9999.0
        let rigActs = Array(SpriteView.rigActs).sorted()
        let allWants = ["be_close", "give_space", "explore", "watch", "rest", "nap", "play", "work_along", "get_attention"]
        let faces = ["happy", "love", "pout", "surprised", "curious", "worried", "sleepy"]
        let logEvery = max(1, Int(fps / ((sc["log_hz"] as? Double) ?? 10)))
        var frames: [[String: Any]] = []
        var i = 0
        let dt = 1 / fps
        while t < duration {
            // the timeline, as it comes due
            while next < timeline.count, (timeline[next]["t"] as? Double ?? 0) <= t {
                let e = timeline[next]; next += 1
                var note = e; note["kind"] = "scene"; note["t"] = (t * 100).rounded() / 100
                events.append(note)
                // what she should glance at (checked half a second later)
                let oldIDs = Set(w.wins.map(\.id))
                defer {
                    if let fresh = w.wins.prefix(3).first(where: { !oldIDs.contains($0.id) }), e["windows"] != nil {
                        A.expect(t, CGPoint(x: fresh.frame.midX, y: fresh.frame.midY), "new_window")
                    }
                    if e["app"] != nil || e["front"] != nil, let fw = w.wins.first?.frame { A.expect(t, CGPoint(x: fw.midX, y: fw.midY), "app") }
                    if e["voice"] != nil || e["speak"] != nil || e["show"] != nil { A.expect(t, nil, "him") }
                }
                if let p = point(e["mouse"]) { w.mouse = p; mouseFrom = p; mouseTo = p; mouseT1 = t }
                if let p = point(e["mouse_to"]) {
                    mouseFrom = w.mouse; mouseTo = p; mouseT0 = t; mouseT1 = t + ((e["over"] as? Double) ?? 1)
                }
                if let wd = e["wander"] as? [String: Any], let c = point(wd["around"]) {
                    wander = (c, (wd["radius"] as? Double) ?? 200, t + ((wd["for"] as? Double) ?? 30), c)
                }
                if let ty = e["type"] as? [String: Any] {
                    typing = (t + ((ty["for"] as? Double) ?? 10), (ty["rate"] as? Double) ?? 250,
                              (ty["backspace"] as? Double) ?? 0.05, (ty["caret_step"] as? Double) ?? 7)
                }
                if e.keys.contains("focus") {
                    let f = e["focus"] as? [String: Any]
                    w.field = rect(f?["field"]); w.caret = rect(f?["caret"])
                }
                if e.keys.contains("window") {
                    if let mv = e["window_to"] as? [Double], let from = rect(e["window"]), let to = rect(mv) {
                        w.window = from
                        windowMove = (w.wins[0].id, from, to, t, t + ((e["over"] as? Double) ?? 0.5))
                    } else { w.window = rect(e["window"]) }
                }
                if e["windows"] != nil { w.wins = windows(e["windows"]) }
                // he clicks into a window: it comes to the front
                if let id = e["front"] as? Int, let i = w.wins.firstIndex(where: { $0.id == id }) {
                    let win = w.wins.remove(at: i); w.wins.insert(win, at: 0)
                    w.frontApp = win.app; body.touched(); body.appSwitched(name: win.app)
                }
                if let id = e["close"] as? Int { w.wins.removeAll { $0.id == id } }
                if let m = e["move"] as? [String: Any], let id = m["id"] as? Int, let to = rect(m["to"]),
                   let cur = w.wins.first(where: { $0.id == id }) {
                    windowMove = (id, cur.frame, to, t, t + ((m["over"] as? Double) ?? 0.5))
                }
                if e.keys.contains("title") { w.frontTitle = e["title"] as? String }
                if let ch = e["screen_changing"] as? Bool { w.screenChanging = ch }
                if let p = point(e["screen_change"]) { w.screenChange = (w.now, p) }   // something changed there (her eyes' glance)
                if e["voice"] as? Bool == true { body.heardVoice() }                    // he says something, not to her
                if let on = e["call"] as? Bool { w.callOn = on }        // an app took the mic (a call)
                if let on = e["sound"] as? Bool { w.soundOn = on }      // something is making sound
                if let a = e["app"] as? String { w.frontApp = a; body.touched(); body.appSwitched(name: a) }
                if e["pet"] as? Bool == true { body.touched(); body.petted() }
                if e["double_pet"] as? Bool == true { body.touched(); body.petted(); body.doublePetted() }   // as her view sends a double-click
                // Friday through her: a voiced line (/mouth/play), shown words (/mouth/show), a push (/iris/notice)
                // he talks to her: her name heard (onWake), then what he said finished (onHeard, onDone)
                if e["wake"] as? Bool == true { body.setListening(true) }
                if e["heard"] as? Bool == true { body.awaitingAnswer(); body.setListening(false) }
                if let sp = e["speak"] as? [String: Any] { body.speaking(sp["text"] as? String ?? "", seconds: sp["seconds"] as? Double ?? 3) }
                if let sh = e["show"] as? [String: Any] { body.showing(sh["text"] as? String ?? "", seconds: sh["seconds"] as? Double ?? 6) }
                if let n = e["notify"] as? String { body.notified(n) }
                if let p = point(e["click"]) { w.mouse = p; body.touched(); body.clicked(at: p) }
                if let d = e["drag"] as? [String: Any], let path = d["path"] as? [[Double]] {
                    dragPath = path.compactMap { point($0) }; dragT0 = t; dragT1 = t + ((d["over"] as? Double) ?? 1.5)
                    if let first = dragPath.first {
                        // he picks her up where she is: the path starts at her
                        let s = body.simState()
                        let me = CGPoint(x: (s["x"] as! Double) + Double(Body.size.width) / 2, y: (s["y"] as! Double) + Double(Body.size.height) * 0.8)
                        dragPath[0] = me; _ = first
                    }
                }
                if let sc = e["scroll"] as? [String: Any] { scrolling = (t + ((sc["for"] as? Double) ?? 3), (sc["dy"] as? Double) ?? 6) }
                if let m = e["mind"] as? [String: Any] {
                    body.mind(want: m["want"] as? String ?? "", strength: m["strength"] as? Double ?? 0.6,
                              mood: (m["mood"] as? [String: Double]) ?? [:], say: m["say"] as? String ?? "", face: m["face"] as? String ?? "")
                }
                if let mood = e["mood"] as? [String: Double] {
                    if let v = mood["valence"] { body.soul.valence = v }
                    if let v = mood["arousal"] { body.soul.arousal = v }
                    if let v = mood["sleepiness"] { body.soul.sleepiness = v }
                    if let v = mood["boredom"] { body.soul.boredom = v }
                }
                if let to = e["come"] as? String { _ = body.come(to) }          // he called her over (/iris/come)
                if e["shoo"] as? Bool == true { body.shooed() }                 // "Iris, go away" (/iris/mood shoo)
                if let h = e["hold"] as? [String: Any] { body.hold(h["seconds"] as? Double ?? 10, talk: false, pose: h["pose"] as? String ?? "") }
                if e["screens"] != nil { w.screens = screens(e["screens"]); A.screens = w.screens }
            }
            if t >= nextMind {
                nextMind = t + Double.rnd(mindEvery[0]...mindEvery[1])
                let st = body.simState()
                let asleep = st["sleeping"] as! Bool, video = (st["watching_video"] as? Bool) ?? false
                var wants = A.typing ? ["give_space", "work_along", "watch", "be_close"] : video ? ["watch", "rest", "be_close"]
                    : asleep ? ["nap", "rest"] : allWants
                if adversarial { wants += ["get_attention", "play", "be_close"] }
                let want = wants.rndElement()!
                let face = Double.rnd(0...1) < 0.5 ? "" : faces.rndElement()!
                var say = ""
                if adversarial ? Double.rnd(0...1) < 0.3 : (want == "get_attention" && !A.typing && t - lastSayT >= 600) {
                    say = ["Look at this!", "Hey, come see!", "Psst, over here!"].rndElement()!; lastSayT = t
                }
                body.mind(want: want, strength: Double.rnd(0.3...0.9), mood: [:], say: say, face: face)
                if Double.rnd(0...1) < 0.7 {
                    var act = rigActs.rndElement()!
                    if adversarial && A.typing && Double.rnd(0...1) < 0.5 { act = "dance" }
                    if adversarial || (act != lastMindAct && t - lastMindActT >= 45) {
                        body.perform(act, seconds: 4 + 6 * Double.rnd(0.3...0.9)); lastMindAct = act; lastMindActT = t
                    }
                }
            }
            // his hand
            if t < mouseT1 {
                let k = (t - mouseT0) / max(0.001, mouseT1 - mouseT0)
                let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
                w.mouse = CGPoint(x: mouseFrom.x + (mouseTo.x - mouseFrom.x) * e, y: mouseFrom.y + (mouseTo.y - mouseFrom.y) * e)
            } else if var wd = wander, t < wd.until {
                if hypot(w.mouse.x - wd.goal.x, w.mouse.y - wd.goal.y) < 4 {
                    wd.goal = CGPoint(x: wd.c.x + CGFloat.rnd(-1...1) * wd.r, y: wd.c.y + CGFloat.rnd(-1...1) * wd.r * 0.6)
                }
                let dx = wd.goal.x - w.mouse.x, dy = wd.goal.y - w.mouse.y, d = max(1, hypot(dx, dy))
                let step = min(d, 500 * dt)
                w.mouse = CGPoint(x: w.mouse.x + dx / d * step, y: w.mouse.y + dy / d * step)
                wander = wd
            }
            if !dragPath.isEmpty {
                let k = min(1, (t - dragT0) / max(0.001, dragT1 - dragT0))
                let seg = k * Double(dragPath.count - 1)
                let j = min(dragPath.count - 2, Int(seg))
                let f = seg - Double(j)
                let a = dragPath[j], b = dragPath[j + 1]
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                w.mouse = p
                body.dragged(p)
                if k >= 1 { body.dropped(); dragPath = [] }
            }
            if let ty = typing, t < ty.until {
                keyAcc += ty.rate / 60 * dt * Double.rnd(0.3...1.7)
                while keyAcc >= 1 {
                    keyAcc -= 1
                    let back = Double.rnd(0...1) < ty.back
                    if let c = w.caret {
                        var c2 = c
                        c2.origin.x += back ? -ty.caretStep : ty.caretStep
                        if let f = w.field, c2.maxX > f.maxX - 10 { c2.origin.x = f.minX + 10; c2.origin.y -= 18 }
                        if let f = w.field, c2.minY < f.minY { c2.origin.y = f.maxY - 24 }
                        w.caret = c2
                    }
                    body.touched()
                    body.key(code: back ? 51 : (Double.rnd(0...1) < 0.03 ? 36 : 0))
                }
                A.typing = true
            } else { A.typing = false }
            if let s = scrolling, t < s.until, i % 3 == 0 { body.touched(); body.scrolled(CGFloat(s.dy), precise: false) }
            if let m = windowMove, let wi = w.wins.firstIndex(where: { $0.id == m.id }) {
                let k = min(1, (t - m.t0) / max(0.001, m.t1 - m.t0))
                w.wins[wi].frame = CGRect(x: m.from.minX + (m.to.minX - m.from.minX) * k, y: m.from.minY + (m.to.minY - m.from.minY) * k,
                                  width: m.from.width + (m.to.width - m.from.width) * k, height: m.from.height + (m.to.height - m.from.height) * k)
                if k >= 1 { windowMove = nil }
            }
            // hovering, as her view's tracking area would see it
            let s0 = body.simState()
            let mine = CGRect(x: s0["x"] as! Double, y: s0["y"] as! Double, width: Double(Body.size.width), height: Double(Body.size.height))
            let over = mine.contains(w.mouse) && dragPath.isEmpty
            if over != hovering { hovering = over; body.hover(over) }

            w.now = w.now.addingTimeInterval(dt)
            t += dt
            body.frame()
            let s = body.simState()
            if i % 60 == 0 && (s["sleeping"] as! Bool) { asleepAt.append(t) }
            // where the action is: following his front window to his other screen, sitting near it,
            // out of a call's way, in a corner for his full-screen film
            do {
                let bw = Double(Body.size.width), bx = s["x"] as! Double, by = s["y"] as! Double
                let me = CGRect(x: bx, y: by, width: bw, height: Double(Body.size.height))
                let her = A.screenIndex(CGFloat(bx + bw / 2))
                let held = s["held"] as! Bool
                if let c = coming, abs(bx - c.x) < 40 {
                    extra["come_arrived", default: 0] += 1
                    extra["come_s_max"] = max(extra["come_s_max"] ?? 0, t - c.t)
                    coming = nil
                }
                if let fav = fav0, abs(bx + bw / 2 - fav[0]) < 120, abs(by - fav[1]) < 20 {
                    extra["s_at_favourite", default: 0] += dt
                }
                if let fw = w.wins.first?.frame {
                    let fi = A.screenIndex(fw.midX)
                    let full = w.screens.contains { $0.frame == fw }
                    if fi != frontIdx {
                        if frontIdx != -9 && fi != her && !full { following = true }
                        frontIdx = fi; frontSince = t
                    }
                    if following && her == fi && !held {
                        following = false
                        extra["front_follows", default: 0] += 1
                        if extra["front_follow_s"] == nil { extra["front_follow_s"] = t - frontSince }
                    }
                    if her == fi && !full && !w.callOn && t - frontSince > 60 {
                        extra["s_front_here", default: 0] += dt
                        if max(0, fw.minX - me.maxX, me.minX - fw.maxX) <= 300 { extra["s_near_front", default: 0] += dt }
                    }
                    if w.callOn {
                        extra["s_call", default: 0] += dt
                        // after the call's first minute (her walk to a corner), any walking is her moving corners
                        if extra["s_call", default: 0] > 60, (s["walk"] as? Double ?? 0) > 0.05 { extra["s_call_walking", default: 0] += dt }
                        let out = w.screens.count > 1 ? her != fi : !me.intersects(fw) && max(0, fw.minX - me.maxX, me.minX - fw.maxX) > 200
                        if out { extra["s_call_out_of_view", default: 0] += dt }
                        if let b = s["bubble"] as? [Double], b.count == 4 { extra["s_call_bubble", default: 0] += dt }
                    }
                    if full, let fsi = w.screens.firstIndex(where: { $0.frame == fw }), her != fsi, her >= 0 {
                        extra["s_fullscreen_other", default: 0] += dt
                        let vf = w.screens[her].visibleFrame
                        let cornered = min(bx - vf.minX, vf.maxX - (bx + bw)) <= 120
                        if cornered && Sim.pose(body.face) == "sit" { extra["s_fullscreen_corner_sit", default: 0] += dt }
                    }
                }
            }
            let hand = A.typing ? (w.caret.map { CGPoint(x: $0.midX, y: $0.midY) } ?? w.mouse) : w.mouse
            A.field = w.field
            A.caret = w.caret
            A.change = w.screenChange.map { ($0.point, t - w.now.timeIntervalSince($0.at)) }
            A.step(t: t, s, face: body.face, mouse: w.mouse, windows: w.wins.map(\.frame), hand: hand)
            // he's at the Mac: the scenario says so ("present": [[from, to], …], e.g. reading without
            // a touch), else he touched something in the last two minutes
            let present = presentSpans.map { sp in sp.contains { $0.count == 2 && t >= $0[0] && t < $0[1] } }
                ?? ((s["his_idle"] as? Double ?? 999) < 120)
            A.life(t: t, s, face: body.face, present: present)
            if keepFrames && i % logEvery == 0 {
                var f = s.filter { !($0.value is NSNull) }
                f["t"] = (t * 100).rounded() / 100
                f["pose"] = pose(body.face)
                f["screen"] = A.screenIndex(CGFloat(s["x"] as! Double) + Body.size.width / 2)
                f["mouse"] = [Double(w.mouse.x).rounded(), Double(w.mouse.y).rounded()]
                for k in ["x", "y", "vy", "target", "perch", "turn", "lean", "sit", "walk", "valence", "arousal", "sleepiness", "boredom", "affection", "in_the_way"] {
                    if let v = f[k] as? Double { f[k] = (v * 100).rounded() / 100 }
                }
                frames.append(f)
            }
            i += 1
        }
        var fs = A.findings(); if forcedHops > 0 { fs["window_left_her"] = Double(forcedHops) }
        // how alive and how varied: entropy of what she did, the most common share, irregular gaps
        if !acts.isEmpty {
            var n: [String: Double] = [:]
            for a in acts { n[a.1, default: 0] += 1 }
            let tot = Double(acts.count)
            fs["acts"] = tot
            fs["act_kinds"] = Double(n.count)
            fs["act_entropy_bits"] = (n.values.reduce(0) { $0 - ($1 / tot) * log2($1 / tot) } * 100).rounded() / 100
            fs["act_top_share"] = ((n.values.max()! / tot) * 100).rounded() / 100
            var run = 1, best = 1
            for k in 1..<acts.count { run = acts[k].1 == acts[k - 1].1 ? run + 1 : 1; best = max(best, run) }
            fs["act_same_run_max"] = Double(best)
            // gaps between her acts, leaving out any stretch she slept through
            var gaps: [Double] = []
            var prev = 0.0
            for a in acts {
                if !asleepAt.contains(where: { $0 > prev && $0 < a.0 }) { gaps.append(a.0 - prev) }
                prev = a.0
            }
            if gaps.count > 2 {
                let m = gaps.reduce(0, +) / Double(gaps.count)
                let sd = sqrt(gaps.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(gaps.count))
                fs["act_gap_mean_s"] = (m * 10).rounded() / 10
                fs["act_gap_cv"] = ((sd / m) * 100).rounded() / 100
                fs["act_gap_max_s"] = (gaps.max()! * 10).rounded() / 10
            }
        }
        for (k, v) in extra { fs[k] = (v * 100).rounded() / 100 }
        var r: [String: Any] = ["seed": Int(seed), "findings": fs, "notes": A.notes]
        if keepFrames { r["frames"] = frames; r["events"] = events }
        return r
    }

    /// The body she is in, as SpriteView.pose(_:) picks it (that one is private to the renderer).
    static func pose(_ f: Face) -> String {
        if f.sleeping { return "sleep" }
        if f.held { return "carried" }
        if f.hint == "wave" { return "wave" }
        if f.walk > 0.05 { return "walk" }
        if f.hop > 6 && f.vy != 0 { return "jump" }
        if f.hint == "typing" { return "laptop" }
        if f.hint == "watching" || f.sit > 0.6 { return "sit" }
        return "stand"
    }
}

/// Watches every frame for what would look wrong on his screens.
final class Analyzer {
    var screens: [Display]
    var typing = false
    private(set) var notes: [String] = []
    private var c: [String: Double] = [:]
    private var last: [String: Any]?
    private var lastT = 0.0
    private var air: (t: Double, y0: CGFloat, kind: String, x0: CGFloat)?
    private var lastTarget: Double?
    private var moveDir: CGFloat = 0
    private var moveDirAt = -99.0
    private var screenNow = -1
    private var restStart: (t: Double, x: Double)?
    private var mouseSeen: (t: Double, at: CGPoint)?    // when his cursor last moved (a parked one is no one to follow)
    init(screens: [Display]) { self.screens = screens }

    func screenIndex(_ px: CGFloat) -> Int {
        screens.firstIndex { $0.frame.minX <= px && px < $0.frame.maxX } ?? -1
    }

    private func note(_ t: Double, _ s: String) {
        if notes.count < 200 { notes.append(String(format: "%7.2fs ", t) + s) }
    }

    var returnedAt: Double?
    var plainSitFrom: Double?                        // when her present plain awake sit began (no clip, no act)
    var field: CGRect?
    var caret: CGRect?
    var change: (point: CGPoint, t: Double)?         // where his screen last changed, and when (sim time)
    private var expects: [(t: Double, at: CGPoint?, why: String)] = []
    /// She should look at `at` (nil: at him) within half a second of t.
    func expect(_ t: Double, _ at: CGPoint?, _ why: String) { expects.append((t, at, why)) }
    func step(t: Double, _ s: [String: Any], face: Face, mouse: CGPoint, windows: [CGRect], hand: CGPoint) {
        let dt = t - lastT
        lastT = t
        c["seconds"] = t
        let x = CGFloat(s["x"] as! Double), y = CGFloat(s["y"] as! Double), vy = CGFloat(s["vy"] as! Double)
        let held = s["held"] as! Bool
        let target = s["target"] as? Double
        let speed = CGFloat(s["speed"] as! Double)
        let pose = Sim.pose(face)
        c["t_" + pose, default: 0] += dt
        let w = Body.size.width, h = Body.size.height
        let mid = x + w / 2
        defer { last = s }
        guard let p = last else { screenNow = screenIndex(mid); return }
        let px = CGFloat(p["x"] as! Double), py = CGFloat(p["y"] as! Double), pvy = CGFloat(p["vy"] as! Double)
        let dx = x - px, dy = y - py

        // (a display rearranged under her, or a move made while she was faded out, is not a jump he sees)
        let unseen = (s["display_moved"] as? Bool) == true || ((s["alpha"] as? Double) ?? 1) < 0.05 || ((p["alpha"] as? Double) ?? 1) < 0.05
        // 1. a jump in place that no walk or carry explains
        if !unseen && !held && !(p["held"] as! Bool) && !((s["riding"] as? Bool) ?? false) && vy == 0 && pvy == 0 && abs(dx) > max(speed, 160) * CGFloat(dt) * 1.6 + 1 {
            c["teleport_x"] = (c["teleport_x"] ?? 0) + 1
            note(t, String(format: "TELEPORT x %.0f → %.0f (%.0f pt in one frame)", px, x, dx))
        }
        // 2. snapped up or down without flying (vy 0 both frames)
        if !unseen && !held && !(p["held"] as! Bool) && !((s["riding"] as? Bool) ?? false) && abs(dy) > 12 && vy == 0 && pvy == 0 {
            c["snap_y"] = (c["snap_y"] ?? 0) + 1
            note(t, String(format: "SNAP y %.0f → %.0f at x %.0f (no jump, no fall)", py, y, x))
        }
        // 2b. sliding along asleep: a walk with her eyes shut (QA: while she napped)
        if !unseen && !held && (s["sleeping"] as! Bool) && (p["sleeping"] as! Bool) && !((s["riding"] as? Bool) ?? false)
            && vy == 0 && pvy == 0 && abs(dx) > 0.5 {
            c["s_moving_asleep"] = (c["s_moving_asleep"] ?? 0) + dt
        }
                // 3. airborne: a jump she meant, or a fall she didn't
        if air == nil && vy != 0 && !held {
            air = (t, py, vy > 0 ? "jump" : "fall", x)
        }
        if let a = air, vy == 0 || held {
            let drop = a.y0 - y
            if held { air = nil } else {
                if a.kind == "jump" && drop > 120 {
                    c["hops_down"] = (c["hops_down"] ?? 0) + 1
                    note(t, String(format: "HOPPED DOWN %.0f pt (y %.0f at x %.0f → y %.0f at x %.0f)", drop, a.y0, a.x0, y, x))
                }
                if a.kind == "fall" {
                    c["falls"] = (c["falls"] ?? 0) + 1
                    c["fall_pts_max"] = max(c["fall_pts_max"] ?? 0, Double(drop))
                    if drop > 40 { note(t, String(format: "FELL %.0f pt (%@ from y %.0f at x %.0f → y %.0f at x %.0f)", drop, a.kind, a.y0, a.x0, y, x)) }
                }
                if a.kind == "jump" && drop < -120 {
                    c["big_jumps_up"] = (c["big_jumps_up"] ?? 0) + 1
                    note(t, String(format: "JUMPED UP %.0f pt (y %.0f → %.0f at x %.0f)", -drop, a.y0, y, x))
                }
                air = nil
            }
        }
        // 4. half on one screen, half on another (or half off every screen)
        let me = CGRect(x: x, y: y, width: w, height: h)
        let covering = screens.filter { $0.frame.intersects(me.insetBy(dx: 2, dy: 2)) }.count
        let fullyOn = screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(me) }
        if !fullyOn && !held && vy == 0 {
            c["s_straddling_seam"] = (c["s_straddling_seam"] ?? 0) + dt
            let resting = target == nil && vy == 0
            if resting {
                c["s_resting_on_seam"] = (c["s_resting_on_seam"] ?? 0) + dt
                if (p["target"] as? Double) != nil || restStart == nil { note(t, String(format: "RESTING ACROSS A SEAM at x %.0f–%.0f y %.0f (%d screens under her)", x, x + w, y, covering)) }
            }
        }
        // 5. feet on nothing: not on any screen's floor or a window top
        let feet = CGPoint(x: mid, y: y)
        let onScreen = screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(feet) }
        if !onScreen && !held && vy == 0 { c["s_feet_off_screens"] = (c["s_feet_off_screens"] ?? 0) + dt }
        if vy == 0 && !held {
            let floors = screens.filter { $0.frame.minX <= mid && mid < $0.frame.maxX }.map(\.visibleFrame.minY)
            let onFloor = floors.contains { abs($0 - y) < 2 }
            let onWindow = windows.contains { abs($0.maxY - y) < 2 && $0.minX - 20 < x && x < $0.maxX - w + 20 }
            if !onFloor && !onWindow {
                c["s_standing_on_nothing"] = (c["s_standing_on_nothing"] ?? 0) + dt
                if (c["s_standing_on_nothing"] ?? 0) < dt * 1.5 { note(t, String(format: "STANDING ON NOTHING at x %.0f y %.0f", x, y)) }
            }
        }
        // 5b. fallen below every screen (she'd be gone from his sight)
        if y < (screens.map(\.frame.minY).min() ?? 0) - 200 {
            if (c["s_below_all_screens"] ?? 0) == 0 { note(t, String(format: "FELL BELOW EVERY SCREEN at x %.0f y %.0f", x, y)) }
            c["s_below_all_screens"] = (c["s_below_all_screens"] ?? 0) + dt
        }
        // 6. which screen she's on, and how she got there
        let si = screenIndex(mid)
        if si != screenNow {
            c["screen_changes"] = (c["screen_changes"] ?? 0) + 1
            if !held && !(p["held"] as! Bool) {
                c["own_screen_changes"] = (c["own_screen_changes"] ?? 0) + 1
                if c["first_own_change_t"] == nil { c["first_own_change_t"] = t }
            }
            note(t, String(format: "now on screen %d (was %d) at x %.0f y %.0f%@", si, screenNow, x, y, held ? " — carried" : ""))
            screenNow = si
        }
        // 7. retargeting: a new destination, and turning back within moments
        if let tg = target {
            if let lt = lastTarget, abs(lt - tg) > 1 {
                c["retargets"] = (c["retargets"] ?? 0) + 1
            }
            if abs(dx) > 0.01 {
                let d: CGFloat = dx > 0 ? 1 : -1
                if moveDir != 0 && d != moveDir && t - moveDirAt < 4 {
                    c["reversals"] = (c["reversals"] ?? 0) + 1
                    note(t, String(format: "TURNED BACK at x %.0f after %.1fs walking the other way", x, t - moveDirAt))
                }
                if d != moveDir { moveDir = d; moveDirAt = t }
            }
        }
        lastTarget = target
        // 8. walking one way while her face (and flip) says another
        if face.walk > 0.5 && abs(dx) > 0.01 && !held && !(p["held"] as! Bool) {
            c["s_walking"] = (c["s_walking"] ?? 0) + dt
            let dir: CGFloat = face.flip ? -1 : 1
            if (dx > 0) != (dir > 0) { c["s_flip_wrong"] = (c["s_flip_wrong"] ?? 0) + dt }
            let rigTurn = max(-1, min(1, face.turn * 0.3 + dir * 0.75 * min(1, face.walk)))
            if rigTurn * dir < 0.2 { c["s_face_not_toward_travel"] = (c["s_face_not_toward_travel"] ?? 0) + dt }
            // toward him: walking at his cursor (she comes to him with her face to him)
            if (mouse.x - mid) * dx > 0 { c["s_walking_toward_cursor"] = (c["s_walking_toward_cursor"] ?? 0) + dt }
        }
        // 9. in his way while he types
        if typing {
            c["s_typing"] = (c["s_typing"] ?? 0) + dt
            if (s["in_the_way"] as! Double) > 0.3 { c["s_in_his_way_typing"] = (c["s_in_his_way_typing"] ?? 0) + dt }
        }
        // 9b. up on a window, and on one that isn't the front one
        if (s["on_window"] as? Bool) == true {
            c["s_on_window"] = (c["s_on_window"] ?? 0) + dt
            if (s["on_front_window"] as? Bool) != true { c["s_on_back_window"] = (c["s_on_back_window"] ?? 0) + dt }
        }
        // 9c. watching a video with him: sitting to watch, and never in front of it
        if (s["watching_video"] as? Bool) == true {
            c["s_video"] = (c["s_video"] ?? 0) + dt
            if face.hint == "watching" { c["s_watching_pose"] = (c["s_watching_pose"] ?? 0) + dt }
            if let front = windows.first, front.intersects(me.insetBy(dx: 10, dy: 10)) { c["s_covering_video"] = (c["s_covering_video"] ?? 0) + dt }
        }
        // 9d. while he types: how far from his hands, and how restless
        if typing {
            c["typing_dist_sum"] = (c["typing_dist_sum"] ?? 0) + Double(abs(mid - hand.x)) * dt
            if face.walk > 0.5 { c["s_walking_while_typing"] = (c["s_walking_while_typing"] ?? 0) + dt }
            if let f = field {
                let gap = max(0, f.minX - (x + w), x - f.maxX)
                c["field_gap_sum"] = (c["field_gap_sum"] ?? 0) + Double(gap) * dt
            }
        }
        // 9e. after he comes back: how long until she's near him
        if let r = returnedAt {
            if hypot(mid - mouse.x, (y + h * 0.5) - mouse.y) < 450 || (s["sleeping"] as! Bool) == false && abs(mid - mouse.x) < 400 {
                c["greet_approach_s"] = (c["greet_approach_s"] ?? 0) + (t - r); returnedAt = nil
            } else if t - r > 60 { c["greet_approach_s"] = (c["greet_approach_s"] ?? 0) + 60; returnedAt = nil }
        }
        // 9f. a plain sit, awake: no drawn seat, no act, not typing along — what he sees as her staring
        if Sim.pose(face) == "sit" && face.seat.isEmpty && face.act.isEmpty && face.hint.isEmpty && (s["talking"] as? Bool) != true {
            let from = plainSitFrom ?? t
            plainSitFrom = from
            c["plain_sit_max"] = max(c["plain_sit_max"] ?? 0, t - from)
        } else { plainSitFrom = nil }
        // never talking or listening with her eyes shut (her name, Friday's words wake her)
        if (s["sleeping"] as! Bool) && ((s["talking"] as? Bool) == true || (s["listening"] as? Bool) == true) {
            c["s_asleep_attending"] = (c["s_asleep_attending"] ?? 0) + dt
        }
        // Friday talking through her: her mouth moving, her face toward him; her bubble off his work
        if (s["talking"] as? Bool) == true {
            c["s_talking"] = (c["s_talking"] ?? 0) + dt
            let dxh = hand.x - mid
            if abs(dxh) < 120 || (face.turn > 0.05) == (dxh > 0) { c["s_talking_facing_him"] = (c["s_talking_facing_him"] ?? 0) + dt }
        }
        if let b = s["bubble"] as? [Double], b.count == 4 {
            let r = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
            c["s_bubble"] = (c["s_bubble"] ?? 0) + dt
            if let f = field, r.intersects(f) { c["s_bubble_over_field"] = (c["s_bubble_over_field"] ?? 0) + dt }
            if let k = caret, r.intersects(k.insetBy(dx: -40, dy: -20)) { c["s_bubble_over_caret"] = (c["s_bubble_over_caret"] ?? 0) + dt }
            if !screens.contains(where: { $0.frame.contains(r) }) { c["s_bubble_off_screen"] = (c["s_bubble_off_screen"] ?? 0) + dt }
            // where the old bubble went (always over her head, kept on her screen), for before/after
            let vis = (screens.first { $0.frame.intersects(me) } ?? screens[0]).visibleFrame
            let old = CGRect(x: min(vis.maxX - r.width, max(vis.minX, mid - r.width / 2)), y: me.maxY - 14, width: r.width, height: r.height)
            if let f = field, old.intersects(f) { c["s_old_bubble_over_field"] = (c["s_old_bubble_over_field"] ?? 0) + dt }
            if let k = caret, old.intersects(k.insetBy(dx: -40, dy: -20)) { c["s_old_bubble_over_caret"] = (c["s_old_bubble_over_caret"] ?? 0) + dt }
        }
        // her eyes: on his cursor when it's near, on what changed when it's far, at him while
        // she talks; and a glance within half a second at a new window, a new app, his voice
        let eye = CGPoint(x: mid, y: y + h * 0.68)
        let free = (s["sleeping"] as! Bool) == false && !held && face.walk < 0.05 && face.act.isEmpty
            && face.hint != "typing" && face.hint != "wave" && !face.listening && vy == 0
        func toward(_ q: CGPoint) -> Bool {
            let d = q.x - eye.x
            return abs(d) < 80 || (d > 0) == (face.gaze.x > 0) && abs(face.gaze.x) > 0.12
        }
        let mode = s["gaze_mode"] as? String ?? ""
        if mouseSeen.map({ hypot($0.at.x - mouse.x, $0.at.y - mouse.y) >= 30 }) ?? true { mouseSeen = (t, mouse) }
        let mouseMoving = t - (mouseSeen?.t ?? t) < Body.restEyesAfter
        if free && !typing && (s["talking"] as? Bool) != true && mode != "him" && mode != "glance" {
            let dist = hypot(mouse.x - eye.x, mouse.y - eye.y)
            if dist < 540 && mouseMoving {
                c["s_cursor_near"] = (c["s_cursor_near"] ?? 0) + dt
                if toward(mouse) { c["s_gaze_on_cursor"] = (c["s_gaze_on_cursor"] ?? 0) + dt }
            } else if dist > 660, let ch = change, t - ch.t > 0.4 && t - ch.t < 5.5, abs(ch.point.x - eye.x) > 150 {
                c["s_far_change"] = (c["s_far_change"] ?? 0) + dt
                if toward(ch.point) { c["s_gaze_on_change"] = (c["s_gaze_on_change"] ?? 0) + dt }
            }
        }
        if free && (s["talking"] as? Bool) == true {
            c["s_talking_free"] = (c["s_talking_free"] ?? 0) + dt
            if abs(face.gaze.x) <= 0.45 { c["s_talking_eye_contact"] = (c["s_talking_eye_contact"] ?? 0) + dt }
        }
        while let e = expects.first, t >= e.t + 0.5 {
            expects.removeFirst()
            guard free, t < e.t + 0.6 else { continue }
            c["looks_due_" + e.why] = (c["looks_due_" + e.why] ?? 0) + 1
            let hit = e.at.map(toward) ?? (abs(face.gaze.x) <= 0.45 && mode == "him")
            if hit { c["looks_" + e.why] = (c["looks_" + e.why] ?? 0) + 1 }
            else { note(t, "DIDN'T LOOK (\(e.why)) gaze \(String(format: "%.2f", face.gaze.x)) mode \(mode)") }
        }
        // emotes she shows (♪ ! … above her head)
        let em = (s["emote"] as? String) ?? ""
        if !em.isEmpty && ((p["emote"] as? String) ?? "").isEmpty { c["emotes"] = (c["emotes"] ?? 0) + 1 }
        if (s["sleeping"] as! Bool) == false && t > 0 { c["lid_sum"] = (c["lid_sum"] ?? 0) + (s["lid"] as? Double ?? 0) * dt; c["s_awake"] = (c["s_awake"] ?? 0) + dt }
        // 9f. over his full-screen picture (visible), and time out of sight
        let alpha = (s["alpha"] as? Double) ?? 1
        if alpha < 0.05 { c["s_hidden"] = (c["s_hidden"] ?? 0) + dt }
        if alpha > 0.5, let fw = windows.first, screens.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(fw) && fw.width >= $0.frame.width - 4 && fw.height >= $0.frame.height - 4 }),
           fw.intersects(me.insetBy(dx: 5, dy: 5)) {
            c["s_over_fullscreen"] = (c["s_over_fullscreen"] ?? 0) + dt
        }
        // 10. under his cursor
        if me.contains(mouse) && !held { c["s_under_cursor"] = (c["s_under_cursor"] ?? 0) + dt }
        // 11. pose flicker: a pose held for under 0.4 s
        if let lp = p["_pose"] as? String, lp != pose { _ = lp }
        // a drawn gait is the body only while she walks (SpriteView.pose: a wave, sleep or being held come first);
        // every gait Stages names is drawn (iris/Resources/anim)
        poseFlicker(t, pose == "walk" && !face.gait.isEmpty ? "gait_" + face.gait : pose)
        if target == nil && vy == 0 { if restStart == nil { restStart = (t, Double(x)) } } else { restStart = nil }
        c["walked_pts"] = (c["walked_pts"] ?? 0) + Double(held ? 0 : abs(dx))
    }

    private var curPose = ""
    private var poseSince = 0.0
    /// Walking, jumping and standing are one rigged body (SpriteView draws them all as "@idle"),
    /// so only a change between bodies — standing, sitting, laptop, waving, asleep — can flicker.
    /// a drawn gait (run, tiptoe, sad_walk) is its own body too ("gait_run"), as SpriteView draws it.
    private func poseFlicker(_ t: Double, _ p0: String) {
        let pose = ["walk", "jump", "stand"].contains(p0) ? "stand" : p0
        guard pose != curPose else { return }
        if !curPose.isEmpty && t - poseSince < 0.4 {
            c["pose_flickers"] = (c["pose_flickers"] ?? 0) + 1
            note(t, String(format: "POSE FLICKER %@ for %.2fs → %@", curPose, t - poseSince, pose))
        }
        c["pose_changes"] = (c["pose_changes"] ?? 0) + 1
        curPose = pose; poseSince = t
    }

    // MARK: how alive she looks to him (the same measures scripts/iris_journal_report.py takes from
    // her real poses.jsonl)
    private var lifePose = ""
    private var lifeSince = 0.0
    private var lifePrev: (pose: String, held: Double)?   // the body before this one, and how long it held
    private var wokeAt: Double?                           // she last left sleep
    private var lastStir = 0.0                            // last thing he could see her do (a body, a clip, a step, a hop)
    /// The body as SpriteView draws it: a drawn clip is its own body; walking and standing are one rig.
    static func lifeBody(_ f: Face) -> String {
        if !f.act.isEmpty && !SpriteView.rigActs.contains(f.act) && Body.catalog[f.act] != nil { return "clip" }
        let p = Sim.pose(f)
        return ["walk", "jump", "stand"].contains(p) ? "stand" : p
    }
    func life(t: Double, _ s: [String: Any], face: Face, present: Bool) {
        let dt = 1 / Sim.fps
        let pose = Analyzer.lifeBody(face)
        let asleep = pose == "sleep"
        if present {
            c["s_present"] = (c["s_present"] ?? 0) + dt
            if asleep { c["s_present_asleep"] = (c["s_present_asleep"] ?? 0) + dt }
        }
        let moving = face.walk > 0.05 || face.vy != 0
        var stir = false
        if pose != lifePose {
            stir = true
            if !lifePose.isEmpty {
                let held = t - lifeSince
                if held < 2 { c["poses_under_2s"] = (c["poses_under_2s"] ?? 0) + 1 }
                // standing ↔ sitting and straight back within a minute
                if let pv = lifePrev, pv.pose == pose, Set([pose, lifePose]) == ["stand", "sit"], held < 60 {
                    c["sit_stand_flips_60"] = (c["sit_stand_flips_60"] ?? 0) + 1
                }
                if lifePose == "sleep" { wokeAt = t }
                if asleep, let w = wokeAt, t - w < 60 { c["wake_resleep_60"] = (c["wake_resleep_60"] ?? 0) + 1 }
                if pose == "wave" {
                    c["waves"] = (c["waves"] ?? 0) + 1
                    if present { c["waves_present"] = (c["waves_present"] ?? 0) + 1 }
                }
                lifePrev = (lifePose, held)
            }
            lifePose = pose; lifeSince = t
        }
        // walking, hopping or playing a clip is doing something the whole time it lasts
        if !face.act.isEmpty || moving { stir = true }
        // (on her laptop her hands type along with his: that is doing something, not sitting and blinking)
        if stir || !present || asleep || pose == "laptop" { lastStir = t }
        if present && !asleep { c["still_max_present_s"] = max(c["still_max_present_s"] ?? 0, t - lastStir) }
    }

    func findings() -> [String: Any] {
        var c = self.c
        if let p = c["s_present"], p > 0 {
            c["asleep_share_present"] = (c["s_present_asleep"] ?? 0) / p
            c["waves_per_present_h"] = (c["waves_present"] ?? 0) / (p / 3600)
        }
        if let d = c.removeValue(forKey: "typing_dist_sum"), let ty = c["s_typing"], ty > 0 { c["mean_dist_typing"] = d / ty }
        if let g = c.removeValue(forKey: "field_gap_sum"), let ty = c["s_typing"], ty > 0 { c["mean_gap_to_field"] = g / ty }
        if let l = c.removeValue(forKey: "lid_sum"), let a = c["s_awake"], a > 0 { c["mean_lid_awake"] = l / a }
        return c.mapValues { ($0 * 100).rounded() / 100 }
    }
}
