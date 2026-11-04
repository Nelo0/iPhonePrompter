import Foundation

public enum PromptMode: String, Codable, CaseIterable, Sendable {
    case speech, fixedSpeed, manual

    public var label: String {
        switch self {
        case .speech: return "Follow my voice"
        case .fixedSpeed: return "Fixed speed"
        case .manual: return "Manual"
        }
    }
}

/// Reading-position model shared by all prompt modes. Positions are fractional
/// script-token indices; the view maps them to pixels. Deterministic and clock-free:
/// the caller advances time with `tick(dt:)`.
public struct PromptController: Equatable, Sendable {
    public var mode: PromptMode = .speech {
        didSet {
            if mode == .fixedSpeed && oldValue != .fixedSpeed { fixedScrollY = layoutY(for: display) }
        }
    }
    /// Whether the prompt is advancing (fixed speed) / accepting speech moves (speech mode).
    /// Independent of recording: pausing the prompt never pauses a take.
    public var isRunning = false
    public private(set) var target: Double = 0
    public private(set) var display: Double = 0
    /// Visual speed in screen points per second, independent of words per line.
    public var pointsPerSecond: Double = 30
    public private(set) var fixedScrollY: Double = 0
    private var tokenY: [Double] = []
    private var endY: Double = 0
    public var renderedY: Double? { mode == .fixedSpeed && !tokenY.isEmpty ? fixedScrollY : nil }
    public private(set) var tokenCount: Int = 0
    /// Ratio of comparison tokens to display words (contractions/numbers expand).
    public private(set) var tokensPerWord: Double = 1
    /// Token indices where display lines start, provided by the view after layout.
    public var lineStarts: [Int] = []
    /// Higher values converge faster. Units: 1/second.
    public var smoothing: Double = 7

    public init() {}

    public mutating func load(document: ScriptDocument, position: Int = 0) {
        tokenCount = document.tokens.count
        tokenY = []; endY = 0; fixedScrollY = 0
        tokensPerWord = document.wordCount > 0 ? Double(document.tokens.count) / Double(document.wordCount) : 1
        lineStarts = document.sentenceStarts
        jump(to: Double(position), animated: false)
    }

    /// Integer token index currently targeted.
    public var position: Int { Int(target.rounded(.down)) }

    public var isAtEnd: Bool { tokenCount == 0 || target >= Double(tokenCount) }

    public mutating func jump(to position: Double, animated: Bool = true) {
        target = clamp(position)
        if !animated || mode == .fixedSpeed { display = target }
        fixedScrollY = layoutY(for: target)
    }

    /// Supplies actual typeset positions, including wrapped lines and paragraph gaps.
    public mutating func installLayout(tokenY: [Double], endY: Double) {
        guard tokenY.count == tokenCount, tokenY.allSatisfy(\.isFinite), endY.isFinite,
              zip(tokenY, tokenY.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else { return }
        self.tokenY = tokenY
        self.endY = max(endY, tokenY.last ?? 0)
        fixedScrollY = layoutY(for: display)
    }

    private func layoutY(for position: Double) -> Double {
        guard let first = tokenY.first else { return 0 }
        if position >= Double(tokenCount) { return endY }
        let i = max(0, min(tokenY.count - 1, Int(position)))
        let next = i + 1 < tokenY.count ? tokenY[i + 1] : endY
        return max(first, tokenY[i] + (next - tokenY[i]) * (position - Double(i)))
    }

    /// Token index for the line crossing the reading marker. Scrolling itself never
    /// depends on this inverse mapping and therefore cannot pause between words.
    private func position(atY y: Double) -> Double {
        if y >= endY { return Double(tokenCount) }
        guard !tokenY.isEmpty else { return target }
        var lo = 0, hi = tokenY.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokenY[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        var index = max(0, lo - 1)
        while index > 0 && tokenY[index - 1] == tokenY[index] { index -= 1 }
        return Double(index)
    }

    /// Speech mode: accept the aligner's position.
    public mutating func follow(alignedPosition: Int) {
        guard mode == .speech else { return }
        target = clamp(Double(alignedPosition))
    }

    public mutating func nextLine() { jump(to: Double(lineStart(after: position))) }
    public mutating func previousLine() { jump(to: Double(lineStart(before: position))) }

    public mutating func adjustSpeed(by delta: Double) {
        pointsPerSecond = min(150, max(5, pointsPerSecond + delta))
    }

    /// Advances fixed-speed scrolling and the smoothed display position.
    public mutating func tick(dt: Double) {
        guard dt > 0 else { return }
        if mode == .fixedSpeed && isRunning && !isAtEnd {
            guard !tokenY.isEmpty else { return }
            fixedScrollY = min(endY, fixedScrollY + max(0, pointsPerSecond) * dt)
            target = position(atY: fixedScrollY)
            display = target
            return
        }
        let diff = target - display
        if abs(diff) < 0.005 { display = target; return }
        // Large manual jumps converge faster so the reader is not left waiting.
        let k = abs(diff) > 40 ? smoothing * 3 : smoothing
        display += diff * (1 - exp(-k * dt))
    }

    private func clamp(_ p: Double) -> Double { min(max(0, p), Double(tokenCount)) }

    private func lineStart(after p: Int) -> Int {
        lineStarts.first(where: { $0 > p }) ?? tokenCount
    }

    private func lineStart(before p: Int) -> Int {
        // From mid-line, go to the start of the current line first; from a line start, the previous line.
        guard let currentIdx = lineStarts.lastIndex(where: { $0 <= p }) else { return 0 }
        if lineStarts[currentIdx] < p && Double(lineStarts[currentIdx]) < target { return lineStarts[currentIdx] }
        return currentIdx > 0 ? lineStarts[currentIdx - 1] : 0
    }
}
