import AppKit

/// A scenario with "real_view": true runs her real picture's pose choice beside the simulated body: a
/// SpriteView (never in a window, never drawn) gets the body's Face every frame on the simulator's clock and
/// keeps its own pose journal (poses.jsonl, in the run's scratch memory), so the check reads the body swaps he
/// would see — a clip cut off mid-way, a wake straight from lying to sitting, her laptop put away and out again
///
/// drawing it off screen as well (SKRenderer) wedged two processes in the GPU driver on this Mac's
/// Intel graphics (SpriteKit's add_subdivs on her sleep pose), so there is no picture here, only her choices.
final class SimView {
    let view: SpriteView

    init() {
        SpriteView.loadNow = true
        // check.py: run from.build/release, Bundle.main has none of her art, so this view had no rig and no
        // clips — 7 body swaps a run instead of 30, and every clip asked for (her wake_up too) never shown. Her art
        // is the package's Resources, found as Body.catalog finds catalog.json.
        if Bundle.main.url(forResource: "live", withExtension: "json", subdirectory: "live/stand") == nil {
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            if let dir = ["../../Resources", "../../../Resources"].map({ exe.appendingPathComponent($0).standardizedFileURL })
                .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("live/stand/live.json").path) }),
               let b = Bundle(url: dir) {
                SpriteView.art = b
            }
        }
        view = SpriteView(frame: NSRect(origin: .zero, size: Body.size))
    }

    /// One simulated frame: the face goes on her picture, which picks its body and journals any change.
    func frame(face: Face) { view.face = face }
}
