import os
import AppKit
import CoreMedia
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Her eyes: every screen, a glance a second at most (a stream per display). A frame that changed is read
/// (Vision, on this Mac) once it settles; what's on each display, which app
/// and window they're in, and every window on screen are kept for Friday to ask
/// about. Without Screen Recording she sees nothing and says so — never an
/// old frame passed off as now.
// (strict concurrency): her eyes' state is `q`'s — read and written only inside q.sync — except the timer
// (main's) and windowsAt (tick's own: one tick runs at a time, `busy`, now kept in q too). That, not the compiler, is
// what makes it safe to share with her capture streams, her reads and the routes.
final class Eyes: @unchecked Sendable {
    struct Display: Codable {
        var id: UInt32
        var frame: [Double]          // x, y, w, h — global points
        var text: String
        var changedAt: Date?
        var readAt: Date?
        var seenAt: Date?
    }

    struct Win: Codable {
        var app: String
        var title: String
        var display: UInt32?
        var frame: [Double]
    }

    private let q = DispatchQueue(label: "iris.eyes")
    private let ocrQ = DispatchQueue(label: "iris.eyes.ocr", qos: .utility)
    private var displays: [UInt32: Display] = [:]
    private var thumbs: [UInt32: [UInt8]] = [:]
    private var pendingRead: [UInt32: Date] = [:]
    private var reading = Set<UInt32>()
    private var lastRead = Date.distantPast
    private var windows: [Win] = []
    private var windowsAt = Date.distantPast
    static let windowsEveryS: Double = 3
    private var lastChange = Date.distantPast
    private var lastError: String?
    // (owner: = off for an hour): no screen read and nothing of their
    // screens handed to Friday until then
    private var offUntil = Date.distantPast
    // their focused window as Friday last asked (now()), to tell the screen the person works on from the other one
    private var focusedCache: CGRect?
    // her screen reads were ~45% of her CPU (a 10 s sample; 37% CPU with them at it). Words on their
    // screens count only while they're at the Mac and mostly on the screen the person works on (core/iris_reflex)
    static let readAwayS: Double = 300        // away this long: no reads; the first look after they're back reads
    static let otherScreenEveryS: Double = 60 // the screen the person isn't working on: at most once a minute (was 10 s)
    static let handsBusyS: Double = 60        // their last key, click or scroll this recent: their screen read every 10 s
    static let restingEveryS: Double = 30     // their hands resting longer: at most every 30 s
    var pausedUntil: Date? { q.sync { offUntil > Date() ? offUntil : nil } }
    func pause(for seconds: Double) {
        q.sync {
            offUntil = seconds > 0 ? Date().addingTimeInterval(seconds) : .distantPast
            // kept through her restarts (91 in 9 days): she watched again at once after one
            Store.save(OffUntil(at: seconds > 0 ? offUntil.timeIntervalSince1970 : 0), "eyes_off.json")
        }
    }
    private var busy = false
    private var timer: Timer?

    var changingRecently: Bool { q.sync { Date().timeIntervalSince(lastChange) < 8 } }

    // where on their screens the picture last changed: the middle of the changed cells of
    // the 32x18 glance, in the window server's coordinates (y down from the primary's top)
    private var changeSpotCG: (at: Date, point: CGPoint)?
    /// Where their screen last changed, and when, in Cocoa coordinates (main thread: reads NSScreen).
    var changeSpot: (at: Date, point: CGPoint)? {
        guard let c = q.sync(execute: { changeSpotCG }) else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return (c.at, CGPoint(x: c.point.x, y: primaryH - c.point.y))
    }

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    // her glance is a running stream per display, not a screenshot every second. Iris.log
    // held 3,303 "SKView: no drawables available for rendering. Skipping this frame." lines, every
    // one 30-90 ms after her once-a-second capture (unified log, shareable content
    // .368, screenshot .389, skipped frame .417; per process the skips sit in one tenth of the
    // second, the eyes timer's), and they pile up while the Mac is loaded. Each second asked
    // ScreenCaptureKit for the window list (a TCC check on her main thread), then one-shot
    // screenshots of both displays, each its own capture in replayd. A stream is ScreenCaptureKit's
    // way to watch a screen: set up once, it hands over a 64-pixel frame at most once a second and
    // only when the picture changed. The window list comes from the window server's own list.
    private var streams: [UInt32: SCStream] = [:]       // q
    private var shown: [UInt32: SCDisplay] = [:]         // q: the displays her streams watch
    private var glances: [UInt32: [UInt8]] = [:]         // q: each display's latest 32x18 glance
    private var glanceAt: [UInt32: Date] = [:]           // q: its stream's last frame (changed or not)
    private var me: [SCRunningApplication] = []          // q: Iris, left out of every picture
    private var opening = false                          // q: streams being set up
    private var openTried = Date.distantPast             // q
    private let frames = DispatchQueue(label: "iris.eyes.frames", qos: .utility)
    private lazy var output = Output(self)

