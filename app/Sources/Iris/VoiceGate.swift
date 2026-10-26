import Accelerate
import Foundation

/// 10-20: is someone likely speaking into her microphone? Her ears run Apple's recognizer only while
/// this says yes (Ears.measure). It used to be "one buffer 9 dB over the room's level", so any room
/// sound ran the recognizer: with him idle at 23:06 and nothing playing, a task was up 79-92% of the
/// time and localspeechrecognition.xpc had used 105 CPU-minutes in 15 h.
///
/// A voice, unlike a fan swelling, a keyboard or a clatter, is voiced: what it adds to the room repeats
/// at its pitch (80-400 Hz). Every ~21 ms the last ~43 ms are taken apart (FFT). The part above the
/// room's own noise, in 80-1000 Hz where the pitch lives, is checked for repeating at a pitch (its
/// autocorrelation, one more FFT). A frame is voiced when the voice band (200-4000 Hz) is `minSNR` over
/// the room and that part is clearly periodic. Speech starts when `onsetNeeded` of the last
/// `onsetWindow` seconds are voiced, and lasts while a voiced frame comes at least every `hangover`.
/// The room's noise is the per-frequency minimum of the recent spectrum (~2 s), so a steady fan or hum
/// is no news, and a voice, which pauses between syllables, does not become the room.
///
/// Not voiced, so not speech here: whispering. A tonal sound that swells (a motor's hum) and music
/// are periodic and still count, as they did before.
///
/// Pure: samples in, a decision out, no audio kept. Any buffer size and sample rate.
struct VoiceGate {
    struct Tuning {
        var minSNR: Float = 6            // voice-band energy over the room's noise there, dB
        var minPeriodic: Float = 0.8     // autocorrelation of the new sound at a pitch lag (0...1)
        var onsetWindow = 0.20           // seconds looked back for the start of speech...
        var onsetNeeded = 0.10           // ...of which this much must be voiced
        var hangover = 0.45              // speech goes on while a voiced frame comes this often
        var noiseWindow = 2.0            // seconds of spectrum the room's noise is the minimum of
    }

    let rate: Double
    let tuning: Tuning
    private let frameLen: Int, hop: Int, nfft: Int, log2n: vDSP_Length
    private let fft: Box
    private let window: [Float]
    private let windowACF: [Float]           // the window's own autocorrelation, to undo its taper
    private let kBandLo: Int, kBandHi: Int, kPitchLo: Int, kPitchHi: Int
    private let lagLo: Int, lagHi: Int
    private let hopSeconds: Double
    private let subLen: Int, subCount = 6
    private var pending: [Float] = []
    private var smooth: [Float] = []         // per-bin power, lightly smoothed over frames
    private var subMin: [[Float]] = []       // its minimum in each of the last few sub-windows
    private var curMin: [Float] = []
    private var curCount = 0
    private var noise: [Float] = []
    private var heard = 0                    // samples analysed so far
    private var recent: [Bool] = []
    private var sinceVoiced = Double.infinity
    // scratch, reused every frame
    private var buf: [Float], power: [Float], re: [Float], im: [Float]
    private(set) var speaking = false
    /// The last frame's measures, for /health and the bench.
    private(set) var snrDB: Float = 0, periodic: Float = 0

