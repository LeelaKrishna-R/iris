import AppKit
import AVFoundation

/// Iris: Friday's body on their Mac — a chibi girl on their screens with eyes
/// (both displays), ears (the Yeti), a mouth (the speakers) and hands
/// (keyboard and mouse). Her brain is Friday Core, reached over the local
/// link; her own self (moods, habits, what she's learned about them) is
/// her own and lives here.
// (strict concurrency): her app delegate and everything it owns run on the main thread; only route(), which
// Link calls on its own queue, is nonisolated, and it sends main-thread work there through main {}.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    let body = Body()
    let eyes = Eyes()
    let ears = Ears()
    let mouth = Mouth()
    var link: Link?
    /// Her hands' own queue: typing and pressing, one after another, off her main thread.
    nonisolated static let handsQueue = DispatchQueue(label: "iris.hands")

    func applicationDidFinishLaunching(_ n: Notification) {
        // one Iris: an older copy (macOS reopens apps after a permission change) gives way to this one
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.forceTerminate() }
        // the wait lets an older copy let go of her port before this one takes it; with none, nothing to wait for
        if !others.isEmpty { Thread.sleep(forTimeInterval: 0.3) }
        // review every Accessibility element gives up after AXQuick.timeout unless it says otherwise — the
        // children /hands/see and her eyes walk didn't carry their parent's 0.25 s, and waited macOS's 6 s
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXQuick.timeout)
        body.eyes = eyes
        body.start()
        eyes.start()
        // no Accessibility ask at launch either: allowed; /health reports it if it goes

        ears.onWake = { [weak self] in self?.body.setListening(true) }
        ears.onHeard = { [weak self] h in
            self?.body.bubble?.say("“\(h.text)”", for: 4)
            self?.body.awaitingAnswer()          // her thinking pose at once, not after Core's round trip
            self?.untaken(h.at)
        }
        ears.onDone = { [weak self] in self?.body.setListening(false); self?.mouth.uncut() }
        ears.onVoice = { [weak self] in self?.body.heardVoice() }
        ears.start()
        body.onTalk = { [weak self] in self?.ears.listenNow() }
        // a click on her peeks at their day card; a double-click (a bow) leaves none up; their pointer resting on
        // her, one line of it in her bubble
        body.onPetted = { [weak self] in
            self?.body.notePeeked()                 // a click on her is a look at what waited: her note cue ends
            if let f = self?.body.frameOnScreen { DayCard.shared.peek(near: f) }
        }
        body.onDoublePetted = { DayCard.shared.unpeek("the person double-clicked her") }
        body.onHoverHint = { DayCard.shared.hint() }
        body.onDayCard = { [weak self] in if let f = self?.body.frameOnScreen { DayCard.shared.toggle(near: f) } }
        // "How Iris is" reads her ears and eyes when her menu opens; her settings act on them (an hour off, as
        // "stop listening" / "stop watching my screen" said to her do; both kept through her restarts)
        Menu.shared.readState = { [weak self] in
            (earsStatus: self?.ears.status(), eyesOffUntil: self?.eyes.pausedUntil, screenPermitted: Eyes.permitted)
        }
        Menu.shared.onSetting = { [weak self] what in
            guard let self else { return }
            switch what {
            case "ears_off": self.ears.off(for: 3600)
            case "ears_on": self.ears.on()
            case "eyes_off": self.eyes.pause(for: 3600)
            case "eyes_on": self.eyes.pause(for: 0)
            default: return
            }
            log("menu: \(what)")
        }
        // VoiceOver: her window says who she is and what a click does (her body is drawn, so it had no words)
        body.view?.setAccessibilityElement(true)
        body.view?.setAccessibilityRole(.image)
        body.view?.setAccessibilityLabel("Iris, \(Config.agentName)'s companion")
        body.view?.setAccessibilityHelp("Click to see your day. Right-click for her menu: how she is, and her settings.")
        ApprovalCard.shared.onDecided = { [weak self] choice, what in self?.body.approvalAnswered(choice, what: what) }
        body.onAsk = { [weak self] in
            AskBox.shared.show { text in
                let at = self?.ears.typed(text)
                self?.body.bubble?.say("“\(text)”", for: 4)
                if let at { self?.untaken(at) }
            }
        }
        AskHotKey.register({ [weak self] in self?.body.onAsk?() }, talk: { [weak self] in self?.ears.listenNow() })

        mouth.onStart = { [weak self] text, secs, listen in
            self?.ears.mute(for: secs, line: text, listen: listen)
            self?.body.speaking(text, seconds: secs)
        }
        ears.onBargeIn = { [weak self] in self?.mouth.cut() }      // the rest of what the person cut off waits (Mouth.cut)

        link = Link { [weak self] path, query, body, reply in
            guard let self else { return reply(503, ["ok": false]) }
            self.route(path, query, body, reply)
        }
        do { try link?.start() } catch { log("link failed: \(error)") }
        log("iris: awake")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.showIfFirstRun() }
    }

    /// their ask (spoken or typed) queued at `at`, looked at again after Stages.askWaitS: still in her queue,
    /// Friday didn't take it (its watcher down or restarting). She says so in her bubble, and it is dropped, so it
    /// isn't answered whenever Friday returns. Taken, as it is within moments while Friday is up: nothing.
    private func untaken(_ at: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Stages.askWaitS) { [weak self] in
            guard let self, self.ears.takeBack(at) else { return }
            log("ears: \(Config.agentName) didn't take what the person said in \(Int(Stages.askWaitS)) s; said so, and it's dropped")
            self.body.showing(Stages.fridayNotAnswering, seconds: 6)
        }
    }

    func applicationWillTerminate(_ n: Notification) { body.soul.save() }

    nonisolated private func route(_ path: String, _ query: [String: String], _ body: [String: Any],
                                   _ reply: @escaping Link.Reply) {
        // a route's main-thread work, made here on Link's queue and run on main
        @Sendable func main(_ work: @escaping @Sendable @MainActor () -> (Int, [String: Any])) {
            DispatchQueue.main.async { MainActor.assumeIsolated { let (s, o) = work(); reply(s, o) } }
        }
        // typing and pressing sleep and poll (12 ms per 16 characters; up to 1 s for an app to come forward),
        // which froze her body when they ran on main; her hands' own serial queue keeps what the person asked in order.
        func hands(_ work: @escaping @Sendable () -> (Int, [String: Any])) {
            App.handsQueue.async { let (s, o) = work(); reply(s, o) }
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
            let into: @Sendable () -> (kind: String, why: String) = { Focus.into(appName: query["app"]) }
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
            // "take a screenshot": saved to Pictures/Iris Screenshots
            eyes.shot { paths in
                reply(paths.isEmpty ? 500 : 200, paths.isEmpty ? ["ok": false, "reason": "capture_failed"]
                                                                : ["ok": true, "paths": paths])
            }
        case "/ears/words":
            // the names in their life (Core's core/stt_names, the same list their phone's voice is
            // primed with), so both of her recognizers expect them
            let w = (body["words"] as? [String] ?? []).map { String($0.prefix(40)) }.filter { !$0.isEmpty }
            main {                                     // review set where her ears read them, on main
                self.ears.extraWords = Array(w.prefix(80))
                return (200, ["ok": true, "words": self.ears.extraWords.count])
            }
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
            // the queue is capped (Mouth.cap); a full one is said, never grown
            if mouth.isFull { return reply(429, ["ok": false, "reason": "busy"]) }
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
            hands { Hands.type(text) ? (200, ["ok": true]) : (403, ["ok": false, "reason": "accessibility_not_allowed"]) }
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
            hands {                                    // review up to 600 elements walked, off her main thread
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
            hands {
                let r = Hands.press(want, role: role, app: app, nth: nth)
                let ok = r["ok"] as? Bool ?? false
                if ok, let at = r["at"] as? [Double], at.count == 2, at != [0, 0] {
                    DispatchQueue.main.async { self.body.usedHands(at: CGPoint(x: at[0], y: at[1])) }
                }
                return (ok ? 200 : (r["reason"] as? String == "accessibility_not_allowed" ? 403 : 404), r)
            }
        case "/hands/quit":
            // "quit Safari": the app is asked to quit as ⌘Q would (it asks them about anything
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
            let why = body["why"] as? String ?? ""          // Core's cause for it, for her journal
            main {
                guard Body.catalog[id] != nil else { return (400, ["ok": false, "reason": "no_such_animation"]) }
                self.body.perform(id, seconds: secs, asked: why)
                return (200, ["ok": true])
            }
        case "/iris/catalog":
            reply(200, ["ok": true, "animations": Body.catalog.values.map {
                ["id": $0["id"] ?? "", "when": $0["when"] ?? "", "rig": $0["rig"] ?? ""] }])
        case "/iris/notice":
            // Friday's reminder or push just appeared on their screen (core/notify, best-effort)
            let title = body["title"] as? String ?? ""
            log("notice: " + String(title.prefix(40)))      // whether she was told is in her log
            main { self.body.notified(String(title.prefix(80))); return (200, ["ok": true]) }
        case "/iris/usage":
            // their active minutes per app on a day (default today), from her eyes; local only
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
            main { (200, ["ok": true, "decisions": ApprovalCard.shared.pendingDecisions(),
                          "showing": ApprovalCard.shared.showing]) }
        case "/iris/decisions_ack":
            // Core confirms the clicks it decided; only those leave her list (review)
            let ids = (body["ids"] as? [Any] ?? []).compactMap { $0 as? String }
            main { ApprovalCard.shared.ack(ids); return (200, ["ok": true]) }
        case "/iris/day":
            // their day at a glance beside her (core/iris_day_card), rows Core read, unreadable ones "off"
            // Core's JSON rows, parsed here and used once on main — handed over, never touched here again
            let rows = Handoff((body["rows"] as? [Any] ?? []).compactMap { $0 as? [String: Any] })
            let at = (body["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let waiting = body["waiting"] as? [String: Any]           // core/iris_note, for her still note
            let dayKey = waiting?["key"] as? String, dayWhy = waiting?["why"] as? String
            main {
                self.body.noteWaiting(key: dayKey, why: dayWhy)
                let todos = DayCard.shared.text("todos")       // a to-do come due since the last card (Body.dayCard)
                DayCard.shared.update(rows: rows.value, at: at, near: self.body.frameOnScreen)
                if !DayCard.shared.hidden {
                    self.body.dayCard(todosBefore: todos, todosAfter: DayCard.shared.text("todos"), card: DayCard.shared.frame)
                }
                return (200, ["ok": true, "hidden": DayCard.shared.hidden])
            }
        case "/iris/status":
            // Core's word for "How Iris is" (core/iris_status) in; her menu's quiet asks out
            // review (a162): what waits for them comes with each status too (30 s), for her note cue; a look
            // without "waiting" (her 2 s asks) says nothing of it, and null is nothing waits
            let said = body.keys.contains("waiting")
            let waiting = body["waiting"] as? [String: Any]
            let waitKey = waiting?["key"] as? String, waitWhy = waiting?["why"] as? String
            let word = Handoff(body)                       // Core's JSON, used once on main
            main {
                if said { self.body.noteWaiting(key: waitKey, why: waitWhy) }
                return (200, CoreWord.shared.received(word.value))
            }
        case "/iris/day_state":
            main { (200, DayCard.shared.state()) }
        case "/iris/day_ack":
            // Core acted on these card clicks (core/iris_day_card._take_acts); only those leave her list
            let tokens = (body["tokens"] as? [Any] ?? []).compactMap { $0 as? String }
            main { DayCard.shared.ack(tokens); return (200, ["ok": true]) }
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
            let ambientAt = body["ambient_at"] as? Double         // Core's last moment of its own, for one gap
            main {
                if let a = ambientAt { self.body.coreAmbient(at: Date(timeIntervalSince1970: a)) }
                self.body.mind(want: w, strength: k, mood: mood, say: say, face: face); return (200, ["ok": true])
            }
        case "/iris/come":
            // the person called her over (core/iris_talk): "cursor" (beside their pointer) or "other_screen"
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

/// `Iris --simulate scenario.json [out.json] [--seeds ]`: her body and mind
/// headless against made-up screens, on a fast clock (Sim.swift).
// This top level runs on the main thread (said, for her main-actor body and the simulator).
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--simulate" {
    MainActor.assumeIsolated { Sim.run(CommandLine.arguments) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

/// A value parsed on one thread and used, once, on another (a route's JSON, from Link's queue to main).
/// Unchecked because the value isn't Sendable: whoever makes it hands it over and never touches it again.
final class Handoff<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
