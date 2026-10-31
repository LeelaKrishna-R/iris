import AppKit
import SpriteKit

/// How she looks this instant. The body sets it every frame; the view turns
/// it into her picture, bent and moving.
struct Face: Equatable {
    var turn: CGFloat = 0        // -1 looking left … 1 right
    var tilt: CGFloat = 0        // head tilt / nod
    var lean: CGFloat = 0        // whole body, radians, around her feet
    var hop: CGFloat = 0         // points off the ground
    var squash: CGFloat = 0      // -0.2 landing … 0.15 stretching
    var walk: CGFloat = 0
    var walkPhase: CGFloat = 0
    var sit: CGFloat = 0
    var lid: CGFloat = 0         // 1 = eyes shut (a blink)
    var mood: CGFloat = 0        // how she feels, -1 sad … 1 happy (shows on her mouth)
    var held = false             // he is carrying her with the mouse
    var happyEyes: CGFloat = 0
    var wide: CGFloat = 0
    var dizzy: CGFloat = 0
    var wince: CGFloat = 0
    var mouthOpen: CGFloat = 0
    var talking = false
    var pout: CGFloat = 0
    var cat: CGFloat = 0
    var blush: CGFloat = 0
    var breathe: CGFloat = 0
    var hairSway: CGFloat = 0
    var listening = false
    var sleeping = false
    var flip = false
    var hint = ""
    var emote: String? = nil
    var emoteAge: CGFloat = 9
    var keys = 0                 // his keystrokes so far (typing frames step on each)
    var vy: CGFloat = 0          // vertical speed, for the jump frames
    var gaze = CGPoint.zero      // where her eyes look, -1…1
    var vx: CGFloat = 0          // how fast she's moving sideways (hair swings with it)
    var clock: CGFloat = 0
    var act = ""                 // a library animation she is performing
    var actMoves = false
    var snug = false               // asleep a good while: under her blanket
    var why = ""                   // the cause in the world of what she's doing now (poses.jsonl's why)
    var gait = ""                  // a drawn walk her walk's cause asks for: "sad_walk", "tiptoe" (Stages.gait)
    var seat = ""                  // a drawn clip in place of her sit pose: "sit_legs", "fishing", "read_book" (Stages.seat)
}

/// Iris from her illustrations, animated: every picture sits on a warp mesh
/// (SpriteKit, on the GPU) that bends with her — the head tilts and nods at
/// the neck, the chest breathes, the long hair trails and sways, the legs
/// step, the whole of her squashes and stretches. Blinks and speech change
/// only the eyes and mouth (masked), and a new pose melts in while she keeps
/// moving, so nothing is ever a still picture slid around.
final class SpriteView: SKView {
    var face = Face() { didSet { apply() } }
    var onPet: (() -> Void)?
    var onDoublePet: (() -> Void)?     // a double-click on her (the first click was a pet already)
    var onDrag: ((CGPoint) -> Void)?
    var onDrop: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?

    static let names = ["master"]      // the drawn stills she once switched between are her rig now
    static let standing: Set<String> = ["master", "blink", "happy", "talk", "surprised", "curious", "wave", "pout",
                                        "worried", "love", "look_left", "listening", "dizzy", "walk"]

    // where things are on her picture, 0…1 from the bottom-left (measured on master.png)
    private let neck = CGPoint(x: 0.47, y: 0.54)

    private let sceneK = SKScene()
    private let rig = SKNode()
    private var main: SKSpriteNode!
    private var fading: SKSpriteNode?
    private let emoteNode = SKLabelNode(fontNamed: "Helvetica-Bold")
    private let groundShadow = SKShapeNode(ellipseOf: CGSize(width: 54, height: 8))
    private var textures: [String: SKTexture] = [:]
    private var rigs: [String: Live] = [:]     // her rigged poses: stand, sit, laptop, wave, sleep
    private var livePose = ""                  // which one shows ("" = a drawn clip)
    private var waveClock: CGFloat = 0
    private var viseme = ""
    private var visemeAt: CGFloat = 0
    private var clips: [String: [SKTexture]] = [:]
    private var clipNames = Set<String>()
    private var clipUse: [String: Date] = [:]
    private var loading = Set<String>()
    private var unloadable = Set<String>()
    private var drawnSize = CGSize.zero
    // nothing preloaded: every everyday pose is her rig; drawn clips are rare moments, loaded when wanted
    static let everyday: [String] = []
    static let keepClips = 8
    static let loader = DispatchQueue(label: "iris.clips", qos: .userInitiated)
    /// The simulator's real view (SimView, "real_view") steps her on its own clock and loads clips at once;
    /// the live app keeps the wall clock and loads in the background.
    static var now: () -> Date = { Date() }
    static var loadNow = false
    /// Where her art is (anim, live, sprites): the app bundle; the simulator's real view, run from .build/,
    /// points it at the package's Resources (SimView).
    static var art: Bundle = .main

