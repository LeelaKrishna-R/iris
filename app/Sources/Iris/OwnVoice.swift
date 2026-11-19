import Foundation

/// Her own voice in what her ears heard, and their "stop" over it (she answered herself, and couldn't be
/// interrupted).
///
/// Seen in use: her reply "Yeah, it stopped on the way to me. Voice
/// never made it past the app this time." came back 11 s later as their words, word for word, and was answered. Her
/// ears keep one recognition task going while she talks (so her name can cut in), and that task's words pile up:
/// once her mute ended, the next guess held her whole line, and in the few seconds after an answer anything heard is
/// taken as their follow-up. Ears now starts a fresh task when she stops talking; this is the check behind it.
///
/// While she talked, only her name stopped her. "Stop", "wait", "hold on" now do too — when the person says them, not she:
/// the words in her own line are hers.
///
/// Apart from Ears (AVFoundation, Speech) so it compiles on its own: tests/test_iris_own_voice_1116.py.
enum OwnVoice {
    static let stopPhrases = ["stop", "wait", "hold on", "hang on", "shut up", "enough", "be quiet", "pause",
                              "never mind", "nevermind", "okay okay", "ok ok", "that's enough", "thats enough"]

    static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func count(_ phrase: String, in low: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b")
        else { return 0 }
        return re.numberOfMatches(in: low, range: NSRange(low.startIndex..., in: low))
    }

    /// He said "stop" (or "wait", "hold on" …) while she talked: one said more often in what her ears heard than in
    /// the line she is saying. `heard` is the task's words so far, which hold her line as well as their.
    static func stopSaid(_ heard: String, ownLine: String) -> Bool {
        let low = words(heard).joined(separator: " "), own = words(ownLine).joined(separator: " ")
        return stopPhrases.contains { count($0, in: low) > count($0, in: own) }
    }

    /// What was heard is her own last answer coming back. Review 37: `answer` is her whole last answer, its clips
    /// joined (Core sends one clip a sentence); matched in order, a garbled word or two allowed (longest common
    /// subsequence, by word). Hers when that covers at least 75% of what was heard and 60% of her answer, and it
    /// isn't plainly their answer to her: a reply that opens with "yes", "no", "okay" … when she didn't, or that drops
    /// the lead-in of her question ("Should I delete the one from the bank?" → "delete the one from the bank please").
    static let answerWords: Set<String> = ["yes", "yeah", "yep", "yup", "no", "nope", "nah", "okay", "ok", "sure",
                                           "please", "don't", "dont", "do", "correct", "right", "exactly", "fine"]

    static func isEcho(_ heard: String, answer: String) -> Bool {
        let w = words(heard), hers = words(answer)
        guard w.count >= 6, !hers.isEmpty else { return false }
        if let first = w.first, answerWords.contains(first), hers.first != first { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?"), hers.count >= 2, !(w.starts(with: hers.prefix(2))) {
            return false                                   // her question, answered without its lead-in
        }
        // review 38: an echo begins and ends on her words; their own word before or after hers ("cancel the meeting at
        // 3 with sam" after "The meeting is at 3 with Sam.", "…with sam right") makes it their. A misheard first or
        // last word lets an echo through, the safer way to be wrong: the fresh task after her line is the guard.
        let set = Set(hers)
        guard let f = w.first, let l = w.last, set.contains(f), set.contains(l) else { return false }
        let common = inOrder(w, hers)
        return Double(common) >= 0.75 * Double(w.count) && Double(common) >= 0.6 * Double(hers.count)
    }

    /// What was heard with her own last words taken off its front: the end of her answer heard ahead of their ask.
    /// the person said "\(Config.agentName)", she said "Yes?", and what came to Friday
    /// was "Yes, can you check my emails and see which one needs a reply" — her "Yes?" first. When the first words
    /// heard are her answer's last words and two or more of their follow, hers go. Unchanged otherwise.
    static func withoutHerTail(_ heard: String, answer: String) -> String {
        let tokens = heard.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let said = tokens.map { words($0).joined(separator: " ") }
        let hers = words(answer)
        guard !hers.isEmpty, said.count >= 3 else { return heard }
        // her question answered in her own words is their ("the second one please" to "…the first or the second one?");
        // only her one- or two-word "Yes?" is taken off a question
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") && hers.count > 2 { return heard }
        for k in stride(from: min(hers.count, said.count - 2), through: 1, by: -1) {
            if Array(said[0..<k]) == Array(hers[(hers.count - k)...]) {
                return tokens[k...].joined(separator: " ")
            }
        }
        return heard
    }

    /// How many words both say in the same order, gaps allowed (longest common subsequence, by word).
    static func inOrder(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// the room has been talking — the TV, a call,
    /// people — when, in the last `window` seconds, voice was heard in at least `share` of the seconds that were
    /// neither hers (she was speaking) nor their to her. Then what follows her answer needs her name: the few seconds
    /// after an answer, where anything heard was taken as their follow-up, were the TV's every time.
    /// `voiced`: the seconds (epoch) voice was heard; `spans`: [start, end] of hers and of their asks to her.
    static func roomBusy(voiced: [Double], spans: [[Double]], now: Double, window: Double = 60,
                         share: Double = 0.4) -> Bool {
        let from = now - window
        func taken(_ t: Double) -> Bool { spans.contains { $0.count == 2 && t >= $0[0] - 0.5 && t <= $0[1] + 0.5 } }
        var free = 0.0
        var s = from
        while s < now { if !taken(s) { free += 1 }; s += 1 }
        guard free >= 15 else { return false }               // too little of the room heard to say
        let other = Set(voiced.filter { $0 >= from && $0 <= now && !taken($0) }.map { Int($0) }).count
        return Double(other) / free >= share
    }
}
