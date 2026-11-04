import Foundation
import CoreMedia

/// Unique, never-overwriting take names: "LensPrompt 2026-11-04 at 10.15.30.mov",
/// then " 2", " 3"… if that name exists.
public enum TakeNamer {
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "LensPrompt \(f.string(from: date))"
    }

    public static func uniqueURL(in folder: URL, date: Date, ext: String = "mov",
                                 timeZone: TimeZone = .current,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = baseName(for: date, timeZone: timeZone)
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Pre-flight checks for the output folder.
public enum OutputValidator {
    public static let defaultMinimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    public enum Problem: Equatable, Sendable {
        case missingFolder(String)
        case notADirectory(String)
        case notWritable(String)
        case lowDiskSpace(available: Int64, required: Int64)

        public var message: String {
            switch self {
            case .missingFolder(let p): return "The output folder does not exist: \(p). Choose another folder."
            case .notADirectory(let p): return "The output location is not a folder: \(p)."
            case .notWritable(let p): return "LensPrompt cannot write to \(p). Choose a folder you can write to."
            case .lowDiskSpace(let a, let r):
                let fmt = ByteCountFormatter()
                return "Not enough free space: \(fmt.string(fromByteCount: a)) available, at least \(fmt.string(fromByteCount: r)) needed."
            }
        }
    }

    /// Creates the folder if its parent exists and `create` is true, then verifies
    /// that a file can really be written (permission bits alone can be misleading).
    public static func validate(folder: URL, minimumFreeBytes: Int64 = defaultMinimumFreeBytes,
                                create: Bool = true,
                                availableBytes: ((URL) -> Int64?)? = nil) -> Problem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard create else { return .missingFolder(folder.path) }
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                return .notWritable(folder.path)
            }
            isDir = true
        }
        guard isDir.boolValue else { return .notADirectory(folder.path) }
        let probe = folder.appendingPathComponent(".lensprompt-write-test-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: probe, options: .withoutOverwriting)
            try fm.removeItem(at: probe)
        } catch {
            return .notWritable(folder.path)
        }
        let available = availableBytes?(folder) ?? freeBytes(at: folder)
        if let available, available < minimumFreeBytes {
            return .lowDiskSpace(available: available, required: minimumFreeBytes)
        }
        return nil
    }

    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Audio sync offset convention: **positive values delay audio relative to video**.
/// Audio timestamps are shifted by the offset in the capture clock domain; samples that
/// land before the writer session start are dropped, and the session end trims the tail.
public struct AudioOffsetTimeline: Equatable, Sendable {
    public static let range = -1000...1000
    public let offset: CMTime

    public init(milliseconds: Int) {
        let clamped = min(max(milliseconds, Self.range.lowerBound), Self.range.upperBound)
        offset = CMTime(value: CMTimeValue(clamped), timescale: 1000)
    }

    public func adjusted(_ pts: CMTime) -> CMTime { CMTimeAdd(pts, offset) }

    public enum Decision: Equatable { case write(CMTime), drop, trimFront(frames: Int, newStart: CMTime) }

    /// Decides what to do with an audio buffer of `frames` frames at `sampleRate`
    /// captured at `pts`, given the video-defined session start.
    public func decide(pts: CMTime, frames: Int, sampleRate: Double, sessionStart: CMTime) -> Decision {
        let start = adjusted(pts)
        let duration = CMTime(seconds: Double(frames) / sampleRate, preferredTimescale: CMTimeScale(sampleRate.rounded()))
        let end = CMTimeAdd(start, duration)
        if CMTimeCompare(end, sessionStart) <= 0 { return .drop }
        if CMTimeCompare(start, sessionStart) >= 0 { return .write(start) }
        let skipSeconds = CMTimeGetSeconds(CMTimeSubtract(sessionStart, start))
        let skip = min(frames, Int((skipSeconds * sampleRate).rounded(.up)))
        if skip >= frames { return .drop }
        let newStart = CMTimeAdd(start, CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(sampleRate.rounded())))
        return .trimFront(frames: skip, newStart: newStart)
    }
}

/// AAC-compatible output rate for a captured input rate (Bluetooth mics are often 16/24 kHz).
public enum AudioFormatPlanner {
    public static let aacRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    public static func aacSampleRate(forInput rate: Double) -> Double {
        if aacRates.contains(rate) { return rate }
        return aacRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 48000
    }

    public static func outputChannels(forInput channels: Int) -> Int { min(max(channels, 1), 2) }
}

/// A capture format candidate abstracted from AVCaptureDevice.Format for testing.
public struct FormatCandidate: Equatable, Sendable {
    public var index: Int
    public var width: Int
    public var height: Int
    public var maxFrameRate: Double
    public var minFrameRate: Double
    public init(index: Int, width: Int, height: Int, maxFrameRate: Double, minFrameRate: Double) {
        self.index = index; self.width = width; self.height = height
        self.maxFrameRate = maxFrameRate; self.minFrameRate = minFrameRate
    }
    public var supports30: Bool { maxFrameRate >= 29.9 && minFrameRate <= 30.1 }
}

public enum FormatChooser {
    /// Prefers exactly 1920×1080 that supports 30 fps; otherwise the landscape format
    /// closest in pixel count to 1080p that supports 30 fps; otherwise the closest overall.
    public static func choose(_ formats: [FormatCandidate], width: Int = 1920, height: Int = 1080) -> FormatCandidate? {
        if let exact = formats.first(where: { $0.width == width && $0.height == height && $0.supports30 }) { return exact }
        let targetPixels = Double(width * height)
        func cost(_ f: FormatCandidate) -> Double {
            var c = abs(log(Double(f.width * f.height) / targetPixels))
            if f.height > f.width { c += 2 }  // prefer landscape
            if !f.supports30 { c += 1 }
            return c
        }
        return formats.min(by: { cost($0) < cost($1) })
    }

    /// Frame rate to use for a chosen format: 30 if supported, else the max available ≤ 30, else max.
    public static func frameRate(for f: FormatCandidate) -> Double {
        if f.supports30 { return 30 }
        if f.maxFrameRate < 30 { return f.maxFrameRate }
        return f.minFrameRate > 30 ? f.minFrameRate : 30
    }
}
