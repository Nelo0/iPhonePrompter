import Foundation
import AVFoundation
import Speech
import LensPromptCore

enum SpeechEvent: Sendable {
    case hypothesis(Hypothesis, latency: Double?)
    case failed(String)
}

enum SpeechAvailability: Equatable {
    case unknown
    case checking
    case ready
    case needsDownload
    case downloading(Double)
    case unavailable(String)

    var label: String {
        switch self {
        case .unknown, .checking: return "Checking on-device speech recognition…"
        case .ready: return "On-device English recognition ready"
        case .needsDownload: return "Speech following needs macOS to enable its on-device English speech model for LensPrompt (it downloads it if it is not already on this Mac)."
        case .downloading(let p): return "Downloading speech model… \(Int(p * 100))%"
        case .unavailable(let why): return why
        }
    }
}

/// Recognition is behind this interface so a different local engine can be substituted.
protocol SpeechRecognizing: AnyObject, Sendable {
    var events: AsyncStream<SpeechEvent> { get }
    func start(naturalFormat: AVAudioFormat) async throws
    /// Non-blocking; safe to call from the capture queue. Buffers are bounded.
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

/// Local recognition using SpeechAnalyzer + SpeechTranscriber (macOS 26). Audio never
/// leaves the Mac; models are system-managed assets installed through AssetInventory.
final class LocalSpeechTranscriberAdapter: SpeechRecognizing, @unchecked Sendable {
    static let locale = Locale(identifier: "en-US")

    let events: AsyncStream<SpeechEvent>
    private let eventCont: AsyncStream<SpeechEvent>.Continuation
    private var rawCont: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var tasks: [Task<Void, Never>] = []
    private let lock = NSLock()
    private var fedSeconds: Double = 0

    init() {
        (events, eventCont) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    static func availability() async -> SpeechAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("On-device speech recognition is not available on this Mac. Use fixed-speed or manual scrolling.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
            return .unavailable("English (US) on-device recognition is not supported here. Use fixed-speed or manual scrolling.")
        }
        let t = makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .downloading: return .downloading(0)
        case .unsupported: return .unavailable("The speech model for English is unsupported on this Mac.")
        @unknown default: return .unavailable("Unknown speech model state.")
        }
    }

    /// Asks macOS to download/install the system speech model (explicit user action).
    static func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else { return }
        let t = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            try await request.downloadAndInstall()
            observation.invalidate()
        }
    }

    func start(naturalFormat: AVAudioFormat) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
            throw RecordingError("English on-device recognition is not supported on this Mac.")
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else {
            throw RecordingError("No compatible audio format for speech recognition.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(400))
        let (rawStream, rawCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(400))
        lock.withLock {
            self.analyzer = analyzer; self.transcriber = transcriber
            self.inputCont = inputCont; self.rawCont = rawCont; self.fedSeconds = 0
        }

        try await analyzer.start(inputSequence: inputStream)

        // Results → hypotheses. Volatile results replace each other; finals commit.
        let eventCont = self.eventCont
        tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let end = result.range.end
                    var latency: Double?
                    if let self, end.isValid {
                        latency = max(0, self.fed - CMTimeGetSeconds(end))
                    }
                    eventCont.yield(.hypothesis(Hypothesis(text: text, isFinal: result.isFinal), latency: latency))
                }
            } catch is CancellationError {
            } catch {
                eventCont.yield(.failed("Speech recognition stopped: \(error.localizedDescription). Manual and fixed-speed scrolling still work."))
            }
        })

        // Format conversion off the capture queue.
        tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
            var converter: SpeechAudioConverter?
            var converterInput: AVAudioFormat?
            for await buffer in rawStream {
                guard let self else { break }
                let out: AVAudioPCMBuffer
                do {
                    if converterInput != buffer.format {
                        converter = try SpeechAudioConverter(inputFormat: buffer.format, outputFormat: analyzerFormat)
                        converterInput = buffer.format
                    }
                    guard let converter else { throw RecordingError("Speech audio converter is not ready.") }
                    out = try converter.convert(buffer)
                } catch {
                    eventCont.yield(.failed(error.localizedDescription))
                    break
                }
                guard out.frameLength > 0 else { continue }
                self.addFed(Double(out.frameLength) / analyzerFormat.sampleRate)
                inputCont.yield(AnalyzerInput(buffer: out))
            }
            inputCont.finish()
        })
    }

    private var fed: Double { lock.lock(); defer { lock.unlock() }; return fedSeconds }
    private func addFed(_ s: Double) { lock.lock(); fedSeconds += s; lock.unlock() }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let c = rawCont; lock.unlock()
        c?.yield(buffer)
    }

    func stop() async {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            let a = self.analyzer
            rawCont?.finish(); rawCont = nil
            self.analyzer = nil; self.transcriber = nil
            return a
        }
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
