import Foundation
import AppKit
import AVFoundation
import Observation
import QuartzCore
import LensPromptCore

enum CameraHealth: Equatable {
    case disabled              // --no-capture
    case denied
    case noneSelected
    case missing(String)
    case starting
    case live
    case stalled
    case suspended
    case inUse

    var label: String {
        switch self {
        case .disabled: return "Capture disabled for this launch (--no-capture)"
        case .denied: return "Camera access is denied"
        case .noneSelected: return "No camera selected"
        case .missing(let n): return "\(n) is not available"
        case .starting: return "Starting camera…"
        case .live: return "Live"
        case .stalled: return "No video frames — the camera stopped sending video"
        case .suspended: return "Camera suspended (iPhone moved, locked, or in a call)"
        case .inUse: return "Camera is in use by another app"
        }
    }
    var isLive: Bool { self == .live }
}

enum BannerAction: Equatable {
    case openCameraSettings, openMicrophoneSettings, reconnect, chooseFolder, downloadSpeech, dismiss
}

struct Banner: Equatable, Identifiable {
    var id = UUID()
    var message: String
    var isError: Bool
    var actions: [BannerAction] = []
}

@MainActor
@Observable
final class AppModel {
    let store = LocalStore()
    @ObservationIgnored let capture = CaptureService()
    @ObservationIgnored let engine: CaptureRecordingEngine
    let takes: TakeController
    let captureDisabled: Bool

    var settings: AppSettings { didSet { scheduleSettingsSave(); panels?.refresh() } }
    var presets: [LayoutPreset] = []

    // Devices
    var cameras: [DeviceInfo] = []
    var microphones: [DeviceInfo] = []
    var cameraAuth: AVAuthorizationStatus = .notDetermined
    var micAuth: AVAuthorizationStatus = .notDetermined
    var videoFormatText = "—"
    var formatNote: String?
    var cameraHealth: CameraHealth = .noneSelected
    var meter = LevelMeterModel()
    var micHealth: LevelMeterModel.Health = .noInput
    var micFormatText = "—"
    var banner: Banner?
    var showRecordings = false
    var showStudioSettings = false
    var studioSettingsTab: StudioSettingsTab = .teleprompter
    var libraryRefreshing = false
    var libraryError: String?
    var recordingSizes: [URL: Int64] = [:]

    // Script
    var scriptText: String = "" { didSet { if scriptText != oldValue { scriptEdited() } } }
    @ObservationIgnored private(set) var document = ScriptDocument(text: "")
    var documentVersion = 0
    var scriptFileName: String?

    // Prompt
    @ObservationIgnored var prompt = PromptController()
    @ObservationIgnored private(set) var aligner = ScriptAligner(document: ScriptDocument(text: ""))
    var promptRunning = false
    var promptMode: PromptMode = .speech
    var scrollPointsPerSecond: Double = 30
    var promptPositionCoarse = 0
    var trackingStatus: TrackingStatus = .idle
    var speechAvailability: SpeechAvailability = .unknown
    var recognitionLatency: Double?
    var lastHeardText = ""
    @ObservationIgnored private var speech: SpeechRecognizing?
    @ObservationIgnored private var speechEventsTask: Task<Void, Never>?
    var speechRunning = false

    // Modes
    var placementMode = false { didSet { panels?.refresh() } }
    var readingMode = false { didSet { panels?.refresh() } }

    @ObservationIgnored var panels: PanelCoordinator?
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var scriptWork: DispatchWorkItem?
    @ObservationIgnored private var stalledSince: CFTimeInterval?
    @ObservationIgnored private var lastConfiguredCamera: String?? = .none
    @ObservationIgnored private var lastConfiguredMic: String?? = .none

