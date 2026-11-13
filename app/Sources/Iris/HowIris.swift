import Foundation

/// "How Iris is", the top of her menu (owner: her menu and status): her real state,
/// read when the menu opens, never a green "all good" without reading it. Her ears and eyes are hers to read; her
/// voice and her quiet hour are Core's, from its last status (core/iris_status, every 30 s); Friday is reachable
/// when Core's last signed request to her is recent (Link). Whatever wasn't read says so. Pure: tested with a driver
/// (tests/test_iris_how_she_is_1111.py).
enum HowIris {
    /// Core's status older than this is no word from it.
    static let coreFreshS: Double = 120
    /// Core reaches her every few seconds (her reflex loop's look); quieter than this, it isn't reaching her.
    static let fridayQuietS: Double = 30

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    static func span(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 1 { return "\(Int(s)) s" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// Her ears' problem code (Ears.status / MicHealth) in words.
    static func earsProblem(_ p: String?) -> String {
        guard let p, !p.isEmpty else { return "no reason given" }
        let words = ["microphone_not_allowed": "the microphone isn't allowed",
                     "speech_recognition_not_allowed": "speech recognition isn't allowed",
                     "recognizer_unavailable": "the recognizer isn't available",
                     "no_microphone": "no microphone found", "not_started": "they haven't started",
                     "audio_engine_stopped": "the audio engine stopped",
                     "no_audio_from_microphone": "no sound is reaching her from the microphone"]
        if let w = words[p] { return w }
        if p.hasPrefix("recognition_failing") { return "recognition keeps failing" }
        if p.hasPrefix("audio_engine") { return "the audio engine failed" }
        return p.replacingOccurrences(of: "_", with: " ")
    }

    static func ears(_ s: [String: Any]?, now: Date) -> String {
        guard let s else { return "Ears: unknown (couldn't read them)" }
        if let off = s["off_until"] as? Double, off > now.timeIntervalSince1970 {
            return "Ears: off until \(clock(Date(timeIntervalSince1970: off)))"
        }
        if s["listening"] as? Bool == true { return "Ears: listening" }
        return "Ears: not listening (\(earsProblem(s["problem"] as? String)))"
    }

    static func eyes(permitted: Bool, offUntil: Date?, now: Date) -> String {
        if let o = offUntil, o > now { return "Eyes: off until \(clock(o))" }
        return permitted ? "Eyes: on" : "Eyes: can't see your screen (Screen Recording isn't allowed)"
    }

    static func cents(_ c: Double) -> String { String(format: "%.1f¢", c) }

    /// Core's word on her voice: {next: "friday" | "free", why_free, last: {voice: friday|kokoro|mac}, spent_cents
    /// (nil when today's count can't be read), cap_cents, free: "kokoro" | "mac" (nil when not asked)}.
    static func voice(_ core: [String: Any]?, fresh: Bool) -> String {
        guard fresh, let v = core?["voice"] as? [String: Any] else { return "Voice: unknown (no word from \(Config.agentName) lately)" }
        let cap = v["cap_cents"] as? Double ?? 10
        let spend = (v["spent_cents"] as? Double).map { "\(cents($0)) of \(cents(cap)) today" }
            ?? "today's spend couldn't be read"
        // her last line said from Friday's watcher (core/iris_voice._LAST_VOICE), "here": not another process's line
        let last = (v["last"] as? [String: Any])?["voice"] as? String
        let lastSaid = ["friday": "\(Config.agentName)'s voice", "kokoro": "Kokoro", "mac": "the Mac voice"][last ?? ""]
            .map { "; her last line here: \($0)" } ?? ""
        // Core asks her own voice server's /health with each status (core/iris_voice._fallback_up) and says which
        // voice her free one would be: "mac" when it isn't answering (it had been down a week, unsaid)
        let ownDown = v["free"] as? String == "mac"
        if v["next"] as? String == "friday" {
            return "Voice: \(Config.agentName)'s voice\(lastSaid)\(ownDown ? "; her own voice isn't running" : "") · \(spend)"
        }
        let why = (v["why_free"] as? String).map { " (\(Config.agentName)'s voice: \($0))" } ?? ""
        let free = ownDown ? "the Mac voice, her own isn't running" : "her free voice"
        return "Voice: \(free)\(why)\(lastSaid) · \(spend)"
    }

    static func friday(lastContact: Date?, now: Date) -> String {
        guard let t = lastContact else { return "\(Config.agentName): hasn't reached me since I started" }
        let ago = now.timeIntervalSince(t)
        return ago <= fridayQuietS ? "\(Config.agentName): reaching me" : "\(Config.agentName): hasn't reached me for \(span(ago))"
    }

    /// Her quiet hour ("make Iris quiet", Core's) or their do not disturb; nil when neither holds.
    static func quiet(_ core: [String: Any]?, fresh: Bool, now: Date) -> String? {
        guard fresh, let q = core?["quiet"] as? [String: Any] else { return "Quiet: unknown (no word from \(Config.agentName) lately)" }
        if let why = q["unread"] as? String { return "Quiet: unknown (\(why))" }
        let t = now.timeIntervalSince1970
        if let u = q["hush_until"] as? Double, u > t { return "Quiet until \(clock(Date(timeIntervalSince1970: u)))" }
        if let u = q["dnd_until"] as? Double, u > t {
            return "Quiet: your do not disturb, until \(clock(Date(timeIntervalSince1970: u)))"
        }
        return nil
    }

    static func fresh(_ coreAt: Date?, now: Date) -> Bool {
        guard let c = coreAt else { return false }
        return now.timeIntervalSince(c) <= coreFreshS
    }

    /// The lines under "How Iris is", in order.
    static func lines(ears e: [String: Any]?, screenPermitted: Bool, eyesOffUntil: Date?, core: [String: Any]?,
                      coreAt: Date?, lastFridayContact: Date?, now: Date) -> [String] {
        let f = fresh(coreAt, now: now)
        return [ears(e, now: now), eyes(permitted: screenPermitted, offUntil: eyesOffUntil, now: now),
                voice(core, fresh: f), friday(lastContact: lastFridayContact, now: now),
                quiet(core, fresh: f, now: now)].compactMap { $0 }
    }

    /// Her menu's settings as they stand now: (title, on: a checkmark or nil, action). Quiet is Core's: with no
    /// fresh word on it, it can't be offered (nil action).
    static func toggles(earsOffUntil: Double?, eyesOffUntil: Date?, screenPermitted: Bool = true,
                        core: [String: Any]?, coreAt: Date?,
                        quietAsked: Bool, now: Date) -> [(title: String, on: Bool?, action: String?)] {
        let earsOn = !((earsOffUntil ?? 0) > now.timeIntervalSince1970)
        let eyesOn = !((eyesOffUntil.map { $0 > now }) ?? false)
        // checked: on; a click turns it off for an hour (as "stop listening" said to her does), or back on
        let earsTitle = earsOn ? "Listen" : "Listen (off until \(clock(Date(timeIntervalSince1970: earsOffUntil ?? 0))))"
        let eyesTitle = eyesOn ? "Look at My Screen" : "Look at My Screen (off until \(clock(eyesOffUntil ?? now)))"
        var out: [(String, Bool?, String?)] = [(earsTitle, earsOn, earsOn ? "ears_off" : "ears_on")]
        // without Screen Recording she can't look, so it isn't shown on (nor offered)
        out.append(screenPermitted ? (eyesTitle, eyesOn, eyesOn ? "eyes_off" : "eyes_on")
                                   : ("Look at My Screen (Screen Recording isn't allowed)", false, nil))
        let f = fresh(coreAt, now: now)
        let q = core?["quiet"] as? [String: Any]
        if quietAsked {
            out.append(("Quiet: asking \(Config.agentName)…", nil, nil))
        } else if !f || q == nil || q?["unread"] != nil {
            out.append(("Be Quiet for an Hour (no word from \(Config.agentName))", nil, nil))
        } else if let u = q?["hush_until"] as? Double, u > now.timeIntervalSince1970 {
            out.append(("Talk Again", nil, "talk"))
        } else {
            out.append(("Be Quiet for an Hour", nil, "quiet"))
        }
        return out
    }
}
