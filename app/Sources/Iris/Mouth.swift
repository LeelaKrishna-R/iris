import AVFoundation
import Foundation
import os

/// One clip her mouth plays: Friday's voice from an mp3 / wav (PlayerClip), or a stand-in in the tests.
protocol MouthClip: AnyObject {
    var duration: Double { get }
    var isPlaying: Bool { get }
    /// Called once, on any thread, when it finished or couldn't go on (a decode error).
    var onEnd: (() -> Void)? { get set }
    /// Starts it; false when it wouldn't start.
    func start() -> Bool
    func halt()
}

/// Friday's voice through AVAudioPlayer.
final class PlayerClip: NSObject, MouthClip, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onEnd: (() -> Void)?

    init?(_ data: Data) {
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        player = p
        super.init()
        p.delegate = self
        p.prepareToPlay()
    }

    var duration: Double { player.duration }
    var isPlaying: Bool { player.isPlaying }
    func start() -> Bool { player.play() }
    func halt() { player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onEnd?() }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        log("mouth: a clip couldn't be decoded (\(error.map { "\($0)" } ?? "no reason given")); the next one")
        onEnd?()
    }
}

/// Friday's voice through her ears' own engine (SharedAudio), so the echo canceller there takes it out of what her
/// ears hear. Made only while that engine runs with voice processing; otherwise PlayerClip.
final class EngineClip: NSObject, MouthClip, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    private let ended = OSAllocatedUnfairLock(initialState: false)
    var onEnd: (() -> Void)?

    init?(_ data: Data, engine: AVAudioEngine) {
        guard engine.isRunning, let buf = EngineClip.decode(data) else { return nil }
        self.engine = engine
        buffer = buf
        super.init()
    }

    /// The clip's audio, whole (an mp3 or a wav from Core), or nil when it can't be read.
    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let head = [UInt8](data.prefix(4))
        let ext = head.starts(with: [0x52, 0x49, 0x46, 0x46]) ? "wav" : "mp3"        // "RIFF", else mp3 (ID3 / sync)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iris-clip-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        return buf.frameLength > 0 ? buf : nil
    }

    var duration: Double { Double(buffer.frameLength) / max(1, buffer.format.sampleRate) }
    var isPlaying: Bool { node.isPlaying }

    func start() -> Bool {
        guard engine.isRunning else { return false }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in self?.finished() }
        node.play()
        return true
    }

    func halt() {
        node.stop()
        finished()
    }

    /// Once: its node leaves the engine (on main, where the engine is changed) and Mouth is told.
    private func finished() {
        guard ended.withLock({ was in defer { was = true }; return !was }) else { return }
        let end = onEnd
        DispatchQueue.main.async { [engine, node] in
            if node.engine != nil { engine.detach(node) }
            end?()
        }
    }
}

/// Her mouth: Friday's voice through the Mac mini speakers, one clip after another.
///
/// play()'s result was ignored and a decode error had no handler, so a clip that never started or never
/// finished left `playing` set; every clip after it queued behind it and she was silent until a restart. Now a
/// clip that won't start, fails to decode, or hasn't finished `grace` seconds after its length is passed over, and
/// the queue holds at most `cap` clips besides the one playing (play() refuses more: `isFull`).
// (strict concurrency): the queue and the clip playing are her main thread's (@MainActor); what play() is
// called with (the HTTP server's thread) and Ears' barge-in read only the two counts, each kept in a lock
// (OSAllocatedUnfairLock: Sendable). @preconcurrency until main.swift, which makes and wires it, is main-actor too.
@preconcurrency @MainActor
final class Mouth {
    nonisolated static let cap = 12

    private var queue: [(MouthClip, String, Bool, String)] = []
    private var playing: MouthClip?
    private let grace: Double
    /// A clip started: its words, its length, whether it answers them, and its tone as it was queued with.
    var onStart: ((String, Double, Bool, String) -> Void)?

    /// What play() is called with (the HTTP server's thread) and her main thread share, under one lock (review:
    /// a stop clears both together): how many clips are held (waiting, or playing), and the clips handed over by
    /// enqueue(), in the order they came, until main takes them. Unchecked because a clip isn't Sendable: it is only
    /// touched by whoever holds this lock, and once taken, only on main.
    private struct Shared { var held = 0; var inbox: [(MouthClip, String, Bool, String)] = [] }
    private nonisolated let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
    /// Each clip's number as it starts (review its callbacks named it by its memory address, which a
    /// freed clip's timer could share with a new one, and stop it).
    private var clipSeq = 0, playingSeq = 0

