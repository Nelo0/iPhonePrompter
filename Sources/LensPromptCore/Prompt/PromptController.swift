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
    public var mode: PromptMode = .speech
    /// Whether the prompt is advancing (fixed speed) / accepting speech moves (speech mode).
    /// Independent of recording: pausing the prompt never pauses a take.
    public var isRunning = false
    public private(set) var target: Double = 0
    public private(set) var display: Double = 0
    public var wordsPerMinute: Double = 140
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
        tokensPerWord = document.wordCount > 0 ? Double(document.tokens.count) / Double(document.wordCount) : 1
        lineStarts = document.sentenceStarts
        jump(to: Double(position), animated: false)
    }

    /// Integer token index currently targeted.
    public var position: Int { Int(target.rounded(.down)) }

    public var isAtEnd: Bool { tokenCount == 0 || target >= Double(tokenCount) }

    public mutating func jump(to position: Double, animated: Bool = true) {
        target = clamp(position)
        if !animated { display = target }
    }

    /// Speech mode: accept the aligner's position.
    public mutating func follow(alignedPosition: Int) {
        guard mode == .speech else { return }
        target = clamp(Double(alignedPosition))
    }

    public mutating func nextLine() { jump(to: Double(lineStart(after: position))) }
    public mutating func previousLine() { jump(to: Double(lineStart(before: position))) }

    public mutating func adjustSpeed(by delta: Double) {
        wordsPerMinute = min(400, max(40, wordsPerMinute + delta))
    }

    /// Advances fixed-speed scrolling and the smoothed display position.
    public mutating func tick(dt: Double) {
        guard dt > 0 else { return }
        if mode == .fixedSpeed && isRunning && !isAtEnd {
            target = clamp(target + wordsPerMinute / 60 * tokensPerWord * dt)
            display = target  // already continuous
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
