import SwiftUI
import AVKit
import LensPromptCore

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            VStack(spacing: 0) {
                if let banner = model.banner { BannerView(model: model, banner: banner) }
                RecordingBar(model: model)
                Divider()
                VSplitView {
                    if !model.settings.previewHidden {
                        PreviewPane(model: model).frame(minHeight: 160, idealHeight: 340)
                    }
                    ScriptEditorPane(model: model).frame(minHeight: 140)
                }
                Divider()
                TakesStrip(model: model)
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 780, minHeight: 560)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showRecordings) { RecordingsBrowser(model: model) }
    }
}

// MARK: - Banner

struct BannerView: View {
    let model: AppModel
    let banner: Banner
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.isError ? .yellow : .blue)
            Text(banner.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            ForEach(banner.actions, id: \.self) { a in
                Button(title(a)) { model.perform(a) }
            }
            Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
        }
        .padding(10)
        .background(banner.isError ? Color.red.opacity(0.18) : Color.blue.opacity(0.15))
    }
    func title(_ a: BannerAction) -> String {
        switch a {
        case .openCameraSettings: return "Camera Settings…"
        case .openMicrophoneSettings: return "Microphone Settings…"
        case .reconnect: return "Reconnect"
        case .chooseFolder: return "Choose Folder…"
        case .downloadSpeech: return "Enable Speech Model"
        case .dismiss: return "OK"
        }
    }
}

// MARK: - Recording bar

struct RecordingBar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: recordIcon).foregroundStyle(model.takes.state.isRecording ? .white : .red)
                    Text(recordTitle).bold()
                }
                .frame(minWidth: 150)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.takes.state.isRecording ? .red : .gray.opacity(0.5))
            .disabled(isTransitioning)
            .help("Start/stop recording (⇧⌘R)")
            .accessibilityLabel(recordTitle)

            stateView
            Spacer()
            Toggle("3-second countdown", isOn: $model.settings.countdownEnabled).toggleStyle(.checkbox)
                .disabled(model.takes.state.isBusy)
            Toggle(isOn: Binding(get: { !model.settings.previewHidden }, set: { model.settings.previewHidden = !$0 })) {
                Text("Show preview")
            }
            .toggleStyle(.checkbox)
            .help("Hiding the preview never stops capture or recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var isTransitioning: Bool {
        switch model.takes.state { case .preparing, .stopping: return true; default: return false }
    }
    private var recordIcon: String {
        switch model.takes.state {
        case .recording: return "stop.fill"
        case .countdown: return "xmark"
        default: return "record.circle"
        }
    }
    private var recordTitle: String {
        switch model.takes.state {
        case .recording: return "Stop Recording"
        case .countdown: return "Cancel Countdown"
        case .preparing: return "Preparing…"
        case .stopping: return "Saving…"
        default: return "Record"
        }
    }

    @ViewBuilder private var stateView: some View {
        switch model.takes.state {
        case .recording(let start):
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    Text("RECORDING  \(formatDuration(ctx.date.timeIntervalSince(start)))")
                        .font(.headline.monospacedDigit()).foregroundStyle(.red)
                }
            }
            .accessibilityLabel("Recording in progress")
        case .countdown(let n):
            Text("Starting in \(n)… (Esc cancels)").font(.headline).foregroundStyle(.orange)
        case .preparing: ProgressView().controlSize(.small); Text("Checking camera, microphone and folder…").foregroundStyle(.secondary)
        case .stopping: ProgressView().controlSize(.small); Text("Finalizing the movie file…").foregroundStyle(.secondary)
        case .saved(let take):
            Label("Saved \(take.fileName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
        case .failed(let msg, _):
            Label(msg, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(msg)
        case .idle:
            Text(model.cameraHealth.isLive ? "Ready to record" : model.cameraHealth.label).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @Bindable var model: AppModel
    var body: some View {
        ZStack {
            Color.black
            if !model.captureDisabled {
                CameraPreview(session: model.capture.session, mirrored: model.settings.previewMirrored)
            }
            if model.settings.showFramingGuides { FramingGuides(aspect: videoAspect) }
            if !model.cameraHealth.isLive {
                Color.black.opacity(0.65)
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(model.cameraHealth.label).font(.headline)
                    Text(guidance).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                    if !model.captureDisabled { Button("Reconnect") { model.reconnect() }.disabled(model.inputsLocked) }
                }
                .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                if model.settings.previewMirrored { Text("Preview mirrored — recording is not").font(.caption2).padding(3).background(.black.opacity(0.6)) }
            }
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack {
                Toggle("Mirror preview", isOn: $model.settings.previewMirrored).toggleStyle(.checkbox)
                Toggle("Framing grid", isOn: $model.settings.showFramingGuides).toggleStyle(.checkbox)
                    .help("Show a rule-of-thirds grid in the preview only")
            }
            .font(.caption).padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6)).padding(6)
        }
        .accessibilityElement(children: .contain)
    }

    private var videoAspect: CGFloat {
        let parts = model.videoFormatText.split(separator: " ").first?.split(separator: "×").compactMap { Double($0) } ?? []
        return parts.count == 2 && parts[1] > 0 ? CGFloat(parts[0] / parts[1]) : 16.0 / 9.0
    }

    private var guidance: String {
        switch model.cameraHealth {
        case .missing, .noneSelected:
            return "Bring the iPhone close to the Mac, lock it in landscape on the tripod with its rear camera facing you, and make sure both use the same Apple Account with Wi-Fi and Bluetooth on (or connect a USB cable). Then choose it under Camera."
        case .stalled, .suspended:
            return "The iPhone may have been moved, locked, picked up, or taken a call. Put it back on the stand and choose Reconnect."
        case .inUse: return "Quit the other app that is using the camera (for example Photo Booth or FaceTime), then choose Reconnect."
        case .denied: return "Open System Settings › Privacy & Security › Camera and allow LensPrompt."
        case .disabled: return "Relaunch without --no-capture to use the camera."
        default: return ""
        }
    }
}

