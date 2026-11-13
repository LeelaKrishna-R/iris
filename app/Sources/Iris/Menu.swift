import AppKit

// Her right-click menu's targets (out of Body.swift).
@MainActor          // AppKit calls its targets on the main thread
final class Menu: NSObject {
    static let shared = Menu()
    weak var body: Body?
    /// what her menu reads when it opens (main.swift: her ears' status, her eyes' pause, Screen Recording).
    var readState: (() -> (earsStatus: [String: Any]?, eyesOffUntil: Date?, screenPermitted: Bool))?
    /// her settings, done by the app that owns her ears and eyes (main.swift).
    var onSetting: ((String) -> Void)?
    @objc func talk() { body?.onTalk?() }
    @objc func ask() { body?.onAsk?() }
    @objc func welcome() { Welcome.show() }
    @objc func nap() { body?.toggleNap() }
    @objc func day() { body?.onDayCard?() }
    @objc func quit() { body?.soul.save(); NSApp.terminate(nil) }

    /// whether her body and her bubble can be captured in a screen share or recording. Off at every launch and
    /// never remembered: she and what she says stay out of shares unless he switches this on for the share at hand
    /// (a demo). His day card stays out whatever this says (DayCard).
    private(set) var inScreenShares = false
    var sharing: NSWindow.SharingType { inScreenShares ? .readOnly : .none }
    @objc func screenShares() {
        inScreenShares.toggle()
        body?.window?.sharingType = sharing
        body?.bubble?.share(sharing)
        log("menu: she \(inScreenShares ? "can" : "can't") be seen in screen shares and recordings now")
    }

    /// A setting from "How Iris is" (HowIris.toggles): "ears_off" / "ears_on" (an hour, or back on), "eyes_off" /
    /// "eyes_on", "quiet" / "talk" (Core's: asked of it, CoreWord).
    @objc func setting(_ sender: NSMenuItem) {
        guard let what = sender.representedObject as? String else { return }
        switch what {
        case "quiet", "talk": CoreWord.shared.ask(what)
        case "ears_off", "ears_on", "eyes_off", "eyes_on": onSetting?(what)
        default: log("menu: no such setting \(what)")
        }
    }
}
