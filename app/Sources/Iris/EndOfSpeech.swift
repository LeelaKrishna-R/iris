import Foundation

/// When what you said to her is over (Ears.checkSilence), as rules alone so they can be checked without a
/// microphone: 1.3 s after the last word with the mic quiet, 2.2 s at most, 1.2 s more when the last word
/// plainly goes on ("and", "to", "my", "what" …), 2 s after her name alone. An ask that closes itself
/// ("… please", "… thanks", "… thank you", "… right now"), two words or more, ends 0.8 s after its last
/// word; everything else waits as long as before, so "Can you check" isn't cut off.
enum EndOfSpeech {
    static let afterWords = 1.3          // no new word for this long, and the mic quiet...
    static let quietMic = 0.7            // ...for this long (Ears reads it), ends it
    static let anyway = 2.2              // no new word for this long ends it, mic or not
    static let goesOnExtra = 1.2
    static let afterBareWake = 2.0       // only her name so far: he's still finding the words
    static let afterClosing = 0.8        // his ask closed itself
    static let goesOn: Set<String> = ["and", "or", "but", "so", "to", "the", "a", "an", "my", "your", "for", "with",
                                      "of", "in", "on", "at", "about", "from", "is", "are", "was", "can", "could",
                                      "would", "will", "should", "what", "how", "when", "where", "who", "why",
                                      "if", "that", "this", "because", "um", "uh", "like", "then"]
    static let closingWords: Set<String> = ["please", "thanks"]
    static let closingPairs: Set<String> = ["thank you", "right now"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
    }

    /// His last word plainly goes on ("remind me to …").
    static func trailing(_ text: String) -> Bool {
        words(text).last.map { goesOn.contains($0) } ?? false
    }

    /// His ask closes itself: a closing word, or a closing pair, after at least one word of the ask.
    static func closes(_ text: String) -> Bool {
        let w = words(text)
        guard w.count >= 2, let last = w.last else { return false }
        if closingWords.contains(last) { return true }
        return w.count >= 3 && closingPairs.contains("\(w[w.count - 2]) \(last)")
    }

    /// Over, `since` seconds after his last new word, with the mic quiet (`micQuiet`) or not.
    static func done(text: String, since: TimeInterval, micQuiet: Bool, bareWake: Bool) -> Bool {
        if bareWake { return since > afterBareWake }
        let extra = trailing(text) ? goesOnExtra : 0
        if since > anyway + extra { return true }
        guard micQuiet else { return false }
        return since > (closes(text) ? afterClosing : afterWords + extra)
    }
}