    nonisolated init(grace: Double = 3) { self.grace = grace }

    /// Whether play() would refuse a clip now (the one playing and `cap` waiting).
    nonisolated var isFull: Bool { shared.withLockUnchecked { $0.held > Self.cap } }

    /// Nothing playing and nothing waiting.
    var isIdle: Bool { playing == nil && queue.isEmpty }

    /// Queue an mp3/wav; returns its length in seconds, or nil if it can't be played or the queue is full.
    /// `listen`: it answers them, so their next words after it are for her without her name (Ears.mute).
    /// `tone`: how much the line matters (her bubble's colour), handed back by onStart with the clip it came with.
    nonisolated func play(_ data: Data, text: String, listen: Bool = true, tone: String = "") -> Double? {
        // through her ears' engine while it runs with voice processing (her own voice cancelled from what she
        // hears); the old player when it doesn't, or the clip can't be read there
        let viaEngine: MouthClip? = SharedAudio.processing ? EngineClip(data, engine: SharedAudio.engine) : nil
        guard let clip = viaEngine ?? PlayerClip(data) else { return nil }
        let secs = clip.duration
        return enqueue(clip, text: text, listen: listen, tone: tone) ? secs : nil
    }

    /// Queues a clip, handed over to her main thread (whoever made it doesn't touch it again); false when full.
    @discardableResult
    nonisolated func enqueue(_ clip: sending MouthClip, text: String, listen: Bool = true, tone: String = "") -> Bool {
        let took = shared.withLockUnchecked { s -> Bool in
            guard s.held <= Self.cap else { return false }
            s.held += 1
            s.inbox.append((clip, text, listen, tone))
            return true
        }
        guard took else { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.queue += self.shared.withLockUnchecked { s in defer { s.inbox.removeAll() }; return s.inbox }
                if self.playing == nil { self.next() }
            }
        }
        return true
    }

    private nonisolated func release() {
        shared.withLockUnchecked { $0.held = max(0, $0.held - 1) }
    }

    /// Whether clip number `seq` is the one playing now.
    private func isPlaying(_ seq: Int) -> Bool { playing != nil && playingSeq == seq }

    /// The next clip that starts; one that won't is passed over.
    private func next() {
        playing = nil
        while !queue.isEmpty {
            let (clip, text, listen, tone) = queue.removeFirst()
            clipSeq += 1
            let id = clipSeq
            playing = clip
            playingSeq = id
            clip.onEnd = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isPlaying(id) else { return }
                        self.release()
                        self.next()
                    }
                }
            }
            if clip.start() {
                onStart?(text, clip.duration, listen, tone)
                // The delegate never calling back left her silent for good: past its length, it's over.
                DispatchQueue.main.asyncAfter(deadline: .now() + clip.duration + grace) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isPlaying(id) else { return }
                        log("mouth: a clip hadn't finished \(self.grace)s after its length; the next one")
                        self.playing?.halt()
                        self.release()
                        self.next()
                    }
                }
                return
            }
            log("mouth: a clip wouldn't start; the next one")
            clip.onEnd = nil
            playing = nil
            release()
        }
    }

    /// Everything stopped and the queue emptied, on her main thread (now, or next when called from another).
    nonisolated func stop() {
        if Thread.isMainThread { MainActor.assumeIsolated { halt() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { self.halt() } } }
    }

    private func halt() {
        // review what was accepted but not yet taken goes too (it played over their barge-in), with the count
        shared.withLockUnchecked { $0.inbox.removeAll(); $0.held = 0 }
        queue.removeAll()
        playing?.onEnd = nil
        playing?.halt()
        playing = nil
    }

    // QA: the person cut in (her name while she talked: Ears' barge-in). Core makes an answer a
    // sentence at a time, so the rest of the one the person interrupted kept arriving and the next
    // sentence played over them. Clips are refused until they have finished what the person cut in with
    // (Ears.onDone), or 15 s pass if that never comes.
    private nonisolated let cutUntil = OSAllocatedUnfairLock(initialState: Date.distantPast)

    nonisolated func cut() {
        stop()
        cutUntil.withLock { $0 = Date().addingTimeInterval(15) }
    }

    nonisolated func uncut() {
        cutUntil.withLock { $0 = .distantPast }
    }

    nonisolated var isCut: Bool { cutUntil.withLock { Date() < $0 } }
}
