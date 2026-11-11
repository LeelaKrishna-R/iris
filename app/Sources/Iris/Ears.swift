import Accelerate
import AVFoundation
import CoreAudio
import Speech

/// Her ears: the default microphone (his Blue Yeti), heard on this Mac by
/// Apple's on-device recognizer, always on and free. "Friday …" or "Iris …"
/// — or anything said within a few seconds of Friday answering — is meant
/// for her and queued for Friday Core. Muted while Friday speaks, so she
/// never hears herself.
final class Ears {
    struct Heard: Codable {
        var text: String; var at: Date; var addressed: Bool; var typed: Bool? = nil
        /// When each stage of hearing it happened (epoch seconds): its task began, the first word, the
        /// wake word, his last word. Core logs the latency of each (core/iris._ears_budget),.
        var times: [String: Double]? = nil
    }

    var onWake: (() -> Void)?
    /// He said her name while she was talking (barge-in): stop her voice.
    var onBargeIn: (() -> Void)?
    var onHeard: ((Heard) -> Void)?
    var onDone: (() -> Void)?
    /// He is saying words (to her or not): new words heard, at most once a second.
    var onVoice: (() -> Void)?
    private var voiceToldAt = Date.distantPast

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var lastPartialAt = Date()
    private var taskAt = Date.distantPast       // this recognition task began (stage times)
    private var firstWordAt: Date?
    /// What he says now is for her (her name in a guess, or a follow-up): decided again on his finished words.
    private var addressed = false
    private var followUpWake = false
    private var wokeAt: Date?
    private var conversationUntil = Date.distantPast
    private var mutedUntil = Date.distantPast
    /// What she is saying right now, lowercased: her own words heard back are not his.
    private var ownLine = ""
    private var silenceTimer: Timer?
    // (owner: = off for an hour): the mic engine stops, then starts again on its own
    private(set) var offUntil = Date.distantPast
    private var offTimer: Timer?
    // each recognition task is numbered. Starting a new one cancels the old, and the
    // old one's handler then reports an error: that error used to start yet another task,
    // which cancelled this one, forever (~3 a second: 120% CPU, 126 threads, and nothing
    // heard). Only the current task's handler acts, and a real failure backs off.
    private var generation = 0
    private var failures = 0
    private var lastFailure = ""
    private(set) var running = false
    private(set) var onDevice = false
    private(set) var problem: String?
    // What /health says is what the engine and the tap say (MicHealth). The last buffer the
    // tap got (under `gate`); the engine's configuration and the default input are watched, and a 5-second check
    // restarts an engine found stopped or silent.
    private var lastAudioAt = Date.distantPast
    private var configWatch: NSObjectProtocol?
    private var inputWatch: AudioObjectPropertyListenerBlock?
    private var healthTimer: Timer?
    private var restartedAt = Date.distantPast

    private let lock = NSLock()
    private var queue: [Heard] = []
    private var waiters: [(Heard?) -> Void] = []

