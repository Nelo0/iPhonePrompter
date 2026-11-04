import Foundation
import CoreGraphics

/// Prompt typography and appearance.
public struct PromptStyle: Codable, Equatable, Sendable {
    public var fontSize: Double = 30
    public var lineSpacing: Double = 6
    public var backgroundOpacity: Double = 0.85
    public var activeLineEmphasis: Double = 0.7   // 0 = none, 1 = strong dimming of other lines
    public var activeEdge: ActiveLineEdge = .bottom
    /// Extra distance in points between the panel edge and the active line block.
    public var edgeInset: Double = 10
    /// When the active line is at the bottom edge, how many upcoming lines stay visible below it.
    public var upcomingLinesBelow: Int = 1
    public var horizontalPadding: Double = 16
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PromptStyle()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        fontSize = v(.fontSize, d.fontSize); lineSpacing = v(.lineSpacing, d.lineSpacing)
        backgroundOpacity = v(.backgroundOpacity, d.backgroundOpacity)
        activeLineEmphasis = v(.activeLineEmphasis, d.activeLineEmphasis)
        activeEdge = v(.activeEdge, d.activeEdge); edgeInset = v(.edgeInset, d.edgeInset)
        upcomingLinesBelow = min(3, max(0, v(.upcomingLinesBelow, d.upcomingLinesBelow)))
        horizontalPadding = v(.horizontalPadding, d.horizontalPadding)
    }
}

/// Saved geometry for the prompt panel and phone guide, plus how they relate.
public struct LayoutPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var screenID: String
    public var screenName: String
    public var phoneFrame: SavedFrame
    public var lensOffset: CGPoint
    public var clusterSide: ClusterSide
    /// nil in presets saved before rotation support (= top).
    public var clusterAtBottom: Bool?
    public var promptFrame: SavedFrame
    public var arrangement: PhoneArrangement
    public var style: PromptStyle
    public var guideOpacity: Double
    public var locked: Bool

    public init(name: String, screenID: String, screenName: String, phoneFrame: SavedFrame, lensOffset: CGPoint,
                clusterSide: ClusterSide, promptFrame: SavedFrame, arrangement: PhoneArrangement,
                style: PromptStyle, guideOpacity: Double, locked: Bool, clusterAtBottom: Bool = false) {
        self.clusterAtBottom = clusterAtBottom
        self.name = name; self.screenID = screenID; self.screenName = screenName; self.phoneFrame = phoneFrame
        self.lensOffset = lensOffset; self.clusterSide = clusterSide; self.promptFrame = promptFrame
        self.arrangement = arrangement; self.style = style; self.guideOpacity = guideOpacity; self.locked = locked
    }
}

/// All persisted app preferences. Unknown/missing keys fall back to defaults so older
/// settings files keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var orientation: PhoneOrientation {
        get { PhoneOrientation(side: clusterSide, atBottom: clusterAtBottom, lensOffset: lensOffset) }
        set { clusterSide = newValue.side; clusterAtBottom = newValue.atBottom; lensOffset = newValue.lensOffset }
    }

    public var cameraID: String?
    public var cameraName: String?
    public var microphoneID: String?
    public var microphoneName: String?
    public var outputFolderPath: String?
    public var audioOffsetMs: Int = 0
    public var countdownEnabled = true
    public var previewMirrored = false
    public var showFramingGuides = false
    public var previewHidden = false
    public var promptMode: PromptMode = .speech
    public var wordsPerMinute: Double = 140
    public var scrollPointsPerSecond: Double = 30
    public var style = PromptStyle()
    public var promptFrame: SavedFrame?
    public var phoneFrame: SavedFrame?
    public var lensOffset = CGPoint(x: 0.87, y: 0.24)
    public var clusterSide: ClusterSide = .right
    public var clusterAtBottom = false
    public var arrangement: PhoneArrangement = .phoneBelowText
    public var layoutLocked = false
    public var guideVisible = true
    public var guideOpacity: Double = 0.8
    public var promptVisible = true
    public var scriptPosition: Int = 0
    public var lastPresetName: String?
    public var speechFollowingEnabled = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        cameraID = v(.cameraID, d.cameraID); cameraName = v(.cameraName, d.cameraName)
        microphoneID = v(.microphoneID, d.microphoneID); microphoneName = v(.microphoneName, d.microphoneName)
        outputFolderPath = v(.outputFolderPath, d.outputFolderPath)
        audioOffsetMs = min(1000, max(-1000, v(.audioOffsetMs, d.audioOffsetMs)))
        countdownEnabled = v(.countdownEnabled, d.countdownEnabled)
        previewMirrored = v(.previewMirrored, d.previewMirrored)
        showFramingGuides = v(.showFramingGuides, d.showFramingGuides)
        previewHidden = v(.previewHidden, d.previewHidden)
        promptMode = v(.promptMode, d.promptMode)
        wordsPerMinute = v(.wordsPerMinute, d.wordsPerMinute)
        scrollPointsPerSecond = min(150, max(5, v(.scrollPointsPerSecond, d.scrollPointsPerSecond)))
        style = v(.style, d.style)
        promptFrame = v(.promptFrame, d.promptFrame); phoneFrame = v(.phoneFrame, d.phoneFrame)
        lensOffset = v(.lensOffset, d.lensOffset); clusterSide = v(.clusterSide, d.clusterSide)
        clusterAtBottom = v(.clusterAtBottom, d.clusterAtBottom)
        arrangement = v(.arrangement, d.arrangement); layoutLocked = v(.layoutLocked, d.layoutLocked)
        guideVisible = v(.guideVisible, d.guideVisible); guideOpacity = v(.guideOpacity, d.guideOpacity)
        promptVisible = v(.promptVisible, d.promptVisible)
        scriptPosition = v(.scriptPosition, d.scriptPosition); lastPresetName = v(.lastPresetName, d.lastPresetName)
        speechFollowingEnabled = v(.speechFollowingEnabled, d.speechFollowingEnabled)
    }
}
