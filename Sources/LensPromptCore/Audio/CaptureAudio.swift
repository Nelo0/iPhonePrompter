import AVFoundation
import CoreMedia

/// Decodes every channel, including non-interleaved USB receiver audio. The size of
/// AudioBufferList varies with the channel count; a stack-allocated one-buffer list
/// cannot hold planar stereo and must not be interpreted as digital silence.
public enum CaptureAudio {
    public static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    public static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return result == noErr ? pcm : nil
    }

    public static func levels(_ pcm: AVAudioPCMBuffer) -> (rms: Float, peak: Float)? {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var sum: Double = 0
        var peak: Double = 0
        func accumulate(_ value: Double) {
            guard value.isFinite else { return }
            sum += value * value
            peak = max(peak, abs(value))
        }
        for channel in 0..<channels {
            for frame in 0..<frames {
                let offset = frame * pcm.stride
                switch pcm.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let data = pcm.floatChannelData else { return nil }
                    accumulate(Double(data[channel][offset]))
                case .pcmFormatInt16:
                    guard let data = pcm.int16ChannelData else { return nil }
                    accumulate(Double(data[channel][offset]) / 32768)
                case .pcmFormatInt32:
                    guard let data = pcm.int32ChannelData else { return nil }
                    accumulate(Double(data[channel][offset]) / 2147483648)
                default: return nil
                }
            }
        }
        return (AudioLevels.toDB(Float(sqrt(sum / Double(frames * channels)))), AudioLevels.toDB(Float(peak)))
    }
}
