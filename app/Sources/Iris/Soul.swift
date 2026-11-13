import Foundation

/// What just happened, as she felt it.
enum Stimulus: String, Codable, CaseIterable {
    case key, backspaceBurst, enter, fastTyping, scroll, fastScroll, click, appSwitch, newApp
    case cursorNear, cursorFlick, hover, petted, dragged, dropped, bossBack, bossAway
    case heardName, fridaySpoke, screenBusy, longFocus, video
}

/// Her inner life: a few continuous feelings that drift, get pushed by what
/// the person does, and tire of repetition (habituation) — so the same thing never
/// gets the same reaction twice in a row, and nothing is a fixed script.
/// What the person likes and dislikes is learned and kept (soul.json).
@MainActor          // her body's (Body.soul), on her main thread
final class Soul {
    /// Her clock, for her memory's new fields. A memory is made or read only in Soul's init, on her main thread
    /// (Codable's init is nonisolated, so this says where it runs rather than leave world unchecked).
    nonisolated static func mainNow() -> Date { MainActor.assumeIsolated { world.now } }

    struct Memory: Codable {
        var focusRespect = 0.5     // learned: stay calm and out of the way while the person works
        var playfulness = 0.6      // learned: how much horseplay the person enjoys
        var cling = 0.5            // learned: how close to their cursor she stays
        var hourly = Array(repeating: 0.0, count: 168)
        var places: [String: Double] = [:]   // learned: how good each spot on their screens feels, -1…1
        var placesAt = Soul.mainNow()        // when the places last eased toward neutral (decayPlaces)
        var aversion = 0.5                   // learned: how much being in their way bothers her
        var pets = 0
        var shooed = 0
        var met = Soul.mainNow()

