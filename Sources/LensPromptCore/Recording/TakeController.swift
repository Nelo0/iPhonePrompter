import Foundation
import Observation

/// Explicit recording states. `recording` is only entered once the writer session has
/// actually started with real media.
public enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case countdown(remaining: Int)
    case recording(startedAt: Date)
    case stopping
    case saved(TakeRecord)
    case failed(message: String, partial: TakeRecord?)

    public var isBusy: Bool {
        switch self {
        case .preparing, .countdown, .recording, .stopping: return true
        default: return false
        }
    }
    public var isRecording: Bool { if case .recording = self { return true } else { return false } }
    /// Input/format changes are locked from preparation until the take is finalized.
    public var locksInputs: Bool { isBusy }

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing…"
        case .countdown(let n): return "Starting in \(n)…"
        case .recording: return "Recording"
        case .stopping: return "Saving…"
        case .saved: return "Saved"
        case .failed: return "Recording failed"
        }
    }
}

public enum TakeStatus: String, Codable, Sendable {
    case complete      // finalized normally
    case interrupted   // finalized after a device/write interruption; may be shorter than intended
    case incomplete    // the writer could not finalize; the file may not be playable
}

public struct TakeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var fileURL: URL
    public var createdAt: Date
    public var duration: Double
    public var status: TakeStatus
    public var note: String?
    public var videoFormat: String?
    public var microphoneName: String?
    public var audioOffsetMs: Int

    public init(id: UUID = UUID(), fileURL: URL, createdAt: Date, duration: Double, status: TakeStatus,
                note: String? = nil, videoFormat: String? = nil, microphoneName: String? = nil, audioOffsetMs: Int = 0) {
        self.id = id; self.fileURL = fileURL; self.createdAt = createdAt; self.duration = duration
        self.status = status; self.note = note; self.videoFormat = videoFormat
        self.microphoneName = microphoneName; self.audioOffsetMs = audioOffsetMs
    }

    public var fileName: String { fileURL.lastPathComponent }
}

public struct RecordingError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Outcome of finalizing a writer.
public struct FinalizeResult: Equatable, Sendable {
    public var fileURL: URL
    public var duration: Double
    public var succeeded: Bool
    public var error: String?
    public init(fileURL: URL, duration: Double, succeeded: Bool, error: String? = nil) {
        self.fileURL = fileURL; self.duration = duration; self.succeeded = succeeded; self.error = error
    }
}

/// Abstraction over the capture/writer pipeline so take sequencing is testable.
@MainActor
public protocol RecordingEngine: AnyObject {
    /// Validates devices, permissions, output folder and disk space; creates a writer
    /// that is ready to receive media at `url`. Must not create a playable "take".
    func prepare(url: URL, audioOffsetMs: Int) async throws
    /// Starts appending media. Returns only once the writer session has started.
    func start() async throws
    /// Finalizes the current take.
    func finish() async -> FinalizeResult
    /// Discards a prepared-but-never-started writer and removes any empty file.
    func cancelPrepared() async
    /// Description of the active video format and microphone for take metadata.
    var currentVideoFormat: String? { get }
    var currentMicrophoneName: String? { get }
}

/// Sequences a take: preparing → countdown → recording → stopping → saved/failed.
/// Rejects duplicate commands during transitions.
@MainActor
@Observable
public final class TakeController {
    public private(set) var state: RecordingState = .idle
    public private(set) var takes: [TakeRecord] = []
    public var countdownSeconds = 3
    public var countdownEnabled = true

    private let engine: RecordingEngine
    private let sleep: @Sendable (Double) async throws -> Void
    private var countdownTask: Task<Void, Never>?
    private var generation = 0
    private var activeOffsetMs = 0

    /// Called when a take ends (saved or failed) so the app can persist the take list.
    public var onTakeFinished: ((TakeRecord) -> Void)?
    /// Called when recording actually starts (to start script tracking with the take).
    public var onRecordingStarted: (() -> Void)?

    public init(engine: RecordingEngine, takes: [TakeRecord] = [],
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.engine = engine
        self.takes = takes
        self.sleep = sleep
    }

