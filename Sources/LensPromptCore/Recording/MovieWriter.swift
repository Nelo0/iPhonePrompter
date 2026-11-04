import Foundation
import AVFoundation
import CoreMedia

/// Writes captured camera frames and microphone audio into a QuickTime movie (H.264 + AAC).
///
/// Threading: every method must be called on the same serial queue (the capture data
/// queue). Timestamps are taken from the sample buffers themselves — all buffers from one
/// AVCaptureSession share its synchronization clock — never from UI callback times.
public final class MovieWriter: @unchecked Sendable {
    public let url: URL
    public let timeline: AudioOffsetTimeline
    public private(set) var failure: String?
    public private(set) var droppedVideoFrames = 0
    public private(set) var writtenVideoFrames = 0
    public private(set) var writtenAudioBuffers = 0
    public private(set) var sessionStart: CMTime?

    /// Invoked on the writer queue when the first video frame starts the session.
    public var onSessionStarted: (() -> Void)?
    /// Invoked on the writer queue the first time a write error occurs.
    public var onFailure: ((String) -> Void)?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var accepting = false
    private var finished = false
    private var lastVideoPTS: CMTime = .invalid
    private var lastVideoEnd: CMTime = .invalid
    private var frameDuration: CMTime
    private var pendingAudio: [CMSampleBuffer] = []
    private let pendingAudioLimit = 200

    public struct VideoSpec: Sendable {
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public init(width: Int, height: Int, frameRate: Double) {
            self.width = width; self.height = height; self.frameRate = frameRate
        }
    }

    /// Creates the file and prepares inputs. `audioFormat` is the capture audio format; pass
    /// nil only for video-only tests (the app always requires a microphone).
    public init(url: URL, video: VideoSpec, audioFormat: CMAudioFormatDescription?, audioOffsetMs: Int) throws {
        self.url = url
        self.timeline = AudioOffsetTimeline(milliseconds: audioOffsetMs)
        let fps = max(1, video.frameRate)
        frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        if FileManager.default.fileExists(atPath: url.path) {
            throw RecordingError("Refusing to overwrite existing file \(url.lastPathComponent).")
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let pixels = Double(video.width * video.height)
        let bitrate = Int(min(40_000_000, max(4_000_000, pixels * fps * 0.25)))  // ~15.5 Mbps at 1080p30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError("The video encoder settings are not supported.") }
        writer.add(videoInput)

        if let audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee {
            let rate = AudioFormatPlanner.aacSampleRate(forInput: asbd.mSampleRate)
            let channels = AudioFormatPlanner.outputChannels(forInput: Int(asbd.mChannelsPerFrame))
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVChannelLayoutKey: layoutData,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError("The audio encoder settings are not supported for this microphone format.") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else {
            throw RecordingError("Could not create the movie file: \(writer.error?.localizedDescription ?? "unknown error").")
        }
    }

    /// Begin accepting media; the session starts at the next video frame.
    public func beginAccepting() { accepting = true }

    public var durationSeconds: Double {
        guard let s = sessionStart, lastVideoEnd.isValid else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(lastVideoEnd, s)))
    }

    public func appendVideo(_ sample: CMSampleBuffer) {
        guard accepting, !finished, failure == nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        if lastVideoPTS.isValid && CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            flushPendingAudio()
            onSessionStarted?()
        }
        guard videoInput.isReadyForMoreMediaData else { droppedVideoFrames += 1; return }
        if !videoInput.append(sample) { fail("Writing video failed: \(writer.error?.localizedDescription ?? "unknown error")."); return }
        writtenVideoFrames += 1
        let dur = CMSampleBufferGetDuration(sample)
        if dur.isValid && CMTimeCompare(dur, .zero) > 0 { frameDuration = dur }
        lastVideoPTS = pts
        lastVideoEnd = CMTimeAdd(pts, frameDuration)
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        guard accepting, !finished, failure == nil, let audioInput else { return }
        guard let start = sessionStart else {
            pendingAudio.append(sample)
            if pendingAudio.count > pendingAudioLimit { pendingAudio.removeFirst(pendingAudio.count - pendingAudioLimit) }
            return
        }
        writeAudio(sample, input: audioInput, sessionStart: start)
    }

    private func flushPendingAudio() {
        guard let audioInput, let start = sessionStart else { return }
        let pending = pendingAudio
        pendingAudio = []
        for s in pending { writeAudio(s, input: audioInput, sessionStart: start) }
    }

    private func writeAudio(_ sample: CMSampleBuffer, input: AVAssetWriterInput, sessionStart: CMTime) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        var output: CMSampleBuffer?
        switch timeline.decide(pts: pts, frames: frames, sampleRate: asbd.mSampleRate, sessionStart: sessionStart) {
        case .drop: return
        case .write(let newPTS):
            output = Self.retime(sample, to: newPTS)
        case .trimFront(let skip, let newPTS):
            var sub: CMSampleBuffer?
            let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                                sampleRange: CFRange(location: skip, length: frames - skip),
                                                                sampleBufferOut: &sub)
            guard status == noErr, let sub else { return }
            output = Self.retime(sub, to: newPTS)
        }
        guard let output else { return }
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(output) { fail("Writing audio failed: \(writer.error?.localizedDescription ?? "unknown error")."); return }
        writtenAudioBuffers += 1
    }

    /// Copies a sample buffer, shifting all timing entries so the first PTS equals `pts`.
    static func retime(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        let delta = CMTimeSubtract(pts, original)
        if CMTimeCompare(delta, .zero) == 0 { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0..<Int(count) {
            if timings[i].presentationTimeStamp.isValid { timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, delta) }
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, delta) }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        onFailure?(message)
    }

    /// Finalizes the movie. The completion runs on an AVFoundation queue.
    public func finish(completion: @escaping @Sendable (FinalizeResult) -> Void) {
        guard !finished else { return }
        finished = true
        accepting = false
        let url = self.url
        guard let start = sessionStart, writtenVideoFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(FinalizeResult(fileURL: url, duration: 0, succeeded: false,
                                      error: failure ?? "No video frames were received, so no take was saved."))
            return
        }
        let duration = durationSeconds
        let priorFailure = failure
        if writer.status == .writing {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            writer.endSession(atSourceTime: lastVideoEnd.isValid ? lastVideoEnd : start)
            let writer = self.writer
            writer.finishWriting {
                let ok = writer.status == .completed
                completion(FinalizeResult(fileURL: url, duration: duration, succeeded: ok && priorFailure == nil,
                                          error: ok ? priorFailure : (writer.error?.localizedDescription ?? "The movie could not be finalized.")))
            }
        } else {
            // The writer already failed; the file (with completed movie fragments) is left in place.
            completion(FinalizeResult(fileURL: url, duration: duration, succeeded: false,
                                      error: priorFailure ?? writer.error?.localizedDescription ?? "The movie could not be finalized."))
        }
    }

    /// Discards a writer that never started a session and removes its file.
    public func cancel() {
        guard !finished else { return }
        finished = true
        accepting = false
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
