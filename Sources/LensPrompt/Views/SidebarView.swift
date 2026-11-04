import SwiftUI
import AppKit
import LensPromptCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "viewfinder").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 30, height: 30).background(StudioTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text("iPhonePrompter").font(.system(size: 14, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
            VStack(spacing: 4) {
                SidebarItem(title: "Recording studio", icon: "video", selected: !model.showRecordings) {}
                SidebarItem(title: "Recordings", icon: "film.stack", selected: model.showRecordings) { model.openRecordings() }
            }.padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    CameraSection(model: model)
                    MicrophoneSection(model: model)
                    sidebarHeading("Teleprompter").padding(.top, 8)
                    PromptSection(model: model)
                }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 14)
            }.scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 4) {
                sidebarHeading("Setup").padding(.top, 8)
                SidebarItem(title: "Phone placement", icon: "iphone.gen3.landscape", selected: false) { settings(.placement) }
                SidebarItem(title: "Studio settings", icon: "slider.horizontal.3", selected: false) { settings(.teleprompter) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider().overlay(StudioTheme.border)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text("Private. On your Mac.").font(.system(size: 11))
                Spacer()
                Text("0.1").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(StudioTheme.secondary).padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(StudioTheme.sidebar)
    }
    private func settings(_ tab: StudioSettingsTab) { model.studioSettingsTab = tab; model.showStudioSettings = true }
    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).tracking(1.1)
            .textCase(.uppercase).foregroundStyle(StudioTheme.secondary).padding(.horizontal, 8).padding(.bottom, 3)
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? StudioTheme.text : StudioTheme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(selected ? 0.065 : hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.secondary)
            content
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CameraSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Camera", systemImage: "video") {
            HStack(spacing: 5) {
                Picker("Camera", selection: Binding(get: { model.settings.cameraID ?? "" }, set: { model.selectCamera($0.isEmpty ? nil : $0) })) {
                    Text("Select camera").tag("")
                    ForEach(model.cameras) { c in Text(c.name).tag(c.id) }
                    if model.selectedCameraMissing, let id = model.settings.cameraID {
                        Text("\(model.settings.cameraName ?? "Camera") · offline").tag(id)
                    }
                }.labelsHidden().disabled(model.inputsLocked || model.captureDisabled)
                Menu {
                    Button("Refresh devices") { model.refreshDevices() }
                    Button("Reconnect camera") { model.reconnect() }
                    Divider()
                    Text("Continuity Camera selects the iPhone lens.")
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 18)
                .disabled(model.inputsLocked || model.captureDisabled).help("Camera options")
            }
            HStack(spacing: 5) {
                Circle().fill(model.cameraHealth.isLive ? Color.green.opacity(0.8) : Color.orange).frame(width: 5, height: 5)
                Text(model.cameraHealth.isLive ? "Connected" : model.cameraHealth.label).lineLimit(2)
                Spacer(minLength: 2)
                if model.cameraHealth.isLive { Text(model.videoFormatText.replacingOccurrences(of: " @ ", with: " · ")).lineLimit(1).minimumScaleFactor(0.8) }
            }.font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
            if let note = model.formatNote { Text(note).font(.caption2).foregroundStyle(.orange) }
        }
    }
}

struct LevelMeter: View {
    let meter: LevelMeterModel
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(meter.clipping ? Color.red : Color.green.opacity(0.7))
                    .frame(width: geo.size.width * LevelMeterModel.fraction(meter.rmsDB))
                Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1)
                    .offset(x: max(0, geo.size.width * LevelMeterModel.fraction(meter.heldPeakDB) - 1))
            }
        }.frame(height: 4)
        .accessibilityLabel("Microphone level").accessibilityValue("\(Int(meter.rmsDB)) decibels")
    }
}

