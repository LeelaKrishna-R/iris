import AppKit

/// "Ask Friday…" from her menu (10-12): a small box near the pointer to type a
/// question to Friday, for when speaking isn't right. Return sends it, Escape
/// or clicking away closes it. What's typed goes the way her ears' words go.
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
        var origin = NSPoint(x: at.x - size.width / 2, y: at.y + 24)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
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
            f.font = .systemFont(ofSize: 15)
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let text = field?.stringValue ?? ""
            close()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { last = text; send?(text) }
            return true
        }
        if sel == #selector(NSResponder.moveUp(_:)), !last.isEmpty {
            field?.stringValue = last
            textView.moveToEndOfDocument(nil)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
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

/// ⌃⌥Space anywhere opens "Ask Friday…"; ⌃⌥⇧Space starts listening, as her
/// menu's "Talk to Friday" does (10-12). Carbon hot keys: no permission is
/// asked for, and only these two combinations are taken.
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
