import Foundation
import CoreGraphics

/// A display as seen by the layout code (AppKit global coordinates, points, y up).
public struct ScreenDescriptor: Equatable, Codable, Sendable {
    public var id: String          // stable display UUID when available
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: Double
    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, scale: Double = 2) {
        self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame; self.scale = scale
    }
}

/// A window frame stored relative to its display, so it survives display rearrangement
/// and can be clamped back on-screen if that display is gone.
public struct SavedFrame: Equatable, Codable, Sendable {
    public var screenID: String
    public var screenName: String
    /// Origin relative to the screen's frame origin, in points.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Screen size at save time, to rescale if the display resolution changed.
    public var screenWidth: Double
    public var screenHeight: Double

    public init(rect: CGRect, on screen: ScreenDescriptor) {
        screenID = screen.id; screenName = screen.name
        x = rect.minX - screen.frame.minX; y = rect.minY - screen.frame.minY
        width = rect.width; height = rect.height
        screenWidth = screen.frame.width; screenHeight = screen.frame.height
    }
}

public enum PhoneArrangement: String, Codable, CaseIterable, Sendable {
    case phoneBelowText, phoneAboveText, free
    public var label: String {
        switch self {
        case .phoneBelowText: return "Phone below text"
        case .phoneAboveText: return "Phone above text"
        case .free: return "Free positioning"
        }
    }
}

public enum ClusterSide: String, Codable, CaseIterable, Sendable {
    case left, right
    public var flipped: ClusterSide { self == .left ? .right : .left }
}

/// Where the camera cluster appears on the landscape outline, as seen from the screen.
public struct PhoneOrientation: Equatable, Sendable {
    public var side: ClusterSide
    public var atBottom: Bool
    public var lensOffset: CGPoint
    public init(side: ClusterSide, atBottom: Bool, lensOffset: CGPoint) {
        self.side = side; self.atBottom = atBottom; self.lensOffset = lensOffset
    }

    /// Rotating the phone 180° moves the cluster to the opposite corner (and the lens with it).
    public func rotated180() -> PhoneOrientation {
        PhoneOrientation(side: side.flipped, atBottom: !atBottom,
                         lensOffset: CGPoint(x: 1 - lensOffset.x, y: 1 - lensOffset.y))
    }

    /// Mirrors the cluster to the other end, keeping it on the same (top/bottom) edge.
    public func flippedHorizontally() -> PhoneOrientation {
        PhoneOrientation(side: side.flipped, atBottom: atBottom, lensOffset: CGPoint(x: 1 - lensOffset.x, y: lensOffset.y))
    }

    public var label: String { "\(atBottom ? "bottom" : "top") \(side.rawValue)" }
}

public enum ActiveLineEdge: String, Codable, CaseIterable, Sendable {
    case top, bottom, center
}

public enum LayoutGeometry {
    /// Resolves a saved frame to global coordinates. Uses the same display if present
    /// (by id, then by name), otherwise the fallback (main) display, then guarantees the
    /// result is fully inside that display's visible frame.
    public static func resolve(_ saved: SavedFrame, screens: [ScreenDescriptor], fallbackIndex: Int = 0) -> (CGRect, ScreenDescriptor)? {
        guard !screens.isEmpty else { return nil }
        let screen = screens.first(where: { $0.id == saved.screenID })
            ?? screens.first(where: { $0.name == saved.screenName })
            ?? screens[min(max(0, fallbackIndex), screens.count - 1)]
        let sx = saved.screenWidth > 0 ? screen.frame.width / saved.screenWidth : 1
        let sy = saved.screenHeight > 0 ? screen.frame.height / saved.screenHeight : 1
        let sameSize = abs(sx - 1) < 0.001 && abs(sy - 1) < 0.001
        var rect = CGRect(x: screen.frame.minX + saved.x * (sameSize ? 1 : sx),
                          y: screen.frame.minY + saved.y * (sameSize ? 1 : sy),
                          width: saved.width, height: saved.height)
        rect = clamp(rect, into: screen.visibleFrame)
        return (rect, screen)
    }

