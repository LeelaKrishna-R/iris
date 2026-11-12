import AppKit

/// "Ask \(Config.agentName)…" from her menu: a small box near the pointer to type a
/// question to Friday, for when speaking isn't right. Return sends it, Escape
/// or clicking away closes it. What's typed goes the way her ears' words go.
// (strict concurrency): AppKit, on her main thread. @preconcurrency until her body and main.swift, which use it,
// are main-actor too: their calls compile as before.
@preconcurrency @MainActor
final class AskBox: NSObject, NSTextFieldDelegate {
    static let shared = AskBox()
    private var panel: AskPanel?
    private var field: NSTextField?
    private var send: ((String) -> Void)?
    private var last = ""                  // ↑ brings back the last question asked

    func show(_ send: @escaping (String) -> Void) {
        self.send = send
        let size = NSSize(width: 360, height: 44)
        let at = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main
        let origin = AskBox.origin(mouse: at, size: size, visible: screen?.visibleFrame)
        let p = panel ?? AskPanel(contentRect: NSRect(origin: origin, size: size),
                                  styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.setFrameOrigin(origin)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if field == nil {
            let f = NSTextField(frame: NSRect(x: 12, y: 8, width: size.width - 24, height: 28))
            f.placeholderString = "Ask \(Config.agentName)…"
            f.font = .preferredFont(forTextStyle: .title3)          // the system's text style (15 pt by default)
            f.setAccessibilityLabel("Ask \(Config.agentName)")
            f.isBordered = false
            f.focusRingType = .none
            f.drawsBackground = false
            f.delegate = self
            p.contentView?.addSubview(f)
            field = f
        }
        field?.stringValue = ""
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(field)
    }

    /// Where the box opens: just above his pointer, centred on it, kept 8 pt inside his screen (pure, tested).
    nonisolated static func origin(mouse at: NSPoint, size: NSSize, visible vf: NSRect?) -> NSPoint {
        var origin = NSPoint(x: at.x - size.width / 2, y: at.y + 24)
        if let vf {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return origin
    }

    /// What a key does in the box: Return sends what's typed (nothing when it is blank) and closes it, ↑ brings back
    /// the last question asked, Escape closes it; any other key is the field's (pure, tested).
    enum Key: Equatable { case send(String?), recall(String), close, field }

    nonisolated static func key(_ sel: Selector, text: String, last: String) -> Key {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            return .send(text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text)
        }
        if sel == #selector(NSResponder.moveUp(_:)), !last.isEmpty { return .recall(last) }
        if sel == #selector(NSResponder.cancelOperation(_:)) { return .close }
        return .field
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch AskBox.key(sel, text: field?.stringValue ?? "", last: last) {
        case .send(let text):
            close()
            if let text { last = text; send?(text) }
            return true
        case .recall(let text):
            field?.stringValue = text
            textView.moveToEndOfDocument(nil)
            return true
        case .close:
            close()
            return true
        case .field:
            return false
        }
    }

    func close() { panel?.orderOut(nil) }
}

/// A panel that takes typing although Iris is an accessory app, and closes
/// when he clicks elsewhere.
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}

import Carbon.HIToolbox

/// ⌃⌥Space anywhere opens "Ask \(Config.agentName)…"; ⌃⌥⇧Space starts listening, as her
/// menu's "Talk to \(Config.agentName)" does. Carbon hot keys: no permission is
/// asked for, and only these two combinations are taken.
// (strict concurrency): AppKit, on her main thread. @preconcurrency until her body and main.swift, which use it,
// are main-actor too: their calls compile as before.
@preconcurrency @MainActor
enum AskHotKey {
    private static var refs: [EventHotKeyRef?] = []
    private static var handler: EventHandlerRef?
    static var onPress: (() -> Void)?
    static var onTalk: (() -> Void)?

    static func register(_ press: @escaping () -> Void, talk: (() -> Void)? = nil) {
        onPress = press
        onTalk = talk
        guard refs.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { id.id == 2 ? AskHotKey.onTalk?() : AskHotKey.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
        for (n, mods) in [(UInt32(1), controlKey | optionKey), (UInt32(2), controlKey | optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(kVK_Space), UInt32(mods), EventHotKeyID(signature: OSType(0x49524953), id: n),
                                GetApplicationEventTarget(), 0, &ref)                                  // "IRIS"
            refs.append(ref)
        }
    }
}
