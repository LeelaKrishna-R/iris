import AVFoundation
import Foundation

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

/// Her mouth: Friday's voice through the Mac mini speakers, one clip after another.
///
/// play()'s result was ignored and a decode error had no handler, so a clip that never started or never
/// finished left `playing` set; every clip after it queued behind it and she was silent until a restart. Now a
/// clip that won't start, fails to decode, or hasn't finished `grace` seconds after its length is passed over, and
/// the queue holds at most `cap` clips besides the one playing (play() refuses more: `isFull`).
final class Mouth {
    static let cap = 12

    private var queue: [(MouthClip, String, Bool)] = []
    private var playing: MouthClip?
    private let grace: Double
    var onStart: ((String, Double, Bool) -> Void)?

    /// Clips held (waiting, or playing), counted where play() is called (the HTTP server's thread).
    private let heldLock = NSLock()
    private var held = 0

    init(grace: Double = 3) { self.grace = grace }

    /// Whether play() would refuse a clip now (the one playing and `cap` waiting).
    var isFull: Bool { heldLock.lock(); defer { heldLock.unlock() }; return held > Self.cap }

    /// Nothing playing and nothing waiting (read on the main thread).
    var isIdle: Bool { playing == nil && queue.isEmpty }

    /// Queue an mp3/wav; returns its length in seconds, or nil if it can't be played or the queue is full.
    /// `listen`: it answers him, so his next words after it are for her without her name (Ears.mute).
    func play(_ data: Data, text: String, listen: Bool = true) -> Double? {
        guard let clip = PlayerClip(data) else { return nil }
        return enqueue(clip, text: text, listen: listen) ? clip.duration : nil
    }

    /// Queues a clip; false when the queue is full.
    @discardableResult
    func enqueue(_ clip: MouthClip, text: String, listen: Bool = true) -> Bool {
        heldLock.lock()
        guard held <= Self.cap else { heldLock.unlock(); return false }
        held += 1
        heldLock.unlock()
        DispatchQueue.main.async {
            self.queue.append((clip, text, listen))
            if self.playing == nil { self.next() }
        }
        return true
    }

    private func release() {
        heldLock.lock(); held = max(0, held - 1); heldLock.unlock()
    }

    /// The next clip that starts; one that won't is passed over.
    private func next() {
        playing = nil
        while !queue.isEmpty {
            let (clip, text, listen) = queue.removeFirst()
            playing = clip
            clip.onEnd = { [weak self, weak clip] in
                DispatchQueue.main.async {
                    guard let self, let clip, self.playing === clip else { return }
                    self.release()
                    self.next()
                }
            }
            if clip.start() {
                onStart?(text, clip.duration, listen)
                // The delegate never calling back left her silent for good: past its length, it's over.
                DispatchQueue.main.asyncAfter(deadline: .now() + clip.duration + grace) { [weak self, weak clip] in
                    guard let self, let clip, self.playing === clip else { return }
                    log("mouth: a clip hadn't finished \(self.grace)s after its length; the next one")
                    clip.halt()
                    self.release()
                    self.next()
                }
                return
            }
            log("mouth: a clip wouldn't start; the next one")
            clip.onEnd = nil
            playing = nil
            release()
        }
    }

    func stop() {
        let halt = {
            self.queue.removeAll()
            self.playing?.onEnd = nil
            self.playing?.halt()
            self.playing = nil
            self.heldLock.lock(); self.held = 0; self.heldLock.unlock()
        }
        if Thread.isMainThread { halt() } else { DispatchQueue.main.async(execute: halt) }
    }

    // QA: he cut in (her name while she talked: Ears' barge-in). Core makes an answer a
    // sentence at a time, so the rest of the one he interrupted kept arriving and the next
    // sentence played over him. Clips are refused until he has finished what he cut in with
    // (Ears.onDone), or 15 s pass if that never comes.
    private let cutLock = NSLock()
    private var cutUntil = Date.distantPast

    func cut() {
        stop()
        cutLock.lock(); cutUntil = Date().addingTimeInterval(15); cutLock.unlock()
    }

    func uncut() {
        cutLock.lock(); cutUntil = .distantPast; cutLock.unlock()
    }

    var isCut: Bool {
        cutLock.lock(); defer { cutLock.unlock() }
        return Date() < cutUntil
    }
}
