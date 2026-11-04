import Foundation

/// Local persistence for app settings, the current script, layout presets and take
/// metadata. All writes are atomic. Recordings live elsewhere (the output folder) and are
/// never touched by this store.
public final class LocalStore: @unchecked Sendable {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LENSPROMPT_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LensPrompt", isDirectory: true)
    }

    public static var defaultOutputFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("LensPrompt", isDirectory: true)
    }

    public init(root: URL = LocalStore.defaultRoot) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var settingsURL: URL { root.appendingPathComponent("settings.json") }
    var scriptURL: URL { root.appendingPathComponent("script.txt") }
    var presetsURL: URL { root.appendingPathComponent("presets.json") }
    var takesURL: URL { root.appendingPathComponent("takes.json") }

    // MARK: Generic

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try decoder.decode(T.self, from: data) } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        lock.lock(); defer { lock.unlock() }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Settings

    public func loadSettings() -> AppSettings { load(AppSettings.self, from: settingsURL) ?? AppSettings() }
    public func saveSettings(_ s: AppSettings) throws { try save(s, to: settingsURL) }

    // MARK: Script

    public func loadScript() -> String? {
        lock.lock(); defer { lock.unlock() }
        return try? String(contentsOf: scriptURL, encoding: .utf8)
    }

    public func saveScript(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        try Data(text.utf8).write(to: scriptURL, options: .atomic)
    }

    /// Reads a user-chosen UTF-8 text/Markdown file.
    public static func readScriptFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        throw RecordingError("\(url.lastPathComponent) is not UTF-8 text. Save it as UTF-8 plain text or Markdown and try again.")
    }

    // MARK: Presets

    public func loadPresets() -> [LayoutPreset] { load([LayoutPreset].self, from: presetsURL) ?? [] }
    public func savePresets(_ p: [LayoutPreset]) throws { try save(p, to: presetsURL) }

    // MARK: Takes

    public func loadTakes() -> [TakeRecord] { load([TakeRecord].self, from: takesURL) ?? [] }
    public func saveTakes(_ t: [TakeRecord]) throws { try save(t, to: takesURL) }
}
