import SwiftUI
import AVKit
import LensPromptCore

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 280)
            VStack(spacing: 0) {
                if let banner = model.banner { BannerView(model: model, banner: banner) }
                RecordingBar(model: model)
                Divider()
                GeometryReader { geometry in
                    if !model.settings.previewHidden && geometry.size.width >= 900 {
                        HSplitView {
                            ScriptEditorPane(model: model).frame(minWidth: 360, idealWidth: 520)
                            VStack(spacing: 14) {
                                HStack {
                                    Text("Camera preview").font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(model.videoFormatText).font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
                                }
                                let preview = PreviewPane(model: model)
                                preview.aspectRatio(preview.videoAspect, contentMode: .fit)
                                Spacer(minLength: 0)
                            }
                            .padding(24)
                            .frame(minWidth: 360, idealWidth: 520, maxHeight: .infinity, alignment: .top)
                        }
                    } else {
                        VSplitView {
                            if !model.settings.previewHidden {
                                PreviewPane(model: model).frame(minHeight: 180, idealHeight: 300)
                                    .padding(.horizontal, 24).padding(.vertical, 18)
                            }
                            ScriptEditorPane(model: model).frame(minHeight: 140)
                        }
                    }
                }
                Divider()
                TakesStrip(model: model)
            }
            .frame(minWidth: 520)
            .background(StudioTheme.workspace)
        }
        .frame(minWidth: 820, minHeight: 620)
        .font(.system(size: 12))
        .foregroundStyle(StudioTheme.text)
        .tint(StudioTheme.accent)
        .controlSize(.small)
        .background(StudioTheme.workspace)
        .background(StudioWindowChrome())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showRecordings) { RecordingsBrowser(model: model) }
        .sheet(isPresented: $model.showStudioSettings) { StudioSettingsView(model: model) }
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.scriptFileName ?? "Untitled script").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                Text("Recording studio").font(.system(size: 20, weight: .semibold))
            }
            Spacer(minLength: 12)
            stateView.font(.system(size: 11))
            Button { model.toggleRecording() } label: {
                Label(recordTitle, systemImage: recordIcon)
                    .frame(minWidth: 98)
                    .padding(.vertical, 2)
            }
            .buttonStyle(StudioButtonStyle(prominent: true, destructive: model.takes.state.isRecording))
            .disabled(isTransitioning)
            .help("Start/stop recording (⇧⌘R)")
            .accessibilityLabel(recordTitle)
            Menu {
                Toggle("3-second countdown", isOn: $model.settings.countdownEnabled).disabled(model.takes.state.isBusy)
                Toggle("Show camera preview", isOn: Binding(get: { !model.settings.previewHidden }, set: { model.settings.previewHidden = !$0 }))
                Divider()
                Button("Studio settings…") { model.showStudioSettings = true }
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(StudioTheme.secondary) }
            .menuStyle(.borderlessButton).frame(width: 20).help("Studio options")
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
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
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("RECORDING  \(formatDuration(ctx.date.timeIntervalSince(start)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.red)
                }
            }
            .accessibilityLabel("Recording in progress")
        case .countdown(let n):
            Text("Starting in \(n)… (Esc cancels)").font(.headline).foregroundStyle(.orange)
        case .preparing: ProgressView().controlSize(.small); Text("Checking camera, microphone and folder…").foregroundStyle(.secondary)
        case .stopping: ProgressView().controlSize(.small); Text("Finalizing the movie file…").foregroundStyle(.secondary)
        case .saved(let take):
            Label("Take saved", systemImage: "checkmark.circle").foregroundStyle(StudioTheme.secondary).lineLimit(1).help(take.fileName)
        case .failed(let msg, _):
            Label(msg, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(msg)
        case .idle:
            Text(model.cameraHealth.isLive ? "Ready to record" : model.cameraHealth.label).foregroundStyle(StudioTheme.secondary).lineLimit(1)
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
                HStack(spacing: 5) {
                    Circle().fill(model.cameraHealth.isLive ? Color.green : Color.orange).frame(width: 5, height: 5)
                    Text(model.cameraHealth.isLive ? "LIVE PREVIEW" : "CAMERA").font(.system(size: 9, weight: .medium)).tracking(0.7)
                }.padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack {
                StudioIconToggle(title: "Mirror", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $model.settings.previewMirrored)
                    .help("Mirror the preview only; recordings are unchanged")
                StudioIconToggle(title: "Grid", icon: "grid", isOn: $model.settings.showFramingGuides)
                    .help("Rule-of-thirds framing grid; preview only")
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border))
        .accessibilityElement(children: .contain)
    }

    var videoAspect: CGFloat {
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "text.alignleft").foregroundStyle(StudioTheme.secondary)
                Text("Script").font(.system(size: 13, weight: .medium))
                if let name = model.scriptFileName { Text(name).foregroundStyle(StudioTheme.secondary).lineLimit(1) }
                Spacer()
                let _ = model.documentVersion
                Text("\(model.document.wordCount) words").font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
                Button { model.openScript() } label: { Label("Open", systemImage: "arrow.up.doc") }
                    .buttonStyle(StudioButtonStyle()).help("Open script (⌘O)")
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            TextEditor(text: $model.scriptText)
                .font(.system(size: 15, weight: .regular)).lineSpacing(7)
                .foregroundStyle(StudioTheme.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 22).padding(.vertical, 8)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Script editor")
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9))
                Text("Saved locally").font(.system(size: 10))
                Spacer()
                Text("UTF-8 · Plain text").font(.system(size: 10))
            }.foregroundStyle(StudioTheme.secondary).padding(.horizontal, 24).padding(.vertical, 10)
        }.background(StudioTheme.workspace)
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
                    Text(take.fileName).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(formatDuration(take.duration)) · \(statusText(take)) · saved in \(take.fileURL.deletingLastPathComponent().lastPathComponent)")
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                }
                Spacer()
                Button("Preview", systemImage: "play") { PlayerWindows.open(take.fileURL) }.disabled(!exists(take))
                Button { NSWorkspace.shared.activateFileViewerSelecting([take.fileURL]) } label: { Image(systemName: "folder") }.help("Reveal in Finder").disabled(!exists(take))
                if case .saved = model.takes.state { Button("Another Take") { model.anotherTake() } }
                if case .failed = model.takes.state { Button("Another Take") { model.anotherTake() } }
            } else {
                Text("No takes yet. Recordings are saved to \(model.outputFolder.path).").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Recordings…") { model.openRecordings() }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .buttonStyle(StudioButtonStyle())
        .background(StudioTheme.surface)
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