    /// Start when idle/saved/failed; stop when recording; ignored during transitions.
    public func toggle(outputURL: @escaping () throws -> URL, audioOffsetMs: Int) {
        switch state {
        case .idle, .saved, .failed: start(outputURL: outputURL, audioOffsetMs: audioOffsetMs)
        case .recording: stop()
        case .countdown: cancelCountdown()
        case .preparing, .stopping: break
        }
    }

    public func start(outputURL: @escaping () throws -> URL, audioOffsetMs: Int) {
        guard !state.isBusy else { return }
        generation += 1
        let gen = generation
        activeOffsetMs = audioOffsetMs
        state = .preparing
        countdownTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try outputURL()
                try await self.engine.prepare(url: url, audioOffsetMs: audioOffsetMs)
                guard self.generation == gen else { await self.engine.cancelPrepared(); return }
                if self.countdownEnabled && self.countdownSeconds > 0 {
                    for n in stride(from: self.countdownSeconds, through: 1, by: -1) {
                        self.state = .countdown(remaining: n)
                        try await self.sleep(1)
                        guard self.generation == gen, !Task.isCancelled else {
                            await self.engine.cancelPrepared(); return
                        }
                    }
                }
                try await self.engine.start()
                guard self.generation == gen else { _ = await self.engine.finish(); return }
                self.state = .recording(startedAt: Date())
                self.onRecordingStarted?()
            } catch is CancellationError {
                await self.engine.cancelPrepared()
                if self.generation == gen { self.state = .idle }
            } catch {
                await self.engine.cancelPrepared()
                if self.generation == gen {
                    self.state = .failed(message: error.localizedDescription, partial: nil)
                }
            }
        }
    }

    /// Escape / cancel during preparation or countdown. Never discards a running take.
    public func cancelCountdown() {
        switch state {
        case .preparing, .countdown:
            generation += 1
            countdownTask?.cancel()
            countdownTask = nil
            state = .idle
            Task { await engine.cancelPrepared() }
        default: break
        }
    }

    public func stop() {
        guard case .recording = state else { return }
        state = .stopping
        Task { await self.finalize(status: .complete, reason: nil) }
    }

    /// The engine reports an interruption (camera/mic loss, write error, termination).
    /// A running take is finalized and kept; a preparing take is abandoned.
    public func engineFailed(_ message: String) {
        switch state {
        case .recording:
            state = .stopping
            Task { await self.finalize(status: .interrupted, reason: message) }
        case .preparing, .countdown:
            generation += 1
            countdownTask?.cancel()
            state = .failed(message: message, partial: nil)
            Task { await engine.cancelPrepared() }
        case .stopping:
            break  // finalize already running; it reports the writer result
        default:
            break
        }
    }

    /// Finalize for app termination; returns when the file is closed.
    public func finishForTermination() async {
        switch state {
        case .recording:
            state = .stopping
            await finalize(status: .complete, reason: nil)
        case .preparing, .countdown:
            cancelCountdown()
            await engine.cancelPrepared()
        default: break
        }
    }

    public func acknowledge() {
        switch state {
        case .saved, .failed: state = .idle
        default: break
        }
    }

    private func finalize(status: TakeStatus, reason: String?) async {
        let result = await engine.finish()
        var record = TakeRecord(fileURL: result.fileURL, createdAt: Date(), duration: result.duration,
                                status: result.succeeded ? status : .incomplete,
                                note: reason ?? result.error,
                                videoFormat: engine.currentVideoFormat,
                                microphoneName: engine.currentMicrophoneName)
        record.audioOffsetMs = activeOffsetMs
        let fileExists = FileManager.default.fileExists(atPath: result.fileURL.path)
        if fileExists {
            takes.insert(record, at: 0)
            onTakeFinished?(record)
        }
        if result.succeeded && status == .complete {
            state = .saved(record)
        } else {
            let msg = [reason, result.error].compactMap { $0 }.joined(separator: " ")
            state = .failed(message: msg.isEmpty ? "The take ended unexpectedly." : msg,
                            partial: fileExists ? record : nil)
        }
    }

    public func replaceTakes(_ list: [TakeRecord]) { takes = list }
}