struct MicrophoneSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Microphone", systemImage: "mic") {
            Picker("Microphone", selection: Binding(get: { model.settings.microphoneID ?? "" }, set: { model.selectMicrophone($0.isEmpty ? nil : $0) })) {
                Text("Select microphone").tag("")
                ForEach(model.microphones) { Text($0.name).tag($0.id) }
                if model.selectedMicrophoneMissing, let id = model.settings.microphoneID {
                    Text("\(model.settings.microphoneName ?? "Microphone") · offline").tag(id)
                }
            }.labelsHidden().disabled(model.inputsLocked || model.captureDisabled)
            LevelMeter(meter: model.meter)
            HStack {
                Text(model.micFormatText)
                Spacer()
                Text(model.meter.clipping ? "Clipping" : String(format: "%.0f dB", model.meter.heldPeakDB))
                    .foregroundStyle(model.meter.clipping ? Color.red : StudioTheme.secondary)
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
            if model.selectedMicrophoneMissing || model.micHealth == .noInput {
                Text(model.selectedMicrophoneMissing ? "Microphone disconnected" : "Waiting for microphone audio")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: Output and sync

struct OutputSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Recording", systemImage: "externaldrive") {
            Text(model.outputFolder.path).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack {
                Button("Choose Folder…") { model.chooseOutputFolder() }.disabled(model.takes.state.isBusy)
                Button("Show") { NSWorkspace.shared.open(model.outputFolder) }
            }
            .controlSize(.small)
            Divider()
            Text("Audio sync offset").font(.subheadline)
            HStack {
                Slider(value: Binding(get: { Double(model.settings.audioOffsetMs) },
                                      set: { model.settings.audioOffsetMs = Int(($0 / 10).rounded() * 10) }),
                       in: -1000...1000)
                    .disabled(model.takes.state.isBusy)
                Stepper("", value: $model.settings.audioOffsetMs, in: -1000...1000, step: 10).labelsHidden()
                    .disabled(model.takes.state.isBusy)
            }
            HStack {
                Text("\(model.settings.audioOffsetMs > 0 ? "+" : "")\(model.settings.audioOffsetMs) ms").font(.caption.monospacedDigit())
                Spacer()
                Button("Reset to 0") { model.settings.audioOffsetMs = 0 }.controlSize(.small).disabled(model.takes.state.isBusy)
            }
            Text("Positive values delay the audio relative to the video. Use a clap test: if the clap sound comes before the hands meet, increase the value.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Prompt

struct PromptSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Prompt mode", selection: Binding(get: { model.promptMode }, set: { model.setPromptMode($0) })) {
                Text("Voice").tag(PromptMode.speech)
                Text("Fixed").tag(PromptMode.fixedSpeed)
                Text("Manual").tag(PromptMode.manual)
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 8) {
                Button { model.toggleTracking() } label: {
                    Label(model.promptRunning ? "Pause" : "Start prompt", systemImage: model.promptRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(StudioButtonStyle()).disabled(model.promptMode == .manual)
                Button { model.resetToStart() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(StudioButtonStyle()).help("Back to script start").accessibilityLabel("Reset prompt")
            }
            TrackingDot(status: model.trackingStatus, running: model.promptRunning, mode: model.promptMode)
            if model.promptMode == .fixedSpeed {
                HStack {
                    Slider(value: Binding(get: { model.scrollPointsPerSecond }, set: { model.setScrollSpeed($0) }), in: 5...150, step: 1)
                    Text("\(Int(model.scrollPointsPerSecond)) pt/s").font(.system(size: 10, design: .monospaced)).frame(width: 48)
                }
            }
            Toggle("Floating prompt", isOn: $model.settings.promptVisible)
            Toggle("Focus mode", isOn: $model.readingMode).help("Hide floating prompt controls while reading")
            if model.promptMode == .speech && model.speechAvailability != .ready {
                Text(model.speechAvailability.label).font(.system(size: 10)).foregroundStyle(.orange)
                if model.speechAvailability == .needsDownload {
                    Button("Enable voice following") { model.downloadSpeechModel() }.buttonStyle(StudioButtonStyle())
                }
            }
            if model.promptRunning && model.promptMode == .speech && !model.lastHeardText.isEmpty {
                Text(model.lastHeardText).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                    .lineLimit(3).help("Most recently recognized words")
            }
        }.font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).padding(.horizontal, 8).padding(.vertical, 8)
    }
}

struct PromptAppearanceSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Text & appearance", systemImage: "textformat") {
            slider("Text size", $model.settings.style.fontSize, 14...96, "%.0f pt")
            slider("Line spacing", $model.settings.style.lineSpacing, 0...40, "%.0f pt")
            slider("Background", $model.settings.style.backgroundOpacity, 0.2...1, "%.0f%%", scale: 100)
            slider("Line emphasis", $model.settings.style.activeLineEmphasis, 0...1, "%.0f%%", scale: 100)
            slider("Edge margin", $model.settings.style.edgeInset, 0...200, "%.0f pt")
            if model.promptMode == .speech {
                Text("Your current line stays at the top. Upcoming text appears below.").font(.caption).foregroundStyle(StudioTheme.secondary)
            } else {
                Picker("Active line", selection: $model.settings.style.activeEdge) {
                    Text("Top").tag(ActiveLineEdge.top)
                    Text("Center").tag(ActiveLineEdge.center)
                    Text("Bottom").tag(ActiveLineEdge.bottom)
                }.pickerStyle(.segmented)
                if model.settings.style.activeEdge == .bottom {
                    Stepper("Upcoming lines: \(model.settings.style.upcomingLinesBelow)", value: $model.settings.style.upcomingLinesBelow, in: 0...3)
                }
            }
        }
    }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String, scale: Double = 1) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 12)).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * scale)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(StudioTheme.secondary).frame(width: 48, alignment: .trailing)
        }.padding(.vertical, 4)
    }
}

// MARK: Placement