    init(captureDisabled: Bool) {
        self.captureDisabled = captureDisabled
        let engine = CaptureRecordingEngine(capture: capture)
        self.engine = engine
        let loaded = store.loadSettings()
        self.settings = loaded
        self.takes = TakeController(engine: engine, takes: store.loadTakes())
        self.presets = store.loadPresets()
        self.promptMode = loaded.promptMode
        self.scrollPointsPerSecond = loaded.scrollPointsPerSecond
        prompt.mode = loaded.promptMode
        prompt.pointsPerSecond = loaded.scrollPointsPerSecond
        let script = store.loadScript() ?? Self.sampleScript
        scriptText = script
        applyScript(position: loaded.scriptPosition)

        takes.countdownEnabled = loaded.countdownEnabled
        takes.onTakeFinished = { [weak self] _ in self?.persistTakes() }
        takes.onRecordingStarted = { [weak self] in
            guard let self else { return }
            if !self.promptRunning { self.startTracking() }
        }
        engine.onWriterFailure = { [weak self] msg in self?.takes.engineFailed(msg) }
        engine.readinessCheck = { [weak self] in self?.recordingReadinessProblem() }
        capture.onEvent = { [weak self] e in self?.handle(e) }
    }

    static let sampleScript = """
    Welcome to LensPrompt. Paste or open your script here.

    The active line sits right next to your iPhone's camera, so your eyes stay close to the lens while you read. \
    Choose "Follow my voice" and the text moves as you speak. Pause whenever you like; the prompt waits for you.
    """

    // MARK: Lifecycle

