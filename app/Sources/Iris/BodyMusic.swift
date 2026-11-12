import AppKit

// Iris's body — his music (out of Body.swift): whether a song is playing, and her sway to it.
extension Body {
    /// Music playing (a music app and the speakers in use, checked every 2 s): she
    /// sways a little to it. Never over a video, never asleep. (structure audit): her own dance to it
    /// (every Body.danceEveryS) is gone: music had two moments, this and Core's music clip (core/iris_reflex,
    /// picked by what's playing: a conductor for Bach, a guitar for acoustic), and Core's has the better cause.
    /// What she hears is in /eyes/now ("music", Senses) for Core's one answer.
    func listenToMusic(_ now: Date) {
        if now.timeIntervalSince(musicCheckedAt) > 2 {
            musicCheckedAt = now
            // her own voice uses the same speakers: not music (2 s after she stops, for the tail)
            let on = world.musicPlaying && now.timeIntervalSince(talkUntil) > 2
            if on && !musicOn { events.append("music started playing") }
            musicOn = on
            Senses.set(music: on, video: watchingVideo)
        }
        guard musicOn, !watchingVideo, !sleeping, !held, performing.isEmpty else { return }
        let half = Int(clock * 2)                       // a sway each half second, about a beat
        if half != lastSway { lastSway = half; lean.kick(half % 2 == 0 ? 0.12 : -0.12) }
    }
}