    // the on-device recognizer heard "Hey
    // Friday" as "Hey friend", "Iris" as "I was", "while I was away" as "while I wait". It still listens
    // all day (nothing leaves the Mac until her name); from her name on, the same audio also goes to
    // Apple's server recognizer, which is far better at names and whole sentences, and its words are
    // used when they come back within sharpWait of his last word. Off: `defaults write app.iris.companion
    // sharpEars -bool false`.
    static var sharp: Bool { UserDefaults.standard.object(forKey: "sharpEars") as? Bool ?? true }
    static let sharpWait = 1.0
    /// Words he says to her that a recognizer should expect (both recognizers take them).
    static var words: [String] {
        let names = HerName.wakeWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return names + names.flatMap { ["hey \($0)", "okay \($0)"] }
            + ["what did I miss", "remind me", "come here", "go away", "be quiet", "go to sleep", "wake up", "dance", "sit"]
    }
    /// The names in his life, from Core (/ears/words): expected by both recognizers.
    /// kept across her restarts. Core sends them once an hour, so each restart (91 "iris: awake"
    /// in Iris.log) left her recognizers without his names for up to an hour.
    var extraWords: [String] = Store.load([String].self, "ears-words.json") ?? [] {
        didSet { Store.save(extraWords, "ears-words.json") }
    }
    private var expected: [String] { Array((Ears.words + extraWords).prefix(100)) }
    private var taskAudio: [AVAudioPCMBuffer] = []     // this task's audio, from its preroll (under gate)
    private var sharpReq: SFSpeechAudioBufferRecognitionRequest?   // (under gate)
    private var sharpTask: SFSpeechRecognitionTask?
    private var sharpText = ""
    private var sharpGen = 0
    private var sharpDone: (() -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else { self.problem = "microphone_not_allowed"; return }
            SFSpeechRecognizer.requestAuthorization { st in
                DispatchQueue.main.async {
                    guard st == .authorized else { self.problem = "speech_recognition_not_allowed"; return }
                    // "off for an hour" kept through her restarts (she listened again at once)
                    if let off = Store.load(OffUntil.self, "ears_off.json"), off.at > Date().timeIntervalSince1970 {
                        self.off(for: off.at - Date().timeIntervalSince1970)
                        return
                    }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard let rec = recognizer, rec.isAvailable else { problem = "recognizer_unavailable"; retry(); return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { problem = "no_microphone"; retry(); return }
        input.removeTap(onBus: 0)
        voice = VoiceGate(rate: fmt.sampleRate)          // only the tap touches it from here on
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let voiced = self.measure(buf)
            // her ears
            // stayed shut for every line she spoke; now they keep hearing, and only her name
            // (not in her own line) counts while she talks — see partial().
            self.gate.lock()
            self.lastAudioAt = Date()
            let req = self.request
            if req == nil {
                // Quiet room, no recognizer running: keep the last half second, so the
                // first syllable of "Friday" is in the request when sound starts one.
                if let copy = Ears.copy(buf) {
                    self.preroll.append(copy)
                    if self.preroll.count > Ears.prerollBuffers { self.preroll.removeFirst() }
                }
                let start = voiced && !self.starting
                if start { self.starting = true }
                self.gate.unlock()
                if start { DispatchQueue.main.async { self.wake() } }
            } else {
                let sharp = self.sharpReq
                if let copy = Ears.copy(buf) {
                    self.taskAudio.append(copy)
                    if self.taskAudio.count > 1500 { self.taskAudio.removeFirst() }   // ~1 min
                }
                self.gate.unlock()
                req?.append(buf)
                sharp?.append(buf)
            }
        }
        engine.prepare()
        do { try engine.start() } catch { problem = "audio_engine: \(error.localizedDescription)"; retry(); return }
        running = true
        problem = nil
        onDevice = rec.supportsOnDeviceRecognition
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkSilence() }
        watchMic()
        log("ears: listening (on-device: \(onDevice))")
    }

    /// the engine stops when its configuration changes (a mic plugged in or out, another app taking the
    /// device), and the default input can change under it; either restarts it on the device now chosen. Set once.
    private func watchMic() {
        if configWatch == nil {
            configWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                 object: engine, queue: .main) { [weak self] _ in
                self?.restartEngine("the audio configuration changed")
            }
        }
        if inputWatch == nil {
            inputWatch = MicHealth.watchDefaultInput { [weak self] in self?.restartEngine("the default input changed") }
        }
        if healthTimer == nil {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkMic() }
        }
    }

    /// Every 5 s: an engine that stopped, or no audio for twice MicHealth.silentAfter, is restarted (at most every 30 s).
    private func checkMic() {
        guard running, offUntil <= Date(), Date().timeIntervalSince(restartedAt) >= 30 else { return }
        gate.lock(); let ago = Date().timeIntervalSince(lastAudioAt); gate.unlock()
        if !engine.isRunning { restartEngine("the audio engine had stopped") }
        else if ago > 2 * MicHealth.silentAfter { restartEngine("no audio from the microphone for \(Int(ago)) s") }
    }

    /// The engine stopped and started again on the current default input (begin() reads its format again). Never
    /// while he has her ears off.
    private func restartEngine(_ why: String) {
        guard offUntil <= Date() else { return }
        log("ears: restarting the microphone: \(why)")
        restartedAt = Date()
        sleepEars()
        silenceTimer?.invalidate(); silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        begin()
    }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.running, self.offUntil <= Date() else { return }   // never back on while he has them off
            self.begin()
        }
    }

    // recognition only while there is sound. She used to keep a task running all
    // day: every quiet minute ended in "no speech" and a new task 0.3 s later, so the
    // recognizer decoded silence non-stop (35-46% CPU, 370 MB -> 930 MB over 10 hours).
    // Now a task starts when the mic rises above the room's own level, gets the half
    // second before it, and stops after a few quiet seconds.
    // "sound" was any buffer 9 dB over the room's level, so a fan ramping up kept a task
    // running 79-92% of the time with him idle and nothing playing (localspeechrecognition 105
    // CPU-minutes in 15 h). A task now starts on likely speech (VoiceGate: voiced sound over the
    // room's noise, held ~0.1 s), and "quiet" means no speech.
    private let gate = NSLock()
    private var preroll: [AVAudioPCMBuffer] = []
    private var starting = false
    private var lastVoiceAt = Date.distantPast
    private var voice: VoiceGate?                // the audio tap's own (created in begin)
    private var speechNow = false                // (under gate) for status()
    // 0.7 s, was 0.45. The gate opens on sound, then wake() waits for the main thread; a
    // busy frame there cost the first buffers, and with them the "Fri" of "Friday".
    // ~1 s. VoiceGate says speech 0.16 s after it starts (median; 0.25-0.28 s at the 90th
    // percentile, 1.3 s at worst, over 450 voiced clips in rooms in the offline bench), later than
    // raw sound did.
    static let prerollBuffers = 24          // ~1 s at 44.1/48 kHz with 2048-frame buffers
    static let quietStop = 3.0              // seconds of no speech and no words before the task stops

    /// Sound reached the mic: start hearing it, beginning with the half second before.
    private func wake() {
        gate.lock()
        starting = false
        let running = request != nil
        gate.unlock()
        // not while another app has the microphone (a call): what's said there is to other people
        // (a in his Discord talk woke her and was answered aloud), she doesn't speak over a
        // call anyway, and the recognizer ran at ~80% CPU on it. Her menu's "Talk to Friday" still opens.
        if !running && Date() >= conversationUntil && onCall() { return }
        if !running { newTask() }
    }

    private var callCheckedAt = Date.distantPast, callCached = false
    /// Another app holds the microphone (AudioUse.micByOthers), asked at most every 2 s.
    private func onCall() -> Bool {
        if Date().timeIntervalSince(callCheckedAt) >= 2 { callCheckedAt = Date(); callCached = AudioUse.micByOthers }
        return callCached
    }

    /// No sound and no words for a few seconds: stop the recognizer until the next sound.
    private func sleepEars() {
        generation += 1                      // the cancelled task's error is no news
        task?.cancel()
        task = nil
        gate.lock()
        request?.endAudio()
        request = nil
        taskAudio.removeAll()
        sharpReq?.endAudio()
        sharpReq = nil
        gate.unlock()
        lastText = ""
        addressed = false
    }

    private var heardSoundRecently: Bool {
        gate.lock(); defer { gate.unlock() }
        return Date().timeIntervalSince(lastVoiceAt) < 1.0
    }

    /// After a task ends: another at once only if he's still making sound.
    private func nextOrSleep() {
        if heardSoundRecently || Date() < conversationUntil { newTask() } else { sleepEars() }
    }

    private static func copy(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return nil }
        out.frameLength = buf.frameLength
        let n = Int(buf.frameLength)
        if let src = buf.floatChannelData, let dst = out.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) { dst[c].update(from: src[c], count: n) }
            return out
        }
        return nil
    }

    /// One recognition task lasts until he goes quiet (or about a minute).
    private func newTask() {
        generation += 1
        let mine = generation
        task?.cancel()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        r.contextualStrings = expected
        gate.lock()
        for b in preroll { r.append(b) }
        taskAudio = preroll
        preroll.removeAll()
        request = r
        gate.unlock()
        lastText = ""
        addressed = false
        taskAt = Date()
        firstWordAt = nil
        task = recognizer?.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }          // a task already replaced: its end is no news
                if let result {
                    if self.failures >= 5 { self.problem = nil }
                    self.failures = 0
                    let text = result.bestTranscription.formattedString
                    if text != self.lastText {
                        if self.firstWordAt == nil { self.firstWordAt = Date() }
                        self.lastText = text; self.lastPartialAt = Date(); self.partial(text)
                        if Date().timeIntervalSince(self.voiceToldAt) >= 1 { self.voiceToldAt = Date(); self.onVoice?() }
                    }
                    if result.isFinal { self.finish(); self.nextOrSleep() }
                } else if let error {
                    self.finish()
                    let ns = error as NSError
                    let what = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
                    // "no speech" ends a quiet minute: start again at once; anything else backs off
                    let quiet = ns.code == 1110 || ns.code == 203 || ns.code == 301
                    if !quiet {
                        self.failures += 1
                        if what != self.lastFailure || self.failures % 20 == 1 { log("ears: recognition failed (\(self.failures)x): \(what)") }
                        self.lastFailure = what
                        if self.failures >= 5 { self.problem = "recognition_failing: \(what)" }   // /health says she can't hear
                    }
                    if quiet { self.nextOrSleep(); return }
                    // A real failure: stop, and let the next sound start one after a back-off.
                    let wait = min(60, 0.5 * pow(2, Double(min(self.failures, 7))))
                    self.sleepEars()
                    self.gate.lock()
                    self.starting = true             // holds off wake() until the back-off ends
                    self.gate.unlock()
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        self.gate.lock()
                        self.starting = false
                        self.gate.unlock()
                    }
                }
            }
        }
    }

    private func partial(_ text: String) {
        guard !addressed else { return }
        let low = text.lowercased()
        let talking = Date() < mutedUntil
        // the recognizer hears "Iris" as "I was" / "I will" ("Iris come here" → "I was come here"
        // in every on-device run of the bench; "I was" reached Friday as a fragment). At the start of
        // what he says and followed by one of her commands, that is her name.
        if low.range(of: HerName.misheardName, options: .regularExpression) ?? (HerName.wakeWords.contains("friday") ? low.range(of: HerName.misheardFriday, options: .regularExpression) : nil) != nil,
           !talking || ownLine.isEmpty {
            addressed = true; followUpWake = false
            wokeAt = Date()
            startSharp()
            if talking { mutedUntil = Date(); DispatchQueue.main.async { self.onBargeIn?() } }
            DispatchQueue.main.async { self.onWake?() }
            return
        }
        for w in HerName.wakeWords {
            if talking && ownLine.range(of: "\\b\(w)\\b", options: .regularExpression) != nil { continue }   // her own word
            // not when it's the day ("on Friday") or said about her (HerName.about); his finished
            // words are judged again by HerName.choose before anything reaches Friday
            if low.range(of: "\\b\(w)\\b", options: .regularExpression) != nil, HerName.end(in: low) != nil {
                addressed = true; followUpWake = false
                wokeAt = Date()
                startSharp()
                if talking {
                    mutedUntil = Date()               // he cut in: she stops and listens
                    DispatchQueue.main.async { self.onBargeIn?() }
                }
                DispatchQueue.main.async { self.onWake?() }
                return
            }
        }
        if talking { return }                    // while she speaks, only her name is his
        if Date() < conversationUntil {          // a follow-up right after she answered
            addressed = true; followUpWake = true
            wokeAt = Date()
            startSharp()
            DispatchQueue.main.async { self.onWake?() }
        }
    }

    // what he said used to end 1.2 s after the
    // last new word, checked every 0.25 s (1.2-1.45 s). Now: 0.8 s after the last word once the
    // mic is quiet too (the recognizer's words lag the sound, so a quiet mic says he's done), and
    // 1.4 s at most if the room never goes quiet. "Friday" and a pause to think waits 2 s for the
    // rest: it used to go to Friday as "Friday" alone.
    // 0.8 s cut
    // him off mid-sentence ("How", "s sick", "I was", "Can you check" reached Friday). Now 1.3 s
    // after the last word with the mic quiet, 2.2 s at most, and 1.2 s more when his last word
    // plainly goes on ("and", "to", "my", "what" …).
    // The rules themselves: EndOfSpeech (an ask that closes itself, ends at 0.8 s).
    static let endQuietMic = EndOfSpeech.quietMic

    /// Only her name so far ("Friday", "hey Iris"): nothing said after it yet.
    private var bareWake: Bool {
        guard addressed, !followUpWake, HerName.end(in: lastText) != nil else { return false }
        return HerName.after(lastText, followUp: false) == nil
    }

    /// He stopped talking: see endAfterWords.
    private func checkSilence() {
        if !lastText.isEmpty {
            let since = Date().timeIntervalSince(lastPartialAt)
            gate.lock()
            let micQuiet = Date().timeIntervalSince(lastVoiceAt) > Ears.endQuietMic
            gate.unlock()
            guard EndOfSpeech.done(text: lastText, since: since, micQuiet: micQuiet, bareWake: bareWake) else { return }
            finish()
            nextOrSleep()
            return
        }
        // A task with no words: stop it once the room has been quiet a few seconds.
        guard task != nil, Date() >= conversationUntil else { return }
        gate.lock()
        let quietFor = Date().timeIntervalSince(lastVoiceAt)
        gate.unlock()
        if quietFor > Ears.quietStop { sleepEars() }
    }

    private func finish() {
        let text = lastText
        lastText = ""
        guard !text.isEmpty else { return }
        let now = Date()
        let wasAddressed = addressed, followUp = followUpWake
        addressed = false
        if wasAddressed {
            var times = ["task_at": taskAt.timeIntervalSince1970, "last_word_at": lastPartialAt.timeIntervalSince1970]
            if let f = firstWordAt { times["first_word_at"] = f.timeIntervalSince1970 }
            if let w = wokeAt { times["wake_at"] = w.timeIntervalSince1970 }
            let heard = Heard(text: text, at: now, addressed: true, times: times)
            // the stages only, never what he said
            func ms(_ a: Date?, _ b: Date?) -> String { a.flatMap { a in b.map { "\(Int($0.timeIntervalSince(a) * 1000))ms" } } ?? "-" }
            log("ears: heard (first word \(ms(taskAt, firstWordAt)), wake \(ms(taskAt, wokeAt)), end-of-speech \(ms(lastPartialAt, now)))")
            if sharpTask != nil {
                sharpThen(heard, followUp: followUp, onDevice: text)
                return
            }
            handOver(heard, followUp: followUp, onDevice: text, server: "", serverMs: nil)
            return
        }
        if now < mutedUntil { return }       // her own voice heard back while she talked
        deliver(Heard(text: text, at: now, addressed: false), text: text)
    }

    /// He finished something she woke for: what of it is for her, from the finished words of both
    /// recognizers (HerName.choose); when her name is in neither, it wasn't said to her.
    private func handOver(_ heard: Heard, followUp: Bool, onDevice: String, server: String, serverMs: Int?) {
        if let ms = serverMs {
            // the stages only, never what he said
            if server.isEmpty { log("ears: server words missing after \(ms)ms") }
            else if HerName.toHer(server, followUp: followUp) == nil { log("ears: server words without her name (\(ms)ms)") }
        }
        guard let got = HerName.choose(onDevice: onDevice, server: server, followUp: followUp) else {
            log("ears: her name was only in a guess the recognizer took back; not for her")
            deliver(Heard(text: onDevice, at: heard.at, addressed: false), text: onDevice)
            return
        }
        var h = heard
        h.text = got.text
        if got.from == "server", let ms = serverMs {
            h.times?["sharp_ms"] = Double(ms)
            let local = HerName.toHer(onDevice, followUp: followUp) ?? ""
            log("ears: server words (\(ms)ms\(got.text.lowercased() == local.lowercased() ? ", same" : ", differ"))")
        } else if serverMs != nil {
            log("ears: on-device words used")
        }
        deliver(h, text: onDevice)
    }

    private func deliver(_ heard: Heard, text: String) {
        Store.append(["at": heard.at.timeIntervalSince1970, "text": text, "addressed": heard.addressed], to: "ears.jsonl")
        if heard.addressed {
            push(heard)
            DispatchQueue.main.async { self.onHeard?(heard) }
        }
        DispatchQueue.main.async { self.onDone?() }
    }

    /// From her name on, the same audio to Apple's server recognizer too (see `sharp`).
    private func startSharp() {
        guard Ears.sharp, sharpTask == nil, let rec = recognizer, rec.isAvailable else { return }
        sharpGen += 1
        let mine = sharpGen
        sharpText = ""
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = false
        r.contextualStrings = expected
        if #available(macOS 13, *) { r.addsPunctuation = true }
        gate.lock()
        for b in taskAudio { r.append(b) }
        sharpReq = r
        gate.unlock()
        sharpTask = rec.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, mine == self.sharpGen else { return }
                if let result {
                    self.sharpText = result.bestTranscription.formattedString
                    if result.isFinal { self.sharpTask = nil; self.sharpDone?() }
                } else if let error {
                    // "server words missing after 179ms", then the on-device guess "One"; the
                    // server's failure was dropped here, so nothing said why. Its domain and code, never words.
                    let e = error as NSError
                    log("ears: server recognizer failed (\(e.domain) \(e.code))")
                    self.sharpTask = nil
                    self.sharpDone?()
                }
            }
        }
    }

    /// He finished: wait up to sharpWait for the server's words, then hand over the better of the two.
    private func sharpThen(_ heard: Heard, followUp: Bool, onDevice: String) {
        gate.lock()
        sharpReq?.endAudio()
        sharpReq = nil
        gate.unlock()
        let mine = sharpGen
        let t0 = Date()
        var sent = false
        let send: () -> Void = { [weak self] in
            guard let self, !sent else { return }
            sent = true
            self.sharpDone = nil
            if mine == self.sharpGen { self.sharpTask?.cancel(); self.sharpTask = nil }
            self.handOver(heard, followUp: followUp, onDevice: onDevice, server: self.sharpText,
                          serverMs: Int(Date().timeIntervalSince(t0) * 1000))
        }
        sharpDone = send
        if sharpTask == nil { send(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Ears.sharpWait) { send() }
    }

    /// Typed to her (her menu's): meant for Friday, as if
    /// said with her name; Core answers it in her bubble, not out loud.
    func typed(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let heard = Heard(text: String(t.prefix(1000)), at: Date(), addressed: true, typed: true)
        Store.append(["at": heard.at.timeIntervalSince1970, "text": heard.text, "addressed": true, "typed": true],
                     to: "ears.jsonl")
        push(heard)
    }

    /// "Stop listening" for `seconds`: no recognizer, the mic engine stopped (not just ignored), then back on.
    func off(for seconds: Double) {
        guard seconds > 0 else { on(); return }
        offUntil = Date().addingTimeInterval(seconds)
        Store.save(OffUntil(at: offUntil.timeIntervalSince1970), "ears_off.json")
        sleepEars()
        silenceTimer?.invalidate(); silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        offTimer?.invalidate()
        offTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.on() }
        log("ears: off for \(Int(seconds)) s")
    }

    /// Listening again (his word, her menu, or the hour is up).
    func on() {
        offTimer?.invalidate(); offTimer = nil
        let wasOff = offUntil > .distantPast
        offUntil = .distantPast
        if wasOff { Store.save(OffUntil(at: 0), "ears_off.json") }
        if !running { begin() }
        if wasOff { log("ears: on again") }
    }

    /// Talk to her without the wake word (her menu's "Talk to Friday").
    func listenNow() {
        if !running && offUntil > Date() { on() }     // her menu turns her ears back on early
        conversationUntil = Date().addingTimeInterval(8)
        if task == nil { newTask() }
        onWake?()
    }

    /// Friday is about to speak for `seconds`: don't hear it; then, when it answers him (`listen`), listen for a
    /// reply. (journal): a line she says on her own (a thought, a welcome, a notice) opened the
    /// same seven seconds, and his Discord call's "What is the moderator so we can know who is active" was taken
    /// as said to her and answered aloud. Only an answer to him waits for his next words without her name.
    func mute(for seconds: Double, line: String = "", listen: Bool = true) {
        mutedUntil = Date().addingTimeInterval(seconds + 0.6)
        if listen { conversationUntil = mutedUntil.addingTimeInterval(7) }
        ownLine = line.lowercased()
        lastText = ""
        addressed = false
    }

    // MARK: Friday's queue — a long poll from Core takes the next thing he said

    private func push(_ h: Heard) {
        lock.lock()
        if let w = waiters.first { waiters.removeFirst(); waiterIDs.removeFirst(); lock.unlock(); w(h); return }
        queue.append(h)
        if queue.count > 20 { queue.removeFirst() }
        lock.unlock()
    }

    // one reader (Core's loop). A newer poll answers any older one empty: a poll whose
    // Core went away (a restart mid-poll) used to stay first in line for up to 25 s and take what
    // he said next to nobody. A timed-out poll now removes itself, not whichever was first.
    private var waiterSeq = 0

    func next(timeout: Double, _ done: @escaping (Heard?) -> Void) {
        lock.lock()
        if !queue.isEmpty { let h = queue.removeFirst(); lock.unlock(); done(h); return }
        let stale = waiters
        waiters.removeAll()
        waiterSeq += 1
        let mine = waiterSeq
        let fired = NSLock()
        var answered = false
        let once: (Heard?) -> Void = { h in
            fired.lock()
            let first = !answered
            answered = true
            fired.unlock()
            if first { done(h) }
        }
        waiters.append(once)
        waiterIDs = [mine]
        lock.unlock()
        for w in stale { w(nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let i = self.waiterIDs.firstIndex(of: mine) { self.waiterIDs.remove(at: i); self.waiters.remove(at: i) }
            self.lock.unlock()
            once(nil)
        }
    }
    private var waiterIDs: [Int] = []

    // how loud the mic is (dBFS), so "she didn't hear it" can be told apart
    // from "no sound reached the mic". Only the level is kept, never the audio.
    private var levelDB: Float = -160, peakDB: Float = -160, peakAt = Date.distantPast
    /// The room's own level: follows quiet at once, rises slowly (~1 dB a second), so a
    /// fan or the AC is the floor and a voice is above it.
    private var floorDB: Float = -60

    /// Measures the buffer (the level, for /health); true while someone is likely speaking (VoiceGate).
    @discardableResult
    private func measure(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return false }
        let n = Int(buf.frameLength)
        var mean: Float = 0
        vDSP_measqv(ch, 1, &mean, vDSP_Length(n))
        let db = 10 * log10(max(mean, 1e-16))
        levelDB = db
        if db > peakDB || Date().timeIntervalSince(peakAt) > 10 { peakDB = db; peakAt = Date() }
        floorDB = db < floorDB ? db : min(floorDB + 0.045, db)
        let voiced = voice?.feed(ch, count: n) ?? false
        gate.lock()
        if voiced { lastVoiceAt = Date() }
        speechNow = voiced
        gate.unlock()
        return voiced
    }

    func status() -> [String: Any] {
        gate.lock()
        let speech = speechNow
        let heardAt = lastAudioAt
        gate.unlock()
        // Listening only when the engine runs and audio reaches the tap, not because it started once
        let ago: Double? = heardAt == .distantPast ? nil : Date().timeIntervalSince(heardAt)
        let health = MicHealth.of(running: running, engineRunning: engine.isRunning, off: offUntil > Date(),
                                  lastAudioAgo: ago, problem: problem)
        var s: [String: Any] = ["listening": health.listening, "on_device": onDevice, "failures": failures,
                                "hearing": task != nil, "speech": speech, "floor_db": Double(floorDB.rounded()),
                                "level_db": Double(levelDB.rounded()), "peak_db_10s": Double(peakDB.rounded()),
                                "engine_running": engine.isRunning]
        if let ago { s["last_audio_s"] = (ago * 10).rounded() / 10 }
        if let p = health.problem { s["problem"] = p }
        if offUntil > Date() { s["off_until"] = offUntil.timeIntervalSince1970 }
        return s
    }
}