    /// Shrinks the rect if larger than `bounds`, then moves it fully inside.
    public static func clamp(_ rect: CGRect, into bounds: CGRect, minSize: CGSize = CGSize(width: 80, height: 40)) -> CGRect {
        var r = rect
        r.size.width = min(max(r.width, minSize.width), bounds.width)
        r.size.height = min(max(r.height, minSize.height), bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Screen with the largest intersection with `rect`.
    public static func screen(containing rect: CGRect, screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens.max(by: { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) })
            .flatMap { area($0.frame.intersection(rect)) > 0 ? $0 : nil } ?? screens.first
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Absolute lens point from the phone outline and normalized lens offset
    /// (x from the outline's left edge, y from its top edge, both 0...1).
    public static func lensPoint(phone: CGRect, lensOffset: CGPoint) -> CGPoint {
        CGPoint(x: phone.minX + phone.width * lensOffset.x, y: phone.maxY - phone.height * lensOffset.y)
    }

    /// Prompt frame that puts the active reading line beside the lens for the arrangement.
    /// - phoneBelowText: prompt sits directly above the phone outline, active line at its bottom.
    /// - phoneAboveText: prompt sits directly below the phone outline, active line at its top.
    /// - free: unchanged.
    /// The prompt is centered horizontally on the lens and clamped to `bounds`.
    public static func promptFrame(current: CGRect, phone: CGRect, lensOffset: CGPoint,
                                   arrangement: PhoneArrangement, gap: CGFloat = 6, bounds: CGRect) -> CGRect {
        guard arrangement != .free else { return current }
        let lens = lensPoint(phone: phone, lensOffset: lensOffset)
        var r = current
        r.origin.x = lens.x - r.width / 2
        switch arrangement {
        case .phoneBelowText: r.origin.y = phone.maxY + gap
        case .phoneAboveText: r.origin.y = phone.minY - gap - r.height
        case .free: break
        }
        return clamp(r, into: bounds)
    }

    /// The active-line edge implied by an arrangement.
    public static func activeEdge(for arrangement: PhoneArrangement, current: ActiveLineEdge) -> ActiveLineEdge {
        switch arrangement {
        case .phoneBelowText: return .bottom
        case .phoneAboveText: return .top
        case .free: return current
        }
    }

    /// Normalized rectangle from a mouse drag between two points, or nil if too small.
    public static func rectFromDrag(_ a: CGPoint, _ b: CGPoint, minSize: CGSize = CGSize(width: 60, height: 30)) -> CGRect? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return r.width >= minSize.width && r.height >= minSize.height ? r : nil
    }

    /// Resizes a frame to a new size while keeping its horizontal center and the given
    /// vertical edge fixed (the edge nearest the phone/lens).
    public static func resized(_ rect: CGRect, to size: CGSize, keeping edge: ActiveLineEdge, bounds: CGRect) -> CGRect {
        var r = rect
        r.origin.x = rect.midX - size.width / 2
        r.size = size
        switch edge {
        case .bottom: r.origin.y = rect.minY                       // bottom edge stays (phone below text)
        case .top: r.origin.y = rect.maxY - size.height            // top edge stays (phone above text)
        case .center: r.origin.y = rect.midY - size.height / 2
        }
        return clamp(r, into: bounds)
    }

    /// iPhone 15 Pro Max body size, landscape (mm). Used only for an *initial* outline size;
    /// the user resizes the outline to match the real phone against the screen.
    public static let phoneSizeMM = CGSize(width: 159.9, height: 76.7)

    /// Initial outline size from a display's physical width in mm, if known.
    public static func initialPhoneSize(screenWidthPoints: CGFloat, screenWidthMM: CGFloat?) -> CGSize {
        guard let mm = screenWidthMM, mm > 50 else { return CGSize(width: 520, height: 250) }
        let pointsPerMM = screenWidthPoints / mm
        return CGSize(width: (phoneSizeMM.width * pointsPerMM).rounded(), height: (phoneSizeMM.height * pointsPerMM).rounded())
    }
}
