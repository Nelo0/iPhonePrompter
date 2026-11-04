import XCTest
@testable import LensPromptCore

final class RecordingLibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func take(in folder: URL, name: String = "Original.mov") throws -> TakeRecord {
        let url = folder.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return TakeRecord(fileURL: url, createdAt: Date(), duration: 10, status: .interrupted, note: "Camera disconnected")
    }

    func testDiscoveryExcludesActiveRecordingDirectoriesSymlinksAndNonMovies() throws {
        let root = try folder()
        let saved = try take(in: root)
        let active = try take(in: root, name: "Active.mov")
        _ = try take(in: root, name: "notes.txt")
        _ = try take(in: root, name: ".hidden.mov")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.mov"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.mov"), withDestinationURL: saved.fileURL)
        let files = try RecordingLibrary.discover(in: root, excluding: active.fileURL)
        XCTAssertEqual(files.map { $0.url.resolvingSymlinksInPath() }, [saved.fileURL.resolvingSymlinksInPath()])
        XCTAssertEqual(files.first?.bytes, 7)
    }

    func testRenamePreservesContentsExtensionAndMetadata() throws {
        let original = try take(in: folder())
        let renamed = try RecordingLibrary.rename(original, to: "  My best take.mov  ")
        XCTAssertEqual(renamed.fileName, "My best take.mov")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.status, .interrupted)
        XCTAssertEqual(renamed.note, original.note)
        XCTAssertEqual(try Data(contentsOf: renamed.fileURL), Data("fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
    }

    func testRenameNeverOverwritesExistingTake() throws {
        let root = try folder()
        let first = try take(in: root)
        let other = try take(in: root, name: "Keep.mov")
        try Data("different contents".utf8).write(to: other.fileURL)
        XCTAssertThrowsError(try RecordingLibrary.rename(first, to: "Keep"))
        XCTAssertEqual(try String(contentsOf: other.fileURL, encoding: .utf8), "different contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
    }

    func testRenameRejectsPathTraversalAndHiddenOrInvalidNames() throws {
        let original = try take(in: folder())
        for name in ["", "   ", ".", "..", "../escape", "folder/file", "folder\\file", "bad:name", ".hidden", "bad\nname"] {
            XCTAssertThrowsError(try RecordingLibrary.rename(original, to: name), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.fileURL.path))
    }

    func testMergingPreservesKnownIDAndInterruptedStatusWithoutDuplicates() throws {
        let known = try take(in: folder())
        let rediscovered = TakeRecord(fileURL: known.fileURL.resolvingSymlinksInPath(), createdAt: Date(), duration: 10, status: .complete)
        let merged = RecordingLibrary.merging([rediscovered], into: [known])
        XCTAssertEqual(merged, [known])
    }

    func testTrashFailureLeavesOriginalFileUntouched() throws {
        let original = try take(in: folder())
        XCTAssertThrowsError(try RecordingLibrary.moveToTrash(original, using: { _ in throw RecordingError("Denied") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.fileURL.path))
    }

    func testTrashUsesRecoverableMoveInsteadOfDeletingContents() throws {
        let root = try folder()
        let original = try take(in: root)
        let simulatedTrash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: simulatedTrash, withIntermediateDirectories: false)
        let trashedURL = simulatedTrash.appendingPathComponent(original.fileName)
        try RecordingLibrary.moveToTrash(original, using: { try FileManager.default.moveItem(at: $0, to: trashedURL) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: trashedURL), Data("fixture".utf8))
    }
}
