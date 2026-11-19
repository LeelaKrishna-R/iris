import AVFoundation
import os

/// One audio engine for her ears and her voice (
/// .
///
/// Her ears only muted themselves while she talked, so her own words leaked into their (her "Yes?" came to
/// Friday as "Yes, can you check my emails …"), and the TV in the room was heard as well as they were. Apple's voice
/// processing on the microphone — the echo canceller, noise suppressor and level control calls use — removes what
/// the engine itself plays from what the microphone hears, so her voice goes out through this same engine
/// (Mouth's EngineClip) while her ears run it. With her ears off the engine is stopped and her voice goes out as
/// before (PlayerClip): the microphone is never opened just so she can speak.
///
/// 03:2x, tried live: with it on, the engine starts (the output side joined before the voice unit; -10875
/// otherwise) and the Mac's own sound is cancelled (a sentence `say` played peaked -39 dB, against -18 dB without, and
/// wasn't heard) — but their voice at the Mac wasn't heard either: her VoiceGate never opened on the processed signal
/// (all 4 channels the same; floor ~-100 dB). Off by default until her gate is fitted to it and they have tested it:
/// `defaults write app.iris.companion voiceProcessing -bool true` to try it.
enum SharedAudio {
    nonisolated(unsafe) static let engine = AVAudioEngine()

    static var wanted: Bool { UserDefaults.standard.object(forKey: "voiceProcessing") as? Bool ?? false }

    /// Her ears' engine runs with voice processing now (set by Ears on her main thread; read by Mouth on any).
    private static let state = OSAllocatedUnfairLockBox(false)
    static var processing: Bool {
        get { state.get() }
        set { state.set(newValue) }
    }

    /// The engine wouldn't start with voice processing on (this run): her ears use the plain microphone until she
    /// restarts, rather than failing every 10 s.
    nonisolated(unsafe) static var failedWithProcessing = false

    /// Whether a format is one her ears can read (Ears.measure and copy read float, non-interleaved channels).
    static func usable(_ f: AVAudioFormat) -> Bool {
        f.sampleRate > 0 && f.channelCount > 0 && f.commonFormat == .pcmFormatFloat32 && !f.isInterleaved
    }
}

/// A value shared across threads under one lock (Sendable).
final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<T>
    init(_ value: T) { lock = OSAllocatedUnfairLock(initialState: value) }
    func get() -> T { lock.withLock { $0 } }
    func set(_ v: T) { lock.withLock { $0 = v } }
}
