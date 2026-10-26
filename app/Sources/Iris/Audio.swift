import AppKit
import CoreAudio
import Darwin

/// Which apps are using the microphone or making sound right now, from Core
/// Audio's process list (macOS 14.2+, no permission). 10-12: a call is an app
/// using the mic, not a call app's window being open (a Zoom home window or a
/// Teams chat isn't a call), and music in a background tab is still playing.
enum AudioUse {
    private static func processes(input: Bool) -> [(pid: pid_t, id: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr
        else { return [] }
        var out: [(pid_t, String)] = []
        for o in objs {
            var on = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: input ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &on) == noErr, on != 0 else { continue }
            var pid = pid_t(0)
            s = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid) == noErr else { continue }
            out.append((pid, AudioUse.who(pid)))
        }
        return out
    }

    /// The app behind a process: its bundle id, or for a helper with none (10-14: Safari plays
    /// a YouTube video through a WebKit XPC process whose bundle id read "", so video in a
    /// browser counted as silence) a name from its executable path.
    static func who(_ pid: pid_t) -> String {
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !id.isEmpty { return id }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        let path = String(cString: buf)
        if path.contains("WebKit") { return "com.apple.webkit.helper" }
        if path.contains("Google Chrome") { return "com.google.chrome.helper" }
        if path.contains("Firefox") { return "org.mozilla.firefox.helper" }
        if path.contains("Brave") { return "com.brave.browser.helper" }
        if path.contains("Microsoft Edge") { return "com.microsoft.edgemac.helper" }
        if path.contains("Arc.app") { return "company.thebrowser.arc.helper" }
        return path
    }

    /// Another app has the microphone open (not Iris's own ears).
    static var micByOthers: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return processes(input: true).contains { $0.pid != me }
    }

    /// Music or a video is playing: a player app, or a browser (any tab) making sound.
    static var soundPlaying: Bool {
        let players: Set<String> = ["com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.tidal.desktop",
                                    "com.amazon.music", "com.deezer.deezer-desktop", "com.apple.TV", "org.videolan.vlc"]
        let me = ProcessInfo.processInfo.processIdentifier
        return processes(input: false).contains { p in
            let id = p.id.lowercased()
            return p.pid != me && (players.contains(p.id) || id.hasPrefix("com.apple.webkit") || id.contains("chrome")
                                   || id.contains("firefox") || id.contains("brave") || id.contains("edgemac")
                                   || id.contains("thebrowser.arc"))
        }
    }
}
