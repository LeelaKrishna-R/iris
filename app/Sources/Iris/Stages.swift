import Foundation

/// Her drawn clips whose cause is her own body (owner: why aren't her animations used?).
/// Each decision is a pure function of her state, so it can be tested on its own
/// (tests/test_iris_body_stages_1021.py compiles this file with a driver). No dice, no rotation:
/// a clip plays because its state holds, and its why says which state.
enum Stages {
    /// Asleep this long, she is deep asleep: snore instead of her sleep pose. Her poses.jsonl,
    /// to 191 sleeps, median 436 s, 75th percentile 965 s; 40 lasted
    /// 20 minutes or more.
    static let deepSleepAfter: Double = 1200

    /// "snore" ("deep asleep") while she has been asleep deepSleepAfter or longer.
    static func snoring(asleep: Bool, asleepFor: Double) -> Bool { asleep && asleepFor >= deepSleepAfter }

    /// How long she dozes on her feet before sleep: about two droops of the drawn clip (8 frames at ~0.35 s).
    static let dozeSeconds: Double = 6
    /// When she would fall asleep: standing, she dozes off on her feet first ("doze", "sleepy, late at
    /// night") and falls asleep when it ends; seated, she just falls asleep. False seated or going home.
    static func dozeFirst(dozy: Bool, goingHome: Bool, seated: Bool) -> Bool { dozy && !goingHome && !seated }

    /// The doze ends in sleep only if nothing woke her during it: no input from him since it began,
    /// not carried, not listening.
    static func dozeEndsInSleep(inputSinceDozeBegan: Bool, held: Bool, listening: Bool) -> Bool {
        !inputSinceDozeBegan && !held && !listening
    }

    /// How she walks, when her walk has a cause that changes it: "sad_walk" when he told her to go
    /// away, "tiptoe" on her way to a quiet corner because of his call or his film. "" is her own walk.
    /// poses.jsonl (with what pose() read): after the hop down between his screens she was often a few
    /// steps from her spot, and the drawn run came back for 0.1-0.2 s before she arrived (run <-> stand
    /// flickers, 5 in 45 min). The run is for the way over; a stretch shorter than this is her walk.
    /// A run starts only with runStartLeft still to go (at her ~320 pt/s, more than 0.4 s of running before
    /// runMinLeft), so it never shows for a moment; once running she keeps it down to runMinLeft.
    static let runMinLeft: Double = 140
    static let runStartLeft: Double = 300

    static func gait(walking: Bool, inAir: Bool, shooed: Bool, walkWhy: String, left: Double = .infinity,
                     running: Bool = false) -> String {
        guard walking, !inAir else { return "" }
        if shooed { return "sad_walk" }
        if walkWhy.hasPrefix("corner:") { return "tiptoe" }
        if walkWhy == "to the screen he's working on" && left > (running ? runMinLeft : runStartLeft) {
            return "run"                                                     // a quick run over, not a stroll
        }
        return ""
    }

    struct Seat: Equatable { var clip: String; var why: String }

    /// What she does seated, when a drawn clip says it better than her sit pose:
    /// - on top of one of his windows: "sit_legs" ("sitting on top of a window"), legs over the edge;
    /// - he has been away 5 minutes or more, nothing moving on his screens: "fishing" ("waiting,
    ///   patient"), waiting for him;
    /// - a quiet sit with him here (seated a minute, his hand on the Mac within awayFor, no keys for a
    ///   minute): "read_book" ("quiet time while he works").
    /// Never while she types along, watches his video, listens, talks, or is asleep; nil otherwise.
    static func seat(seated: Bool, onWindow: Bool, typingAlong: Bool, watchingVideo: Bool, asleep: Bool,
                     listening: Bool, talking: Bool, seatedFor: Double, hisIdle: Double, sinceKeys: Double,
                     sleepiness: Double, screenMoving: Bool, callOn: Bool, music: Bool,
                     fishing: Bool = false) -> Seat? {
        guard seated, !typingAlong, !asleep, !listening, !talking else { return nil }
        if onWindow { return Seat(clip: "sit_legs", why: "sitting on top of his window") }
        guard !watchingVideo, !callOn, !music else { return nil }
        // pose log 13:00-15:42: fishing held 0-90 s, 23 times in 3 h — a Discord line moving on his other
        // screen ended it and stillness began it again. Once she's fishing she waits until he's back.
        if fishing && hisIdle >= 30 {
            return Seat(clip: "fishing", why: String(format: "waiting for him: away %.0f min", hisIdle / 60))
        }
        if hisIdle >= awayFor && !screenMoving {
            return Seat(clip: "fishing", why: String(format: "waiting for him: away %.0f min", hisIdle / 60))
        }
        // sim 27 (him reading, no input for 30 s or more at a time): her book needed his hand in the last
        // 30 s, so she sat plainly for 783 of 900 s — the stare he sees. He's here until awayFor (then she fishes).
        // -03:00 live (sim 51): "not sleepy" kept her book from every quiet sit after 1 AM, when her
        // sleepiness is 1.00, and her doze waits for 2 min of no input from him: plain sits of 2-5 min. Asleep is
        // already no seat (above), so a sleepy quiet sit with him here is her book too.
        if seatedFor >= quietSitFor && hisIdle < awayFor && sinceKeys >= 60 {
            return Seat(clip: "read_book", why: String(format: "quiet time with him: seated %.0f min, no keys %.0f s",
                                                       seatedFor / 60, min(sinceKeys, 3600)))
        }
        return nil
    }
    static let awayFor: Double = 180        // was 300, the moment she dozed too (fishing 5 s, then asleep)
    static let quietSitFor: Double = 60      // was 300; a long sit is her book, not a stare

    /// A hop down from one of his windows is a jump she lands from ("fall_land", "jumping down from a
    /// window") when it drops at least this far: less is a step, too short for the falling frames.
    static let jumpDownAtLeast: Double = 100
    static func jumpsDown(fromWindow: Bool, drop: Double) -> Bool { fromWindow && drop >= jumpDownAtLeast }

    /// Which way she walks off when he tells her to go away: away from his cursor, unless that side has
    /// under half a walk-off of room and the other has more; then toward the room.
    /// me / cursor: x of her left edge and his cursor; minX / maxX: where her left edge can be on this screen.
    static func shooDirection(me: Double, cursor: Double, minX: Double, maxX: Double, width: Double,
                              step: Double = 300) -> (dir: Double, why: String) {
        let mid = me + width / 2
        let away: Double = cursor > mid ? -1 : 1
        let roomAway = away < 0 ? me - minX : maxX - me
        let roomOther = away < 0 ? maxX - me : me - minX
        if roomAway >= step / 2 || roomAway >= roomOther { return (away, "away from his cursor") }
        return (-away, "toward the room on his cursor's side")
    }

    /// Waiting on Friday's answer to him: thinking first, then foot-tapping ("tap_foot", "waiting,
    /// impatient") once it has taken this long — standing only (the clip stands; seated she keeps thinking).
    static let impatientAfter: Double = 4
    static func impatient(waiting: Bool, waitedFor: Double, seated: Bool) -> Bool {
        waiting && waitedFor >= impatientAfter && !seated
    }
}
