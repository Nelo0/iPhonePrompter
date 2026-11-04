import XCTest
import AVFoundation
@testable import LensPromptCore

final class SpeechAudioConverterTests: XCTestCase {
    func testEitherWirelessReceiverChannelReachesMonoRecognizer() throws {
        for interleaved in [true, false] {
            for activeChannel in 0..<2 {
                let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                        channels: 2, interleaved: interleaved))
                let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                         channels: 1, interleaved: false))
                let converter = try SpeechAudioConverter(inputFormat: input, outputFormat: output)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
                buffer.frameLength = 4800
                for frame in 0..<4800 {
                    for channel in 0..<2 {
                        buffer.floatChannelData![channel][frame * buffer.stride] =
                            channel == activeChannel ? 0.5 * sin(Float(frame) * 0.1) : 0
                    }
                }
                let converted = try converter.convert(buffer)
                XCTAssertEqual(converted.format, output)
                XCTAssertGreaterThan(converted.frameLength, 1000)
                let level = try XCTUnwrap(CaptureAudio.levels(converted))
                XCTAssertGreaterThan(level.peak, -18, "Active channel \(activeChannel), interleaved \(interleaved), must not disappear")
                XCTAssertGreaterThan(level.rms, -22)
            }
        }
    }

    func testMonoPassesThroughWithoutCopyingOrResampling() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let converter = try SpeechAudioConverter(inputFormat: format, outputFormat: format)
        XCTAssertTrue(try converter.convert(buffer) === buffer)
    }

    func testUnexpectedFormatIsAnErrorRatherThanSilentLoss() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = try SpeechAudioConverter(inputFormat: input, outputFormat: output)
        let wrong = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16))
        wrong.frameLength = 16
        XCTAssertThrowsError(try converter.convert(wrong))
    }
}
