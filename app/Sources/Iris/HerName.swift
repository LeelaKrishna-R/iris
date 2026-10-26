import Foundation

/// Her name in what he said, and what of it is for her, decided on his finished words.
///
/// 10-19: her ears woke on a partial guess and kept that guess's place in the text. The on-device
/// recognizer rewrites its words as he goes on, so a name in one guess can be gone from the next, and a
/// place in one guess points elsewhere in the next. In Iris's ears.jsonl (on-device words) and Friday's
/// surface_history (what reached Core): "I was sick" reached Friday as "s sick" (10-14), and a sentence he
/// said to someone else in the room, with no name in its finished words, reached Friday cut at its first
/// word and was answered (10-19). Now her name is looked for again in the finished words, and the text is
/// cut there; when it is in neither recognizer's finished words, it was not said to her.
///
/// Apart from Ears (AVFoundation, Speech) so it compiles on its own: tests/test_iris_her_name_1019.py.
enum HerName {
    static var wakeWords: [String] { Config.wakeWords }
    /// "Hey Friday" misheard by the on-device recognizer (10-15: "Hey friend").
    static let misheardFriday = #"^\s*(?:hey|hi|okay|ok)\s+(?:friend|friends|fried|frida|fri day)\b"#
    /// "Iris" misheard, only at the start and only before one of her commands.
    static let misheardName = #"^\s*(?:hey\s+)?(?:i was|i will|i'll|irish|ires|iras)(?=\s+(?:come|dance|sit|sleep|wake|stop|go|wave|look|move|be quiet|hush|shh|nap|giggle|say hi))"#
    static let trim = CharacterSet(charactersIn: " ,.!?").union(.whitespaces)

    /// 10-22 (production 10-19 11:41: "…Friday is the moderator so we can know who is active", said to his
    /// Discord, answered aloud): her name said about her, or the weekday, is not said to her.
    static let greetingOnly = #"^\s*(?:(?:hey|hi|hello|okay|ok|yo|oh)[\s,]*)*$"#
    static let weekdayBefore = #"\b(?:on|this|next|last|every|by|until|till|since|before|after|from)\s+$"#
    static let partOfDayAfter = #"^\s*(?:night|morning|afternoon|evening)\b"#
    static let aboutAfter = #"^(?:'s|’s|\s+(?:is|was|has|had|does|did|will|would|can|could|should|isn't|wasn't|doesn't|didn't|won't|can't|just|always|never|said|says|told|keeps)\b)"#

    /// Whether the name at `r` in `low` is talked about (mid-sentence, then "is", "was", "'s"...) or is the
    /// day ("on Friday", "Friday night"); at the start, or after a greeting, it is always his call.
    static func about(_ low: String, _ r: Range<String.Index>) -> Bool {
        let before = String(low[..<r.lowerBound]), after = String(low[r.upperBound...])
        if before.range(of: greetingOnly, options: .regularExpression) != nil { return false }
        if low[r] == "friday" && (before.range(of: weekdayBefore, options: .regularExpression) != nil
                                  || after.range(of: partOfDayAfter, options: .regularExpression) != nil) { return true }
        return after.range(of: aboutAfter, options: .regularExpression) != nil
    }

    /// Where her name (or a known mishearing of it) ends in `text`, the earliest one said to her; nil: not in it.
    static func end(in text: String) -> String.Index? {
        let low = text.lowercased()
        var best: Range<String.Index>?
        for w in wakeWords {
            var from = low.startIndex
            while let r = low.range(of: "\\b\(w)\\b", options: .regularExpression, range: from..<low.endIndex) {
                if !about(low, r) {
                    if best == nil || r.lowerBound < best!.lowerBound { best = r }
                    break
                }
                from = r.upperBound
            }
        }
        for pat in [misheardName] + (wakeWords.contains("friday") ? [misheardFriday] : []) {
            if let r = low.range(of: pat, options: .regularExpression), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best else { return nil }
        return text.index(text.startIndex, offsetBy: low.distance(from: low.startIndex, to: r.upperBound),
                          limitedBy: text.endIndex) ?? text.endIndex
    }

    /// What he said after her name in `text` (all of it for a follow-up); nil when her name isn't in it
    /// or nothing follows it.
    static func after(_ text: String, followUp: Bool) -> String? {
        if followUp {
            let t = text.trimmingCharacters(in: trim)
            return t.isEmpty ? nil : t
        }
        guard let e = end(in: text) else { return nil }
        let said = text[e...].trimmingCharacters(in: trim)
        return said.isEmpty ? nil : said
    }

    /// What of `text` is for her: what follows her name, or all of it when nothing does ("what time is it,
    /// Friday"; "Hey Iris") or it is a follow-up; nil when her name isn't in it.
    static func toHer(_ text: String, followUp: Bool) -> String? {
        if let said = after(text, followUp: followUp) { return said }
        guard !followUp, end(in: text) != nil else { return nil }
        let all = text.trimmingCharacters(in: trim)
        return all.isEmpty ? nil : all
    }

    /// The words handed to Friday when he finished: the server's when what follows her name is in them
    /// (they are better at names and whole sentences, 10-15); else the on-device words when her name is in
    /// those; else the server's when her name alone is in them. Nil: her name was in neither recognizer's
    /// finished words (only in a guess the on-device one took back), so it was not said to her.
    static func choose(onDevice: String, server: String, followUp: Bool) -> (text: String, from: String)? {
        if let s = after(server, followUp: followUp) { return (s, "server") }
        if let d = toHer(onDevice, followUp: followUp) { return (d, "on-device") }
        if let s = toHer(server, followUp: followUp) { return (s, "server") }
        return nil
    }
}
