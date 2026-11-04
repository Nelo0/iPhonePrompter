import AppKit

/// App-scoped (not system-wide) prompt shortcuts. Ignored while a text input has focus.
@MainActor
final class KeyboardMonitor {
    private var monitor: Any?
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private var textInputHasFocus: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let tv = responder as? NSTextView { return tv.isEditable || tv.isFieldEditor }
        return responder is NSTextField
    }

    /// Returns true if the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        // Escape: cancel countdown, else leave placement / reading mode. Never stops a take.
        if event.keyCode == 53 {
            if model.panels?.isDrawingOutline == true { model.panels?.finishDrawingOutline(nil); return true }
            if case .countdown = model.takes.state { model.cancelCountdown(); return true }
            if case .preparing = model.takes.state { model.cancelCountdown(); return true }
            if model.placementMode { model.placementMode = false; return true }
            if model.readingMode { model.readingMode = false; return true }
            return false
        }
        if model.panels?.isDrawingOutline == true { return false }
        guard mods.isEmpty, !textInputHasFocus else { return false }
        switch event.keyCode {
        case 49: model.toggleTracking(); return true                 // Space
        case 126: model.previousLine(); return true                  // ↑
        case 125: model.nextLine(); return true                      // ↓
        case 123: model.stepWord(-1); return true                    // ←
        case 124: model.stepWord(1); return true                     // →
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": model.adjustSpeed(10); return true
        case "-": model.adjustSpeed(-10); return true
        default: return false
        }
    }
}