struct PlacementSection: View {
    @Bindable var model: AppModel
    @State private var presetName = ""
    var body: some View {
        SectionBox(title: "Phone placement", systemImage: "iphone.gen3.landscape") {
            Toggle("Placement mode", isOn: $model.placementMode)
                .help("Drag the outline, lens target and prompt into place (Esc to exit)")
            Picker("Layout", selection: Binding(get: { model.settings.arrangement }, set: {
                model.settings.arrangement = $0
                model.panels?.snapPromptToLens()
            })) {
                ForEach(PhoneArrangement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Text("Phone orientation").font(.subheadline)
            Text("Camera cluster: \(model.settings.orientation.label)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Rotate 180°") { model.rotatePhone180() }
                    .help("Use when the phone is mounted the other way up: the camera moves to the opposite corner")
                Button("Flip sides") { model.flipPhoneSides() }
                    .help("Moves the camera cluster to the other end of the phone")
            }
            .controlSize(.small)
            .disabled(model.settings.layoutLocked)
            Divider()
            Text("Phone size on screen").font(.subheadline)
            Button("Draw phone outline…") { model.panels?.beginDrawingOutline() }
                .disabled(model.settings.layoutLocked)
                .help("Drag a box on the screen exactly where the real iPhone covers it (Esc cancels)")
            SizeRow(label: "Width", value: Double(model.settings.phoneFrame?.width ?? 520), range: 160...2000) {
                model.panels?.resizeGuide(width: $0)
            }
            .disabled(model.settings.layoutLocked)
            SizeRow(label: "Height", value: Double(model.settings.phoneFrame?.height ?? 250), range: 70...1000) {
                model.panels?.resizeGuide(height: $0)
            }
            .disabled(model.settings.layoutLocked)
            Button("Reset to iPhone 15 Pro Max estimate") { model.panels?.resetGuideToEstimate() }
                .controlSize(.small).disabled(model.settings.layoutLocked)
            Divider()
            Text("Text box size").font(.subheadline)
            SizeRow(label: "Width", value: Double(model.settings.promptFrame?.width ?? 640), range: 220...2400) {
                model.panels?.resizePrompt(width: $0)
            }
            .disabled(model.settings.layoutLocked)
            SizeRow(label: "Height", value: Double(model.settings.promptFrame?.height ?? 170), range: 70...1200) {
                model.panels?.resizePrompt(height: $0)
            }
            .disabled(model.settings.layoutLocked)
            Divider()
            Button("Place text beside lens") { model.panels?.snapPromptToLens() }
                .disabled(model.settings.arrangement == .free || model.settings.layoutLocked)
                .help("Moves the prompt so its active line sits just above (or below) the lens target")
            Toggle("Show phone outline", isOn: $model.settings.guideVisible)
            HStack {
                Text("Outline opacity").font(.caption)
                Slider(value: $model.settings.guideOpacity, in: 0.05...1)
            }
            Toggle("Lock layout", isOn: $model.settings.layoutLocked)
            Menu("Move to display") {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Button(screen.localizedName) { model.panels?.move(to: screen) }
                }
            }
            .disabled(model.settings.layoutLocked)
            Divider()
            Text("Presets").font(.subheadline)
            HStack {
                TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                Button("Save") {
                    let n = presetName.trimmingCharacters(in: .whitespaces)
                    model.savePreset(named: n.isEmpty ? "Layout \(model.presets.count + 1)" : n)
                    presetName = ""
                }
            }
            ForEach(model.presets) { p in
                HStack {
                    Button(p.name) { model.applyPreset(p) }.buttonStyle(.link)
                    Text(p.screenName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { model.deletePreset(p) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete preset")
                }
            }
            Text("Use the outline to restore your phone position. Align the lens marker, then place the text beside it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Speech

struct SpeechSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Speech following", systemImage: "waveform") {
            Text(model.speechAvailability.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(model.speechAvailability == .ready ? Color.secondary : Color.orange)
            if model.speechAvailability == .needsDownload {
                Button("Enable English speech model") { model.downloadSpeechModel() }.controlSize(.small)
            }
            if case .downloading(let p) = model.speechAvailability { ProgressView(value: p) }
            if let l = model.recognitionLatency, model.speechRunning {
                Text(String(format: "Recognition lag ≈ %.2f s", l)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.speechRunning && model.promptRunning {
                Text(model.lastHeardText.isEmpty ? "Waiting for recognized words…" : "Heard: \(model.lastHeardText)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Speech recognition: \(model.lastHeardText.isEmpty ? "waiting for words" : model.lastHeardText)")
            }
            Text("Voice recognition runs locally. Audio and scripts stay on this Mac.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// Slider + stepper for a size in points, applied live.
struct SizeRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let apply: (CGFloat) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { apply(CGFloat($0.rounded())) }), in: range)
            Stepper("", value: Binding(get: { value }, set: { apply(CGFloat($0)) }), in: range, step: 2).labelsHidden()
            Text("\(Int(value)) pt").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
