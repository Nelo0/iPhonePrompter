import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import LensPromptCore

struct DeviceInfo: Identifiable, Hashable {
    let id: String          // AVCaptureDevice.uniqueID
    let name: String
    let isContinuityCamera: Bool
    let modelID: String
}

enum CaptureEvent {
    case devicesChanged
    case cameraDisconnected(name: String)
    case microphoneDisconnected(name: String)
    case runtimeError(String)
    case interrupted(String)
    case interruptionEnded
    case configured(videoFormat: String, note: String?)
    case configurationFailed(String)
    case cameraStateChanged
    case audioDecodingFailed
}

/// Thread-safe media statistics written on the capture data queue and read on main.
final class MediaStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastVideo: CFTimeInterval = 0
    private var _lastAudio: CFTimeInterval = 0
    private var _videoDims: CMVideoDimensions?
    private var _audioFormat: CMAudioFormatDescription?
    private var _rms: Float = AudioLevels.floorDB
    private var _peak: Float = AudioLevels.floorDB

    func video(_ t: CFTimeInterval, dims: CMVideoDimensions?) { lock.lock(); _lastVideo = t; if let dims { _videoDims = dims }; lock.unlock() }
    func audio(_ t: CFTimeInterval, format: CMAudioFormatDescription?, rms: Float, peak: Float) {
        lock.lock(); _lastAudio = t; _audioFormat = format ?? _audioFormat; _rms = rms; _peak = peak; lock.unlock()
    }
    func reset() { lock.lock(); _lastVideo = 0; _lastAudio = 0; _videoDims = nil; _audioFormat = nil; lock.unlock() }
    func resetAudio() { lock.lock(); _lastAudio = 0; _audioFormat = nil; _rms = AudioLevels.floorDB; _peak = AudioLevels.floorDB; lock.unlock() }
    func resetVideo() { lock.lock(); _lastVideo = 0; _videoDims = nil; lock.unlock() }
    var snapshot: (lastVideo: CFTimeInterval, lastAudio: CFTimeInterval, dims: CMVideoDimensions?, audioFormat: CMAudioFormatDescription?, rms: Float, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (_lastVideo, _lastAudio, _videoDims, _audioFormat, _rms, _peak)
    }
}

