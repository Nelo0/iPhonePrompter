import Foundation
import AVFoundation
import QuartzCore
import LensPromptCore

/// Connects the TakeController's sequencing to the live capture session and MovieWriter.
@MainActor
final class CaptureRecordingEngine: RecordingEngine {
    private let capture: CaptureService
    private var writer: MovieWriter?
    private var micName: String?
    private var formatText: String?
    /// Reports asynchronous writer failures to the coordinator.
    var onWriterFailure: ((String) -> Void)?
    /// Returns a human-readable reason recording cannot start, or nil when ready.
    var readinessCheck: (() -> String?)?

    init(capture: CaptureService) { self.capture = capture }

    var currentVideoFormat: String? { formatText }
    var currentMicrophoneName: String? { micName }

    func prepare(url: URL, audioOffsetMs: Int) async throws {
        if let problem = readinessCheck?() { throw RecordingError(problem) }
        let snap = capture.stats.snapshot
        let now = CACurrentMediaTime()
        guard capture.currentCamera != nil else { throw RecordingError("Select a camera before recording.") }
        guard capture.currentMicrophone != nil else { throw RecordingError("Select a microphone before recording.") }
        guard now - snap.lastVideo < 1.0, let dims = snap.dims else {
            throw RecordingError("The camera is not delivering video. Check that the iPhone is nearby, unlocked once, and not in use by another app, then choose Reconnect.")
        }
        guard now - snap.lastAudio < 1.0, let audioFormat = snap.audioFormat else {
            throw RecordingError("The microphone is not delivering audio. Check that it is connected and selected, then try again.")
        }
        let folder = url.deletingLastPathComponent()
        if let problem = OutputValidator.validate(folder: folder) { throw RecordingError(problem.message) }
        let w = try MovieWriter(url: url, video: .init(width: Int(dims.width), height: Int(dims.height), frameRate: capture.frameRate),
                                audioFormat: audioFormat, audioOffsetMs: audioOffsetMs)
        w.onFailure = { [weak self] msg in
            DispatchQueue.main.async { self?.onWriterFailure?(msg) }
        }
        writer = w
        micName = capture.currentMicrophone?.localizedName
        formatText = "\(dims.width)×\(dims.height) @ \(Int(capture.frameRate.rounded())) fps, H.264/AAC"
        capture.installWriter(w)
    }

    func start() async throws {
        guard let w = writer else { throw RecordingError("Recording was not prepared.") }
        let started: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            capture.onDataQueue {
                w.onSessionStarted = { if once.set() { cont.resume(returning: true) } }
                w.beginAccepting()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if once.set() { cont.resume(returning: false) } }
        }
        if !started {
            throw RecordingError("No video frames arrived within 3 seconds, so recording did not start. Check the camera and try again.")
        }
    }

    func finish() async -> FinalizeResult {
        guard let w = writer else {
            return FinalizeResult(fileURL: URL(fileURLWithPath: "/dev/null"), duration: 0, succeeded: false, error: "No active recording.")
        }
        let result: FinalizeResult = await withCheckedContinuation { cont in
            capture.onDataQueue { w.finish { cont.resume(returning: $0) } }
        }
        capture.installWriter(nil)
        writer = nil
        return result
    }

    func cancelPrepared() async {
        guard let w = writer else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            capture.onDataQueue {
                if w.sessionStart == nil { w.cancel() }
                cont.resume()
            }
        }
        if w.sessionStart == nil {
            capture.installWriter(nil)
            writer = nil
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
