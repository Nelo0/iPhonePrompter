import SwiftUI
import AppKit
import LensPromptCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CameraSection(model: model)
                MicrophoneSection(model: model)
                OutputSection(model: model)
                PromptSection(model: model)
                PlacementSection(model: model)
                SpeechSection(model: model)
            }
            .padding(12)
        }
        .background(Color(white: 0.08))
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Camera

struct CameraSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Camera", systemImage: "camera") {
            Picker("Camera", selection: Binding(get: { model.settings.cameraID ?? "" }, set: { model.selectCamera($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.cameras) { c in
                    Text(c.isContinuityCamera ? "\(c.name) (iPhone)" : c.name).tag(c.id)
                }
                if model.selectedCameraMissing, let id = model.settings.cameraID {
                    Text("\(model.settings.cameraName ?? "Saved camera") — not connected").tag(id)
                }
            }
            .labelsHidden()
            .disabled(model.inputsLocked || model.captureDisabled)
            HStack(spacing: 6) {
                Circle().fill(model.cameraHealth.isLive ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(model.cameraHealth.label).font(.caption).lineLimit(2)
            }
            LabeledContent("Format", value: model.videoFormatText).font(.caption)
            if let note = model.formatNote { Text(note).font(.caption2).foregroundStyle(.orange) }
            if model.inputsLocked { Text("Inputs are locked while a take is in progress.").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh") { model.refreshDevices() }.disabled(model.inputsLocked || model.captureDisabled)
                Button("Reconnect") { model.reconnect() }.disabled(model.inputsLocked || model.captureDisabled)
            }
            .controlSize(.small)
            Toggle("Show framing grid", isOn: $model.settings.showFramingGuides)
                .toggleStyle(.checkbox)
                .help("Rule-of-thirds grid for framing. Visible in the preview only; saved video stays clean.")
            Text("Grid appears in the preview only, not in recordings.")
                .font(.caption2).foregroundStyle(.secondary)
            if !model.cameras.contains(where: \.isContinuityCamera) && !model.captureDisabled {
                Text("No iPhone found. Continuity Camera needs the iPhone nearby, on the same Apple Account, with Wi-Fi and Bluetooth on, or connected by USB.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Continuity Camera chooses the iPhone lens; LensPrompt cannot select individual lenses.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Microphone

struct LevelMeter: View {
    let meter: LevelMeterModel
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * LevelMeterModel.fraction(meter.rmsDB))
                Rectangle().fill(.white).frame(width: 2)
                    .offset(x: max(0, w * LevelMeterModel.fraction(meter.heldPeakDB) - 2))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(meter.rmsDB)) decibels")
    }
}

struct MicrophoneSection: View {
    @Bindable var model: AppModel
    var body: some View {
        SectionBox(title: "Microphone", systemImage: "mic") {
            Picker("Microphone", selection: Binding(get: { model.settings.microphoneID ?? "" }, set: { model.selectMicrophone($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.microphones) { m in Text(m.name).tag(m.id) }
                if model.selectedMicrophoneMissing, let id = model.settings.microphoneID {
                    Text("\(model.settings.microphoneName ?? "Saved microphone") — not connected").tag(id)
                }
            }
            .labelsHidden()
            .disabled(model.inputsLocked || model.captureDisabled)
            Text("Input format: \(model.micFormatText)").font(.caption).foregroundStyle(.secondary)
            LevelMeter(meter: model.meter)
            HStack {
                Text(String(format: "RMS %.0f dB · peak %.0f dB", model.meter.rmsDB, model.meter.heldPeakDB))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if model.meter.clipping { Text("CLIPPING").font(.caption.bold()).foregroundStyle(.red) }
            }
            Group {
                if model.selectedMicrophoneMissing {
                    Text("\(model.settings.microphoneName ?? "The selected microphone") is not connected. LensPrompt will not substitute another microphone — reconnect it or choose one above.")
                        .foregroundStyle(.orange)
                } else {
                    switch model.micHealth {
                    case .noInput: Text(model.settings.microphoneID == nil ? "Select the microphone to record with." : "No audio is arriving from this microphone.").foregroundStyle(.orange)
                    case .silent: Text("Signal is near silence — check the mic is on and not muted.").foregroundStyle(.yellow)
                    case .ok: Text("Receiving microphone audio").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("The same microphone feeds the recording and speech following.").font(.caption2).foregroundStyle(.secondary)
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
        SectionBox(title: "Prompt", systemImage: "text.alignleft") {
            Picker("Mode", selection: Binding(get: { model.promptMode }, set: { model.setPromptMode($0) })) {
                ForEach(PromptMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Button(model.promptRunning ? "Pause" : "Start") { model.toggleTracking() }
                    .disabled(model.promptMode == .manual)
                Button("Back to Start") { model.resetToStart() }
                Spacer()
                TrackingDot(status: model.trackingStatus, running: model.promptRunning, mode: model.promptMode)
            }
            .controlSize(.small)
            if model.promptMode == .fixedSpeed {
                HStack {
                    Text("Speed").font(.caption)
                    Slider(value: Binding(get: { model.scrollPointsPerSecond }, set: { model.setScrollSpeed($0) }), in: 5...150, step: 1)
                    Text("\(Int(model.scrollPointsPerSecond)) pt/s").font(.caption.monospacedDigit()).frame(width: 60)
                }
            }
            if model.promptMode == .manual {
                Text("Use ↑/↓ or the scroll wheel over the prompt to move line by line.").font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Show prompt panel", isOn: $model.settings.promptVisible)
            Toggle("Reading mode (hide prompt controls)", isOn: $model.readingMode)
            DisclosureGroup("Appearance") {
                slider("Text size", $model.settings.style.fontSize, 14...96, "%.0f pt")
                slider("Line spacing", $model.settings.style.lineSpacing, 0...40, "%.0f pt")
                slider("Background", $model.settings.style.backgroundOpacity, 0.2...1, "%.0f%%", scale: 100)
                slider("Active-line emphasis", $model.settings.style.activeLineEmphasis, 0...1, "%.0f%%", scale: 100)
                slider("Edge margin", $model.settings.style.edgeInset, 0...200, "%.0f pt")
                if model.promptMode == .speech {
                    Text("The current line stays at the top, with upcoming lines below. Completed lines are hidden.")
                        .foregroundStyle(.secondary)
                } else if model.settings.style.activeEdge == .bottom {
                    Stepper("Upcoming lines below active line: \(model.settings.style.upcomingLinesBelow)",
                            value: $model.settings.style.upcomingLinesBelow, in: 0...3)
                }
                if model.promptMode != .speech {
                Picker("Active line at", selection: $model.settings.style.activeEdge) {
                    Text("Top").tag(ActiveLineEdge.top)
                    Text("Center").tag(ActiveLineEdge.center)
                    Text("Bottom").tag(ActiveLineEdge.bottom)
                }
                .pickerStyle(.segmented)
                }
            }
            .font(.caption)
        }
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String, scale: Double = 1) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue * scale)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
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
            Text("The outline shows where to put the real phone; it is approximate and does not detect the phone. Near-lens text reduces, but cannot eliminate, gaze offset.")
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
            Text("Recognition runs on this Mac (Apple SpeechAnalyzer). Audio and scripts are not uploaded, and transcripts are not stored.")
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