    func start() {
        refreshPermissions()
        if captureDisabled {
            cameraHealth = .disabled
            banner = Banner(message: "Capture is disabled for this launch (--no-capture). Camera, microphone and recording are off.", isError: false)
        } else {
            requestPermissionsIfNeeded()
        }
        refreshDevices()
        Task { await refreshSpeechAvailability() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthTick() }
        }
    }

    func prepareForTermination() async {
        settings.scriptPosition = prompt.position
        await takes.finishForTermination()
        saveNow()
        await speech?.stop()
        capture.stopRunning()
    }

    // MARK: Permissions

    func refreshPermissions() {
        cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
        micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func requestPermissionsIfNeeded() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            refreshPermissions()
            updatePermissionBanner()
            refreshDevices()
        }
    }

    private func updatePermissionBanner() {
        var actions: [BannerAction] = []
        var parts: [String] = []
        if cameraAuth == .denied || cameraAuth == .restricted {
            parts.append("Camera access is off."); actions.append(.openCameraSettings)
        }
        if micAuth == .denied || micAuth == .restricted {
            parts.append("Microphone access is off."); actions.append(.openMicrophoneSettings)
        }
        if !parts.isEmpty {
            banner = Banner(message: parts.joined(separator: " ") + " Turn it on in System Settings › Privacy & Security, then relaunch LensPrompt.",
                            isError: true, actions: actions)
        }
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .openCameraSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        case .openMicrophoneSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .reconnect: reconnect()
        case .chooseFolder: chooseOutputFolder()
        case .downloadSpeech: downloadSpeechModel()
        case .dismiss: banner = nil
        }
        if action != .reconnect && action != .downloadSpeech { banner = nil }
    }

    // MARK: Devices

    var inputsLocked: Bool { takes.state.locksInputs }

    func refreshDevices() {
        guard !captureDisabled else { cameras = []; microphones = []; return }
        cameras = CaptureService.cameras()
        microphones = CaptureService.microphones()
        if settings.cameraID == nil, let first = cameras.first(where: \.isContinuityCamera) ?? cameras.first {
            settings.cameraID = first.id; settings.cameraName = first.name
        }
        if settings.microphoneID == nil, let def = CaptureService.systemDefaultMicrophoneID(),
           let mic = microphones.first(where: { $0.id == def }) {
            settings.microphoneID = mic.id; settings.microphoneName = mic.name
        }
        applyDeviceSelection()
    }

    /// Configures the session with the saved selections if present. Missing devices are
    /// left unselected (never substituted).
    private func applyDeviceSelection() {
        guard !captureDisabled, !inputsLocked else { return }
        let camID = (cameraAuth == .authorized) ? settings.cameraID.flatMap { id in cameras.contains { $0.id == id } ? id : nil } : nil
        let micID = (micAuth == .authorized) ? settings.microphoneID.flatMap { id in microphones.contains { $0.id == id } ? id : nil } : nil
        if lastConfiguredCamera != .some(camID) || lastConfiguredMic != .some(micID) {
            lastConfiguredCamera = .some(camID); lastConfiguredMic = .some(micID)
            if camID != nil { cameraHealth = .starting }
            capture.configure(cameraID: camID, microphoneID: micID)
            if speechRunning { restartSpeechForNewMicrophone() }
        }
        updateCameraHealth()
    }

    func selectCamera(_ id: String?) {
        guard !inputsLocked else { return }
        settings.cameraID = id
        settings.cameraName = cameras.first { $0.id == id }?.name
        applyDeviceSelection()
    }

    func selectMicrophone(_ id: String?) {
        guard !inputsLocked else { return }
        settings.microphoneID = id
        settings.microphoneName = microphones.first { $0.id == id }?.name
        meter = LevelMeterModel()
        applyDeviceSelection()
    }

    var selectedCameraMissing: Bool {
        guard let id = settings.cameraID else { return false }
        return !cameras.contains { $0.id == id }
    }
    var selectedMicrophoneMissing: Bool {
        guard let id = settings.microphoneID else { return false }
        return !microphones.contains { $0.id == id }
    }

    func reconnect() {
        guard !inputsLocked, !captureDisabled else { return }
        refreshPermissions()
        cameras = CaptureService.cameras()
        microphones = CaptureService.microphones()
        let camID = settings.cameraID.flatMap { id in cameras.contains { $0.id == id } ? id : nil }
        let micID = settings.microphoneID.flatMap { id in microphones.contains { $0.id == id } ? id : nil }
        lastConfiguredCamera = .some(camID); lastConfiguredMic = .some(micID)
        cameraHealth = camID == nil ? .noneSelected : .starting
        stalledSince = nil
        capture.restart(cameraID: cameraAuth == .authorized ? camID : nil, microphoneID: micAuth == .authorized ? micID : nil)
        banner = nil
    }

    private func handle(_ e: CaptureEvent) {
        switch e {
        case .devicesChanged:
            let wasLocked = inputsLocked
            cameras = CaptureService.cameras()
            microphones = CaptureService.microphones()
            if !wasLocked { applyDeviceSelection() } else { updateCameraHealth() }
        case .cameraDisconnected(let name):
            if takes.state.isBusy { takes.engineFailed("\(name) disconnected during the take. The recording was stopped and saved up to that point.") }
            lastConfiguredCamera = .none
            cameraHealth = .missing(name)
            banner = Banner(message: "\(name) disconnected. Reconnect the iPhone (keep it nearby, on the same Apple Account, Wi-Fi and Bluetooth on) and choose Reconnect.", isError: true, actions: [.reconnect])
        case .microphoneDisconnected(let name):
            if takes.state.isBusy { takes.engineFailed("Microphone \(name) disconnected during the take. The recording was stopped and saved; no other microphone was substituted.") }
            lastConfiguredMic = .none
            banner = Banner(message: "Microphone \(name) disconnected. LensPrompt will not switch to another microphone automatically. Reconnect it or choose a replacement.", isError: true)
        case .runtimeError(let msg):
            if takes.state.isRecording { takes.engineFailed("Capture error: \(msg)") }
            banner = Banner(message: "Capture error: \(msg)", isError: true, actions: [.reconnect])
        case .interrupted(let msg):
            banner = Banner(message: msg, isError: true, actions: [.reconnect])
        case .interruptionEnded:
            banner = nil
        case .configured(let format, let note):
            videoFormatText = capture.currentCamera == nil ? "—" : format
            formatNote = note
            updateCameraHealth()
        case .configurationFailed(let msg):
            banner = Banner(message: msg, isError: true, actions: [.reconnect])
        case .audioDecodingFailed:
            banner = Banner(message: "Audio is arriving, but its format could not be decoded. Reconnect the microphone to retry. This is not a muted-microphone warning.", isError: true, actions: [.reconnect])
        case .cameraStateChanged:
            updateCameraHealth()
        }
    }

    private func updateCameraHealth() {
        if captureDisabled { cameraHealth = .disabled; return }
        if cameraAuth == .denied || cameraAuth == .restricted { cameraHealth = .denied; return }
        guard let id = settings.cameraID else { cameraHealth = .noneSelected; return }
        guard cameras.contains(where: { $0.id == id }) else { cameraHealth = .missing(settings.cameraName ?? "The selected camera"); return }
        if let cam = capture.currentCamera {
            if cam.isSuspended { cameraHealth = .suspended; return }
            if cam.isInUseByAnotherApplication && cameraHealth != .live { cameraHealth = .inUse; return }
        }
        let snap = capture.stats.snapshot
        let age = CACurrentMediaTime() - snap.lastVideo
        if snap.lastVideo == 0 { cameraHealth = .starting }
        else if age > 1.5 { cameraHealth = .stalled }
        else { cameraHealth = .live }
    }

    private func healthTick() {
        let now = CACurrentMediaTime()
        let snap = capture.stats.snapshot
        if snap.lastAudio > 0 && now - snap.lastAudio < 0.5 {
            meter.update(rms: snap.rms, peak: snap.peak, at: snap.lastAudio)
        }
        meter.decay(at: now)
        micHealth = settings.microphoneID == nil || selectedMicrophoneMissing ? .noInput : meter.health(at: now)
        if let f = snap.audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
            micFormatText = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame == 1 ? "mono" : "\(asbd.mChannelsPerFrame) ch")"
        }
        updateCameraHealth()
        // A take whose camera stopped sending video is finalized rather than left recording a frozen image.
        if takes.state.isRecording && cameraHealth != .live {
            if stalledSince == nil { stalledSince = now }
            if let s = stalledSince, now - s > 3 {
                stalledSince = nil
                takes.engineFailed("The camera stopped sending video for 3 seconds (\(cameraHealth.label)). The take was stopped and saved.")
            }
        } else { stalledSince = nil }
    }

    // MARK: Output

    var outputFolder: URL {
        settings.outputFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LocalStore.defaultOutputFolder
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where LensPrompt saves recordings."
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolderPath = url.path
            if let problem = OutputValidator.validate(folder: url, create: false) {
                banner = Banner(message: problem.message, isError: true, actions: [.chooseFolder])
            }
        }
    }

    private func recordingReadinessProblem() -> String? {
        if captureDisabled { return "Capture is disabled for this launch (--no-capture)." }
        if cameraAuth != .authorized { return "LensPrompt does not have camera access. Allow it in System Settings › Privacy & Security › Camera." }
        if micAuth != .authorized { return "LensPrompt does not have microphone access. Allow it in System Settings › Privacy & Security › Microphone." }
        if settings.microphoneID == nil { return "Select a microphone before recording." }
        if selectedMicrophoneMissing { return "The selected microphone (\(settings.microphoneName ?? "unknown")) is not connected. Reconnect it or choose another microphone." }
        if selectedCameraMissing { return "The selected camera (\(settings.cameraName ?? "unknown")) is not available. Reconnect the iPhone or choose another camera." }
        if cameraHealth != .live { return "The camera is not live: \(cameraHealth.label)." }
        return nil
    }

    // MARK: Recording

    func toggleRecording() {
        takes.countdownEnabled = settings.countdownEnabled
        let folder = outputFolder
        takes.toggle(outputURL: {
            if let problem = OutputValidator.validate(folder: folder) { throw RecordingError(problem.message) }
            return TakeNamer.uniqueURL(in: folder, date: Date())
        }, audioOffsetMs: settings.audioOffsetMs)
    }

    func cancelCountdown() { takes.cancelCountdown() }

    func anotherTake() {
        takes.acknowledge()
        resetToStart()
    }

    private func persistTakes() {
        try? store.saveTakes(takes.takes)
    }

    func removeTakeFromList(_ take: TakeRecord) {
        // Only removes the list entry; the movie file is never deleted by LensPrompt.
        takes.replaceTakes(takes.takes.filter { $0.id != take.id })
        persistTakes()
    }

    // MARK: Recordings library

    func openRecordings() {
        showRecordings = true
        refreshRecordings()
    }

    func refreshRecordings() {
        guard !libraryRefreshing else { return }
        libraryRefreshing = true
        libraryError = nil
        let folder = outputFolder
        let activeURL = engine.activeRecordingURL
        Task {
            defer { libraryRefreshing = false }
            do {
                let files = try await Task.detached(priority: .utility) {
                    try RecordingLibrary.discover(in: folder, excluding: activeURL)
                }.value
                var discovered: [TakeRecord] = []
                let known = Set(takes.takes.map { $0.fileURL.resolvingSymlinksInPath().standardizedFileURL })
                for file in files {
                    recordingSizes[file.url] = file.bytes
                    guard !known.contains(file.url.resolvingSymlinksInPath().standardizedFileURL) else { continue }
                    let asset = AVURLAsset(url: file.url)
                    let duration = try? await asset.load(.duration)
                    let playable = (try? await asset.load(.isPlayable)) ?? false
                    let seconds = duration.map(CMTimeGetSeconds) ?? 0
                    discovered.append(TakeRecord(fileURL: file.url, createdAt: file.createdAt,
                        duration: seconds.isFinite ? max(0, seconds) : 0,
                        status: playable ? .complete : .incomplete,
                        note: playable ? nil : "Recovered file could not be previewed. Reveal it in Finder to inspect it."))
                }
                // A take can finish while metadata is loading; merge into the latest list.
                let safeDiscovered = discovered.filter { $0.fileURL.resolvingSymlinksInPath().standardizedFileURL != engine.activeRecordingURL?.resolvingSymlinksInPath().standardizedFileURL }
                takes.replaceTakes(RecordingLibrary.merging(safeDiscovered, into: takes.takes))
                persistTakes()
            } catch { libraryError = "Could not read the recordings folder: \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func renameRecording(_ take: TakeRecord, to name: String) -> Bool {
        guard !inputsLocked else { libraryError = "Finish the current recording before renaming files."; return false }
        do {
            let renamed = try RecordingLibrary.rename(take, to: name)
            if let size = recordingSizes.removeValue(forKey: take.fileURL) { recordingSizes[renamed.fileURL] = size }
            takes.replaceTakes(takes.takes.map { $0.id == take.id ? renamed : $0 })
            if case .saved(let saved) = takes.state, saved.id == take.id { takes.acknowledge() }
            persistTakes()
            libraryError = nil
            return true
        } catch { libraryError = error.localizedDescription; return false }
    }

    @discardableResult
    func trashRecording(_ take: TakeRecord) -> Bool {
        guard !inputsLocked else { libraryError = "Finish the current recording before moving files to Trash."; return false }
        do {
            try RecordingLibrary.moveToTrash(take)
            recordingSizes.removeValue(forKey: take.fileURL)
            removeTakeFromList(take)
            if case .saved(let saved) = takes.state, saved.id == take.id { takes.acknowledge() }
            libraryError = nil
            return true
        } catch { libraryError = "Could not move the recording to Trash: \(error.localizedDescription)"; return false }
    }

    // MARK: Script

    private func scriptEdited() {
        scriptWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyScript(position: min(self.prompt.position, Int.max))
                do { try self.store.saveScript(self.scriptText) } catch {
                    self.banner = Banner(message: "Could not autosave the script: \(error.localizedDescription)", isError: true)
                }
            }
        }
        scriptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func applyScript(position: Int) {
        document = ScriptDocument(text: scriptText)
        let p = min(max(0, position), document.tokens.count)
        prompt.load(document: document, position: p)
        aligner.replace(document: document, position: p)
        documentVersion += 1
        promptPositionCoarse = p
        if promptRunning && promptMode == .speech { aligner.beginListening() }
    }

    func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a UTF-8 text or Markdown script."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try LocalStore.readScriptFile(url)
            scriptFileName = url.lastPathComponent
            scriptText = text
            scriptWork?.perform()
            resetToStart()
        } catch {
            banner = Banner(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: Prompt control

    func setPromptMode(_ mode: PromptMode) {
        let wasRunning = promptRunning
        pauseTracking()
        promptMode = mode
        prompt.mode = mode
        settings.promptMode = mode
        if mode != .speech { Task { await stopSpeech() } }
        if wasRunning && mode != .manual { startTracking() }
    }

    func setScrollSpeed(_ points: Double) {
        prompt.pointsPerSecond = min(150, max(5, points))
        scrollPointsPerSecond = prompt.pointsPerSecond
        settings.scrollPointsPerSecond = scrollPointsPerSecond
    }

    func adjustSpeed(_ delta: Double) { setScrollSpeed(scrollPointsPerSecond + delta) }

    func toggleTracking() { promptRunning ? pauseTracking() : startTracking() }

    func startTracking() {
        switch promptMode {
        case .manual:
            promptRunning = false
        case .fixedSpeed:
            prompt.isRunning = true
            promptRunning = true
        case .speech:
            guard speechAvailability == .ready else {
                banner = Banner(message: speechAvailability.label + " Fixed-speed and manual scrolling work without it.", isError: true,
                                actions: speechAvailability == .needsDownload ? [.downloadSpeech] : [])
                return
            }
            aligner.reset(to: prompt.position)
            lastHeardText = ""
            aligner.beginListening()
            prompt.isRunning = true
            promptRunning = true
            trackingStatus = aligner.status
            if !speechRunning { Task { await startSpeech() } }
        }
    }

    func pauseTracking() {
        promptRunning = false
        prompt.isRunning = false
        aligner.stopListening()
        trackingStatus = .idle
        settings.scriptPosition = prompt.position
    }

    func resetToStart() {
        prompt.jump(to: 0, animated: false)
        aligner.reset(to: 0)
        if promptRunning && promptMode == .speech { aligner.beginListening() }
        promptPositionCoarse = 0
        settings.scriptPosition = 0
    }

    /// Click-to-resume: restart following from the clicked word.
    func resume(fromCharacter offset: Int) {
        let idx = document.tokenIndex(atCharacter: offset)
        move(to: idx)
    }

    func nextLine() { prompt.nextLine(); resyncAfterManualMove() }
    func previousLine() { prompt.previousLine(); resyncAfterManualMove() }
    func stepWord(_ delta: Int) { move(to: prompt.position + delta) }

    private func move(to idx: Int) {
        prompt.jump(to: Double(idx))
        resyncAfterManualMove()
    }

    private func resyncAfterManualMove() {
        aligner.reset(to: prompt.position)
        if promptRunning && promptMode == .speech { aligner.beginListening(); trackingStatus = .listening }
        promptPositionCoarse = prompt.position
    }

    /// Advances smoothing/fixed speed. Called from the prompt view's display link.
    func tickPrompt(dt: Double) -> Bool {
        let before = prompt.display
        let beforeY = prompt.renderedY
        prompt.tick(dt: dt)
        if promptMode == .fixedSpeed && promptRunning && prompt.isAtEnd { promptRunning = false; prompt.isRunning = false }
        if prompt.position != promptPositionCoarse { promptPositionCoarse = prompt.position }
        return prompt.display != before || prompt.renderedY != beforeY
    }

    // MARK: Speech

    func refreshSpeechAvailability() async {
        speechAvailability = .checking
        speechAvailability = await LocalSpeechTranscriberAdapter.availability()
    }

    func downloadSpeechModel() {
        speechAvailability = .downloading(0)
        Task {
            do {
                try await LocalSpeechTranscriberAdapter.installAssets { p in
                    Task { @MainActor [weak self] in self?.speechAvailability = .downloading(p) }
                }
                await refreshSpeechAvailability()
                banner = nil
            } catch {
                speechAvailability = .unavailable("Speech model download failed: \(error.localizedDescription)")
            }
        }
    }

    private func startSpeech() async {
        guard !speechRunning else { return }
        guard let fmt = capture.stats.snapshot.audioFormat else {
            banner = Banner(message: "Speech following needs audio from the selected microphone, but none is arriving. Check the microphone.", isError: true)
            pauseTracking()
            return
        }
        let natural = AVAudioFormat(cmAudioFormatDescription: fmt)
        let adapter = LocalSpeechTranscriberAdapter()
        speechRunning = true
        do {
            try await adapter.start(naturalFormat: natural)
        } catch {
            speechRunning = false
            banner = Banner(message: "Speech following could not start: \(error.localizedDescription). Manual and fixed-speed modes still work.", isError: true)
            pauseTracking()
            return
        }
        speech = adapter
        capture.setSpeechTap { [weak adapter] buffer in adapter?.append(buffer) }
        speechEventsTask = Task { [weak self] in
            for await event in adapter.events {
                guard let self else { break }
                self.handleSpeech(event)
            }
        }
    }

    private func handleSpeech(_ event: SpeechEvent) {
        switch event {
        case .hypothesis(let h, let latency):
            if let latency { recognitionLatency = latency }
            guard promptRunning, promptMode == .speech else { return }
            lastHeardText = h.text.split(whereSeparator: \.isWhitespace).suffix(12).joined(separator: " ")
            let outcome = aligner.ingest(h)
            prompt.follow(alignedPosition: outcome.position)
            if trackingStatus != outcome.status { trackingStatus = outcome.status }
        case .failed(let msg):
            // Recognition failure never affects the recording.
            banner = Banner(message: msg, isError: true)
            Task { await stopSpeech() }
            pauseTracking()
        }
    }

    private func stopSpeech() async {
        capture.setSpeechTap(nil)
        speechEventsTask?.cancel()
        speechEventsTask = nil
        let s = speech
        speech = nil
        speechRunning = false
        await s?.stop()
    }

    private func restartSpeechForNewMicrophone() {
        Task {
            await stopSpeech()
            try? await Task.sleep(nanoseconds: 600_000_000)  // let the new input deliver its format
            if promptRunning && promptMode == .speech { await startSpeech() }
        }
    }

    // MARK: Phone orientation

    /// The phone was mounted the other way up: cluster and lens move to the opposite corner.
    func rotatePhone180() {
        guard !settings.layoutLocked else { return }
        settings.orientation = settings.orientation.rotated180()
        if settings.arrangement != .free { panels?.snapPromptToLens() }
    }

    /// Cluster on the other end of the phone (same top/bottom edge).
    func flipPhoneSides() {
        guard !settings.layoutLocked else { return }
        settings.orientation = settings.orientation.flippedHorizontally()
        if settings.arrangement != .free { panels?.snapPromptToLens() }
    }

    // MARK: Presets

    func savePreset(named name: String) {
        guard let p = panels?.makePreset(name: name) else { return }
        presets.removeAll { $0.name == name }
        presets.append(p)
        settings.lastPresetName = name
        try? store.savePresets(presets)
    }

    func applyPreset(_ p: LayoutPreset) {
        settings.style = p.style
        settings.lensOffset = p.lensOffset
        settings.clusterSide = p.clusterSide
        settings.clusterAtBottom = p.clusterAtBottom ?? false
        settings.arrangement = p.arrangement
        settings.guideOpacity = p.guideOpacity
        settings.layoutLocked = p.locked
        settings.phoneFrame = p.phoneFrame
        settings.promptFrame = p.promptFrame
        settings.lastPresetName = p.name
        panels?.restoreFrames()
    }

    func deletePreset(_ p: LayoutPreset) {
        presets.removeAll { $0.id == p.id }
        try? store.savePresets(presets)
    }

    // MARK: Persistence

    private func scheduleSettingsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        do {
            try store.saveSettings(settings)
            try store.saveScript(scriptText)
        } catch {
            banner = Banner(message: "Could not save settings: \(error.localizedDescription)", isError: true)
        }
    }
}
