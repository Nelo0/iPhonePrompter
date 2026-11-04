import XCTest
import AVFoundation
import CoreMedia
@testable import LensPromptCore

final class ResultBox: @unchecked Sendable { var value: FinalizeResult? }

/// End-to-end writer tests with synthetic media (no camera or microphone involved).
/// A click is placed in the audio at a known capture time; after encoding, the click's
/// position in the decoded file must reflect the configured audio offset.
final class MovieWriterTests: XCTestCase {
    let sampleRate = 48000.0
    let base = 5000.0          // arbitrary capture-clock start, like a host-time clock
    let clickAt = 1.0          // seconds after the first video frame
    let duration = 3.0

    func makeVideoSample(pts: CMTime, width: Int = 320, height: Int = 180) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), 0x80, CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fmt!,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    func audioFormat() -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        return fmt!
    }

    func makeAudioSample(startFrame: Int, frames: Int, fmt: CMAudioFormatDescription) -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: frames)
        let clickFrame = Int(clickAt * sampleRate)
        for i in 0..<frames {
            let f = startFrame + i
            samples[i] = (f >= clickFrame && f < clickFrame + 48) ? 0.9 : 0.001 * sin(Float(f) * 0.05)
        }
        var block: CMBlockBuffer?
        let bytes = frames * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        }
        let pts = CMTime(seconds: base + Double(startFrame) / sampleRate, preferredTimescale: 48000)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    /// Feeds 3 s of interleaved media, like a capture session would.
    func writeTake(offsetMs: Int) throws -> (URL, FinalizeResult, MovieWriter) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-writer-\(UUID().uuidString).mov")
        let fmt = audioFormat()
        let writer = try MovieWriter(url: url, video: .init(width: 320, height: 180, frameRate: 30), audioFormat: fmt, audioOffsetMs: offsetMs)
        var started = false
        writer.onSessionStarted = { started = true }
        writer.beginAccepting()
        let framesPerBuffer = 1024
        var audioFrame = -Int(0.2 * sampleRate)   // audio starts 200 ms before video, like a warm session
        let totalVideo = Int(duration * 30)
        for v in 0..<totalVideo {
            let vt = Double(v) / 30
            while Double(audioFrame) / sampleRate < vt {
                writer.appendAudio(makeAudioSample(startFrame: audioFrame, frames: framesPerBuffer, fmt: fmt))
                audioFrame += framesPerBuffer
            }
            writer.appendVideo(makeVideoSample(pts: CMTime(seconds: base + vt, preferredTimescale: 600)))
            // Real-time inputs need a moment to drain.
            Thread.sleep(forTimeInterval: 0.006)
        }
        XCTAssertTrue(started)
        let exp = expectation(description: "finish")
        let box = ResultBox()
        writer.finish { box.value = $0; exp.fulfill() }
        wait(for: [exp], timeout: 20)
        return (url, box.value!, writer)
    }

    func clickTime(in url: URL) throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(out)
        reader.startReading()
        var firstPTS: Double?
        var index = 0
        var bestIndex = 0
        var best: Float = 0
        while let sb = out.copyNextSampleBuffer() {
            if firstPTS == nil { firstPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var data = [Float](repeating: 0, count: len / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for (i, s) in data.enumerated() where abs(s) > best { best = abs(s); bestIndex = index + i }
            index += data.count
        }
        XCTAssertGreaterThan(best, 0.3, "click should survive encoding")
        return (firstPTS ?? 0) + Double(bestIndex) / sampleRate
    }

    func assertTake(offsetMs: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let (url, result, writer) = try writeTake(offsetMs: offsetMs)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(result.succeeded, result.error ?? "", file: file, line: line)
        XCTAssertEqual(result.duration, duration, accuracy: 0.05, file: file, line: line)
        XCTAssertLessThanOrEqual(writer.droppedVideoFrames, 3, "encoder back-pressure only", file: file, line: line)
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1, file: file, line: line)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, file: file, line: line)
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), duration, accuracy: 0.1, file: file, line: line)
        let vTrack = asset.tracks(withMediaType: .video)[0]
        XCTAssertEqual(CMTimeGetSeconds(vTrack.timeRange.start), 0, accuracy: 0.001, file: file, line: line)
        let aTrack = asset.tracks(withMediaType: .audio)[0]
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(aTrack.timeRange.start), -0.0001, "audio must not start before the movie", file: file, line: line)
        XCTAssertLessThanOrEqual(CMTimeGetSeconds(aTrack.timeRange.end), duration + 0.05, "audio must be trimmed at the end", file: file, line: line)
        let measured = try clickTime(in: url)
        XCTAssertEqual(measured, clickAt + Double(offsetMs) / 1000, accuracy: 0.03,
                       "click at \(measured)s for offset \(offsetMs) ms", file: file, line: line)
    }

    func testZeroOffsetKeepsSync() throws { try assertTake(offsetMs: 0) }
    func testPositiveOffsetDelaysAudio() throws { try assertTake(offsetMs: 300) }
    func testNegativeOffsetAdvancesAudio() throws { try assertTake(offsetMs: -300) }
    func testExtremeOffsetsProduceValidFiles() throws {
        try assertTake(offsetMs: 900)
        try assertTake(offsetMs: -900)
    }

    func testRefusesToOverwrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-exists-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data("keep".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MovieWriter(url: url, video: .init(width: 320, height: 180, frameRate: 30), audioFormat: nil, audioOffsetMs: 0))
        XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8))
    }

    func testNoFramesFinishesAsFailureAndRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-empty-\(UUID().uuidString).mov")
        let writer = try MovieWriter(url: url, video: .init(width: 320, height: 180, frameRate: 30), audioFormat: audioFormat(), audioOffsetMs: 0)
        writer.beginAccepting()
        let exp = expectation(description: "finish")
        let box = ResultBox()
        writer.finish { box.value = $0; exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(box.value?.succeeded, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelRemovesPreparedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-cancel-\(UUID().uuidString).mov")
        let writer = try MovieWriter(url: url, video: .init(width: 320, height: 180, frameRate: 30), audioFormat: audioFormat(), audioOffsetMs: 0)
        writer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