// MARK: - Script editor

struct ScriptEditorPane: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Script").font(.headline)
                if let name = model.scriptFileName { Text(name).foregroundStyle(.secondary).font(.caption) }
                Spacer()
                let _ = model.documentVersion
                Text("\(model.document.wordCount) words · position \(min(model.promptPositionCoarse, model.document.tokens.count))/\(model.document.tokens.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Open…") { model.openScript() }.help("Open a UTF-8 text or Markdown file (⌘O)")
            }
            TextEditor(text: $model.scriptText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .background(Color(white: 0.1))
                .accessibilityLabel("Script editor")
            Text("Autosaved. Markdown is shown as plain text. Click a phrase in the prompt to resume from there.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

// MARK: - Takes

struct TakesStrip: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if let take = model.takes.takes.first {
                Image(systemName: take.status == .complete ? "film" : "exclamationmark.triangle").foregroundStyle(take.status == .complete ? Color.secondary : Color.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(take.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text("\(formatDuration(take.duration)) · \(statusText(take)) · saved in \(take.fileURL.deletingLastPathComponent().lastPathComponent)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Play") { PlayerWindows.open(take.fileURL) }.disabled(!exists(take))
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.fileURL]) }.disabled(!exists(take))
                if case .saved = model.takes.state { Button("Another Take") { model.anotherTake() } }
                if case .failed = model.takes.state { Button("Another Take") { model.anotherTake() } }
            } else {
                Text("No takes yet. Recordings are saved to \(model.outputFolder.path).").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Recordings…") { model.openRecordings() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    func exists(_ t: TakeRecord) -> Bool { FileManager.default.fileExists(atPath: t.fileURL.path) }
}

func statusText(_ t: TakeRecord) -> String {
    switch t.status {
    case .complete: return "complete"
    case .interrupted: return "interrupted — \(t.note ?? "")"
    case .incomplete: return "incomplete, may not play"
    }
}

@MainActor
enum PlayerWindows {
    private static var windows: [NSWindow] = []
    static func open(_ url: URL) {
        let player = AVPlayer(url: url)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                player.pause()
                windows.removeAll { $0 === w }
            }
        }
        player.play()
    }
}