        init() {}
        // a memory written by an older Iris keeps what it has; new things start fresh
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            focusRespect = (try? c.decode(Double.self, forKey: .focusRespect)) ?? 0.5
            playfulness = (try? c.decode(Double.self, forKey: .playfulness)) ?? 0.6
            cling = (try? c.decode(Double.self, forKey: .cling)) ?? 0.5
            hourly = (try? c.decode([Double].self, forKey: .hourly)) ?? Array(repeating: 0.0, count: 168)
            places = (try? c.decode([String: Double].self, forKey: .places)) ?? [:]
            placesAt = (try? c.decode(Date.self, forKey: .placesAt)) ?? Soul.mainNow()      // older memories: from now
            aversion = (try? c.decode(Double.self, forKey: .aversion)) ?? 0.5
            pets = (try? c.decode(Int.self, forKey: .pets)) ?? 0
            shooed = (try? c.decode(Int.self, forKey: .shooed)) ?? 0
            met = (try? c.decode(Date.self, forKey: .met)) ?? Soul.mainNow()
        }
    }

    // feelings
    var valence = 0.4       // -1 sad … 1 happy
    var arousal = 0.5       // 0 drowsy … 1 wired
    var boredom = 0.2
    var curiosity = 0.6
    var affection = 0.5
    var sleepiness = 0.1

    private(set) var memory: Memory
    private var habit: [Stimulus: Double] = [:]
    private var lastSave = world.now
    private(set) var lastDeed: (what: String, at: Date)?

    init() {
        memory = Store.load(Memory.self, "soul.json") ?? Memory()
        decayPlaces()                                   // the days she was off ease them too
    }

    func save() { Store.save(memory, "soul.json"); lastSave = world.now }

    /// How strongly she feels a stimulus now (0…1): repeated ones fade, and
    /// a rested one surprises her again.
    func feel(_ s: Stimulus, _ intensity: Double = 1) -> Double {
        let h = habit[s] ?? 0
        habit[s] = min(1, h + 0.12 + 0.2 * intensity)
        let k = intensity * (1 - h * 0.85) * (0.7 + Double.rnd(0...0.6))
        apply(s, k)
        return k
    }

    private func apply(_ s: Stimulus, _ k: Double) {
        switch s {
        case .key: arousal += 0.004 * k; boredom -= 0.01 * k
        case .fastTyping: arousal += 0.05 * k; curiosity += 0.02 * k
        case .backspaceBurst: valence -= 0.03 * k
        case .enter: valence += 0.01 * k
        case .scroll: curiosity += 0.01 * k; boredom -= 0.01 * k
        case .fastScroll: arousal += 0.03 * k
        case .click: boredom -= 0.02 * k
        case .appSwitch, .newApp: curiosity += 0.08 * k; arousal += 0.04 * k
        case .cursorNear: affection += 0.01 * k
        case .cursorFlick: arousal += 0.1 * k
        case .hover: affection += 0.05 * k; valence += 0.03 * k
        case .petted: valence += 0.3 * k; affection += 0.2 * k; arousal += 0.15 * k; boredom -= 0.3
        case .dragged: arousal += 0.2 * k
        case .dropped: valence -= 0.05 * k
        case .bossBack: valence += 0.3 * k; arousal += 0.4 * k; sleepiness -= 0.6; boredom -= 0.4
        case .bossAway: boredom += 0.1
        case .heardName: arousal += 0.3; sleepiness -= 0.5; affection += 0.05
        case .fridaySpoke: valence += 0.02
        case .screenBusy: curiosity += 0.02 * k
        case .longFocus: arousal -= 0.05
        case .video: curiosity += 0.05 * k
        }
        clamp()
    }

    /// Time passing, `dt` seconds. `active`: the person touched the Mac recently.
    func drift(_ dt: Double, active: Bool, typingRate: Double) {
        for (k, v) in habit { habit[k] = max(0, v - dt * 0.05) }
        valence += (0.35 - valence) * dt * 0.01 + noise(dt) * 0.6
        arousal += ((active ? 0.5 : 0.25) - arousal) * dt * 0.02 + noise(dt) * 0.8
        boredom += dt * (active ? (typingRate > 20 ? 0.0004 : 0.002) : 0.006)
        curiosity += (0.5 - curiosity) * dt * 0.01 + noise(dt)
        affection += dt * (active ? -0.0003 : 0.001)
        // late at night their being here doesn't wake her (sim 26: heavier eyelids, a nap sooner once the person goes quiet)
        sleepiness += dt * (active ? (Soul.lateNight ? 0 : -0.0005) : 0.0025) + (Soul.lateNight ? dt * 0.0006 : 0)
        clamp()
        let c = Calendar.current.dateComponents([.weekday, .hour], from: world.now)
        let slot = ((c.weekday ?? 1) - 1) * 24 + (c.hour ?? 0)
        memory.hourly[slot] += ((active ? 1 : 0) - memory.hourly[slot]) * min(1, dt / 3600)
        if world.now.timeIntervalSince(lastSave) > 120 { decayPlaces(); save() }
    }

    static var lateNight: Bool { let h = Calendar.current.component(.hour, from: world.now); return h >= 1 && h < 6 }

    /// He usually is at the Mac at this hour (learned over weeks).
    var expectsHim: Double {
        let c = Calendar.current.dateComponents([.weekday, .hour], from: world.now)
        return memory.hourly[((c.weekday ?? 1) - 1) * 24 + (c.hour ?? 0)]
    }

    // MARK: places — where she likes to be, learned from what happens there

    static func placeKey(_ x: CGFloat, _ y: CGFloat) -> String { "\(Int((x / 70).rounded(.down))):\(Int((y / 140).rounded(.down)))" }

    func place(_ x: CGFloat, _ y: CGFloat) -> Double { memory.places[Soul.placeKey(x, y)] ?? 0 }

    /// A spot felt good (petted there, the person set her down there) or bad (in their way).
    func feelPlace(_ x: CGFloat, _ y: CGFloat, _ delta: Double) {
        let k = Soul.placeKey(x, y)
        let v = (memory.places[k] ?? 0) + delta
        memory.places[k] = min(1, max(-1, v))
        // the neighbours feel a little of it too
        for dx in [-1, 1] {
            let n = "\(Int((x / 70).rounded(.down)) + dx):\(Int((y / 140).rounded(.down)))"
            memory.places[n] = min(1, max(-1, (memory.places[n] ?? 0) + delta * 0.35))
        }
        if memory.places.count > 4000 { memory.places = memory.places.filter { abs($0.value) > 0.05 } }
    }

    /// (UX audit #9): a spot learned from one shoo was avoided for good (soul.json held 91 spots, most at -1).
    /// What she learned of a place eases back toward neutral, half of it each Soul.placeHalfLifeS, so where the person keeps
    /// moving her from is kept off for days and comes back once the person stops.
    static let placeHalfLifeS: Double = 7 * 86400

    func decayPlaces() {
        let dt = world.now.timeIntervalSince(memory.placesAt)
        guard dt > 0 else { memory.placesAt = world.now; return }       // a clock that stepped back: nothing to ease
        let k = pow(0.5, dt / Soul.placeHalfLifeS)
        memory.places = memory.places.mapValues { $0 * k }.filter { abs($0.value) > 0.01 }
        memory.placesAt = world.now
    }

    /// He typed while she was on top of their work: it bothers her more next time.
    func inTheWay() { memory.aversion = min(2, memory.aversion + 0.03) }

    // MARK: learning

    /// She did something ("play", "approach", "perform") — remembered so their
    /// reaction in the next minute teaches her.
    func did(_ what: String) { lastDeed = (what, world.now) }

    /// (UX audit #9): the person shooed her, or carried her away, while they were working: she was in the way of their work.
    /// Her respect for their focus rises (Body.focusRespectPull keeps her pull toward them lower while the person types). `how`:
    /// 1 for a shoo, 0.5 for a drag away, as reward weighs them.
    func interrupted(_ how: Double) {
        memory.focusRespect = bounded(memory.focusRespect + 0.08 * how)
    }

    func reward(_ r: Double) {
        if r > 0 { memory.pets += 1 } else { memory.shooed += 1 }
        guard let d = lastDeed, world.now.timeIntervalSince(d.at) < 60 else { return }
        let lr = 0.08
        switch d.what {
        case "play": memory.playfulness = bounded(memory.playfulness + lr * r)
        case "approach": memory.cling = bounded(memory.cling + lr * r)
        case "interrupt": memory.focusRespect = bounded(memory.focusRespect - lr * r)
        default: break
        }
    }

    private func bounded(_ x: Double) -> Double { min(0.95, max(0.05, x)) }

    private func noise(_ dt: Double) -> Double { Double.rnd(-1...1) * 0.004 * sqrt(max(dt, 0.001) * 30) }

    private func clamp() {
        valence = min(1, max(-1, valence))
        for p in [\Soul.arousal, \Soul.boredom, \Soul.curiosity, \Soul.affection, \Soul.sleepiness] {
            self[keyPath: p] = min(1, max(0, self[keyPath: p]))
        }
    }

    func feelings() -> [String: Double] {
        ["valence": valence, "arousal": arousal, "boredom": boredom, "curiosity": curiosity,
         "affection": affection, "sleepiness": sleepiness,
         "focus_respect": memory.focusRespect, "playfulness": memory.playfulness, "cling": memory.cling]
    }
}