    /// Owns the FFT setup (a struct can't free it).
    private final class Box {
        let setup: FFTSetup
        init(_ log2n: vDSP_Length) { setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))! }
        deinit { vDSP_destroy_fftsetup(setup) }
    }

    init(rate: Double, tuning: Tuning = Tuning()) {
        self.rate = rate
        self.tuning = tuning
        let l = max(8, Int(log2(rate * 0.043).rounded()))      // ~43 ms: 2048 at 44.1/48 kHz
        frameLen = 1 << l
        hop = frameLen / 2
        nfft = frameLen * 2                                     // zero-padded: a linear autocorrelation
        log2n = vDSP_Length(l + 1)
        fft = Box(log2n)
        var w = [Float](repeating: 0, count: frameLen)
        vDSP_hann_window(&w, vDSP_Length(frameLen), Int32(vDSP_HANN_NORM))
        window = w
        let hz = rate / Double(nfft)
        kBandLo = Int(200 / hz); kBandHi = Int(4000 / hz)
        kPitchLo = Int(80 / hz); kPitchHi = Int(1000 / hz)
        lagLo = Int(rate / 400); lagHi = min(frameLen / 2, Int(rate / 80))
        hopSeconds = Double(hop) / rate
        subLen = max(1, Int((tuning.noiseWindow / Double(subCount)) / hopSeconds))
        var acf = [Float](repeating: 0, count: lagHi + 1)
        for lag in 0...lagHi {
            var s: Float = 0
            vDSP_dotpr(w, 1, Array(w[lag...]), 1, &s, vDSP_Length(frameLen - lag))
            acf[lag] = s
        }
        windowACF = acf
        buf = [Float](repeating: 0, count: nfft)
        power = [Float](repeating: 0, count: nfft / 2)
        re = [Float](repeating: 0, count: nfft / 2)
        im = [Float](repeating: 0, count: nfft / 2)
    }

    /// Feeds one buffer of mono samples; true while speech is likely.
    @discardableResult
    mutating func feed(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        var at = 0
        while pending.count - at >= frameLen {
            let start = at
            let frameCopy = Array(pending[start..<start + frameLen])
            frame(frameCopy)
            at += hop
        }
        if at > 0 { pending.removeFirst(at) }
        return speaking
    }

    @discardableResult
    mutating func feed(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { feed($0.baseAddress!, count: $0.count) }
    }

    /// `buf` (nfft reals) through the real FFT in place, forward or inverse. Forward leaves the
    /// spectrum packed in re/im (DC in re[0], Nyquist in im[0]); inverse leaves the sequence's even
    /// samples in re and odd ones in im.
    private mutating func fftInPlace(_ direction: FFTDirection) {
        let half = nfft / 2
        let setup = fft.setup, n = log2n
        buf.withUnsafeBufferPointer { bp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, n, direction)
                }
            }
        }
    }

    private mutating func frame(_ x: [Float]) {
        let half = nfft / 2
        for i in frameLen..<nfft { buf[i] = 0 }
        vDSP_vmul(x, 1, window, 1, &buf, 1, vDSP_Length(frameLen))
        fftInPlace(FFTDirection(FFT_FORWARD))
        im[0] = 0                                   // Nyquist, not needed
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        heard += hop

        // The room's noise per bin: the minimum of the lightly smoothed spectrum over ~2 s.
        let top = kBandHi
        if smooth.isEmpty {
            smooth = Array(power[0...top]); curMin = smooth
            subMin = Array(repeating: smooth, count: subCount); noise = smooth
        }
        for k in 0...top {
            smooth[k] = 0.7 * smooth[k] + 0.3 * power[k]
            if smooth[k] < curMin[k] { curMin[k] = smooth[k] }
        }
        curCount += 1
        if curCount >= subLen {
            subMin.removeFirst(); subMin.append(curMin); curMin = smooth; curCount = 0
        }
        // The minimum of a fluctuating spectrum sits under its mean: x2 puts steady noise near 0 dB.
        for k in 0...top {
            var m = curMin[k]
            for s in subMin where s[k] < m { m = s[k] }
            noise[k] = m * 2
        }

        var band: Float = 0, bandNoise: Float = 0
        for k in kBandLo...kBandHi { band += power[k]; bandNoise += noise[k] }
        snrDB = 10 * log10(max(band, 1e-20) / max(bandNoise, 1e-20))

        // What is new in the pitch band (a real, zero-phase spectrum), and whether it repeats at a
        // pitch: its inverse transform is the autocorrelation.
        for i in 0..<nfft { buf[i] = 0 }
        for k in kPitchLo...kPitchHi {
            let e = power[k] - noise[k]
            if e > 0 { buf[2 * k] = e }
        }
        fftInPlace(FFTDirection(FFT_INVERSE))
        let r0 = re[0]
        var best: Float = 0
        if r0 > 0 {
            for lag in lagLo...lagHi {
                let v = lag % 2 == 0 ? re[lag / 2] : im[lag / 2]
                let norm = (v / r0) * (windowACF[0] / max(windowACF[lag], 1e-9))
                if norm > best { best = norm }
            }
        }
        periodic = min(best, 1.5)

        let voiced = snrDB >= tuning.minSNR && periodic >= tuning.minPeriodic
        let keep = max(1, Int((tuning.onsetWindow / hopSeconds).rounded()))
        recent.append(voiced)
        if recent.count > keep { recent.removeFirst(recent.count - keep) }
        sinceVoiced = voiced ? 0 : sinceVoiced + hopSeconds
        if speaking {
            if sinceVoiced > tuning.hangover { speaking = false }
        } else if Double(heard) >= rate * 0.5 {          // half a second to learn the room first
            let need = max(1, Int((tuning.onsetNeeded / hopSeconds).rounded()))
            if voiced && recent.filter({ $0 }).count >= need { speaking = true }
        }
    }
}
