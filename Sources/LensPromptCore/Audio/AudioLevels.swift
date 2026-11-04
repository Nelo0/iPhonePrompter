import Foundation

/// RMS / peak computation for meter display.
public enum AudioLevels {
    public static let floorDB: Float = -80

    public static func toDB(_ linear: Float) -> Float {
        linear <= 0 ? floorDB : max(floorDB, 20 * log10(linear))
    }

    /// Returns (rms dBFS, peak dBFS) for normalized float samples (-1...1).
    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (floorDB, floorDB) }
        var sum: Float = 0, peak: Float = 0
        for s in samples { sum += s * s; peak = max(peak, abs(s)) }
        return (toDB((sum / Float(samples.count)).squareRoot()), toDB(peak))
    }

    public static func measure(_ samples: [Float]) -> (rms: Float, peak: Float) {
        samples.withUnsafeBufferPointer { measure($0) }
    }

    public static func measureInt16(_ samples: UnsafeBufferPointer<Int16>) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (floorDB, floorDB) }
        var sum: Float = 0, peak: Float = 0
        for s in samples {
            let f = Float(s) / 32768
            sum += f * f; peak = max(peak, abs(f))
        }
        return (toDB((sum / Float(samples.count)).squareRoot()), toDB(peak))
    }
}

/// Meter state with peak hold, clipping indication and silence / no-signal detection.
public struct LevelMeterModel: Equatable, Sendable {
    public enum Health: Equatable, Sendable {
        case noInput        // no audio buffers arriving
        case silent         // buffers arrive but the signal is near digital silence
        case ok
    }

    public private(set) var rmsDB: Float = AudioLevels.floorDB
    public private(set) var peakDB: Float = AudioLevels.floorDB
    public private(set) var heldPeakDB: Float = AudioLevels.floorDB
    public private(set) var clipping = false

    private var lastBufferTime: Double = -.infinity
    private var lastSoundTime: Double = -.infinity
    private var lastClipTime: Double = -.infinity
    private var heldPeakTime: Double = -.infinity
    private var startedAt: Double?

    public var clipThresholdDB: Float = -0.5
    public var silenceThresholdDB: Float = -60
    public var silenceAfter: Double = 4
    public var noInputAfter: Double = 1.0
    public var clipHold: Double = 1.5
    public var peakHold: Double = 1.2

    public init() {}

    public mutating func update(rms: Float, peak: Float, at time: Double) {
        if startedAt == nil { startedAt = time }
        lastBufferTime = time
        rmsDB = rms
        peakDB = peak
        if peak >= heldPeakDB || time - heldPeakTime > peakHold { heldPeakDB = peak; heldPeakTime = time }
        if peak >= clipThresholdDB { lastClipTime = time }
        if rms > silenceThresholdDB { lastSoundTime = time }
        clipping = time - lastClipTime <= clipHold
    }

    public func health(at time: Double) -> Health {
        if time - lastBufferTime > noInputAfter { return .noInput }
        let since = max(lastSoundTime, startedAt ?? time)
        if time - since > silenceAfter { return .silent }
        return .ok
    }

    public mutating func decay(at time: Double) {
        clipping = time - lastClipTime <= clipHold
        if time - lastBufferTime > noInputAfter {
            rmsDB = AudioLevels.floorDB; peakDB = AudioLevels.floorDB; heldPeakDB = AudioLevels.floorDB
        }
    }

    /// 0...1 meter fraction for a dB value over a -60...0 dB scale.
    public static func fraction(_ db: Float) -> Double { Double(min(1, max(0, (db + 60) / 60))) }
}