    static func loadFrames(_ clip: String, drawnAt size: CGSize) -> [SKTexture]? {
        var frames: [SKTexture] = []
        for i in 0..<16 {
            guard let url = SpriteView.art.url(forResource: "\(i)", withExtension: "webp", subdirectory: "anim/\(clip)")
                    ?? SpriteView.art.url(forResource: "\(i)", withExtension: "png", subdirectory: "anim/\(clip)"),
                  let t = Textures.load(url, drawnAt: size) else { break }
            frames.append(t)
        }
        return frames.isEmpty ? nil : frames
    }

    /// A clip's frames if they're loaded; otherwise start loading them and say not yet.
    private func frames(_ clip: String) -> [SKTexture]? {
        if let f = clips[clip] { clipUse[clip] = Date(); return f }
        guard clipNames.contains(clip), !loading.contains(clip), !unloadable.contains(clip) else { return nil }
        if SpriteView.loadNow {
            if let f = SpriteView.loadFrames(clip, drawnAt: drawnSize) { clips[clip] = f; return f }
            unloadable.insert(clip); return nil
        }
        loading.insert(clip)
        let size = drawnSize
        SpriteView.loader.async { [weak self] in
            let f = SpriteView.loadFrames(clip, drawnAt: size)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(clip)
                if let f { self.clips[clip] = f; self.clipUse[clip] = Date() } else { self.unloadable.insert(clip) }   // asked again every frame otherwise
                // keep about 30 of her library loaded; the least recently used go first
                let extra = self.clips.keys.filter { !SpriteView.everyday.contains($0) }
                if extra.count > SpriteView.keepClips {
                    for k in extra.sorted(by: { (self.clipUse[$0] ?? .distantPast) < (self.clipUse[$1] ?? .distantPast) })
                        .prefix(extra.count - SpriteView.keepClips) { self.clips[k] = nil }
                }
            }
        }
        return nil
    }       // real animation frames (Resources/anim)
    private var frameAt: CGFloat = 0
    private var blendFor: CGFloat = 0
    private var tapAt: CGFloat = 0
    private var actShowing = ""                // the drawn clip of hers showing, as asked (f.act) — to play out when it ends
    private var actShowingMoves = false
    private var finishBy: Date?
    private var settle: CGFloat = 0
    private var dangle: CGFloat = 0
    private var rigAct = ""
    private var landedFor: CGFloat = 0
    private var actClock: CGFloat = 0
    private var frameIndex = 0
    private var lastKeys = 0
    private var nextFrameIn: CGFloat = 0.15
    private(set) var showing = "master"
    private var spriteSize = CGSize.zero
    private let cols = 8, rows = 12
    private var src: [SIMD2<Float>] = []
    private var clock: CGFloat = 0
    private var lastUpdate = SpriteView.now()
    /// Her last pose, for the pose journal.
    private(set) var journalPose = ""
    private var journalPoseAt = SpriteView.now()

    private var downAt: CGPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowsTransparency = true
        preferredFramesPerSecond = 60
        ignoresSiblingOrder = true
        sceneK.size = frame.size
        sceneK.scaleMode = .resizeFill
        sceneK.backgroundColor = .clear
        sceneK.anchorPoint = .zero

        for n in SpriteView.names {
            guard let url = SpriteView.art.url(forResource: n, withExtension: "png", subdirectory: "sprites")
                ?? SpriteView.art.url(forResource: n, withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { continue }
            let t = SKTexture(image: img)
            t.filteringMode = .linear
            textures[n] = t
        }
        // her everyday loops load now; the rest of her library loads the first time she wants it
        let animDir = SpriteView.art.resourceURL?.appendingPathComponent("anim")
        clipNames = Set((try? FileManager.default.contentsOfDirectory(atPath: animDir?.path ?? "")) ?? [])
        drawnSize = CGSize(width: (frame.height - 12) * 289 / 440, height: frame.height - 12)
        for clip in SpriteView.everyday where clipNames.contains(clip) {
            if let f = SpriteView.loadFrames(clip, drawnAt: drawnSize) { clips[clip] = f }
        }
        let h = frame.height - 12
        spriteSize = CGSize(width: h * 289 / 440, height: h)

        groundShadow.fillColor = NSColor.black.withAlphaComponent(0.13)
        groundShadow.strokeColor = .clear
        groundShadow.position = CGPoint(x: frame.width / 2, y: 6)
        sceneK.addChild(groundShadow)

        rig.position = CGPoint(x: frame.width / 2, y: 4)
        sceneK.addChild(rig)
        main = sprite("master")
        rig.addChild(main)
        for p in ["stand", "sit", "laptop", "wave", "sleep"] {
            let r = Live(size: spriteSize, pose: p)
            guard r.ok else { continue }
            r.zPosition = 0.5
            r.alpha = 0
            rig.addChild(r)
            rigs[p] = r
        }


        emoteNode.fontSize = 19
        emoteNode.fontColor = NSColor(calibratedRed: 0.50, green: 0.38, blue: 0.62, alpha: 1)
        emoteNode.position = CGPoint(x: frame.width - 22, y: frame.height - 30)
        emoteNode.alpha = 0
        emoteNode.zPosition = 10
        sceneK.addChild(emoteNode)

        for r in 0...rows { for c in 0...cols { src.append(SIMD2(Float(c) / Float(cols), Float(r) / Float(rows))) } }
        presentScene(sceneK)
    }

    required init?(coder: NSCoder) { fatalError() }

    var loaded: Bool { textures["master"] != nil }

    /// How far below her feet her window must sit for the clip showing: "sit_legs" is drawn on an edge
    /// 93 px up its 440 px picture (measured on anim/sit_legs/0.webp: rows 345-347 from the top), legs
    /// hanging below it, so the drawn edge goes on the window's top. 0 for everything else.
    var ledge: CGFloat { showing == "@sit_legs" ? 4 + spriteSize.height * 93 / 440 : 0 }

    private func sprite(_ name: String) -> SKSpriteNode {
        let s = SKSpriteNode(texture: textures[name], size: spriteSize)
        s.anchorPoint = CGPoint(x: 0.5, y: 0)
        return s
    }

    /// Which body she is in: a library clip she is performing, or one of her
    /// rigged poses. Her feelings show on whichever pose she is in (expression()),
    /// so a smile never makes her stand up from sitting.
    private func pose(_ f: Face) -> String {
        if !f.act.isEmpty && !SpriteView.rigActs.contains(f.act) {
            if frames(f.act) != nil { return "@" + f.act }
            // poses.jsonl 23:23:25: chase -> idle for 0.16 s -> getup while getup's frames loaded. One
            // drawn clip to the next holds the one showing until the next is ready, not a flash of her rig.
            if loading.contains(f.act), showing != "@live", showing.hasPrefix("@"), clips[String(showing.dropFirst())] != nil { return showing }
        }
        // a drawn clip whose time was up was cut wherever
        // it stood — mid-reach, mid-bite — and her rig popped in (sim 58: 7 of 12 clips left mid-way, mean of 10 runs). Standing
        // still where she is, the clip plays on to the end of its loop (back to its first frame, the pose it
        // set out from), or to its last frame if it plays once, at most 1.3 s more. Walking, carried,
        // in the air or asleep, she goes at once.
        if f.act.isEmpty, !actShowing.isEmpty, !SpriteView.ownPace.contains(actShowing), showing == "@" + actShowing, !actShowingMoves, !f.held, !f.sleeping,
           f.walk <= 0.05, f.vy == 0, f.hint != "wave", let fr = clips[actShowing] {
            let once = SpriteView.once.contains(actShowing)
            let left = once ? fr.count - 1 - frameIndex : (frameIndex == 0 ? 0 : fr.count - frameIndex)
            let now = SpriteView.now(), step = Double(SpriteView.pace("@" + actShowing)) * 1.35
            if finishBy == nil && left > 0 && Double(left) * step <= 1.3 { finishBy = now.addingTimeInterval(Double(left) * step + 0.05) }
            if left > 0, let by = finishBy, now < by { return showing }
        }
        finishBy = nil
        if f.sleeping { return "@sleep" }
        // (owner: the Iris panel's moves): her rig draws its actions only standing or
        // sitting (apply below), so a nod or a dance asked while she typed along or waved was taken,
        // reported done ("Dancing" in the ledger) and never shown. An action of her rig leaves those poses
        // while it plays.
        let rigAct = SpriteView.rigActs.contains(f.act)
        if f.hint == "wave" && !rigAct { return "@wave" }
        // pose log 01:40:18–21: sit ↔ stand six times in 3 s (held 0.1–0.2 s) during look_around — a
        // value hovering at a single threshold flipped her body every frame. Each threshold now has a
        // margin on the side she is already on: seated she stays down until sit falls below 0.4, and a
        // drift under 0.2 doesn't stand her up to walk.
        // pose log 12:55:31-12:56:10: typing <-> idle up to four times in one second while she typed along:
        // her laptop pose is seated too, but only "sit" got the margin, so a walk value hovering at 0.05 flipped it
        let seatedNow = livePose == "sit" || livePose == "laptop" || showing == "@typing" || showing == "@" + f.seat
        if f.walk > (seatedNow ? 0.2 : 0.05) || (f.hop > 6 && f.vy != 0) {
            // walking and jumping: her rig, standing — or the drawn walk her walk's cause asks for
            if !f.gait.isEmpty && f.vy == 0 && !rigAct {
                if frames(f.gait) != nil { return "@" + f.gait }
                if let hold = holdWhileLoading(f.gait) { return hold }
            }
            return "@idle"
        }
        // a nod or a shake of her head is her head only, and her laptop pose has one: she nods over her
        // keys instead of putting the laptop away for a second and a half and taking it out again (sim 47 and
        // poses.jsonl /29: typing -> sit -> typing for each "his typing stopped" nod). A dance still stands.
        if f.hint == "typing" && (!rigAct || SpriteView.headActs.contains(f.act)) { return "@typing" }
        if f.hint == "watching" || f.sit > (seatedNow ? 0.4 : 0.6) {
            // seated, a drawn clip says it better when its state holds (Stages.seat)
            if !f.seat.isEmpty && !rigAct {
                if frames(f.seat) != nil { return "@" + f.seat }
                if let hold = holdWhileLoading(f.seat) { return hold }
            }
            return "@sit"
        }
        return "@idle"
    }

    /// poses.jsonl..29: idle -> sit for 0.0-0.1 s -> fishing (16 times), snore -> sit -> fishing, read_book
    /// -> sit -> fishing: her sit pose popped in for the moment the clip's frames took to load, then the clip cut over
    /// it. While they load she stays in the body she is in, if it can still be drawn.
    private func holdWhileLoading(_ clip: String) -> String? {
        guard loading.contains(clip), !journalPose.isEmpty else { return nil }
        if ["@idle", "@sit", "@typing", "@wave", "@sleep"].contains(journalPose) || clips[String(journalPose.dropFirst())] != nil { return journalPose }
        return nil
    }

    /// Little actions her rig performs itself, smoothly, on whatever pose she is in
    /// (catalog.json marks them "rig"): no drawn frames.
    static let rigActs: Set<String> = ["nod", "shake_head", "giggle", "yawn", "look_around", "dance", "sigh", "think", "shy"]
    /// Her rig's actions that move only her head and face: shown on her laptop too.
    static let headActs: Set<String> = rigActs.subtracting(["dance"])
    /// Drawn clips that play once and hold their last frame instead of looping: getting up, waking up.
    static let once: Set<String> = ["wake_up", "getup"]
    /// Drawn clips her state ends, not her time: her doze (asleep or woken), her snore (woken) — these go at once.
    static let ownPace: Set<String> = ["doze", "snore"]
    /// Seconds a frame of a drawn clip shows, before her slight unevenness (×0.8…1.35).
    static func pace(_ want: String) -> CGFloat {
        ["@sleep": 0.75, "@blanket": 0.8, "@sit": 0.55, "@idle": 0.5, "@typing": 0.3, "@wave": 0.16, "@talk": 0.14,
         // her body's own clips: a doze droops slowly, a snore breathes,
         // legs swing, pages turn, a line waits for a bite
         "@doze": 0.35, "@snore": 0.5, "@sit_legs": 0.18, "@read_book": 0.6,
         "@fishing": 0.8, "@sulk": 0.3,
         // waking, she sits up in bed, rubs her eyes and yawns, slowly (8 frames, about 2.4 s)
         "@wake_up": 0.3][want] ?? 0.13
    }

    /// What her face is feeling this instant.
    private func expression(_ f: Face) -> String {
        if f.dizzy > 0.5 { return "dizzy" }
        if f.wince > 0.5 { return "worried" }
        if f.listening { return "listening" }
        if f.happyEyes > 0.5 { return f.blush > 0.55 ? "love" : "happy" }
        if f.cat > 0.5 { return "love" }
        if f.wide > 0.5 { return "surprised" }
        if f.pout > 0.5 { return "pout" }
        if f.hint == "curious" { return "curious" }
        return ""
    }

    private func apply() {
        let f = face
        let now = SpriteView.now()
        let dt = CGFloat(min(0.05, max(0, now.timeIntervalSince(lastUpdate))))   // a clock stepping back is no frame back
        clock += dt
        lastUpdate = now

        // asleep, her breathing needs few frames (the app held a steady ~16% CPU at 60 fps)
        // awake and still (sitting, typing along, a clip in place) was 60 fps too; her drawing was about a
        // third of her CPU (sample, 37% with him at it). Movement keeps 60: walking, carried, a hop or fall.
        let moving = f.held || f.walk > 0.05 || abs(f.vx) > 1 || f.vy != 0 || f.hop > 0.5
        let fps = f.sleeping ? 20 : moving ? 60 : 30
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        var want = pose(f)
        if !f.act.isEmpty && want == "@" + f.act { actShowing = f.act; actShowingMoves = f.actMoves }
        else if !(f.act.isEmpty && want == "@" + actShowing) { actShowing = "" }
        if want != journalPose {
            // from, to and why: what drove it (a clip, sleep, his typing, walking, sitting), and how long
            // the last pose held — the report reads this to find poses that flicker or never change
            // a drawn walk or seat in place of her rig is named as the clip it is
            let drawnStage = want == "@" + f.gait || want == "@" + f.seat
            let what = !f.act.isEmpty ? "clip \(f.act)" : drawnStage ? "clip \(want.dropFirst())" : f.sleeping ? "asleep" : !f.hint.isEmpty ? f.hint
                : f.walk > 0.05 ? "walking" : f.sit > 0.6 ? "sitting" : "standing"
            let why = f.why.isEmpty ? what : "\(what): \(f.why)"     // and its cause
            // idle_s: seconds since his last key, click or mouse move (the system's clock) — whether he
            // was at the Mac for this change, which the report can't otherwise tell
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            // typing <-> idle still flips in 50-100 ms while she types along (poses.jsonl),
            // with her why saying her walk was under 0.05; what pose() read when it chose is kept, so the next one says which input
            let seatedNow = livePose == "sit" || livePose == "laptop" || showing == "@typing" || showing == "@" + f.seat
            func r2(_ v: CGFloat) -> Double { Double(Int(v * 100)) / 100 }
            Store.append(["at": now.timeIntervalSince1970, "from": journalPose, "to": want, "why": why,
                          "held_s": Double(Int(now.timeIntervalSince(journalPoseAt) * 10)) / 10,
                          "idle_s": Double(Int(min(idle, 86_400) * 10)) / 10,
                          "in": ["walk": r2(f.walk), "vy": r2(f.vy), "hop": r2(f.hop), "sit": r2(f.sit), "act": f.act,
                                 "hint": f.hint, "seat": f.seat, "gait": f.gait, "seated": seatedNow],
                          // a drawn clip left: the frame it was on, of how many (was it cut off mid-way)
                          "left_at": journalPose.hasPrefix("@") && showing == journalPose ? [frameIndex, clips[String(journalPose.dropFirst())]?.count ?? 0] : []],
                         to: "poses.jsonl",
                         cap: 5_000_000)
            journalPose = want
            journalPoseAt = now
        }
        // she is her own picture, rigged, in every everyday pose: always moving, never a held image
        let poseFor: [String: String] = ["@idle": "stand", "@sit": "sit", "@typing": "laptop", "@wave": "wave", "@sleep": "sleep"]
        let wantPose = poseFor[want] ?? ""
        let usePose = rigs[wantPose] != nil ? wantPose : ""
        if usePose != livePose {
            // the old body sinks fast toward the new one, then a clean cut to the new
            // body landing with a little squash: never two see-through pictures at once
            let sink = 0.09
            func leave(_ n: SKNode) {
                guard n.alpha > 0.01 else { n.alpha = 0; return }
                let down = SKAction.scaleY(to: 0.86, duration: sink)
                down.timingMode = .easeIn
                n.run(.sequence([down, .fadeAlpha(to: 0, duration: 0), .scaleY(to: 1, duration: 0)]), withKey: "fade")
            }
            func arrive(_ n: SKNode) {
                n.alpha = 0
                let up = SKAction.scaleY(to: 1.03, duration: 0.09), back = SKAction.scaleY(to: 1, duration: 0.1)
                up.timingMode = .easeOut; back.timingMode = .easeInEaseOut
                n.run(.sequence([.wait(forDuration: sink), .fadeAlpha(to: 1, duration: 0), .scaleY(to: 0.9, duration: 0),
                                 up, back]), withKey: "fade")
            }
            for (name, r) in rigs {
                r.removeAction(forKey: "fade")
                if name == usePose { arrive(r) } else { leave(r) }
            }
            main.removeAction(forKey: "fade")
            if usePose.isEmpty { arrive(main) } else { leave(main) }
            settle = 0
            if usePose.isEmpty { showing = "" }
            livePose = usePose
        }
        if let r = rigs[usePose] {
            driveLive(f, want: expression(f), rig: r, dt: dt)
            want = "@live"
            showing = want
        }
        if want == "@live" {
            // the rig is drawn; nothing to swap
        } else if want.hasPrefix("@"), let frames = frames(String(want.dropFirst())) {
            if want != showing { frameIndex = 0; frameAt = 0 }
            let n = frames.count
            switch want {
            case "@walk", "@sad_walk", "@tiptoe":          // feet keep pace with how far she has walked
                frameIndex = Int((f.walkPhase / (2 * .pi) * CGFloat(n)).rounded(.down)) % n
            case "@hop":                                   // the jump frames follow her real arc
                frameIndex = f.vy > 150 ? min(2, n - 1) : f.vy > -80 ? min(3, n - 1) : min(4, n - 1)
            case "@fall_land":
                // down from his window — the falling frames (0-2) while she is in the air, then the
                // landing (3 onward, 0.15 s each) once her feet are down, holding the last
                if f.vy != 0 { landedFor = 0; frameIndex = f.vy > 0 ? 0 : f.vy > -400 ? min(1, n - 1) : min(2, n - 1) }
                else { landedFor += dt; frameIndex = min(n - 1, 3 + Int(landedFor / 0.15)) }
            default:                                       // loops, at a living, slightly uneven pace
                frameAt += max(dt, 0.016)
                if frameAt >= nextFrameIn {
                    frameAt = 0
                    blendFor = nextFrameIn * 0.75             // the last frame melts into this one
                    // a clip that plays once stays on its last frame (getting up, waking up), a loop goes round
                    frameIndex = SpriteView.once.contains(String(want.dropFirst())) ? min(n - 1, frameIndex + 1) : (frameIndex + 1) % n
                    nextFrameIn = SpriteView.pace(want) * CGFloat.random(in: 0.8...1.35)
                }
            }
            lastKeys = f.keys
            setTexture(frames[frameIndex], name: want)
        } else if want != showing, let t = textures[want] {
            // the old pose fades out on top while the new one is already moving underneath
            setTexture(t, name: want)
        }

        // chasing or pouncing on his cursor: drawn toward the right, turned to face it when it's on her left
        let towardCursor = showing == "@chase" || showing == "@pounce"
        let mirror = ((showing == "@walk" || showing == "@run" || showing == "@sad_walk" || showing == "@tiptoe" || towardCursor || (f.actMoves && showing == "@" + f.act)) && f.flip)
        // a change of body is a little squash and settle, so the dissolve reads as her moving
        settle = max(0, settle - dt / 0.32)
        let dip = settle > 0 ? sin(.pi * (1 - settle)) * 0.055 : 0
        rig.xScale = (1 - f.squash * 0.6 + dip * 0.5) * (mirror ? -1 : 1)
        rig.yScale = 1 + f.squash - dip
        rig.zRotation = -f.lean
        rig.position.y = 4 + f.hop
        // on a window's top edge with her legs over it, the shadow would hang in the air below the edge
        groundShadow.alpha = showing == "@sit_legs" ? 0 : max(0.25, 1 - f.hop / 50)
        groundShadow.xScale = max(0.5, 1 - f.hop / 80)

        let grid = warp(f)
        for n in [main, fading].compactMap({ $0 }) { n.warpGeometry = grid }

        if let e = f.emote, f.emoteAge < 1.6 {
            if emoteNode.text != e { emoteNode.text = e }
            emoteNode.alpha = max(0, min(1, (1.6 - f.emoteAge) * 2))
            emoteNode.position.y = frame.height - 30 + min(1, f.emoteAge * 4) * 8 + f.hop
        } else {
            emoteNode.alpha = 0
        }
    }

    /// Her face and body as rig parameters this frame.
    private func driveLive(_ f: Face, want: String, rig live: Live, dt: CGFloat) {
        var p = Live.Params()
        let c = f.clock
        // the head is never quite still: a slow drift and sway, plus what the body asks
        p.tilt = f.tilt * 0.5 + sin(c * 0.7) * 0.03 + sin(c * 0.23 + 1.3) * 0.025
            + (want == "curious" ? 0.16 : want == "listening" ? -0.1 : want == "dizzy" ? sin(c * 4) * 0.12 : 0)
        p.turn = max(-1, min(1, f.turn + sin(c * 0.31) * 0.12))
        p.gaze = CGPoint(x: max(-1, min(1, f.gaze.x)), y: max(-1, min(1, f.gaze.y)))
        p.nod = -p.gaze.y * 0.14          // her chin follows her eyes a little: up to look up, down to look down
        p.lid = f.lid
        p.happy = f.happyEyes > 0.5 || want == "happy" || want == "love"
        p.breath = f.breathe
        // walking: legs step with the distance she covers, she faces where she's going,
        // her body rocks with each step
        if f.walk > 0.05 {
            p.stride = min(1, f.walk)
            p.step = f.walkPhase
            p.dir = f.flip ? -1 : 1
            p.turn = max(-1, min(1, p.turn * 0.3 + p.dir * 0.75 * p.stride))
            p.tilt += sin(f.walkPhase) * 0.05 * p.stride
            p.gaze = CGPoint(x: p.dir * 0.8, y: 0)
        }
        p.blush = want == "love" ? 1 : want == "pout" ? 0.45 : max(0, f.blush - 0.3) * 1.4
        if f.talking {
            // speech changes shape on its own rhythm while Friday talks
            visemeAt += dt
            if visemeAt > CGFloat.random(in: 0.07...0.15) {
                visemeAt = 0
                viseme = f.mouthOpen > 0.5 ? ["a", "o", "e", "a", "i", "smile_open"].randomElement()! : ["", "i"].randomElement()!
            }
            p.mouth = viseme
            p.nod += sin(c * 5) * 0.35
        } else {
            p.mouth = want == "happy" ? "laugh" : want == "love" ? "cat" : want == "surprised" ? "o" :
                want == "pout" ? "pout" : want == "worried" ? "wobble" : want == "dizzy" ? "wobble" : f.cat > 0.5 ? "cat" :
                f.mood < -0.35 ? "frown" : f.mood < -0.15 ? "flat" : f.mood > 0.75 ? "grin" : ""
        }
        // a little action of her own, performed by the rig
        if f.act != rigAct { rigAct = f.act; actClock = 0 } else { actClock += dt }
        let headActOnLaptop = live.pose == "laptop" && SpriteView.headActs.contains(f.act)
        if SpriteView.rigActs.contains(f.act) && (live.pose == "stand" || live.pose == "sit" || headActOnLaptop) {
            let t = actClock
            switch f.act {
            case "nod":
                p.nod = max(0, sin(t * 7)) * 0.9; p.mouth = "smile_open"
            case "shake_head":
                // at 0.55 her "no" read as standing still at her size (frames of the panel's tap);
                // a full turn each way, eyes going with it, easing out over three seconds
                let k = max(0, 1 - t / 3)
                p.turn = sin(t * 8) * 0.95 * k; p.gaze = CGPoint(x: sin(t * 8) * 0.9 * k, y: 0); p.mouth = "frown"
            case "giggle":
                p.happy = true; p.mouth = "laugh"; p.blush = 0.6
                p.tilt += sin(t * 15) * 0.035; p.breath = sin(t * 18) * 1.2
            case "yawn":
                let k = min(1, t / 0.6) * max(0, min(1, (2.6 - t) / 0.6))
                p.lid = 0.3 + 0.7 * k; p.mouth = k > 0.5 ? "o" : "i"; p.nod = -0.6 * k; p.breath = 1.2 * k
            case "look_around":
                p.turn = sin(t * 1.4) * 0.95; p.gaze = CGPoint(x: sin(t * 1.4 + 0.3), y: 0.15 * sin(t * 0.7))
                p.mouth = "o"
            case "dance":
                p.happy = sin(t * 3) > 0; p.mouth = "smile_open"
                p.tilt = sin(t * 6) * 0.12; p.turn = sin(t * 3) * 0.45
                if live.pose == "stand" { p.stride = 0.7; p.step = t * 6; p.dir = sin(t * 3) > 0 ? 1 : -1 }
            case "sigh":
                // half-lidded and a small dip read as no move; a breath in, then eyes nearly shut,
                // head dropping and the breath let out through an "o"
                let k = min(1, t / 0.8)
                p.lid = 0.25 + 0.6 * k; p.mouth = t > 0.6 && t < 1.8 ? "o" : "flat"
                p.nod = 0.7 * k; p.breath = t < 0.6 ? 1.6 : -1.4 * k
            case "think":
                // a 0.16 tilt read as no move; head tipped well over, eyes up and away, lips pursed
                p.tilt += 0.3; p.gaze = CGPoint(x: 0.9, y: 0.9); p.mouth = "pout"
                p.turn = 0.45 + sin(t * 0.8) * 0.08
            case "shy":
                p.blush = 1; p.mouth = "wobble"; p.gaze = CGPoint(x: -0.5, y: -0.8); p.turn = -0.45; p.nod = 0.3
            default: break
            }
        }
        if f.held && live.pose == "stand" {
            // carried: legs kick, she swings against the way she's carried, a startled little face
            dangle += (max(-1, min(1, -f.vx / 900)) - dangle) * min(1, dt * 6)
            p.stride = 0.9
            p.step = f.clock * 15
            p.dir = 0
            p.tilt = dangle * 0.35 + sin(f.clock * 5) * 0.05
            p.turn = -dangle * 0.5
            p.gaze = CGPoint(x: 0, y: -0.6)
            p.mouth = f.happyEyes > 0.5 ? "laugh" : (Int(f.clock * 2) % 3 == 0 ? "wobble" : "o")
        } else {
            dangle = 0
        }
        switch live.pose {
        case "wave":
            waveClock += dt
            p.wave = sin(waveClock * 9)
            p.mouth = ""
        case "laptop":
            // a dip on each of his keystrokes (she types along), else a gentle rhythm of her own
            if f.keys != lastKeys { tapAt = 0.12; lastKeys = f.keys } else { tapAt = max(0, tapAt - dt) }
            p.tap = tapAt > 0 ? 1 : max(0, CGFloat(sin(Double(f.clock) * 11))) * 0.6
            p.mouth = ""                           // her laptop picture has no mouths drawn
            if !headActOnLaptop {                  // a nod or a look of hers keeps her own eyes and turn
                p.gaze = CGPoint(x: -0.2, y: -0.8)
                p.turn *= 0.3
            }
        case "sleep":
            p.tilt = sin(f.clock * 0.4) * 0.01
            p.turn = 0
            p.lid = 0
            p.happy = false
            p.mouth = ""
            p.breath = CGFloat(sin(Double(f.clock) * 1.3))
        default:
            break
        }
        if live.pose != "wave" { waveClock = 0 }
        live.apply(p, dt: dt, vx: f.vx)
    }

    /// A frame of the same clip swaps in place; a different clip or picture melts in.
    private func setTexture(_ t: SKTexture, name: String) {
        if name == showing, blendFor > 0, main.texture !== t, let prev = main.texture {
            // a drawn frame never snaps to the next: the old one fades out over it
            let old = SKSpriteNode(texture: prev, size: spriteSize)
            old.anchorPoint = CGPoint(x: 0.5, y: 0)
            old.zPosition = 1
            old.warpGeometry = main.warpGeometry
            rig.addChild(old)
            old.run(.sequence([.fadeOut(withDuration: Double(blendFor)), .removeFromParent()]))
        }
        blendFor = 0
        if name != showing {
            fading?.removeFromParent()
            let old = SKSpriteNode(texture: main.texture, size: spriteSize)
            old.anchorPoint = CGPoint(x: 0.5, y: 0)
            old.zPosition = 1
            old.xScale = main.xScale
            rig.addChild(old)
            old.run(.sequence([.fadeOut(withDuration: 0.07), .removeFromParent()]))
            fading = old
            showing = name
        }
        if main.texture !== t { main.texture = t }
    }

    private func headRotation(_ f: Face) -> CGFloat {
        let idle = sin(clock * 0.9) * 0.025 + sin(clock * 0.37 + 1) * 0.02
        return -(f.tilt * 0.55 + idle + f.turn * 0.04)
    }

    /// Where each mesh point of her picture goes this frame.
    private func warp(_ f: Face) -> SKWarpGeometryGrid {
        let aspect = Float(spriteSize.height / spriteSize.width)
        let a = showing.hasPrefix("@") ? Float(headRotation(f)) * 0.3 : Float(headRotation(f))
        let ca = cos(a), sa = sin(a)
        let nx = Float(neck.x), ny = Float(neck.y)
        let breathe = Float(f.breathe)
        let sway = Float(f.hairSway) + Float(sin(clock * 1.3)) * 0.012 + Float(sin(clock * 0.53 + 2)) * 0.008
        let walking = Float(f.walk)
        let step = Float(sin(f.walkPhase))
        let sitting = !SpriteView.standing.contains(showing)
        let animated = showing.hasPrefix("@")
        let turnShift = Float(f.turn) * 0.012
        var dst = [SIMD2<Float>]()
        dst.reserveCapacity(src.count)
        for p in src {
            var x = p.x, y = p.y
            // head: everything above the neck turns about it, easing in across the collar
            let w = smooth(ny - 0.04, ny + 0.08, y)
            if w > 0 {
                let dx = x - nx, dy = (y - ny) * aspect
                let rx = dx * ca - dy * sa, ry = dx * sa + dy * ca
                x += (rx - dx) * w + turnShift * w
                y += ((ry - dy) / aspect) * w
            }
            // breathing: the chest widens and lifts a touch
            let chest = bell(0.40, 0.14, y)
            x = 0.5 + (x - 0.5) * (1 + 0.010 * breathe * chest)
            y += 0.004 * breathe * chest
            // long hair: the outer strands below the face trail and sway, most at the tips
            let outer = smooth(0.18, 0.34, abs(p.x - 0.5))
            let tips = smooth(0.70, 0.25, p.y)
            x += sway * outer * tips * 0.9
            // legs step while walking (standing pictures only)
            if !animated && !sitting && walking > 0.01 && p.y < 0.26 {
                let leg: Float = p.x < 0.5 ? 1 : -1
                let k = (0.26 - p.y) / 0.26
                x += leg * step * 0.045 * k * walking
                y += max(0, leg * step) * 0.02 * k * walking
            }
            dst.append(SIMD2(x, y))
        }
        return SKWarpGeometryGrid(columns: cols, rows: rows, sourcePositions: src, destinationPositions: dst)
    }

    private func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private func bell(_ c: Float, _ w: Float, _ x: Float) -> Float { exp(-((x - c) * (x - c)) / (2 * w * w)) }

    /// What she looks like right now, as PNG (her window is kept out of screen
    /// captures, so this is how anyone can check).
    func snapshot() -> Data? {
        guard let tex = texture(from: sceneK) else { return nil }
        return NSBitmapImageRep(cgImage: tex.cgImage()).representation(using: .png, properties: [:])
    }

    // MARK: touch

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = CGRect(x: (bounds.width - spriteSize.width) / 2 + 12, y: 4, width: spriteSize.width - 24,
                       height: spriteSize.height)
        return r.contains(p) ? self : nil
    }
    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds.insetBy(dx: 22, dy: 6), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseDown(with e: NSEvent) { downAt = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt else { return }
        let p = NSEvent.mouseLocation
        if dragged || hypot(p.x - d.x, p.y - d.y) > 4 { dragged = true; onDrag?(p) }
    }
    override func mouseUp(with e: NSEvent) {
        if dragged { onDrop?() } else if e.clickCount == 2, let d = onDoublePet { d() } else { onPet?() }
        downAt = nil
        dragged = false
    }
    override func rightMouseDown(with e: NSEvent) { onMenu?(e) }
}