    func start() {
        if let off = Store.load(OffUntil.self, "eyes_off.json"), off.at > Date().timeIntervalSince1970 {
            q.sync { offUntil = Date(timeIntervalSince1970: off.at) }   // their "stop watching" outlives her restart
        }
        // she never asks on her own: the person allowed it once, and a request at
        // every launch was the dialog the person kept clicking. If it is really gone,
        // /health says screen_recording_not_allowed and Friday tells them.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.look() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.close() }
    }

    private func look() {
        // busy was set here on main and cleared in the detached task: both under q now
        guard q.sync(execute: { () -> Bool in if busy { return false }; busy = true; return true }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.tick()
            self?.q.sync { self?.busy = false }
        }
    }

    /// Once a second, off the main thread: the window list, and each display's latest glance
    /// judged by see() (no new frame from its stream is an unchanged screen); a read when due.
    private func tick() async {
        let (open, tried) = q.sync { (!streams.isEmpty || opening, openTried) }
        if !open && Date().timeIntervalSince(tried) >= 5 { await openStreams() }
        let (looks, targets, mine) = q.sync { (glances, shown, me) }
        // the window list every 3 s, not every tick (a top own cost in a sample with them at the Mac)
        if Date().timeIntervalSince(windowsAt) >= Eyes.windowsEveryS || q.sync(execute: { windows.isEmpty }) {
            windowsAt = Date()
            let wins = Eyes.windowList(on: Array(targets.values))
            q.sync { windows = wins }
        }
        for (id, thumb) in looks {
            guard let d = targets[id], see(id, frame: d.frame, thumb) else { continue }
            do {
                let full = SCStreamConfiguration()
                full.width = d.width
                full.height = d.height
                full.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: d, excludingApplications: mine, exceptingWindows: []),
                    configuration: full)
                read(id, img)
            } catch {
                q.sync { lastError = "capture_failed: \(error.localizedDescription)" }
            }
        }
    }

    private func openStreams() async {
        q.sync { opening = true; openTried = Date() }
        defer { q.sync { opening = false } }
        guard Eyes.permitted else {
            q.sync { lastError = "screen_recording_not_allowed" }
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            q.sync { me = mine }
            for d in content.displays {
                let cfg = SCStreamConfiguration()
                cfg.width = 64
                cfg.height = max(2, 64 * d.height / max(1, d.width))
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.queueDepth = 3
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = false
                let s = SCStream(filter: SCContentFilter(display: d, excludingApplications: mine, exceptingWindows: []),
                                 configuration: cfg, delegate: output)
                try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: frames)
                // known before it starts: its first frame (the screen as it is) arrives at once
                q.sync { streams[d.displayID] = s; shown[d.displayID] = d }
                try await s.startCapture()
            }
            q.sync { lastError = nil }
        } catch {
            close()                                       // none half-open; tried again in 5 s
            q.sync { lastError = "capture_failed: \(error.localizedDescription)"; openTried = Date() }
        }
    }

    /// Stops every stream (their displays changed, or one stopped); the next tick opens them again.
    private func close() {
        let old: [SCStream] = q.sync {
            let s = Array(streams.values)
            streams = [:]; shown = [:]; glances = [:]; glanceAt = [:]; openTried = .distantPast
            return s
        }
        for s in old { s.stopCapture { _ in } }
    }

    fileprivate func frame(_ buffer: CMSampleBuffer, from stream: SCStream) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        guard let id = q.sync(execute: { streams.first { $0.value === stream }?.key }) else { return }
        let now = Date()
        if status == .idle { q.sync { glanceAt[id] = now }; return }
        guard status == .complete, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: CVPixelBufferGetWidth(px),
                                  height: CVPixelBufferGetHeight(px), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(px), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let img = ctx.makeImage() else { return }
        let thumb = Eyes.thumb(img)
        q.sync { glances[id] = thumb; glanceAt[id] = now }
    }

    fileprivate func stopped(_ stream: SCStream, _ error: Error) {
        q.sync { lastError = "capture_failed: \(error.localizedDescription)" }
        close()
    }

    /// The window server's list of their windows on screen (Iris left out), placed on `displays`.
    static func windowList(on displays: [SCDisplay]) -> [Win] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows(from: list, mine: ProcessInfo.processInfo.processIdentifier,
                       displays: displays.map { ($0.displayID, $0.frame) })
    }

    /// His windows from the window server's list: on the normal layer, not hers, named, wider than 40 pt, each with
    /// the display its middle is on (pure, tested).
    static func windows(from list: [[String: Any]], mine: Int32, displays: [(id: UInt32, frame: CGRect)]) -> [Win] {
        list.compactMap { w -> Win? in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != mine,
                  let app = w[kCGWindowOwnerName as String] as? String, !app.isEmpty,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: b), f.width > 40 else { return nil }
            let disp = displays.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }
            return Win(app: app, title: w[kCGWindowName as String] as? String ?? "", display: disp?.id,
                       frame: [f.minX, f.minY, f.width, f.height])
        }
    }

    /// A glance changed from the one before: its 32×18 grey thumbnails differ by more than 1.5 a cell on average
    /// (pure, tested).
    static func changed(_ old: [UInt8], _ new: [UInt8]) -> Bool {
        let diff = zip(old, new).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(diff) / Double(new.count) > 1.5
    }

    /// Whether to read a screen now (see(_:frame:_:)): never while a read runs, within 10 s of the last, while the person
    /// asked her not to watch, or with them away; the screen the person isn't on at most every Eyes.otherScreenEveryS; their hands
    /// resting, at most every Eyes.restingEveryS; then once it has settled (0.9 s still), or every 30 s while it keeps
    /// changing (pure, tested).
    static func readNow(now: Date, changed: Bool, pendingSince: Date?, readAt: Date?, lastRead: Date, reading: Bool,
                        offUntil: Date, idle: Double, front: Bool) -> Bool {
        guard !reading, now.timeIntervalSince(lastRead) >= 10, now >= offUntil else { return false }
        guard idle < Eyes.readAwayS else { return false }        // they're away: their screens' words feed nothing
        guard front || now.timeIntervalSince(readAt ?? .distantPast) >= Eyes.otherScreenEveryS else { return false }
        let sinceRead = now.timeIntervalSince(readAt ?? .distantPast)
        guard idle < Eyes.handsBusyS || sinceRead >= Eyes.restingEveryS else { return false }
        guard let p = pendingSince else { return false }
        let settled = !changed && now.timeIntervalSince(p) >= 0.9
        let stale = sinceRead >= 30 && now.timeIntervalSince(p) >= 2
        return settled || stale
    }

    /// Records the glance; true when the screen should be read now — it
    /// changed and has held still a moment, or it keeps changing and the last
    /// read is 30 s old.
    private func see(_ id: UInt32, frame: CGRect, _ thumb: [UInt8]) -> Bool {
        let now = Date()
        return q.sync {
            var d = displays[id] ?? Display(id: id, frame: [], text: "", changedAt: nil, readAt: nil, seenAt: nil)
            d.frame = [frame.minX, frame.minY, frame.width, frame.height]
            d.seenAt = glanceAt[id]                  // when her stream last reported this screen
            let before = thumbs[id]
            let changed = before.map { Eyes.changed($0, thumb) } ?? true
            thumbs[id] = thumb
            if changed {
                d.changedAt = now
                lastChange = now
                if let old = before, let spot = Eyes.spot(old, thumb, in: frame) { changeSpotCG = (now, spot) }
                pendingRead[id] = pendingRead[id] ?? now
            }
            displays[id] = d
            // reading costs seconds of CPU on this Mac: at most one read every 10 s, both screens together
            guard reading.isEmpty, now.timeIntervalSince(lastRead) >= 10, now >= offUntil else { return false }
            // hardware input only (keys another app posts aren't them: the phantom wave)
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            let front = focusedCache.map { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? true
            // their hands resting a minute or more (reading, watching), at most every 30 s: a chat or a video
            // moving had her read every ~9 s, each read a 45-60% CPU spike, for words that only count while the person works;
            // once it settles; while it keeps changing, one every 30 s
            return Eyes.readNow(now: now, changed: changed, pendingSince: pendingRead[id], readAt: d.readAt,
                                lastRead: lastRead, reading: false, offUntil: offUntil, idle: idle, front: front)
        }
    }

    private func read(_ id: UInt32, _ img: CGImage) {
        q.sync { reading.insert(id); pendingRead[id] = nil; lastRead = Date() }
        ocrQ.async { [weak self] in
            guard let self else { return }
            // every read is Vision's accurate recognizer, revision 2. She read a changed screen
            // first with .fast (no language correction) and again with accurate revision 3 (with it)
            // only after 10 s still; a terminal running tests is never still that long, so what her
            // reflexes and Friday got was the quick read: in her eyes logs, 270 of 309
            // "AssertionError"s read "AssertlonError" and 28 of 75 "N failed" "N falled" (i as l, m as
            // rn, "è" for e), and the two reads of one screen spelled its lines differently, so lines
            // already there came back as new. Measured on this Mac (Intel, no Neural Engine) on
            // four 1920x1080 frames drawn like their VS Code (editor, terminal, chat; 103-110 known lines
            // each) and their two real screens (scratch bench, per read after warm-up):
            //   .fast:               CER 21-26%, 5-8 lines exact, 0.25 s CPU (0.1 s on their screens)
            //   accurate rev 3 + LC: CER 13-16%, 32-51 lines exact, 3.6-5.4 s CPU
            //   accurate rev 2:      CER  8-10%, 68-76 lines exact, 1.3-1.7 s CPU, 2.6-3.3 s wall
            // Revision 3's text finder drops whole lines and cuts their first letters on a large
            // frame (of 24 lines on a white 1080p terminal it returned 12); revision 2 finds them.
            // Language correction changed a handful of characters and cost 2 s more, so it is off.
            let req = VNRecognizeTextRequest()
            req.revision = VNRecognizeTextRequestRevision2
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US"]
            req.minimumTextHeight = 0.008
            let h = VNImageRequestHandler(cgImage: img, options: [:])
            var lines: [String] = []
            let started = Date()
            if (try? h.perform([req])) != nil {
                let obs = (req.results ?? []).sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
                }
                lines = obs.compactMap { $0.topCandidates(1).first?.string }
            }
            let text = lines.joined(separator: "\n")
            let now = Date()
            let ms = Int(now.timeIntervalSince(started) * 1000)
            var previous = ""
            self.q.sync {
                previous = self.displays[id]?.text ?? ""
                self.displays[id]?.text = text
                self.displays[id]?.readAt = now
                self.reading.remove(id)
            }
            if Eyes.differs(previous, text) {
                let front = Eyes.workingApp?.localizedName ?? ""
                Store.append(["at": now.timeIntervalSince1970, "display": id, "front_app": front, "read_ms": ms,
                              "text": String(text.prefix(6000))], to: "eyes.jsonl")
            }
        }
    }

    // MARK: a screenshot the person asked for

    /// Every display as the person sees it (Iris left out), saved as PNGs in
    /// ~/Pictures/Iris Screenshots (not a folder macOS guards, so nothing is
    /// asked of them). The saved files' paths, or [] when it couldn't be taken.
    func shot(_ done: @escaping @Sendable ([String]) -> Void) {
        Task.detached(priority: .userInitiated) {
            var saved: [String] = []
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let dir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Pictures/\(Config.agentName) Screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let stamp = f.string(from: Date())
                for (i, d) in content.displays.enumerated() {
                    let scale = NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
                    }?.backingScaleFactor ?? 1
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(CGFloat(d.width) * scale)
                    cfg.height = Int(CGFloat(d.height) * scale)
                    cfg.showsCursor = false
                    let img = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []),
                        configuration: cfg)
                    let name = "Screenshot \(stamp)" + (content.displays.count > 1 ? " (\(i + 1))" : "") + ".png"
                    let url = dir.appendingPathComponent(name)
                    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(dest, img, nil)
                    if CGImageDestinationFinalize(dest) { saved.append(url.path) }
                }
            } catch {
                log("eyes: screenshot failed: \(error.localizedDescription)")
            }
            done(saved)
        }
    }

    // MARK: what Friday asks

    /// What's playing, from window titles she can already read (Screen Recording, her eyes): Spotify's window
    /// is titled with the song while one plays ("Spotify Premium" / "Spotify" when not); a browser window on a
    /// YouTube video ("… - YouTube") counts only while sound is playing. No other app is asked (an AppleScript
    /// query would be a new permission prompt on their screen). "what's playing" could only say whether.
    static func nowPlaying(soundOn: Bool) -> [String: String]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return nowPlaying(from: list, soundOn: soundOn)
    }

    /// What's playing, from the window server's list: Spotify's song (its window's title once it isn't "Spotify"), or
    /// a YouTube page's title while a sound plays (pure, tested).
    static func nowPlaying(from list: [[String: Any]], soundOn: Bool) -> [String: String]? {
        let browsers: Set<String> = ["Safari", "Google Chrome", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]
        var video: [String: String]?
        for d in list where (d[kCGWindowLayer as String] as? Int) == 0 {
            let app = d[kCGWindowOwnerName as String] as? String ?? ""
            let title = (d[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            if app == "Spotify" {
                if !title.hasPrefix("Spotify") { return ["app": "Spotify", "title": title] }
            } else if soundOn, video == nil, browsers.contains(app),
                      let r = title.range(of: #"\s+-\s+YouTube(?: Music)?$"#, options: .regularExpression) {
                let t = String(title[..<r.lowerBound])
                    .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
                if !t.isEmpty { video = ["app": "YouTube", "title": t] }
            }
        }
        return video
    }

    func now() -> [String: Any] {
        let front = Eyes.workingApp
        let any = CGEventType(rawValue: ~0)!
        var out: [String: Any] = [
            "front_app": front?.localizedName ?? "",
            "front_title": Eyes.focusedTitle() ?? "",
            "idle_s": CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any),   // their hands only
            "permitted": Eyes.permitted,
            // an app has the mic (a call is live) / something is playing (any tab)
            "mic_others": AudioUse.micByOthers,
            "sound": AudioUse.soundPlaying,
        ]
        // (structure audit): whether they're watching a film and whether music is playing are her body's
        // answers (Body.isVideo with their screen moving; World.musicPlaying, her own voice left out), so Core's
        // reflexes read these instead of keeping lists of their own
        let sensed = Senses.now()
        out["video"] = sensed.video
        out["music"] = sensed.music
        let focused = Eyes.focusedFrame()
        q.sync {
            focusedCache = focused
            out["ok"] = Eyes.permitted && lastError == nil && !displays.isEmpty
            if let e = lastError { out["reason"] = e } else if displays.isEmpty { out["reason"] = "no_frame_yet" }
            if offUntil > Date() {                     // the person asked her not to watch: nothing of their screens
                out["ok"] = false
                out["reason"] = "paused"
                out["front_app"] = ""                  // which app and window they're in is their screen too
                out["front_title"] = ""
                out["paused_until"] = offUntil.timeIntervalSince1970
                return
            }
            if let np = Eyes.nowPlaying(soundOn: AudioUse.soundPlaying) { out["now_playing"] = np }
            out["displays"] = displays.values.sorted { $0.id < $1.id }.map { d -> [String: Any] in
                var m: [String: Any] = ["id": d.id, "frame": d.frame, "text": d.text]
                if let t = d.changedAt { m["changed_at"] = t.timeIntervalSince1970 }
                if let t = d.readAt { m["read_at"] = t.timeIntervalSince1970 }
                if let t = d.seenAt { m["seen_at"] = t.timeIntervalSince1970 }
                return m
            }
            out["windows"] = windows.map { ["app": $0.app, "title": $0.title, "display": $0.display ?? 0, "frame": $0.frame] }
            // the display their focused window is on — where their typing goes, so where its
            // output appears (her reflexes took Claude's output on their other screen as their)
            if let f = focused,
               let d = displays.values.first(where: { $0.frame.count == 4
                   && CGRect(x: $0.frame[0], y: $0.frame[1], width: $0.frame[2], height: $0.frame[3])
                       .contains(CGPoint(x: f.midX, y: f.midY)) }) {
                out["front_display"] = d.id
            }
        }
        return out
    }

    // MARK: helpers

    /// 32×18 grey thumbnail, enough to tell a frame changed.
    static func thumb(_ img: CGImage) -> [UInt8] {
        let w = 32, h = 18
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.interpolationQuality = .low
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// The middle of what changed between two glances (cells that moved by more than a
    /// faint flicker, weighted by how much), as a point on the display `frame` (y down).
    static func spot(_ a: [UInt8], _ b: [UInt8], in frame: CGRect) -> CGPoint? {
        let w = 32, h = 18
        guard a.count == w * h, b.count == w * h else { return nil }
        var sx = 0.0, sy = 0.0, sw = 0.0
        for i in 0..<(w * h) {
            let d = Double(abs(Int(a[i]) - Int(b[i])))
            guard d > 12 else { continue }
            sx += d * (Double(i % w) + 0.5); sy += d * (Double(i / w) + 0.5); sw += d
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: frame.minX + sx / sw / Double(w) * frame.width, y: frame.minY + sy / sw / Double(h) * frame.height)
    }

    static func differs(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        let sa = Set(a.split(whereSeparator: \.isWhitespace)), sb = Set(b.split(whereSeparator: \.isWhitespace))
        let union = sa.union(sb).count
        return union == 0 ? false : Double(sa.intersection(sb).count) / Double(union) < 0.9
    }

    /// The app they're working in: the frontmost one, unless that's one of macOS's own agents with no Dock
    /// icon (a notification banner's UserNotificationCenter, Control Center, the Dock), then the last
    /// regular app that was (her eye break, watch and thoughts ran "on UserNotificationCenter"
    /// while a banner had focus for a second).
    static var workingApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        workingLock.lock(); defer { workingLock.unlock() }
        if let front, front.activationPolicy == .regular {
            lastRegular = front
            return front
        }
        if let last = lastRegular, !last.isTerminated { return last }
        // None seen since she started (she restarted under Discord's local-network dialog,
        // up since 03:28): the regular app whose window is frontmost on screen.
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t,
               let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                lastRegular = app
                return app
            }
        }
        return front
    }
    /// only ever read or written under workingLock (workingApp), which is what makes this static safe.
    nonisolated(unsafe) private static var lastRegular: NSRunningApplication?
    private static let workingLock = NSLock()

    /// His focused window's frame in the window server's coordinates (y down from the primary's top).
    static func focusedFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = Eyes.workingApp else { return nil }
        let ax = AXQuick.app(app.processIdentifier)        // review Link's queue waits on this
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win else { return nil }
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXQuick.element(w as! AXUIElement), kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(AXQuick.element(w as! AXUIElement), kAXSizeAttribute as CFString, &size) == .success,
              let pv = pos, let sv = size else { return nil }
        var p = CGPoint.zero, z = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &z) else { return nil }
        return CGRect(origin: p, size: z)
    }

    static func focusedTitle() -> String? {
        guard AXIsProcessTrusted(), let app = Eyes.workingApp else { return nil }
        let ax = AXQuick.app(app.processIdentifier)        // review Link's queue waits on this
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win else { return nil }
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(AXQuick.element(w as! AXUIElement), kAXTitleAttribute as CFString, &t)
        return t as? String
    }
}

/// Her streams' frames and stops, handed to her eyes (SCStream holds its output and delegate weakly).
private final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var eyes: Eyes?
    init(_ eyes: Eyes) { self.eyes = eyes }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        eyes?.frame(buffer, from: stream)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { eyes?.stopped(stream, error) }
}


/// what her body senses of their music and their film (Body sets it on her main thread), read by /eyes/now off it.
enum Senses {
    private static let sensed = OSAllocatedUnfairLock(initialState: (music: false, video: false))   // Sendable

    static func set(music m: Bool, video v: Bool) {
        sensed.withLock { $0 = (m, v) }
    }

    static func now() -> (music: Bool, video: Bool) { sensed.withLock { $0 } }
}
