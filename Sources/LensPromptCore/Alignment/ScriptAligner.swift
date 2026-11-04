import Foundation

/// Speech-following status shown to the user.
public enum TrackingStatus: String, Equatable, Sendable {
    case idle          // not receiving recognition
    case listening     // receiving recognition, no confident match yet
    case following     // recent words confidently matched the script
    case uncertain     // recent words do not match; holding position
    case lost          // many words without a match nearby; manual resync suggested
}

/// A recognition hypothesis. Volatile (partial) hypotheses replace the previous
/// volatile hypothesis; a final hypothesis commits its words and clears the volatile text.
public struct Hypothesis: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public struct AlignmentConfig: Equatable, Sendable {
    /// Number of most recent spoken tokens aligned against the script.
    public var tailLength = 10
    /// Script tokens searched behind / ahead of the current position.
    public var backWindow = 30
    public var forwardWindow = 60
    public var minMatches = 2
    public var minScore = 1.3
    /// Minimum matched weight contributed by newly spoken tokens to justify a move.
    public var minNewScore = 1.0
    /// Trailing spoken tokens allowed after the last matched token (misrecognized words).
    public var maxTrailingUnmatched = 2
    /// Backward moves need stronger evidence and are bounded in size.
    public var minBackMatches = 4
    public var maxBackJump = 25
    /// New spoken tokens without a match before reporting uncertain / lost.
    public var uncertainAfter = 5
    public var lostAfter = 14
    /// Forward-only whole-script search used to recover once lost.
    public var reacquireMinMatches = 6
    public init() {}
}

/// Result of feeding a hypothesis to the aligner.
public struct AlignmentOutcome: Equatable, Sendable {
    public var position: Int
    public var moved: Bool
    public var status: TrackingStatus
}

/// Maps recognized words onto a script position. Purely deterministic: all state lives
/// here and is driven only by `ingest` / `reset` calls, so behavior is fully testable.
///
/// `position` is the index of the next script token to be read (0...tokens.count).
public final class ScriptAligner {
    public private(set) var document: ScriptDocument
    public private(set) var position: Int = 0
    public private(set) var status: TrackingStatus = .idle
    public let config: AlignmentConfig

    // Spoken token history: committed (final) tokens, bounded, plus the current volatile tokens.
    private var finalized: [Int] = []         // vocabulary ids
    private var finalizedDropped = 0          // tokens trimmed from the front of `finalized`
    private var volatileTokens: [Int] = []
    private var volatileIsLastPartial = false
    /// Absolute spoken index of the last token that justified a move or confirmation.
    private var lastMatchedSpokenIndex = -1
    private let historyLimit = 64
    // Vocabulary: every distinct normalized word gets an integer id so exact matches are
    // integer compares and fuzzy comparisons are computed once per word pair.
    private var vocab: [String: Int] = [:]
    private var vocabBytes: [[UInt8]] = []
    private var scriptIDs: [Int] = []
    private var fuzzyCache: [Int: Double] = [:]

    // Reused DP buffers (flat, row-major) to keep per-update cost low.
    private var bufH: [Double] = []
    private var bufM: [Int] = []
    private var bufN: [Double] = []
    private var bufC: [Int] = []

    public init(document: ScriptDocument, config: AlignmentConfig = AlignmentConfig()) {
        self.document = document
        self.config = config
        self.scriptIDs = []
        self.scriptIDs = document.tokens.map { id(for: $0.text) }
    }

    private func id(for word: String) -> Int {
        if let v = vocab[word] { return v }
        let v = vocabBytes.count
        vocab[word] = v
        vocabBytes.append(Array(word.utf8))
        return v
    }

    /// Replaces the script and resets all matching state.
    public func replace(document: ScriptDocument, position: Int = 0) {
        self.document = document
        scriptIDs = document.tokens.map { id(for: $0.text) }
        reset(to: position)
    }

    /// Restarts matching from a chosen script position (click-to-resume, manual resync).
    public func reset(to newPosition: Int) {
        position = max(0, min(newPosition, document.tokens.count))
        finalized = []
        finalizedDropped = 0
        volatileTokens = []
        volatileIsLastPartial = false
        lastMatchedSpokenIndex = -1
        status = .idle
    }

    /// Marks the start of listening (status becomes `.listening` until a match).
    public func beginListening() {
        if status == .idle { status = .listening }
    }

    public func stopListening() {
        volatileTokens = []
        status = .idle
    }

    private var spokenCount: Int { finalizedDropped + finalized.count + volatileTokens.count }

