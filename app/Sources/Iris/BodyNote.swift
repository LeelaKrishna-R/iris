import Foundation

/// What waits for them, as Core last said it with her status or her day card (core/iris_note.waiting, UX audit
/// #5), when it said it, and the set the person already looked at by clicking her (the peek). Kept on her body (Body.noteCue).
final class NoteCue {
    var key: String?
    var why: String?
    var peekedKey: String?
    var heardAt = Date.distantPast
    /// Review (a162): Core says what waits with every status (30 s, core/iris_status); no word for this long and
    /// the cue goes: a Core that stopped, or a lost send, can't leave her holding a note for something long opened.
    static let heardForS: TimeInterval = 120
}

// Iris's body — her quiet "a note for you": while something waits for them she holds her sticky note at her
// chest, still (Stages.seat, Stages.stillSeats); it ends when nothing waits, when the person opens their Notifications (Core
// says nothing waits), when the person clicks her (that set is seen until something new comes), or when Core has said nothing
// for NoteCue.heardForS.
extension Body {
    func noteWaiting(key: String?, why: String?) {
        if noteCue.key != key { trace?("note", ["waiting": key != nil, "why": why ?? ""]) }
        noteCue.key = key
        noteCue.why = why
        noteCue.heardAt = world.now
    }

    func notePeeked() { noteCue.peekedKey = noteCue.key }

    /// Her note cue's cause while it's hers to show: something waits, Core said so in the last 2 minutes, and the person
    /// hasn't clicked her for this set.
    var noteShown: String? {
        guard let k = noteCue.key, k != noteCue.peekedKey,
              world.now.timeIntervalSince(noteCue.heardAt) < NoteCue.heardForS else { return nil }
        return noteCue.why ?? "something waits for you"
    }
}
