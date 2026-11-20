import AVFoundation
import os

/// One audio engine for her ears and her voice, so that she can hear like a person does: not her own voice, and
/// not the room's.
///
/// Her ears only muted themselves while she talked, so her own words leaked into their (her "Yes?" came to
/// Friday as "Yes, can you check my emails …"), and the TV in the room was heard as well as they were. Apple's voice
/// processing on the microphone — the echo canceller, noise suppressor and level control calls use — removes what
/// the engine itself plays from what the microphone hears, so her voice goes out through this same engine
/// (Mouth's EngineClip) while her ears run it. With her ears off the engine is stopped and her voice goes out as
/// before (PlayerClip): the microphone is never opened just so she can speak.
///
/// Tried live: with it on, the engine starts (the output side joined before the voice unit; -10875 otherwise) and the
/// Mac's own sound is cancelled: a sentence played at full volume from the Mac's speakers reached her at about -60 dB,
/// and her voice gate still called buffers of what was left voice, so the gate reads the processed signal. The
/// microphone then comes as four identical channels, and the recognizer was being handed all four; it now gets the
/// first as mono (forRecognizer). Whether a voice at the desk is heard with it on is not yet shown, so it is off by
/// default: her menu's "Echo Cancelling (Trial)" switches it.
enum SharedAudio {
    nonisolated(unsafe) static let engine = AVAudioEngine()

    static let wantedKey = "voiceProcessing"
    static var wanted: Bool { UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? false }

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

    /// What the speech recognizer is given of a buffer with more than two channels: its first channel alone, as
    /// mono; nil for mono and stereo, which go to it as they are. With voice processing on the microphone comes as
    /// four channels, all the same (her log), and her ears' own measures read
    /// only the first — but the recognizer was handed all four, a layout it is not made for, and heard nothing while
    /// her voice gate opened.
    static func forRecognizer(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buf.format.channelCount > 2, usable(buf.format), let src = buf.floatChannelData,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate,
                                       channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buf.frameLength
        dst[0].update(from: src[0], count: Int(buf.frameLength))
        return out
    }
}

/// A value shared across threads under one lock (Sendable).
final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<T>
    init(_ value: T) { lock = OSAllocatedUnfairLock(initialState: value) }
    func get() -> T { lock.withLock { $0 } }
    func set(_ v: T) { lock.withLock { $0 = v } }
}