/// Owns the single AVCaptureSession used for preview, recording and speech: the camera
/// and the independently selected microphone feed one session, so every sample buffer
/// shares the session's synchronization clock. Audio is fanned out to the writer, the
/// level meter and (optionally) the speech recognizer from the same callback.
final class CaptureService: NSObject, @unchecked Sendable,
                            AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let stats = MediaStats()
    private let sessionQueue = DispatchQueue(label: "LensPrompt.session")
    let dataQueue = DispatchQueue(label: "LensPrompt.media", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    private var kvo: [NSKeyValueObservation] = []

    /// Called on main for session/device events.
    var onEvent: ((CaptureEvent) -> Void)?

    // Data-queue-owned state.
    private var writer: MovieWriter?
    private var reportedAudioDecodeFailure = false
    private var speechTap: ((AVAudioPCMBuffer) -> Void)?

    private(set) var currentCamera: AVCaptureDevice?
    private(set) var currentMicrophone: AVCaptureDevice?
    private(set) var frameRate: Double = 30

    override init() {
        super.init()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        // Normalize USB/Bluetooth native formats before metering, writing or recognition.
        audioOutput.audioSettings = CaptureAudio.outputSettings
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        observeNotifications()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Discovery

    static func cameras() -> [DeviceInfo] {
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
                                                 mediaType: .video, position: .unspecified)
        return s.devices.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName, isContinuityCamera: $0.isContinuityCamera, modelID: $0.modelID) }
            .sorted { ($0.isContinuityCamera ? 0 : 1, $0.name) < ($1.isContinuityCamera ? 0 : 1, $1.name) }
    }

    static func microphones() -> [DeviceInfo] {
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        var seen = Set<String>()
        return s.devices.filter { seen.insert($0.uniqueID).inserted }
            .map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName, isContinuityCamera: false, modelID: $0.modelID) }
            .sorted { $0.name < $1.name }
    }

    static func systemDefaultMicrophoneID() -> String? { AVCaptureDevice.default(for: .audio)?.uniqueID }

    // MARK: Configuration

    /// Reconfigures inputs. Never substitutes a different device: a missing ID leaves that input empty.
    func configure(cameraID: String?, microphoneID: String?) {
        sessionQueue.async { [weak self] in self?.configureOnQueue(cameraID: cameraID, microphoneID: microphoneID) }
    }

    private func configureOnQueue(cameraID: String?, microphoneID: String?) {
        session.beginConfiguration()
        var note: String?
        var formatText = "No camera selected"
        var failure: String?

        if videoInput?.device.uniqueID != cameraID {
            if let v = videoInput { session.removeInput(v); videoInput = nil; stats.resetVideo() }
            if let id = cameraID, let device = AVCaptureDevice(uniqueID: id) {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) { session.addInput(input); videoInput = input }
                    else { failure = "\(device.localizedName) could not be added. It may be in use by another app." }
                } catch {
                    failure = "\(device.localizedName) could not be opened: \(error.localizedDescription)"
                }
            }
        }
        if audioInput?.device.uniqueID != microphoneID {
            if let a = audioInput { session.removeInput(a); audioInput = nil; stats.resetAudio() }
            if let id = microphoneID, let device = AVCaptureDevice(uniqueID: id) {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) { session.addInput(input); audioInput = input }
                    else { failure = "\(device.localizedName) could not be added as the microphone." }
                } catch {
                    failure = "\(device.localizedName) could not be opened: \(error.localizedDescription)"
                }
            }
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if let device = videoInput?.device {
            (formatText, note) = applyPreferredFormat(device)
        }
        // The saved video is never mirrored, whatever the preview shows.
        if let c = videoOutput.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        session.commitConfiguration()

        currentCamera = videoInput?.device
        currentMicrophone = audioInput?.device
        observeDeviceState()
        if !session.isRunning && (videoInput != nil || audioInput != nil) { session.startRunning() }
        if session.isRunning && videoInput == nil && audioInput == nil { session.stopRunning() }
        let fmt = formatText, n = note, f = failure
        DispatchQueue.main.async { [weak self] in
            if let f { self?.onEvent?(.configurationFailed(f)) }
            self?.onEvent?(.configured(videoFormat: fmt, note: n))
        }
    }

    /// Selects 1920×1080 at 30 fps when the device offers it, otherwise the closest format.
    private func applyPreferredFormat(_ device: AVCaptureDevice) -> (String, String?) {
        let formats = device.formats
        let candidates: [FormatCandidate] = formats.enumerated().map { i, f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxR = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let minR = f.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
            return FormatCandidate(index: i, width: Int(d.width), height: Int(d.height), maxFrameRate: maxR, minFrameRate: minR)
        }
        guard let choice = FormatChooser.choose(candidates) else { return ("No video formats reported", nil) }
        let fps = FormatChooser.frameRate(for: choice)
        do {
            try device.lockForConfiguration()
            device.activeFormat = formats[choice.index]
            let duration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
            if formats[choice.index].videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps + 0.01 && $0.maxFrameRate >= fps - 0.01 }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            return ("Format could not be set: \(error.localizedDescription)", nil)
        }
        frameRate = fps
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let text = "\(d.width)×\(d.height) @ \(Int(fps.rounded())) fps"
        let note = (choice.width == 1920 && choice.height == 1080 && fps == 30) ? nil
            : "1920×1080 at 30 fps is not offered by this camera; using the closest available format."
        return (text, note)
    }

    func stopRunning() { sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } } }

    var isRunning: Bool { session.isRunning }

    // MARK: Writer / speech plumbing (data queue)

    func installWriter(_ w: MovieWriter?) { dataQueue.sync { writer = w } }
    func onDataQueue(_ block: @escaping () -> Void) { dataQueue.async(execute: block) }
    func setSpeechTap(_ tap: ((AVAudioPCMBuffer) -> Void)?) { dataQueue.async { [weak self] in self?.speechTap = tap } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        if output === videoOutput {
            var dims: CMVideoDimensions?
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                dims = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(pb)), height: Int32(CVPixelBufferGetHeight(pb)))
            }
            stats.video(now, dims: dims)
            writer?.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer)
            guard let pcm = CaptureAudio.pcmBuffer(sampleBuffer), let levels = CaptureAudio.levels(pcm) else {
                // A decode failure is not silence. Don't update the meter with invented zeroes.
                if !reportedAudioDecodeFailure {
                    reportedAudioDecodeFailure = true
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.audioDecodingFailed) }
                }
                return
            }
            reportedAudioDecodeFailure = false
            stats.audio(now, format: fmt, rms: levels.rms, peak: levels.peak)
            speechTap?(pcm)
        }
    }

    // MARK: Notifications

    private func observeNotifications() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(.devicesChanged)
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let device = n.object as? AVCaptureDevice else { self?.onEvent?(.devicesChanged); return }
            if device.uniqueID == self.currentCamera?.uniqueID { self.onEvent?(.cameraDisconnected(name: device.localizedName)) }
            if device.uniqueID == self.currentMicrophone?.uniqueID { self.onEvent?(.microphoneDisconnected(name: device.localizedName)) }
            self.onEvent?(.devicesChanged)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onEvent?(.runtimeError(err?.localizedDescription ?? "The capture session stopped unexpectedly."))
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.interrupted("Capture was interrupted (another app may be using the camera or microphone)."))
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.interruptionEnded)
        })
    }

    private func observeDeviceState() {
        kvo = []
        guard let cam = currentCamera else { return }
        let handler: (AVCaptureDevice, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onEvent?(.cameraStateChanged) }
        }
        kvo.append(cam.observe(\.isSuspended, options: [.new], changeHandler: handler))
        kvo.append(cam.observe(\.isInUseByAnotherApplication, options: [.new], changeHandler: handler))
    }

    /// Restart after a runtime error (user-initiated "Reconnect").
    func restart(cameraID: String?, microphoneID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.videoInput = nil; self.audioInput = nil
            self.session.commitConfiguration()
            self.stats.reset()
            self.configureOnQueue(cameraID: cameraID, microphoneID: microphoneID)
        }
    }
}