    @discardableResult
    public func ingest(_ hypothesis: Hypothesis) -> AlignmentOutcome {
        let tokens = TextNormalizer.spokenTokens(hypothesis.text).map { id(for: $0) }
        if hypothesis.isFinal {
            finalized.append(contentsOf: tokens)
            volatileTokens = []
            volatileIsLastPartial = false
            if finalized.count > historyLimit {
                let drop = finalized.count - historyLimit
                finalized.removeFirst(drop)
                finalizedDropped += drop
            }
        } else {
            volatileTokens = tokens
            volatileIsLastPartial = true
        }
        if status == .idle { status = .listening }
        return align()
    }

    // MARK: - Alignment

    private struct Candidate {
        var end: Int               // script position after the last matched token
        var lastSpoken: Int        // absolute spoken index of the last matched token
        var matches: Int
        var score: Double
    }

    private func align() -> AlignmentOutcome {
        let spoken = finalized + volatileTokens
        let total = spokenCount
        guard !document.tokens.isEmpty, !spoken.isEmpty else {
            return AlignmentOutcome(position: position, moved: false, status: status)
        }
        let tail = Array(spoken.suffix(config.tailLength))
        let tailStartAbs = total - tail.count
        let lo = max(0, position - config.backWindow)
        let hi = min(document.tokens.count, position + config.forwardWindow)

        var moved = false
        var accepted = false
        if let best = bestCandidate(tail: tail, tailStartAbs: tailStartAbs, scriptRange: lo..<hi, local: true) {
            (accepted, moved) = apply(best)
        }
        if !accepted, status == .lost || unmatchedSince(total) >= config.lostAfter,
           let found = reacquire(tail: tail, tailStartAbs: tailStartAbs) {
            (accepted, moved) = apply(found)
        }
        let unmatched = unmatchedSince(total)
        if !accepted {
            if unmatched >= config.lostAfter { status = .lost }
            else if unmatched >= config.uncertainAfter && status != .lost { status = .uncertain }
        }
        return AlignmentOutcome(position: position, moved: moved, status: status)
    }

    private func unmatchedSince(_ total: Int) -> Int {
        // Words spoken since the last confident match (or since listening began).
        let base = lastMatchedSpokenIndex >= 0 ? lastMatchedSpokenIndex + 1 : finalizedDropped
        return max(0, total - base)
    }

    /// Applies a candidate if it is new evidence. Returns (accepted, moved).
    private func apply(_ c: Candidate) -> (Bool, Bool) {
        // Only words spoken after the last accepted match may move the position. This is
        // what prevents a revised partial hypothesis from advancing twice for the same words
        // or nudging the position backwards when a volatile word is withdrawn.
        guard c.lastSpoken > lastMatchedSpokenIndex else { return (false, false) }
        if c.end < position {
            guard c.matches >= config.minBackMatches, position - c.end <= config.maxBackJump else { return (false, false) }
        }
        lastMatchedSpokenIndex = c.lastSpoken
        status = .following
        if c.end != position {
            position = c.end
            return (true, true)
        }
        return (true, false)
    }

    /// Similarity factor (0...1) between a spoken word id and a script word id.
    private func similarityFactor(_ spoken: Int, _ script: Int, isLastPartial: Bool) -> Double {
        if spoken == script { return 1 }
        let key = (spoken << 21) ^ script ^ (isLastPartial ? (1 << 62) : 0)
        if let v = fuzzyCache[key] { return v }
        let a = vocabBytes[spoken], b = vocabBytes[script]
        var v = 0.0
        let maxLen = max(a.count, b.count)
        if maxLen >= 5 {
            let limit = maxLen >= 8 ? 2 : 1
            if abs(a.count - b.count) <= limit, Self.editDistance(a, b, limit: limit) <= limit { v = 0.75 }
        }
        // A word still being recognized ("telep" for "teleprompter").
        if v == 0, isLastPartial, a.count >= 3, b.count > a.count, b.starts(with: a) { v = 0.6 }
        if fuzzyCache.count > 200_000 { fuzzyCache.removeAll(keepingCapacity: true) }
        fuzzyCache[key] = v
        return v
    }

