import Foundation

/// Her drawn clips whose cause is her own body.
/// Each decision is a pure function of her state, so it can be tested on its own
/// (tests/test_iris_body_stages_1021.py compiles this file with a driver). No dice, no rotation:
/// a clip plays because its state holds, and its why says which state.
enum Stages {
    /// Asleep this long, she is deep asleep: snore instead of her sleep pose. Her poses.jsonl,
    /// 10-14 23:15 to 10-21 00:33: 191 sleeps, median 436 s, 75th percentile 965 s; 40 lasted
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
    static func gait(walking: Bool, inAir: Bool, shooed: Bool, walkWhy: String) -> String {
        guard walking, !inAir else { return "" }
        if shooed { return "sad_walk" }
        if walkWhy.hasPrefix("corner:") { return "tiptoe" }
        if walkWhy == "to the screen he's working on" { return "run" }      // 10-24: a quick run over, not a stroll
        return ""
    }

    struct Seat: Equatable { var clip: String; var why: String }

    /// What she does seated, when a drawn clip says it better than her sit pose:
    /// - on top of one of his windows: "sit_legs" ("sitting on top of a window"), legs over the edge;
    /// - he has been away 5 minutes or more, nothing moving on his screens: "fishing" ("waiting,
    ///   patient"), waiting for him;
    /// - a long quiet sit with him here (seated 5 minutes, his hand on the Mac in the last 30 s, no keys
    ///   for a minute, not sleepy): "read_book" ("quiet time while he works").
    /// Never while she types along, watches his video, listens, talks, or is asleep; nil otherwise.
    static func seat(seated: Bool, onWindow: Bool, typingAlong: Bool, watchingVideo: Bool, asleep: Bool,
                     listening: Bool, talking: Bool, seatedFor: Double, hisIdle: Double, sinceKeys: Double,
                     sleepiness: Double, screenMoving: Bool, callOn: Bool, music: Bool,
                     fishing: Bool = false) -> Seat? {
        guard seated, !typingAlong, !asleep, !listening, !talking else { return nil }
        if onWindow { return Seat(clip: "sit_legs", why: "sitting on top of his window") }
        guard !watchingVideo, !callOn, !music else { return nil }
        // 10-21 pose log 13:00-15:42: fishing held 0-90 s, 23 times in 3 h — a Discord line moving on his other
        // screen ended it and stillness began it again. Once she's fishing she waits until he's back.
        if fishing && hisIdle >= 30 {
            return Seat(clip: "fishing", why: String(format: "waiting for him: away %.0f min", hisIdle / 60))
        }
        if hisIdle >= awayFor && !screenMoving {
            return Seat(clip: "fishing", why: String(format: "waiting for him: away %.0f min", hisIdle / 60))
        }
        if seatedFor >= quietSitFor && hisIdle < 30 && sinceKeys >= 60 && sleepiness < 0.45 {
            return Seat(clip: "read_book", why: String(format: "quiet time with him: seated %.0f min, no keys %.0f s",
                                                       seatedFor / 60, min(sinceKeys, 3600)))
        }
        return nil
    }
    static let awayFor: Double = 180        // 10-21: was 300, the moment she dozed too (fishing 5 s, then asleep)
    static let quietSitFor: Double = 300

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
