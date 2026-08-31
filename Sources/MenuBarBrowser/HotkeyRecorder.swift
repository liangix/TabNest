import AppKit
import SwiftUI

/// 点击后直接按下组合键；至少需要一个修饰键。
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var shortcut: SiteHotkey?

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onChange = { shortcut = $0 }
        field.shortcut = shortcut
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        nsView.shortcut = shortcut
    }
}

@MainActor
final class RecorderField: NSView {
    var onChange: ((SiteHotkey?) -> Void)?
    var shortcut: SiteHotkey? { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (window?.firstResponder === self ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = shortcut?.displayName ?? (window?.firstResponder === self
            ? L10n.text(.hotkeyRecordPrompt)
            : L10n.text(.hotkeyRecordIdle))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: 9, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty && (event.keyCode == 53 || event.keyCode == 51 || event.keyCode == 117) {
            shortcut = nil
            onChange?(nil)
            return
        }

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= SiteHotkey.command }
        if flags.contains(.option) { modifiers |= SiteHotkey.option }
        if flags.contains(.control) { modifiers |= SiteHotkey.control }
        if flags.contains(.shift) { modifiers |= SiteHotkey.shift }
        guard modifiers != 0,
              let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            NSSound.beep()
            return
        }

        let display = Self.displayName(for: event.keyCode, characters: characters)
        let value = SiteHotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyDisplay: display)
        shortcut = value
        onChange?(value)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    private static func displayName(for keyCode: UInt16, characters: String) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            115: "Home", 116: "⇞", 117: "⌦", 119: "End", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return special[keyCode] ?? characters.uppercased()
    }
}
