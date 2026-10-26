import AppKit
import CoreAudio
import ApplicationServices

/// What Body and Soul read from the Mac — screens, his cursor, the front
/// window, the field he's typing in, the time, chance — behind one seam, so
/// `Iris --simulate` can run her real decisions and movement against made-up
/// screens and a fast clock (Sim.swift). Live, every value is read exactly as
/// before (NSScreen, NSEvent, Accessibility, Date()).
struct Display {
    var frame: CGRect
    var visibleFrame: CGRect
    var id: UInt32 = 0          // the display's own number: the same monitor after it's rearranged
}

/// A window on his screens, as the window server lists them (front to back).
struct SeenWindow: Equatable {
    var id: Int
    var frame: CGRect          // Cocoa coordinates
    var app: String
}

protocol World: AnyObject {
    var now: Date { get }
    var screens: [Display] { get }
    var mouse: CGPoint { get }
    /// The focused window of the front app (not hers), Cocoa coordinates.
    func frontWindow() -> CGRect?
    /// The field he's typing in and its caret, Cocoa coordinates.
    func focus() -> (field: CGRect?, caret: CGRect?)
    /// Where his keys are going (Focus.into): terminal, editor, chat, other or unknown, and why.
    func keysInto() -> (kind: String, why: String)
    var frontApp: String? { get }
    /// The front window's title (a browser tab's page title): "Lo-fi beats - YouTube".
    var frontTitle: String? { get }
    /// Whether his screen has been changing lately, when her eyes can't say (live: unknown → true).
    var screenChanging: Bool { get }
    /// Where his screen last changed and when, when her eyes can't say (live: unknown → nil).
    var screenChange: (at: Date, point: CGPoint)? { get }
    /// The system's count of key presses (heard even without Accessibility).
    var keyCounter: UInt32 { get }
    /// Seconds since a hand last touched a key, the mouse or the trackpad (hardware only: keys another app
    /// posts don't count).
    var handsIdle: Double { get }
    var accessibility: Bool { get }
    /// His windows on screen, frontmost first, at most `maxAge` seconds old.
    func windows(maxAge: Double) -> [SeenWindow]
    /// Music is playing: a music app (or a music page's browser) making sound now.
    var musicPlaying: Bool { get }
    /// Another app has the microphone open: a call is on (AudioUse.micByOthers).
    var callOn: Bool { get }
    /// Something is making sound: a player or any browser tab (AudioUse.soundPlaying).
    var soundOn: Bool { get }
}

final class RealWorld: World {
    var now: Date { Date() }
    // Core Audio's process list, asked at most every 2 s (her body reads these every frame)
    private var audioAt = Date.distantPast, call = false, sound = false
    private func audio() {
        guard Date().timeIntervalSince(audioAt) >= 2 else { return }
        audioAt = Date()
        call = AudioUse.micByOthers
        sound = AudioUse.soundPlaying
    }
    var callOn: Bool { audio(); return call }
    var soundOn: Bool { audio(); return sound }
    var musicPlaying: Bool {
        // Which apps are making sound right now (Core Audio's process list,
        // macOS 14.2+, no permission). The output device itself reads "running"
        // all the time (10-11: some app always holds a stream), so it can't tell.
        let players: Set<String> = ["com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.tidal.desktop",
                                    "com.amazon.music", "com.deezer.deezer-desktop"]
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr
        else { return false }
        let title = (frontTitle ?? "").lowercased()
        let musicPage = ["music", "spotify", "soundcloud", "playlist", "lofi", "lo-fi", "radio", "album"]
            .contains { title.contains($0) }
        for o in objs {
            var out = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &out) == noErr, out != 0 else { continue }
            var pid = pid_t(0)
            s = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid) == noErr else { continue }
            let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            if players.contains(id) { return true }
            // a browser's sound comes from its helper process; only a music page counts
            if musicPage && (id.hasPrefix("com.apple.WebKit") || id.lowercased().contains("chrome")
                             || id.lowercased().contains("firefox") || id.lowercased().contains("brave")) { return true }
        }
        return false
    }
    // 10-22: built once and kept until macOS says his displays changed (resolution, arrangement, the Dock or
    // menu bar resizing the visible frame); her body reads this from ~46 places, many every frame, and
    // rebuilding it each time was her top own function in a 10 s sample with him at the Mac
    private var screensKept: [Display]?
    private var screensWatch: NSObjectProtocol?
    var screens: [Display] {
        if let kept = screensKept { return kept }
        if screensWatch == nil {
            screensWatch = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screensKept = nil
            }
        }
        let built = NSScreen.screens.map { s in
            Display(frame: s.frame, visibleFrame: s.visibleFrame,
                    id: (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
        }
        screensKept = built
        return built
    }
    var mouse: CGPoint { NSEvent.mouseLocation }
    func frontWindow() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXPositionAttribute as CFString, &pv)
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXSizeAttribute as CFString, &sv)
        var p = CGPoint.zero, sz = CGSize.zero
        guard let pv, let sv, AXValueGetValue(pv as! AXValue, .cgPoint, &p),
              AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryH - p.y - sz.height, width: sz.width, height: sz.height)
    }
    func focus() -> (field: CGRect?, caret: CGRect?) {
        let f = Focus.now()
        return (f?.field, f?.caret)
    }
    func keysInto() -> (kind: String, why: String) { Focus.into() }
    var frontApp: String? { NSWorkspace.shared.frontmostApplication?.localizedName }
    var screenChanging: Bool { true }
    var screenChange: (at: Date, point: CGPoint)? { nil }
    var frontTitle: String? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?, title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win,
              AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
    // 10-22: hardware keys only. The session's counter also counted keys other apps post, and one at 07:14
    // (his last real input 05:51) had her wave "he came back after 83 min away" to an empty room.
    var keyCounter: UInt32 { CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown) }
    var handsIdle: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
    var accessibility: Bool { Hands.permitted }

    // The window server's own list: ordered front to back with ids (Eyes' ScreenCaptureKit list
    // has neither), bounds need no permission, and one call is well under a millisecond.
    private var winCache: [SeenWindow] = []
    private var winAt = Date.distantPast
    func windows(maxAge: Double) -> [SeenWindow] {
        if Date().timeIntervalSince(winAt) < maxAge { return winCache }
        winAt = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { winCache = []; return [] }
        winCache = list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((d[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let b = d[kCGWindowBounds as String] as? [String: Double],
                  let w = b["Width"], let h = b["Height"], w > 60, h > 60,
                  let id = d[kCGWindowNumber as String] as? Int else { return nil }
            let r = CGRect(x: b["X"] ?? 0, y: primaryH - (b["Y"] ?? 0) - h, width: w, height: h)
            return SeenWindow(id: id, frame: r, app: d[kCGWindowOwnerName as String] as? String ?? "")
        }
        return winCache
    }
}

/// Everything reads the world through here; the simulator swaps it.
var world: World = RealWorld()

/// Chance, seedable: live it is seeded from the system, a simulation from its
/// scenario, so a run can be repeated exactly (SplitMix64).
struct Dice: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var dice = Dice(seed: UInt64.random(in: 0...UInt64.max))

extension Double {
    static func rnd(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &dice) }
    static func rnd(_ r: Range<Double>) -> Double { Double.random(in: r, using: &dice) }
}
extension CGFloat {
    static func rnd(_ r: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: r, using: &dice) }
}
extension Bool {
    static func rnd() -> Bool { Bool.random(using: &dice) }
}
extension Array {
    func rndElement() -> Element? { randomElement(using: &dice) }
}
