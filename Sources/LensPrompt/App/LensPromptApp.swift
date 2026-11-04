import SwiftUI
import AppKit
import LensPromptCore

@main
struct LensPromptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("LensPrompt", id: "main") {
            MainView(model: delegate.model)
                .onAppear { delegate.installPanels() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { LensPromptCommands(model: delegate.model) }
    }
}

struct LensPromptCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Script…") { model.openScript() }.keyboardShortcut("o")
        }
        CommandMenu("Recording") {
            Button("Start/Stop Recording") { model.toggleRecording() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Choose Output Folder…") { model.chooseOutputFolder() }
            Button("Reconnect Devices") { model.reconnect() }
        }
        CommandMenu("Prompt") {
            Button("Start/Pause Prompt (Space)") { model.toggleTracking() }
            Button("Back to Script Start") { model.resetToStart() }.keyboardShortcut(.home, modifiers: [.command])
            Button("Placement Mode") { model.placementMode.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Reading Mode") { model.readingMode.toggle() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Show/Hide Prompt Panel") { model.settings.promptVisible.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Follow My Voice") { model.setPromptMode(.speech) }.keyboardShortcut("1", modifiers: [.command])
            Button("Fixed Speed") { model.setPromptMode(.fixedSpeed) }.keyboardShortcut("2", modifiers: [.command])
            Button("Manual") { model.setPromptMode(.manual) }.keyboardShortcut("3", modifiers: [.command])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var keyMonitor: KeyboardMonitor?

    override init() {
        let disabled = CommandLine.arguments.contains("--no-capture") || ProcessInfo.processInfo.environment["LENSPROMPT_NO_CAPTURE"] == "1"
        model = AppModel(captureDisabled: disabled)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        keyMonitor = KeyboardMonitor(model: model)
        model.start()
        // Panels are created after SwiftUI opens the main window (AppKit only opens the
        // initial window when no other window is visible at launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installPanels() }
        if let snapshotDir = ProcessInfo.processInfo.environment["LENSPROMPT_SNAPSHOT_DIR"], !snapshotDir.isEmpty {
            // Debug aid: renders LensPrompt's own windows to PNG files and quits.
            // Uses view caching, not screen capture; only meaningful with --no-capture.
            let dir = URL(fileURLWithPath: snapshotDir, isDirectory: true)
            let placement = ProcessInfo.processInfo.environment["LENSPROMPT_SNAPSHOT_PLACEMENT"] == "1"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model] in
                if placement { model.placementMode = true }
                NSApp.windows.first { $0.title == "LensPrompt" }?.setContentSize(NSSize(width: 1280, height: 760))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        let name = w.title.isEmpty ? "window\(n)" : w.title.replacingOccurrences(of: " ", with: "_")
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)\(placement ? "-placement" : "").png"))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func installPanels() {
        guard model.panels == nil else { return }
        let panels = PanelCoordinator(model: model)
        model.panels = panels
        panels.restoreFrames()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.takes.state.isBusy {
            Task { @MainActor in
                await model.prepareForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        model.settings.scriptPosition = model.prompt.position
        model.saveNow()
        return .terminateNow
    }
}
