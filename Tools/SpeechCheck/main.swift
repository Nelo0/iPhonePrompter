// lensprompt-speech-check
//
// Offline verification of the real on-device recognizer + LensPrompt's script aligner.
// It never uses the microphone: speech is synthesized with `say` into a temporary file,
// then streamed to SpeechAnalyzer in real time (paced 100 ms chunks) exactly like live
// capture would be. It reports recognition latency and whether alignment reached the
// expected script positions without backward jumps.
//
// Usage: lensprompt-speech-check [--right-channel] [--fast]   (--fast streams as fast as possible)

import Foundation
@preconcurrency import AVFoundation
import Speech
import LensPromptCore

let script = """
Hello everyone, and welcome back to the channel. Today I want to show you how I record videos with my phone on a tripod. \
The phone sits right in front of the screen, so the words stay close to the lens. \
First, I open the script and choose the follow my voice mode. Then I press record and simply start talking. \
If I pause for a moment, the text waits for me. If I stumble, I can just say the sentence again. \
At the end, I stop the recording and the movie file is saved on my Mac. Thanks for watching, and see you next time.
"""

// What the "speaker" says: fillers, a pause, a repeated sentence, and a skipped phrase.
let spoken = """
Hello everyone, um, and welcome back to the channel. Today I want to show you how I record videos with my phone on a tripod. \
[[slnc 1500]] The phone sits right in front of the screen. \
First, I open the script and choose the follow my voice mode. First, I open the script and choose the follow my voice mode. \
Then I press record and simply start talking. \
If I stumble, I can just say the sentence again. \
At the end, I stop the recording and the movie file is saved on my Mac. Thanks for watching, and see you next time.
"""

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); exit(1) }

@main
struct SpeechCheck {
    static func main() async {
        let fast = CommandLine.arguments.contains("--fast")
        let rightChannel = CommandLine.arguments.contains("--right-channel")
        guard SpeechTranscriber.isAvailable else { fail("SpeechTranscriber is not available on this Mac") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { fail("en-US unsupported") }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        var status = await AssetInventory.status(forModules: [transcriber])
        print("asset status: \(status)")
        if status != .installed {
            // Assets are reserved per app; this asks macOS to install/reserve the system model.
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    print("requesting system speech model installation…")
                    try await req.downloadAndInstall()
                }
            } catch { fail("speech model installation failed: \(error)") }
            status = await AssetInventory.status(forModules: [transcriber])
            print("asset status after request: \(status)")
        }
        guard status == .installed else { fail("speech assets not installed") }

        // 1. Synthesize speech (no microphone involved).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lensprompt-speechcheck-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-r", "170", "-o", tmp.path, spoken]
        do { try say.run(); say.waitUntilExit() } catch { fail("say failed: \(error)") }
        guard say.terminationStatus == 0 else { fail("say exited \(say.terminationStatus)") }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: tmp) } catch { fail("cannot read synthesized audio: \(error)") }
        let fileFormat = file.processingFormat
        let srcFormat = rightChannel
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileFormat.sampleRate, channels: 2, interleaved: true)!
            : fileFormat
        if rightChannel { print("regression input: silent left channel, synthesized speech on right channel only") }
        let duration = Double(file.length) / srcFormat.sampleRate
        print(String(format: "synthesized %.1f s of speech at %.0f Hz", duration, srcFormat.sampleRate))

        // 2. Analyzer fed through an input stream, like the app does.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: srcFormat) else { fail("no analyzer format") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do { try await analyzer.prepareToAnalyze(in: analyzerFormat) } catch { fail("prepare failed: \(error)") }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        do { try await analyzer.start(inputSequence: stream) } catch { fail("start failed: \(error)") }

        let doc = ScriptDocument(text: script)
        let aligner = ScriptAligner(document: doc)
        let clock = ContinuousClock()
        let t0 = clock.now
        actor Feed { var fedAt: [(audioEnd: Double, wall: Double)] = []; func add(_ a: Double, _ w: Double) { fedAt.append((a, w)) }
            func wallTime(forAudio t: Double) -> Double? { fedAt.first(where: { $0.audioEnd >= t })?.wall } }
        let feed = Feed()

        let resultsTask = Task { () -> [(Double, Bool, Int, TrackingStatus, Double?)] in
            var log: [(Double, Bool, Int, TrackingStatus, Double?)] = []
            do {
                for try await r in transcriber.results {
                    let now = (clock.now - t0).seconds
                    let audioEnd = CMTimeGetSeconds(r.range.end)
                    let fedWall = await feed.wallTime(forAudio: audioEnd)
                    let latency = fedWall.map { now - $0 }
                    let out = aligner.ingest(Hypothesis(text: String(r.text.characters), isFinal: r.isFinal))
                    log.append((now, r.isFinal, out.position, out.status, latency))
                }
            } catch { print("results error: \(error)") }
            return log
        }

        // 3. Stream audio in 100 ms chunks, paced in real time unless --fast.
        let converter: SpeechAudioConverter
        do { converter = try SpeechAudioConverter(inputFormat: srcFormat, outputFormat: analyzerFormat) }
        catch { fail("converter setup failed: \(error)") }
        let chunk = AVAudioFrameCount(srcFormat.sampleRate / 10)
        var audioPos = 0.0
        while file.framePosition < file.length {
            let source = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: chunk)!
            do { try file.read(into: source, frameCount: chunk) } catch { break }
            let buf: AVAudioPCMBuffer
            if rightChannel {
                let stereo = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: source.frameLength)!
                stereo.frameLength = source.frameLength
                for frame in 0..<Int(source.frameLength) {
                    stereo.floatChannelData![0][frame * stereo.stride] = 0
                    stereo.floatChannelData![1][frame * stereo.stride] = source.floatChannelData![0][frame * source.stride]
                }
                buf = stereo
            } else { buf = source }
            let out: AVAudioPCMBuffer
            do { out = try converter.convert(buf) } catch { fail("speech conversion failed: \(error)") }
            audioPos += Double(buf.frameLength) / srcFormat.sampleRate
            cont.yield(AnalyzerInput(buffer: out))
            await feed.add(audioPos, (clock.now - t0).seconds)
            if !fast {
                let target = t0 + .milliseconds(Int(audioPos * 1000))
                try? await Task.sleep(until: target, clock: clock)
            }
        }
        cont.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { print("finalize error: \(error)") }
        let log = await resultsTask.value

        // 4. Report.
        var maxBack = 0, last = 0
        for e in log { maxBack = max(maxBack, last - e.2); last = e.2 }
        let latencies = log.compactMap { $0.4 }.sorted()
        func pct(_ p: Double) -> Double { latencies.isEmpty ? .nan : latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * p))] }
        print("results: \(log.count) (\(log.filter { $0.1 }.count) final)")
        print(String(format: "recognition latency (audio fed → result): median %.2f s, p90 %.2f s, max %.2f s%@",
                     pct(0.5), pct(0.9), latencies.last ?? .nan, fast ? " [--fast: not real-time]" : ""))
        print("final position \(aligner.position) / \(doc.tokens.count) tokens, status \(aligner.status.rawValue), max backward step \(maxBack)")
        let skipped = "if i pause for a moment the text waits for me"
        print("note: spoken audio skips the phrase \"\(skipped)\" and repeats one sentence.")
        if aligner.position < doc.tokens.count - 3 { fail("alignment did not reach the end of the script") }
        if maxBack > 25 { fail("alignment moved backward by \(maxBack) tokens") }
        print("PASS")
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
