import AppKit

// Iris's body — what the simulator and Friday read of her (out of Body.swift): her events, her state,
// and the simulator's handles.
extension Body {
    /// What happened since her mind last asked (it asks with every thought).
    func takeEvents() -> [String] { defer { events.removeAll() }; return events }

    func toggleNap() { if sleeping { wake("he chose Wake") } else { fallAsleep("he chose Nap") } }

    /// The simulator puts her somewhere to start (on that screen's floor unless told).
    func simPlace(x px: CGFloat, y py: Double?) {
        x = px
        y = py.map { CGFloat($0) } ?? screenAt(px + Body.size.width / 2).visibleFrame.minY
    }

    static func bubbleRect(_ text: String, _ pet: CGRect, _ avoid: [CGRect]) -> [Double] {
        let size = BubbleView().fit(text)
        let o = Bubble.place(size: size, pet: pet, screens: world.screens, avoid: avoid)
        return [Double(o.x), Double(o.y), Double(size.width), Double(size.height)]
    }

    /// Everything the simulator logs each frame.
    func simState() -> [String: Any] {
        ["x": Double(x), "y": Double(y), "vy": Double(vy), "target": targetX.map { Double($0) } as Any,
         "perch": perchTop.map { Double($0) } as Any, "riding": riding,
         "on_window": standingOn != nil, "on_front_window": standingOn != nil && standingOn == world.frontWindow(), "crouching": launch != nil, "speed": Double(speed), "sit": Double(sit.value),
         "sleeping": sleeping, "held": held, "walk": Double(currentWalk), "flip": face.flip, "turn": Double(turn.value),
         "lean": Double(lean.value), "hint": face.hint, "act": performing, "seat": face.seat, "working_along": workingAlong,
         "emote": emoteAge < 1 ? (emote ?? "") : "", "in_the_way": inTheWay(CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height)),
         "want": wanting.want, "watching_video": watchingVideo, "alpha": Double(alpha), "display_moved": moved, "talking": world.now < talkUntil, "gaze_mode": gazeMode, "listening": listening,
         "bubble": world.now < bubbleUntil ? Body.bubbleRect(bubbleText, CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height), bubbleAvoid()) : [Double](), "lid": Double(lid.value), "valence": soul.valence, "arousal": soul.arousal, "sleepiness": soul.sleepiness,
         "boredom": soul.boredom, "affection": soul.affection, "his_idle": world.now.timeIntervalSince(lastInput)]
    }

    /// Where she is on his screens (an approval card goes beside her, ApprovalCard).
    var frameOnScreen: CGRect { CGRect(x: x, y: y, width: Body.size.width, height: Body.size.height) }

    func state() -> [String: Any] {
        ["x": Double(x), "y": Double(y), "sleeping": sleeping, "listening": listening,
         "clip": view?.showing ?? "", "speed": targetX == nil ? 0 : Double(speed), "sit": Double(sit.target),
         "working_along": workingAlong, "performing": performing,
         "noticed_ago_s": Int(world.now.timeIntervalSince(noticedAt)), "want": wanting.want, "want_strength": wanting.k, "typing_recent": world.now.timeIntervalSince(lastTyped) < 4,
         "typed_into": typedInto.kind, "typed_into_why": typedInto.why, "typed_into_ago_s": typedInto.at == .distantPast ? NSNull() : world.now.timeIntervalSince(typedInto.at) as Any,
         "keys_heard": ["monitor": monitorKeys, "counter": countedKeys], "music": musicOn,
         "feelings": soul.feelings(), "pets": soul.memory.pets, "shooed": soul.memory.shooed,
         "touches": touches.map { ["what": $0.what, "at": $0.at.timeIntervalSince1970] },
         "own_moments": ownMoments.map { ["kind": $0.kind, "at": $0.at.timeIntervalSince1970] }]
    }
}
