import AVFoundation

/// Streaming conversion for the speech recognizer. Wireless receivers often expose
/// a stereo input with one transmitter on each channel. The default converter maps
/// only channel zero to mono, so explicitly mix both channels for recognition.
/// Recording keeps the original capture stream and is unaffected.
public final class SpeechAudioConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw RecordingError("The microphone format cannot be converted for speech recognition.")
            }
            converter.downmix = true
            self.converter = converter
        }
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buffer.format == inputFormat else {
            throw RecordingError("The microphone format changed during speech recognition. Restart following to reconnect it.")
        }
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecordingError("Could not allocate audio for speech recognition.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else {
            throw RecordingError("Microphone conversion failed: \(error?.localizedDescription ?? "unsupported audio format").")
        }
        return out
    }
}
