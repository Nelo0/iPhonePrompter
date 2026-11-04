import AppKit
import SwiftUI
import LensPromptCore

final class GuideWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating prompt panel and the phone placement guide, their geometry,
/// persistence, display changes and presets.
@MainActor
final class PanelCoordinator: NSObject, NSWindowDelegate {
    unowned let model: AppModel
    let promptPanel: PromptPanel
    let guideWindow: NSWindow
    let guideView = PhoneGuideView()
    private var restoring = false
    private var drawingWindows: [NSWindow] = []
    var isDrawingOutline: Bool { !drawingWindows.isEmpty }
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        promptPanel = PromptPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 170),
                                  styleMask: [.titled, .resizable, .fullSizeContentView, .utilityWindow],
                                  backing: .buffered, defer: false)
        guideWindow = GuideWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        super.init()

        let p = promptPanel
        p.title = "LensPrompt Prompt"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 220, height: 70)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.contentView = NSHostingView(rootView: PromptPanelContent(model: model))
        p.delegate = self
        p.setAccessibilityLabel("Teleprompter")

        let g = guideWindow
        g.title = "LensPrompt Phone Guide"
        g.isOpaque = false
        g.backgroundColor = .clear
        g.hasShadow = false
        g.level = .floating
        g.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        g.isReleasedWhenClosed = false
        guideView.model = model
        guideView.onGeometryCommitted = { [weak self] in self?.saveGuideFrame() }
        g.contentView = guideView
        g.delegate = self

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreFrames() }
        }
    }

    // MARK: Geometry

    private var mainScreen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// Restores saved frames (clamped to visible bounds of an existing display) or
    /// computes the default phone-below-text layout on the main display.
    func restoreFrames() {
        restoring = true
        defer { restoring = false }
        let screens = Screens.all
        let main = Screens.descriptor(mainScreen)
        let mainIndex = screens.firstIndex(of: main) ?? 0

        if let saved = model.settings.phoneFrame, let (rect, _) = LayoutGeometry.resolve(saved, screens: screens, fallbackIndex: mainIndex) {
            guideWindow.setFrame(rect, display: true)
        } else {
            let size = LayoutGeometry.initialPhoneSize(screenWidthPoints: mainScreen.frame.width, screenWidthMM: Screens.physicalWidthMM(mainScreen))
            let vf = mainScreen.visibleFrame
            let rect = NSRect(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.32, width: size.width, height: size.height)
            guideWindow.setFrame(LayoutGeometry.clamp(rect, into: vf), display: true)
        }
        if let saved = model.settings.promptFrame, let (rect, _) = LayoutGeometry.resolve(saved, screens: screens, fallbackIndex: mainIndex) {
            promptPanel.setFrame(rect, display: true)
        } else {
            promptPanel.setContentSize(NSSize(width: 640, height: 170))
            snapPromptToLens(force: true)
        }
        refresh()
        let needsSave = model.settings.phoneFrame == nil || model.settings.promptFrame == nil
        restoring = false
        if needsSave { saveGuideFrame(); savePromptFrame() }
    }

    func snapPromptToLens(force: Bool = false) {
        let arrangement = model.settings.arrangement == .free && force ? .phoneBelowText : model.settings.arrangement
        guard arrangement != .free else { return }
        let screen = guideWindow.screen ?? mainScreen
        let r = LayoutGeometry.promptFrame(current: promptPanel.frame, phone: guideWindow.frame, lensOffset: model.settings.lensOffset,
                                           arrangement: arrangement, gap: 4, bounds: screen.visibleFrame)
        promptPanel.setFrame(r, display: true, animate: !force)
        model.settings.style.activeEdge = LayoutGeometry.activeEdge(for: arrangement, current: model.settings.style.activeEdge)
        savePromptFrame()
    }

    func move(to screen: NSScreen) {
        let vf = screen.visibleFrame
        var g = guideWindow.frame
        g.origin = NSPoint(x: vf.midX - g.width / 2, y: vf.minY + vf.height * 0.32)
        guideWindow.setFrame(LayoutGeometry.clamp(g, into: vf), display: true)
        saveGuideFrame()
        if model.settings.arrangement == .free {
            var p = promptPanel.frame
            p.origin = NSPoint(x: vf.midX - p.width / 2, y: g.maxY + 4)
            promptPanel.setFrame(LayoutGeometry.clamp(p, into: vf), display: true)
            savePromptFrame()
        } else {
            snapPromptToLens()
        }
    }

    // MARK: Sizing

    /// Changes the prompt panel size, keeping its horizontal center and the edge nearest the phone.
    func resizePrompt(width: CGFloat? = nil, height: CGFloat? = nil) {
        let f = promptPanel.frame
        let size = NSSize(width: max(promptPanel.minSize.width, width ?? f.width), height: max(promptPanel.minSize.height, height ?? f.height))
        let screen = promptPanel.screen ?? mainScreen
        promptPanel.setFrame(LayoutGeometry.resized(f, to: size, keeping: model.settings.style.activeEdge, bounds: screen.visibleFrame), display: true)
        savePromptFrame()
    }

    /// Changes the phone outline size around its center.
    func resizeGuide(width: CGFloat? = nil, height: CGFloat? = nil) {
        let f = guideWindow.frame
        let size = NSSize(width: max(160, width ?? f.width), height: max(70, height ?? f.height))
        let screen = guideWindow.screen ?? mainScreen
        guideWindow.setFrame(LayoutGeometry.resized(f, to: size, keeping: .center, bounds: screen.visibleFrame), display: true)
        saveGuideFrame()
        guideView.needsDisplay = true
    }

    func resetGuideToEstimate() {
        let screen = guideWindow.screen ?? mainScreen
        let size = LayoutGeometry.initialPhoneSize(screenWidthPoints: screen.frame.width, screenWidthMM: Screens.physicalWidthMM(screen))
        resizeGuide(width: size.width, height: size.height)
    }

    /// Covers every display with a drawing overlay; the dragged box becomes the phone outline.
    func beginDrawingOutline() {
        guard !isDrawingOutline, !model.settings.layoutLocked else { return }
        for screen in NSScreen.screens {
            let w = KeyableOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = OutlineDrawingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.onFinish = { [weak self] rect in self?.finishDrawingOutline(rect) }
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            drawingWindows.append(w)
        }
        NSApp.activate()
        if let first = drawingWindows.first(where: { $0.screen == (guideWindow.screen ?? mainScreen) }) ?? drawingWindows.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
    }

    func finishDrawingOutline(_ rect: NSRect?) {
        drawingWindows.forEach { $0.orderOut(nil) }
        drawingWindows = []
        guard let rect else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? mainScreen
        guideWindow.setFrame(LayoutGeometry.clamp(rect, into: screen.frame, minSize: NSSize(width: 160, height: 70)), display: true)
        saveGuideFrame()
        guideView.needsDisplay = true
        model.placementMode = true
        if model.settings.arrangement != .free { snapPromptToLens() }
    }

    private func descriptor(for window: NSWindow) -> ScreenDescriptor {
        Screens.descriptor(window.screen ?? mainScreen)
    }

    func savePromptFrame() {
        guard !restoring else { return }
        model.settings.promptFrame = SavedFrame(rect: promptPanel.frame, on: descriptor(for: promptPanel))
    }

    func saveGuideFrame() {
        guard !restoring else { return }
        model.settings.phoneFrame = SavedFrame(rect: guideWindow.frame, on: descriptor(for: guideWindow))
    }

    func makePreset(name: String) -> LayoutPreset {
        let d = descriptor(for: guideWindow)
        return LayoutPreset(name: name, screenID: d.id, screenName: d.name,
                            phoneFrame: SavedFrame(rect: guideWindow.frame, on: d), lensOffset: model.settings.lensOffset,
                            clusterSide: model.settings.clusterSide,
                            promptFrame: SavedFrame(rect: promptPanel.frame, on: descriptor(for: promptPanel)),
                            arrangement: model.settings.arrangement, style: model.settings.style,
                            guideOpacity: model.settings.guideOpacity, locked: model.settings.layoutLocked,
                            clusterAtBottom: model.settings.clusterAtBottom)
    }

    // MARK: Modes

    /// Applies visibility, locking and interactivity. Never moves windows.
    func refresh() {
        let s = model.settings
        let placing = model.placementMode
        // Prompt panel
        if s.promptVisible || placing {
            if !promptPanel.isVisible { promptPanel.orderFrontRegardless() }
        } else if promptPanel.isVisible { promptPanel.orderOut(nil) }
        promptPanel.isMovable = !s.layoutLocked
        if s.layoutLocked { promptPanel.styleMask.remove(.resizable) } else { promptPanel.styleMask.insert(.resizable) }

        // Phone guide: interactive only while placing; otherwise click-through and faded or hidden.
        let showGuide = placing || s.guideVisible
        if showGuide {
            if !guideWindow.isVisible { guideWindow.orderFrontRegardless() }
            guideWindow.alphaValue = placing ? 1 : CGFloat(max(0.05, s.guideOpacity) * 0.6)
        } else if guideWindow.isVisible { guideWindow.orderOut(nil) }
        guideWindow.ignoresMouseEvents = !(placing && !s.layoutLocked)
        guideView.needsDisplay = true
        guideWindow.invalidateCursorRects(for: guideView)
        // Keep the prompt above the guide so text is never hidden by the outline.
        if promptPanel.isVisible { promptPanel.order(.above, relativeTo: guideWindow.windowNumber) }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === promptPanel { savePromptFrame() } else if w === guideWindow { saveGuideFrame() }
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === promptPanel { savePromptFrame() } else if w === guideWindow { saveGuideFrame(); guideView.needsDisplay = true }
    }
}

