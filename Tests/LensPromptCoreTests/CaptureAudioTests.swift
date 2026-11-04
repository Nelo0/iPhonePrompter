import XCTest
import AVFoundation
import CoreMedia
@testable import LensPromptCore

final class CaptureAudioTests: XCTestCase {
    private func roundTrip(channels: Int, interleaved: Bool, common: AVAudioCommonFormat,
                           activeChannel: Int?, value: Float = 0.5) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 48000,
                                               channels: AVAudioChannelCount(channels), interleaved: interleaved))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        pcm.frameLength = 128
        for channel in 0..<channels {
            for frame in 0..<128 {
                let v: Float = channel == activeChannel ? value : 0
                let offset = frame * pcm.stride
                switch common {
                case .pcmFormatFloat32: pcm.floatChannelData![channel][offset] = v
                case .pcmFormatInt16: pcm.int16ChannelData![channel][offset] = Int16(v * 32768)
                case .pcmFormatInt32: pcm.int32ChannelData![channel][offset] = Int32(Double(v) * 2147483648)
                default: XCTFail("Unsupported fixture")
                }
            }
        }
        var description: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
                       makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                       sampleCount: 128, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                       sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let sb = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil,
                       blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sb), noErr)
        return try XCTUnwrap(CaptureAudio.pcmBuffer(sb))
    }

    func testPlanarStereoWithSoundOnlyOnSecondChannel() throws {
        let pcm = try roundTrip(channels: 2, interleaved: false, common: .pcmFormatFloat32, activeChannel: 1)
        let levels = try XCTUnwrap(CaptureAudio.levels(pcm))
        XCTAssertEqual(levels.peak, -6.0206, accuracy: 0.001)
        XCTAssertEqual(levels.rms, -9.0309, accuracy: 0.001)
        XCTAssertEqual(pcm.floatChannelData![1][0], 0.5)
        XCTAssertEqual(pcm.floatChannelData![0][0], 0)
    }

    func testInterleavedStereoWithSoundOnlyOnSecondChannel() throws {
        let levels = try XCTUnwrap(CaptureAudio.levels(roundTrip(channels: 2, interleaved: true,
                                  common: .pcmFormatFloat32, activeChannel: 1)))
        XCTAssertEqual(levels.peak, -6.0206, accuracy: 0.001)
        XCTAssertEqual(levels.rms, -9.0309, accuracy: 0.001)
    }

    func testMonoAndIntegerNativeFormats() throws {
        for common: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            let levels = try XCTUnwrap(CaptureAudio.levels(roundTrip(channels: 1, interleaved: false,
                                      common: common, activeChannel: 0)))
            XCTAssertEqual(levels.rms, -6.0206, accuracy: 0.001)
        }
    }

    func testActualSilenceRemainsSilence() throws {
        let levels = try XCTUnwrap(CaptureAudio.levels(roundTrip(channels: 2, interleaved: false,
                                  common: .pcmFormatFloat32, activeChannel: nil)))
        XCTAssertEqual(levels.rms, AudioLevels.floorDB)
        XCTAssertEqual(levels.peak, AudioLevels.floorDB)
    }
}
