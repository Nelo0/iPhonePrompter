import Foundation

/// One normalized comparison token in the script, mapped back to the original text.
public struct ScriptToken: Equatable, Sendable {
    public let text: String           // normalized form used for matching
    public let range: NSRange         // UTF-16 range of the original word in the display text
    public let wordIndex: Int         // index of the original (display) word
    public let weight: Double         // matching weight (stopwords count less)
}

/// An immutable tokenized script. Markdown is treated as readable plain text:
/// heading/list markers are just punctuation and never become tokens.
public struct ScriptDocument: Equatable, Sendable {
    public let text: String
    public let tokens: [ScriptToken]
    /// Token indices that begin a sentence (always includes 0 when non-empty).
    public let sentenceStarts: [Int]
    /// Number of original display words.
    public let wordCount: Int

    public init(text: String) {
        self.text = text
        var tokens: [ScriptToken] = []
        var sentenceStarts: [Int] = []
        let ns = text as NSString
        let words = TextNormalizer.rawWords(in: text)
        var previousEnd = 0
        for (wi, w) in words.enumerated() {
            // A sentence starts after ., !, ?, a blank line, or a Markdown heading/list break.
            let gap = ns.substring(with: NSRange(location: previousEnd, length: w.range.location - previousEnd))
            let normalized = TextNormalizer.normalize(word: w.word)
            if !normalized.isEmpty,
               tokens.isEmpty || gap.contains(where: { ".!?\n".contains($0) }) {
                sentenceStarts.append(tokens.count)
            }
            for n in normalized {
                tokens.append(ScriptToken(text: n, range: w.range, wordIndex: wi,
                                          weight: TextNormalizer.stopwords.contains(n) ? 0.45 : 1.0))
            }
            previousEnd = w.range.location + w.range.length
        }
        self.tokens = tokens
        self.sentenceStarts = sentenceStarts
        self.wordCount = words.count
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Token index for a UTF-16 character offset (e.g. a click), choosing the word at or after it.
    public func tokenIndex(atCharacter offset: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var lo = 0, hi = tokens.count - 1
        if offset <= tokens[0].range.location { return 0 }
        while lo < hi {
            let mid = (lo + hi) / 2
            let r = tokens[mid].range
            if r.location + r.length <= offset { lo = mid + 1 } else { hi = mid }
        }
        // Snap to the first token of that word.
        var idx = lo
        while idx > 0 && tokens[idx - 1].range == tokens[idx].range { idx -= 1 }
        return idx
    }

    /// First token index of the sentence containing `index`.
    public func sentenceStart(containing index: Int) -> Int {
        sentenceStarts.last(where: { $0 <= index }) ?? 0
    }
}
