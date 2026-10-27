import AppKit
import Speech
import AVFoundation
import CoreImage
import ImageIO
import Vision

/// Iris: Friday's body on his Mac — a chibi girl on his screens with eyes
/// (both displays), ears (the Yeti), a mouth (the speakers) and hands
/// (keyboard and mouse). Her brain is Friday Core, reached over the local
/// link; her own self (moods, habits, what she's learned about him) is
/// her own and lives here.
final class App: NSObject, NSApplicationDelegate {
    let body = Body()
    let eyes = Eyes()
    let ears = Ears()
    let mouth = Mouth()
    var link: Link?

    func applicationDidFinishLaunching(_ n: Notification) {
        // one Iris: an older copy (macOS reopens apps after a permission change) gives way to this one
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where other.processIdentifier != me {
            other.forceTerminate()
        }
        Thread.sleep(forTimeInterval: 0.3)
        body.eyes = eyes
        body.start()
        eyes.start()
        // no Accessibility ask at launch either: allowed; /health reports it if it goes

        ears.onWake = { [weak self] in self?.body.setListening(true) }
        ears.onHeard = { [weak self] h in
            self?.body.bubble?.say("“\(h.text)”", for: 4)
            self?.body.awaitingAnswer()          // her thinking pose at once, not after Core's round trip
        }
        ears.onDone = { [weak self] in self?.body.setListening(false); self?.mouth.uncut() }
        ears.onVoice = { [weak self] in self?.body.heardVoice() }
        ears.start()
        body.onTalk = { [weak self] in self?.ears.listenNow() }
        body.onAsk = { [weak self] in
            AskBox.shared.show { text in
                self?.ears.typed(text)
                self?.body.bubble?.say("“\(text)”", for: 4)
            }
        }
        AskHotKey.register({ [weak self] in self?.body.onAsk?() }, talk: { [weak self] in self?.ears.listenNow() })

        mouth.onStart = { [weak self] text, secs, listen in
            self?.ears.mute(for: secs, line: text, listen: listen)
            self?.body.speaking(text, seconds: secs)
        }
        ears.onBargeIn = { [weak self] in self?.mouth.cut() }      // the rest of what he cut off waits (Mouth.cut)

        link = Link { [weak self] path, query, body, reply in
            guard let self else { return reply(503, ["ok": false]) }
            self.route(path, query, body, reply)
        }
        do { try link?.start() } catch { log("link failed: \(error)") }
        log("iris: awake")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.showIfFirstRun() }
    }

    func applicationWillTerminate(_ n: Notification) { body.soul.save() }

    private func route(_ path: String, _ query: [String: String], _ body: [String: Any], _ reply: @escaping Link.Reply) {
        func main(_ work: @escaping () -> (Int, [String: Any])) {
            DispatchQueue.main.async { let (s, o) = work(); reply(s, o) }
        }
        switch path {
        case "/health":
            main {
                (200, ["ok": true, "version": "0.1",
                       "permissions": ["screen": Eyes.permitted, "accessibility": Hands.permitted,
                                       "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized],
                       "ears": self.ears.status(), "iris": self.body.state()])
            }
        case "/iris/snapshot":
            main {
                guard let png = self.body.view?.snapshot() else { return (500, ["ok": false, "reason": "no_image"]) }
                return (200, ["ok": true, "png": png.base64EncodedString(), "iris": self.body.state()])
            }
        case "/eyes/focus":
            // ?app=<name>: only where that app's keys would go (Focus.into), for checking it
            let into = { Focus.into(appName: query["app"]) }
            if query["app"] != nil {
                return DispatchQueue.global(qos: .utility).async { let i = into(); reply(200, ["ok": true, "into": i.kind, "why": i.why]) }
            }
            DispatchQueue.global(qos: .utility).async { let i = into(); main {
                guard let f = Focus.now() else { return (200, ["ok": false, "reason": "no_focus"]) }
                func r(_ x: CGRect?) -> Any { x.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } ?? NSNull() }
                return (200, ["ok": true, "app": f.app, "role": f.role, "field": r(f.field), "caret": r(f.caret),
                              "into": i.kind, "why": i.why])
            } }
        case "/eyes/now":
            reply(200, eyes.now())
        case "/iris/senses":
            // "stop watching my screen / stop listening" (an hour), "watch again / listen again" (0)
            let ears = body["ears_off_s"] as? Double
            let eyesOff = body["eyes_off_s"] as? Double
            main {
                if let s = ears { self.ears.off(for: s) }
                if let s = eyesOff { self.eyes.pause(for: s) }
                var out: [String: Any] = ["ok": true]
                if self.ears.offUntil > Date() { out["ears_off_until"] = self.ears.offUntil.timeIntervalSince1970 }
                if let p = self.eyes.pausedUntil { out["eyes_off_until"] = p.timeIntervalSince1970 }
                return (200, out)
            }
        case "/eyes/shot":
            // "take a screenshot": saved to Pictures/Friday Screenshots
            eyes.shot { paths in
                reply(paths.isEmpty ? 500 : 200, paths.isEmpty ? ["ok": false, "reason": "capture_failed"]
                                                                : ["ok": true, "paths": paths])
            }
        case "/ears/words":
            // the names in his life (Core's core/stt_names, the same list his phone's voice is
            // primed with), so both of her recognizers expect them
            let w = (body["words"] as? [String] ?? []).map { String($0.prefix(40)) }.filter { !$0.isEmpty }
            ears.extraWords = Array(w.prefix(80))
            reply(200, ["ok": true, "words": ears.extraWords.count])
        case "/ears/next":
            let t = min(25, max(0, (body["timeout"] as? Double) ?? 20))
            ears.next(timeout: t) { h in
                guard let h else { return reply(200, ["ok": true, "heard": NSNull()]) }
                var heard: [String: Any] = ["text": h.text, "at": h.at.timeIntervalSince1970, "addressed": h.addressed,
                                            "typed": h.typed ?? false]
                for (k, v) in h.times ?? [:] { heard[k] = v }       // her stage times
                reply(200, ["ok": true, "heard": heard])
            }
        case "/mouth/play":
            guard let b64 = body["b64"] as? String, let data = Data(base64Encoded: b64) else {
                return reply(400, ["ok": false, "reason": "no_audio"])
            }
            let text = body["text"] as? String ?? ""
            if mouth.isCut { return reply(409, ["ok": false, "reason": "interrupted"]) }
            // "listen": false from Core for a line she says on her own (core/iris._Speaker: no ask it answers)
            let listen = body["listen"] as? Bool ?? true
            guard let secs = mouth.play(data, text: text, listen: listen) else { return reply(422, ["ok": false, "reason": "unplayable"]) }
            reply(200, ["ok": true, "seconds": secs])
        case "/mouth/show":
            let text = body["text"] as? String ?? ""
            let secs = (body["seconds"] as? Double) ?? 6
            main { self.body.showing(text, seconds: secs); return (200, ["ok": true]) }
        case "/hands/type":
            let text = body["text"] as? String ?? ""
            main { Hands.type(text) ? (200, ["ok": true]) : (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
        case "/hands/keys":
            let k = body["keys"] as? String ?? ""
            main {
                guard Hands.permitted else { return (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
                return Hands.keys(k) ? (200, ["ok": true]) : (400, ["ok": false, "reason": "unknown_key"])
            }
        case "/hands/click":
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let right = body["right"] as? Bool ?? false, dbl = body["double"] as? Bool ?? false
            main {
                guard Hands.click(x: x, y: y, right: right, double: dbl) else {
                    return (403, ["ok": false, "reason": "accessibility_not_allowed"])
                }
                self.body.usedHands(at: CGPoint(x: x, y: y))
                return (200, ["ok": true])
            }
        case "/hands/see":
            let app = body["app"] as? String ?? "", menus = body["menus"] as? Bool ?? false
            main {
                guard Hands.permitted else { return (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
                guard let (name, things) = Hands.see(app: app, menus: menus) else { return (404, ["ok": false, "reason": "no_such_app"]) }
                return (200, ["ok": true, "app": name, "things": things.map {
                    ["role": $0.role, "name": $0.name, "dialog": $0.dialog,
                     "frame": [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)]] }])
            }
        case "/hands/press":
            let want = body["name"] as? String ?? "", role = body["role"] as? String ?? ""
            let app = body["app"] as? String ?? "", nth = body["nth"] as? Int ?? 1
            guard !want.isEmpty else { return reply(400, ["ok": false, "reason": "no_name"]) }
            main {
                let r = Hands.press(want, role: role, app: app, nth: nth)
                let ok = r["ok"] as? Bool ?? false
                if ok, let at = r["at"] as? [Double], at.count == 2, at != [0, 0] {
                    self.body.usedHands(at: CGPoint(x: at[0], y: at[1]))
                }
                return (ok ? 200 : (r["reason"] as? String == "accessibility_not_allowed" ? 403 : 404), r)
            }
        case "/hands/quit":
            // "quit Safari": the app is asked to quit as ⌘Q would (it asks him about anything
            // unsaved); never Iris herself, Finder or the login window
            let name = (body["app"] as? String ?? "").lowercased()
            main {
                if ["iris", "finder", "loginwindow"].contains(name) { return (403, ["ok": false, "reason": "not_allowed"]) }
                guard let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased() == name }) else {
                    return (404, ["ok": false, "reason": "not_running"])
                }
                return app.terminate() ? (200, ["ok": true, "app": app.localizedName ?? name])
                                       : (409, ["ok": false, "reason": "refused"])
            }
        case "/hands/media":
            // "pause the music / skip this song": the media keys, for whatever is playing
            // There's one play/pause key: "pause" with nothing playing would start it, so
            // what's playing is checked first (World.musicPlaying, Core Audio, no permission).
            let k = body["key"] as? String ?? ""
            main {
                guard Hands.permitted else { return (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
                let playing = AudioUse.soundPlaying       // any tab or player, not only the front one
                switch k {
                case "pause", "next", "previous":
                    if !playing { return (409, ["ok": false, "reason": "not_playing"]) }
                case "play":
                    if playing { return (200, ["ok": true, "already": true]) }
                default:
                    return (400, ["ok": false, "reason": "unknown_key"])
                }
                return Hands.media(k == "pause" ? "play" : k) ? (200, ["ok": true]) : (400, ["ok": false, "reason": "unknown_key"])
            }
        case "/hands/move":
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            main { Hands.move(x: x, y: y) ? (200, ["ok": true]) : (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
        case "/hands/scroll":
            let lines = Int32(body["lines"] as? Int ?? -5)
            let x = body["x"] as? Double, y = body["y"] as? Double
            main { Hands.scroll(lines: lines, x: x, y: y) ? (200, ["ok": true]) : (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
        case "/hands/drag":
            let a = body["from"] as? [Double] ?? [], b = body["to"] as? [Double] ?? []
            guard a.count == 2, b.count == 2 else { return reply(400, ["ok": false, "reason": "need_from_and_to"]) }
            main {
                Hands.drag(from: CGPoint(x: a[0], y: a[1]), to: CGPoint(x: b[0], y: b[1]))
                    ? (200, ["ok": true]) : (403, ["ok": false, "reason": "accessibility_not_allowed"])
            }
        case "/iris/act":
            let id = body["id"] as? String ?? ""
            let secs = body["seconds"] as? Double ?? 6
            main {
                guard Body.catalog[id] != nil else { return (400, ["ok": false, "reason": "no_such_animation"]) }
                self.body.perform(id, seconds: secs)
                return (200, ["ok": true])
            }
        case "/iris/catalog":
            reply(200, ["ok": true, "animations": Body.catalog.values.map {
                ["id": $0["id"] ?? "", "when": $0["when"] ?? "", "rig": $0["rig"] ?? ""] }])
        case "/iris/notice":
            // Friday's reminder or push just appeared on his screen (core/notify, best-effort)
            let title = body["title"] as? String ?? ""
            log("notice: " + String(title.prefix(40)))      // whether she was told is in her log
            main { self.body.notified(String(title.prefix(80))); return (200, ["ok": true]) }
        case "/iris/usage":
            // his active minutes per app on a day (default today), from her eyes; local only
            let day = body["day"] as? String
            main { (200, ["ok": true, "day": day ?? Body.dayKey(Date()),
                          "seconds": self.body.usage(day: day).mapValues { Int($0) },
                          "hours": self.body.workHours(day: day)]) }
        case "/iris/events":
            main { (200, ["ok": true, "events": self.body.takeEvents()]) }
        case "/iris/ask":
            // an approval your agent asks for, with Allow / Deny beside her; the click waits in
            // /iris/decisions for the agent, which acts on it once (agents/iris_mcp.py iris_ask)
            let id = body["id"] as? String ?? ""
            let text = body["text"] as? String ?? ""
            guard !id.isEmpty, !text.isEmpty else { return reply(400, ["ok": false, "reason": "no_id_or_text"]) }
            let title = body["title"] as? String ?? "Approval needed"
            let until = (body["until"] as? Double).map { Date(timeIntervalSince1970: $0) }
            main {
                ApprovalCard.shared.show(id: id, title: String(title.prefix(60)), text: String(text.prefix(420)),
                                         until: until, near: self.body.frameOnScreen)
                return (200, ["ok": true])
            }
        case "/iris/ask_done":
            let id = body["id"] as? String ?? ""
            main { ApprovalCard.shared.close(id: id.isEmpty ? nil : id); return (200, ["ok": true]) }
        case "/iris/decisions":
            main { (200, ["ok": true, "decisions": ApprovalCard.shared.takeDecisions(),
                          "showing": ApprovalCard.shared.showing]) }
        case "/iris/hold":
            let secs = body["seconds"] as? Double ?? 10
            let talk = body["talk"] as? Bool ?? false
            let pose = body["pose"] as? String ?? ""
            main { self.body.hold(min(60, secs), talk: talk, pose: pose); return (200, ["ok": true]) }
        case "/iris/mind":
            let w = body["want"] as? String ?? ""
            let k = body["strength"] as? Double ?? 0.5
            let mood = (body["mood"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let say = body["say"] as? String ?? ""
            let face = body["face"] as? String ?? ""
            main { self.body.mind(want: w, strength: k, mood: mood, say: say, face: face); return (200, ["ok": true]) }
        case "/iris/come":
            // he called her over (core/iris_talk): "cursor" (beside his pointer) or "other_screen"
            let to = body["to"] as? String ?? ""
            main {
                guard let why = self.body.come(to) else { return (200, ["ok": true]) }
                return (why == "unknown_place" ? 400 : 409, ["ok": false, "reason": why])
            }
        case "/iris/mood":
            let ev = body["event"] as? String ?? ""
            main {
                switch ev {
                case "shoo": self.body.shooed()
                case "praise": self.body.soul.reward(1)
                default: return (400, ["ok": false, "reason": "unknown_event"])
                }
                return (200, ["ok": true])
            }
        default:
            reply(404, ["ok": false, "reason": "no_such_path"])
        }
    }
}

/// `Iris --hear a.wav`: a recording heard by both of her recognizers, on this Mac and Apple's server
/// (to compare them). Never asks for permission: if speech recognition isn't allowed, says so.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hear" {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized, let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
        print("speech recognition not allowed for this binary"); exit(2)
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    for onDevice in [true, false] {
        let r = SFSpeechURLRecognitionRequest(url: url)
        r.requiresOnDeviceRecognition = onDevice
        r.contextualStrings = Ears.words
        if #available(macOS 13, *) { r.addsPunctuation = !onDevice }
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        var said = ""
        rec.recognitionTask(with: r) { result, error in
            if let result, result.isFinal { said = result.bestTranscription.formattedString; done.signal() }
            else if let error { said = "error: \(error.localizedDescription)"; done.signal() }
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("\(onDevice ? "on-device" : "server   ") \(Int(Date().timeIntervalSince(t0) * 1000))ms: \(said)")
    }
    exit(0)
}

/// `Iris --bubble out.png "words"`: her speech bubble drawn to a file, to look at.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--bubble" {
    let v = BubbleView()
    let size = v.fit(CommandLine.arguments[3])
    v.frame = NSRect(origin: .zero, size: size)
    v.text = CommandLine.arguments[3]
    v.tail = 0.4
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

/// `Iris --instances in.png outdir`: each figure on a sheet as its own PNG
/// (Vision separates touching figures), named by reading order, with a
/// boxes.json of where each was on the sheet.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--instances" {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let req = VNGenerateForegroundInstanceMaskRequest()
    let h = VNImageRequestHandler(cgImage: img, options: [:])
    try! h.perform([req])
    guard let obs = req.results?.first else { print("no foreground"); exit(1) }
    let dir = URL(fileURLWithPath: CommandLine.arguments[3])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ctx = CIContext()
    var boxes: [[String: Any]] = []
    for inst in obs.allInstances {
        let buf = try! obs.generateMaskedImage(ofInstances: IndexSet(integer: inst), from: h, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buf)
        let mask = try! obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst), from: h)
        let mci = CIImage(cvPixelBuffer: mask)
        // where it sat on the sheet: the mask's extent of non-zero pixels
        let w = CVPixelBufferGetWidth(mask), hh = CVPixelBufferGetHeight(mask)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: Float32.self)
        let row = CVPixelBufferGetBytesPerRow(mask) / 4
        var minX = w, minY = hh, maxX = 0, maxY = 0
        var y = 0
        while y < hh { var x = 0; while x < w { if base[y * row + x] > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }; x += 4 }; y += 4 }
        CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        _ = mci
        let out = ctx.createCGImage(ci, from: ci.extent)!
        let name = "inst\(inst).png"
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        boxes.append(["file": name, "x0": minX, "y0": minY, "x1": maxX, "y1": maxY])
    }
    let data = try! JSONSerialization.data(withJSONObject: boxes)
    try! data.write(to: dir.appendingPathComponent("boxes.json"))
    print("instances:", boxes.count)
    exit(0)
}

/// `Iris --cutout in.png out.png`: the character lifted off her plain
/// background (Vision's foreground mask, on this Mac), saved with alpha.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--cutout" {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let req = VNGenerateForegroundInstanceMaskRequest()
    let h = VNImageRequestHandler(cgImage: img, options: [:])
    try! h.perform([req])
    guard let obs = req.results?.first else { print("no foreground"); exit(1) }
    let buf = try! obs.generateMaskedImage(ofInstances: obs.allInstances, from: h, croppedToInstancesExtent: false)
    let ci = CIImage(cvPixelBuffer: buf)
    let ctx = CIContext()
    let out = ctx.createCGImage(ci, from: ci.extent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[3]) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    exit(0)
}

/// `Iris --simulate scenario.json [out.json] [--seeds ]`: her body and mind
/// headless against made-up screens, on a fast clock (Sim.swift).
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--simulate" {
    Sim.run(CommandLine.arguments)
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
