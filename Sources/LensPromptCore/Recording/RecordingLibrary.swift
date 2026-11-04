import Foundation

public struct RecordingFile: Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let bytes: Int64
}

/// File operations for completed takes. Discovery never follows symbolic links or
/// includes the writer's active file. Renaming never overwrites another recording.
public enum RecordingLibrary {
    public static func discover(in folder: URL, excluding activeURL: URL? = nil) throws -> [RecordingFile] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]).compactMap { url in
                guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
                      url.resolvingSymlinksInPath().standardizedFileURL != activeURL?.resolvingSymlinksInPath().standardizedFileURL else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return RecordingFile(url: url, createdAt: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0))
            }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Retains known take IDs and interruption details when finding files on disk.
    public static func merging(_ discovered: [TakeRecord], into existing: [TakeRecord]) -> [TakeRecord] {
        var seen = Set<URL>()
        return (existing + discovered).filter { seen.insert($0.fileURL.resolvingSymlinksInPath().standardizedFileURL).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func rename(_ take: TakeRecord, to proposedName: String) throws -> TakeRecord {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = take.fileURL.pathExtension
        if !ext.isEmpty, name.lowercased().hasSuffix(".\(ext.lowercased())") { name = String(name.dropLast(ext.count + 1)) }
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains(where: { "/\\:".contains($0) || $0.isNewline || $0.asciiValue == 0 }) else {
            throw RecordingError("Use a file name without slashes, colons, or a leading dot.")
        }
        let destination = take.fileURL.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext)
        if destination == take.fileURL { return take }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RecordingError("A recording named \(destination.lastPathComponent) already exists. Choose a different name.")
        }
        try FileManager.default.moveItem(at: take.fileURL, to: destination)
        var updated = take
        updated.fileURL = destination
        return updated
    }

    public static func moveToTrash(_ take: TakeRecord, using trash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws {
        try trash(take.fileURL)
    }
}