// MARK: - SwiftUI content of the prompt panel

struct PromptTextRepresentable: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> PromptTextView {
        let v = PromptTextView(frame: .zero)
        v.model = model
        return v
    }
    func updateNSView(_ nsView: PromptTextView, context: Context) { nsView.needsDisplay = true }
}

struct PromptPanelContent: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    private var toolbarAtTop: Bool { model.settings.style.activeEdge != .top }

    var body: some View {
        ZStack {
            PromptTextRepresentable(model: model)
            if model.placementMode {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(.orange)
                    .allowsHitTesting(false)
                if !model.settings.layoutLocked {
                    Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
                    Text("Prompt area — drag to move, drag edges to resize")
                        .font(.caption).padding(4).background(.black.opacity(0.6)).foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
            }
            VStack {
                if !toolbarAtTop { Spacer() }
                HStack {
                    if model.readingMode {
                        ReadingModeBadge(model: model, hovering: hovering)
                    } else if hovering || model.placementMode {
                        PromptToolbar(model: model)
                    }
                    Spacer()
                    RecordingBadge(model: model)
                }
                .padding(6)
                if toolbarAtTop { Spacer() }
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .preferredColorScheme(.dark)
    }
}

struct TrackingDot: View {
    let status: TrackingStatus
    let running: Bool
    let mode: PromptMode
    var color: Color {
        guard running else { return .gray }
        if mode != .speech { return .blue }
        switch status {
        case .following: return .green
        case .listening: return .teal
        case .uncertain: return .yellow
        case .lost: return .red
        case .idle: return .gray
        }
    }
    var label: String {
        guard running else { return "Paused" }
        switch mode {
        case .fixedSpeed: return "Fixed speed (not following voice)"
        case .manual: return "Manual"
        case .speech:
            switch status {
            case .following: return "Following"
            case .listening: return "Listening…"
            case .uncertain: return "Not matching — holding"
            case .lost: return "Lost — click a phrase to resync"
            case .idle: return "Idle"
            }
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tracking status: \(label)")
    }
}

struct PromptToolbar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 2).contentShape(Rectangle()).gesture(WindowDragGesture())
                .help("Drag to move the prompt")
            Button { model.toggleTracking() } label: { Image(systemName: model.promptRunning ? "pause.fill" : "play.fill") }
                .help(model.promptRunning ? "Pause prompt (Space)" : "Start prompt (Space)")
                .disabled(model.promptMode == .manual)
            Button { model.resetToStart() } label: { Image(systemName: "backward.end.fill") }.help("Back to script start")
            Button { model.previousLine() } label: { Image(systemName: "chevron.up") }.help("Previous line (↑)")
            Button { model.nextLine() } label: { Image(systemName: "chevron.down") }.help("Next line (↓)")
            Menu {
                ForEach(PromptMode.allCases, id: \.self) { m in
                    Button { model.setPromptMode(m) } label: { if m == model.promptMode { Label(m.label, systemImage: "checkmark") } else { Text(m.label) } }
                }
            } label: { Image(systemName: "waveform") }.menuStyle(.borderlessButton).frame(width: 34).help("Prompt mode")
            if model.promptMode == .fixedSpeed {
                Button { model.adjustSpeed(-10) } label: { Image(systemName: "tortoise.fill") }.help("Slower")
                Text("\(Int(model.wordsPerMinute))").font(.caption.monospacedDigit()).foregroundStyle(.white)
                Button { model.adjustSpeed(10) } label: { Image(systemName: "hare.fill") }.help("Faster")
            }
            Button { model.settings.style.fontSize = max(14, model.settings.style.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text")
            Button { model.settings.style.fontSize = min(96, model.settings.style.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger text")
            Button { model.readingMode = true } label: { Image(systemName: "eye") }.help("Reading mode (hide controls; Esc to exit)")
            TrackingDot(status: model.trackingStatus, running: model.promptRunning, mode: model.promptMode)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.75), in: Capsule())
    }
}

struct ReadingModeBadge: View {
    @Bindable var model: AppModel
    let hovering: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(TrackingDot(status: model.trackingStatus, running: model.promptRunning, mode: model.promptMode).color)
                .frame(width: 7, height: 7)
            if hovering {
                Button("Show controls") { model.readingMode = false }.buttonStyle(.borderless).font(.caption2)
            }
        }
        .padding(4)
        .background(.black.opacity(hovering ? 0.7 : 0.25), in: Capsule())
        .opacity(hovering ? 1 : 0.6)
        .help("Reading mode — hover and click Show controls, or press Esc")
    }
}

struct RecordingBadge: View {
    @Bindable var model: AppModel
    var body: some View {
        switch model.takes.state {
        case .recording(let start):
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC \(formatDuration(ctx.date.timeIntervalSince(start)))").font(.caption.monospacedDigit().bold())
                }
                .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red.opacity(0.35), in: Capsule())
            }
            .accessibilityLabel("Recording")
        case .countdown(let n):
            Text("\(n)").font(.title2.bold()).foregroundStyle(.white).padding(.horizontal, 8)
                .background(.orange.opacity(0.6), in: Capsule())
        default: EmptyView()
        }
    }
}

func formatDuration(_ s: Double) -> String {
    let t = max(0, Int(s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