    /// Smith–Waterman style local alignment of the spoken tail against a script range.
    /// Tracks, per cell, matched-token count and the score contributed by *new* spoken
    /// tokens (those after the last accepted match) so stale words cannot move the position.
    private func bestCandidate(tail: [Int], tailStartAbs: Int, scriptRange: Range<Int>, local: Bool) -> Candidate? {
        let m = tail.count, n = scriptRange.count
        guard m > 0, n > 0 else { return nil }
        let mismatch = 0.55, gapSpoken = 0.35, gapScript = 0.3
        let width = n + 1
        let size = (m + 1) * width
        if bufH.count < size {
            bufH = .init(repeating: 0, count: size); bufM = .init(repeating: 0, count: size)
            bufN = .init(repeating: 0, count: size); bufC = .init(repeating: 0, count: size)
        }
        for j in 0...n { bufH[j] = 0; bufM[j] = 0; bufN[j] = 0; bufC[j] = 0 }
        var best: Candidate?
        var bestEff = -Double.infinity
        let toks = document.tokens
        let lastPartialIndex = volatileIsLastPartial && !volatileTokens.isEmpty ? m - 1 : -1
        let lo = scriptRange.lowerBound
        for i in 1...m {
            let row = i * width, prow = (i - 1) * width
            bufH[row] = 0; bufM[row] = 0; bufN[row] = 0; bufC[row] = 0
            let isNew = tailStartAbs + i - 1 > lastMatchedSpokenIndex
            let newSpokenThroughI = max(0, tailStartAbs + i - 1 - lastMatchedSpokenIndex)
            let sid = tail[i - 1]
            let partial = i - 1 == lastPartialIndex
            for j in 1...n {
                let f = similarityFactor(sid, scriptIDs[lo + j - 1], isLastPartial: partial)
                let sim = f > 0 ? f * toks[lo + j - 1].weight : 0
                let diag = bufH[prow + j - 1] + (sim > 0 ? sim : -mismatch)
                let up = bufH[prow + j] - gapSpoken
                let left = bufH[row + j - 1] - gapScript
                var h = 0.0, mc = 0, nw = 0.0, nc = 0
                if diag > h {
                    h = diag; mc = bufM[prow + j - 1] + (sim > 0 ? 1 : 0)
                    nw = bufN[prow + j - 1] + (sim > 0 && isNew ? sim : 0)
                    nc = bufC[prow + j - 1] + (sim > 0 && isNew ? 1 : 0)
                }
                if up > h { h = up; mc = bufM[prow + j]; nw = bufN[prow + j]; nc = bufC[prow + j] }
                if left > h { h = left; mc = bufM[row + j - 1]; nw = bufN[row + j - 1]; nc = bufC[row + j - 1] }
                bufH[row + j] = h; bufM[row + j] = mc; bufN[row + j] = nw; bufC[row + j] = nc
                guard sim > 0, diag >= h, mc >= config.minMatches, h >= config.minScore else { continue }
                let trailing = m - i
                guard trailing <= config.maxTrailingUnmatched else { continue }
                let end = lo + j
                // New words must carry real evidence: one content word or two short words —
                // unless every new word matched and simply continues the confirmed text
                // (e.g. the final "it" of "we did it").
                if isNew && nw < config.minNewScore {
                    let contiguous = nc == newSpokenThroughI && end - position >= 0 && end - position <= nc && mc >= 3
                    if !contiguous { continue }
                }
                let d = end - position
                var eff = h - 0.6 * Double(trailing)
                if local {
                    eff -= d >= 0 ? 0.015 * Double(max(0, d - 3)) : 0.06 * Double(-d)
                }
                // Prefer higher effective score; on ties prefer the candidate nearest the position.
                if eff > bestEff + 1e-9 || (abs(eff - bestEff) <= 1e-9 && abs(d) < abs((best?.end ?? Int.max / 2) - position)) {
                    bestEff = eff
                    best = Candidate(end: end, lastSpoken: tailStartAbs + i - 1, matches: mc, score: h)
                }
            }
        }
        return best
    }

    /// Forward-only whole-script search used when tracking is lost. Requires a long,
    /// unambiguous match so common phrases cannot cause a distant jump.
    private func reacquire(tail: [Int], tailStartAbs: Int) -> Candidate? {
        let range = position..<document.tokens.count
        guard range.count > 0 else { return nil }
        var cands: [Candidate] = []
        let chunk = 200, overlap = config.tailLength * 2
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(range.upperBound, start + chunk + overlap)
            if let c = bestCandidate(tail: tail, tailStartAbs: tailStartAbs, scriptRange: start..<end, local: false) {
                cands.append(c)
            }
            start += chunk
        }
        let strong = cands.filter { $0.matches >= config.reacquireMinMatches }
        guard let top = strong.max(by: { $0.score < $1.score }) else { return nil }
        let rivals = strong.filter { abs($0.end - top.end) > config.tailLength && $0.score > top.score - 1.0 }
        return rivals.isEmpty ? top : nil
    }

    static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
