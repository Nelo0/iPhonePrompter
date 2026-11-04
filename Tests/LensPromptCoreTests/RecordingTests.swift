import XCTest
import CoreMedia
@testable import LensPromptCore

@MainActor
final class FakeEngine: RecordingEngine {
    var prepared: URL?
    var started = false
    var prepareError: Error?
    var startError: Error?
    var finishSucceeded = true
    var calls: [String] = []
    var startGate: CheckedContinuation<Void, Never>?
    var holdStart = false
    var currentVideoFormat: String? = "1920×1080 @ 30 fps"
    var currentMicrophoneName: String? = "Test Mic"

    func prepare(url: URL, audioOffsetMs: Int) async throws {
        calls.append("prepare")
        if let prepareError { throw prepareError }
        prepared = url
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    func start() async throws {
        calls.append("start")
        if let startError { throw startError }
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        started = true
    }
    func finish() async -> FinalizeResult {
        calls.append("finish")
        let url = prepared!
        try? Data("movie".utf8).write(to: url)
        return FinalizeResult(fileURL: url, duration: 2.5, succeeded: finishSucceeded,
                              error: finishSucceeded ? nil : "writer failed")
    }
    func cancelPrepared() async {
        calls.append("cancel")
        if let p = prepared, !started { try? FileManager.default.removeItem(at: p) }
    }
}

@MainActor
final class TakeControllerTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    func url() throws -> URL { TakeNamer.uniqueURL(in: folder, date: Date()) }

    func waitFor(_ c: TakeController, _ pred: (RecordingState) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if pred(c.state) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out; state = \(c.state)", file: file, line: line)
    }

    func testFullTakeLifecycleWithCountdown() async {
        let engine = FakeEngine()
        final class Box: @unchecked Sendable { var c: TakeController?; var seen: [String] = [] }
        let box = Box()
        let c = TakeController(engine: engine, sleep: { _ in
            // Each countdown step sleeps once; record the state shown during that second.
            await MainActor.run { box.seen.append(box.c!.state.label) }
        })
        box.c = c
        var startedCallbacks = 0
        c.onRecordingStarted = { startedCallbacks += 1 }
        c.toggle(outputURL: url, audioOffsetMs: 120)
        XCTAssertEqual(c.state, .preparing)
        await waitFor(c) { $0.isRecording }
        XCTAssertEqual(box.seen, ["Starting in 3…", "Starting in 2…", "Starting in 1…"])
        XCTAssertEqual(startedCallbacks, 1)
        XCTAssertEqual(engine.calls, ["prepare", "start"])
        c.toggle(outputURL: url, audioOffsetMs: 0)
        XCTAssertEqual(c.state, .stopping)
        await waitFor(c) { if case .saved = $0 { return true } else { return false } }
        XCTAssertEqual(c.takes.count, 1)
        XCTAssertEqual(c.takes[0].status, .complete)
        XCTAssertEqual(c.takes[0].audioOffsetMs, 120)
        XCTAssertEqual(c.takes[0].microphoneName, "Test Mic")
    }

    func testDuplicateCommandsIgnoredDuringTransitions() async {
        let engine = FakeEngine()
        engine.holdStart = true
        let c = TakeController(engine: engine, sleep: { _ in })
        c.countdownEnabled = false
        c.start(outputURL: url, audioOffsetMs: 0)
        c.start(outputURL: url, audioOffsetMs: 0)   // duplicate start while preparing
        await waitFor(c) { _ in engine.startGate != nil }
        XCTAssertEqual(c.state, .preparing, "not Recording until the writer session started")
        c.stop()                                     // stop while preparing: ignored
        c.start(outputURL: url, audioOffsetMs: 0)
        engine.startGate?.resume()
        await waitFor(c) { $0.isRecording }
        XCTAssertEqual(engine.calls.filter { $0 == "prepare" }.count, 1)
        c.stop(); c.stop()                           // duplicate stop
        await waitFor(c) { if case .saved = $0 { return true } else { return false } }
        XCTAssertEqual(engine.calls.filter { $0 == "finish" }.count, 1)
    }

