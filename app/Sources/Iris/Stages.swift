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
                     fishing: Bool = false, noteFor: String? = nil) -> Seat? {
        guard seated, !typingAlong, !asleep, !listening, !talking else { return nil }
        // (UX audit #5): something waits for him (core/iris_note: a note that interrupted him, unopened; one
        // kept for him alone is not a cue, review): she holds her sticky note at her chest, still (stillSeats),
        // while he's at the Mac, not typing and not on a call; no sound, no bubble, no walk over. `noteFor` is its
        // cause, said in her pose journal.
        if let note = noteFor, !callOn, sinceKeys >= 4, hisIdle < noteAtMacS {
            return Seat(clip: "sticky_note", why: "a note for you: " + note)
        }
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
    // 23:00 and 23:15 she fished, "away 3 min", with him reading at
    // the Mac. No input is all she has of him (no camera), and three still minutes is a page he's reading, not him gone:
    // ten minutes is away; under it, seated, she reads her book beside him. (was 300, then 180.)
    static let awayFor: Double = 600
    /// he's at the Mac for her note cue: some input this recently.
    static let noteAtMacS: Double = 120
    /// seats drawn as one still frame of their clip, its last (SpriteView): the sticky note held at her chest,
    /// not her slapping it forward again and again.
    static let stillSeats: Set<String> = ["sticky_note"]
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

    // MARK: — three more moves of her own, each from a signal she already has

    /// Her laptop was out, typing along with him, at least this long of his typing when it goes away (Body.typeAlongHoldS
    /// after his last key, or a walk with a reason once he has stopped): she gets up and stretches ("yoga", "stretch
    /// break, calm"). His keys have rested at least quietFor first: a clip that stood her up mid-typing is no end of it.
    static let longTypeAlong: Double = 1200
    static let quietFor: Double = 20
    /// At most one stretch of hers in this long, and none this soon after Friday's own stretch nudge
    /// (core/iris_reflex's "stretch_guide", 50 min at the Mac): one stretch, not two in a row.
    static let stretchEvery: Double = 3600
    static let afterFridayStretch: Double = 1800

    /// She stretches as her laptop goes away after typing along with him `alongFor` seconds of his typing.
    static func stretches(alongFor: Double, keysRested: Double, sinceHerStretch: Double, sinceFridayStretch: Double) -> Bool {
        alongFor >= longTypeAlong && keysRested >= quietFor && sinceHerStretch >= stretchEvery
            && sinceFridayStretch >= afterFridayStretch
    }

    /// A moment she shows him (a to-do on his day card come due) waits until he can look: she's awake, he's
    /// at the Mac (input within awayFor), his keys have rested this long, no video or call in front.
    static let showAfterKeys: Double = 8      // past her nod's 3 s: a short pause between his lines isn't his keys at rest
    static func canShow(awake: Bool, hisIdle: Double, sinceKeys: Double, watching: Bool, callOn: Bool) -> Bool {
        awake && hisIdle < awayFor && sinceKeys >= showAfterKeys && !watching && !callOn
    }
    /// A to-do come due is shown within this long of the card saying so, or not at all (it's old news by then).
    static let showWithin: Double = 600
    /// A reminder push (or Friday's sticky note) for a to-do this recently means it was shown already.
    static let alreadyToldWithin: Double = 900

    /// The to-do on his day card (core/iris_day_card's "todos" row: "Title · 3:00 PM", "(past)" once its time
    /// has passed, one per line) that came due between the last card and this one: listed before with its time
    /// still ahead, listed now as past. A to-do that first shows up already past (moved up from "and N more",
    /// or added late) didn't come due now; one whose title is in a push he got lately (`told`: its reminder went
    /// off, and Friday already showed it) is left out. Nil before there was a card, or when none came due.
    static func cameDue(before: String?, after: String?, told: [String] = []) -> String? {
        guard let before, let after else { return nil }
        func parse(_ text: String) -> [(title: String, past: Bool)] {
            text.split(separator: "\n").compactMap { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                guard let dot = l.range(of: " · ") else { return nil }       // "and 2 more" has no time
                return (String(l[..<dot.lowerBound]), l.hasSuffix("(past)"))
            }
        }
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
                .split(separator: " ").joined(separator: " ")
        }
        let ahead = Set(parse(before).filter { !$0.past }.map { norm($0.title) })
        // whole words either way: "Pay rent" is in "Reminder: pay rent today"; "hi" is not in "this"
        let toldN = told.map { " " + norm($0) + " " }.filter { $0.count > 2 }
        for t in parse(after) where t.past && ahead.contains(norm(t.title)) {
            let n = " " + norm(t.title) + " "
            if n.count <= 2 || toldN.contains(where: { $0.contains(n) || n.contains($0) }) { continue }
            return t.title
        }
        return nil
    }

    // MARK: her day card on demand

    /// His pointer this far outside her and the card is "well away": the peek goes.
    static let peekAwayAt: Double = 240
    /// A peek is up at most this long: it never stays on its own.
    static let peekMostS: Double = 60

    /// Why a peek at his day card ends now ("he typed", "his pointer moved away", "a minute up"), or nil to keep it.
    /// `away`: how far his pointer is outside her frame and the card's (0 on either).
    static func peekEnds(shownFor: Double, typedSince: Bool, away: Double) -> String? {
        if typedSince { return "he typed" }
        if away >= peekAwayAt { return "his pointer moved away" }
        if shownFor >= peekMostS { return "a minute up" }
        return nil
    }

    /// The one line her bubble says when his pointer rests on her: from the card's own rows (core/iris_day_card),
    /// never a read of its own. The next thing today ("Next: Dentist at 2:00 PM"); with nothing next, what was kept
    /// for him ("3 kept for you"), else the top line as it is ("Nothing else today", or what couldn't be read). Nil
    /// before the card has rows.
    static func hoverHint(rows: [(key: String, head: String, text: String, off: Bool)]) -> String? {
        guard let top = rows.first(where: { $0.key == "glance" }) else { return nil }
        let first = String(top.text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        let plain = first.hasSuffix(".") ? String(first.dropLast()) : first
        if !top.off && !plain.isEmpty && plain != "Nothing else today" { return "Next: " + plain }
        if let kept = rows.first(where: { $0.key == "kept" && !$0.off }),
           let n = kept.head.split(separator: "·").last.map({ $0.trimmingCharacters(in: .whitespaces) }), Int(n) != nil {
            return "\(n) kept for you"
        }
        return plain.isEmpty ? nil : plain
    }
}