    func testCancelledCountdownLeavesNoTake() async {
        let engine = FakeEngine()
        let c = TakeController(engine: engine, sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) })
        c.start(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { if case .countdown = $0 { return true } else { return false } }
        c.cancelCountdown()
        XCTAssertEqual(c.state, .idle)
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(c.takes.isEmpty)
        XCTAssertFalse(engine.calls.contains("start"))
        XCTAssertTrue(engine.calls.contains("cancel"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(files.isEmpty, "cancelled countdown must not leave a file: \(files)")
    }

    func testPrepareFailureReportsAndAllowsRetry() async {
        let engine = FakeEngine()
        engine.prepareError = RecordingError("Microphone not connected")
        let c = TakeController(engine: engine, sleep: { _ in })
        c.start(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { if case .failed = $0 { return true } else { return false } }
        if case .failed(let msg, let partial) = c.state {
            XCTAssertEqual(msg, "Microphone not connected"); XCTAssertNil(partial)
        }
        XCTAssertTrue(c.takes.isEmpty)
        engine.prepareError = nil
        c.countdownEnabled = false
        c.toggle(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { $0.isRecording }
    }

    func testDeviceLossDuringRecordingFinalizesAndKeepsTake() async {
        let engine = FakeEngine()
        let c = TakeController(engine: engine, sleep: { _ in })
        c.countdownEnabled = false
        c.start(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { $0.isRecording }
        c.engineFailed("The camera disconnected.")
        await waitFor(c) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let msg, let partial) = c.state else { return XCTFail() }
        XCTAssertTrue(msg.contains("camera disconnected"))
        XCTAssertEqual(partial?.status, .interrupted)
        XCTAssertEqual(c.takes.first?.status, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial!.fileURL.path))
    }

    func testWriterFailureMarksIncomplete() async {
        let engine = FakeEngine()
        engine.finishSucceeded = false
        let c = TakeController(engine: engine, sleep: { _ in })
        c.countdownEnabled = false
        c.start(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { $0.isRecording }
        c.stop()
        await waitFor(c) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(c.takes.first?.status, .incomplete)
    }

    func testTerminationFinalizes() async {
        let engine = FakeEngine()
        let c = TakeController(engine: engine, sleep: { _ in })
        c.countdownEnabled = false
        c.start(outputURL: url, audioOffsetMs: 0)
        await waitFor(c) { $0.isRecording }
        await c.finishForTermination()
        if case .saved = c.state {} else { XCTFail("expected saved, got \(c.state)") }
    }
}

final class OutputPlanningTests: XCTestCase {
    func testUniqueNamesNeverOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let tz = TimeZone(identifier: "UTC")!
        let first = TakeNamer.uniqueURL(in: folder, date: date, timeZone: tz)
        XCTAssertEqual(first.lastPathComponent, "LensPrompt 2026-10-26 at 07.33.20.mov")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = TakeNamer.uniqueURL(in: folder, date: date, timeZone: tz)
        XCTAssertEqual(second.lastPathComponent, "LensPrompt 2026-10-26 at 07.33.20 2.mov")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(TakeNamer.uniqueURL(in: folder, date: date, timeZone: tz).lastPathComponent,
                       "LensPrompt 2026-10-26 at 07.33.20 3.mov")
    }

    func testValidatorDetectsProblems() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lp-val-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("ro").path)
            try? FileManager.default.removeItem(at: base)
        }
        let created = base.appendingPathComponent("new/LensPrompt")
        XCTAssertNil(OutputValidator.validate(folder: created, minimumFreeBytes: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

        let ro = base.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        XCTAssertEqual(OutputValidator.validate(folder: ro, minimumFreeBytes: 1), .notWritable(ro.path))

        let file = base.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(OutputValidator.validate(folder: file, minimumFreeBytes: 1), .notADirectory(file.path))

        XCTAssertEqual(OutputValidator.validate(folder: created, minimumFreeBytes: 1000, availableBytes: { _ in 10 }),
                       .lowDiskSpace(available: 10, required: 1000))
        XCTAssertEqual(OutputValidator.validate(folder: base.appendingPathComponent("missing"), create: false),
                       .missingFolder(base.appendingPathComponent("missing").path))
    }

    func testAudioOffsetTimelineBothDirections() {
        let start = CMTime(value: 10_000, timescale: 1000)  // 10 s
        let plus = AudioOffsetTimeline(milliseconds: 250)
        let minus = AudioOffsetTimeline(milliseconds: -250)
        // Audio buffer captured at 10.000 s, 1024 frames @ 48 kHz (21.3 ms)
        XCTAssertEqual(plus.decide(pts: start, frames: 1024, sampleRate: 48000, sessionStart: start),
                       .write(CMTime(value: 10_250, timescale: 1000)))
        // Negative offset: the same buffer lands before the session start and is dropped.
        XCTAssertEqual(minus.decide(pts: start, frames: 1024, sampleRate: 48000, sessionStart: start), .drop)
        // Buffer straddling the session start after shifting: front-trimmed, not dropped.
        let straddle = CMTime(value: 10_240, timescale: 1000)
        guard case .trimFront(let skip, let newStart) = minus.decide(pts: straddle, frames: 1024, sampleRate: 48000, sessionStart: start) else {
            return XCTFail()
        }
        XCTAssertEqual(skip, 480)  // 10 ms at 48 kHz
        XCTAssertEqual(CMTimeGetSeconds(newStart), 10.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(newStart, start), 0)
        // Range clamps at ±1000 ms.
        XCTAssertEqual(AudioOffsetTimeline(milliseconds: 5000).offset, CMTime(value: 1000, timescale: 1000))
        XCTAssertEqual(AudioOffsetTimeline(milliseconds: -5000).offset, CMTime(value: -1000, timescale: 1000))
    }

    func testAACRatePlanning() {
        XCTAssertEqual(AudioFormatPlanner.aacSampleRate(forInput: 16000), 16000)
        XCTAssertEqual(AudioFormatPlanner.aacSampleRate(forInput: 24000), 24000)
        XCTAssertEqual(AudioFormatPlanner.aacSampleRate(forInput: 96000), 48000)
        XCTAssertEqual(AudioFormatPlanner.outputChannels(forInput: 6), 2)
        XCTAssertEqual(AudioFormatPlanner.outputChannels(forInput: 1), 1)
    }

    func testFormatChooserPrefers1080p30() {
        let formats = [
            FormatCandidate(index: 0, width: 1280, height: 720, maxFrameRate: 60, minFrameRate: 1),
            FormatCandidate(index: 1, width: 1920, height: 1080, maxFrameRate: 30, minFrameRate: 1),
            FormatCandidate(index: 2, width: 3840, height: 2160, maxFrameRate: 30, minFrameRate: 1),
        ]
        XCTAssertEqual(FormatChooser.choose(formats)?.index, 1)
        let noExact = [
            FormatCandidate(index: 0, width: 1080, height: 1920, maxFrameRate: 30, minFrameRate: 1),
            FormatCandidate(index: 1, width: 1760, height: 1328, maxFrameRate: 30, minFrameRate: 1),
            FormatCandidate(index: 2, width: 640, height: 480, maxFrameRate: 30, minFrameRate: 1),
        ]
        XCTAssertEqual(FormatChooser.choose(noExact)?.index, 1)
        XCTAssertEqual(FormatChooser.frameRate(for: FormatCandidate(index: 0, width: 1, height: 1, maxFrameRate: 24, minFrameRate: 24)), 24)
        XCTAssertNil(FormatChooser.choose([]))
    }
}

