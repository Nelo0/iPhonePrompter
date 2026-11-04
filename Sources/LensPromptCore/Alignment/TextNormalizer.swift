import Foundation

/// Deterministic word normalization shared by the script tokenizer and the
/// recognized-speech tokenizer. Matching ignores case and punctuation, expands
/// common contractions, and spells out digits so "10" and "ten" compare equal.
public enum TextNormalizer {

    /// Filler words dropped from *spoken* input only (never from the script).
    public static let fillers: Set<String> = [
        "um", "uh", "umm", "uhh", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "mhm", "uhm",
    ]

    /// Very common words. They still match, but carry less weight so that a run
    /// of them cannot by itself justify a jump.
    public static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "this", "that", "i", "you", "we",
        "they", "he", "she", "so", "as", "do", "not", "have", "has", "will", "would", "can",
        "my", "our", "your", "me", "us", "if", "by", "from", "just", "all", "what", "there",
    ]

    private static let contractions: [String: [String]] = [
        "can't": ["can", "not"], "cannot": ["can", "not"], "won't": ["will", "not"],
        "shan't": ["shall", "not"], "ain't": ["is", "not"], "i'm": ["i", "am"],
        "let's": ["let", "us"], "it's": ["it", "is"], "that's": ["that", "is"],
        "what's": ["what", "is"], "there's": ["there", "is"], "here's": ["here", "is"],
        "he's": ["he", "is"], "she's": ["she", "is"], "who's": ["who", "is"],
        "where's": ["where", "is"], "how's": ["how", "is"],
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "ok": ["okay"],
    ]

    private static let suffixContractions: [(String, [String])] = [
        ("n't", ["not"]), ("'re", ["are"]), ("'ve", ["have"]), ("'ll", ["will"]),
        ("'d", ["would"]), ("'m", ["am"]),
    ]

    /// Splits free text into raw word candidates with their UTF-16 ranges.
    /// Hyphens, slashes and dashes split words; apostrophes stay inside words.
    public static func rawWords(in text: String) -> [(word: String, range: NSRange)] {
        var result: [(String, NSRange)] = []
        let ns = text as NSString
        var current = ""
        var start = -1
        var i = 0
        let length = ns.length
        func flush(_ end: Int) {
            if !current.isEmpty, start >= 0 {
                result.append((current, NSRange(location: start, length: end - start)))
            }
            current = ""
            start = -1
        }
        while i < length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let ch = ns.substring(with: r)
            if isWordCharacter(ch) {
                if start < 0 { start = r.location }
                current += ch
            } else {
                flush(r.location)
            }
            i = r.location + r.length
        }
        flush(length)
        return result
    }

    private static func isWordCharacter(_ ch: String) -> Bool {
        if ch == "'" || ch == "\u{2019}" || ch == "%" || ch == "&" { return true }
        guard let scalar = ch.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Normalizes one raw word into zero or more comparison tokens.
    public static func normalize(word raw: String) -> [String] {
        var w = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
        // Trim stray apostrophes ('quoted' words, plural possessives like dogs').
        w = w.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if w.isEmpty { return [] }
        if w == "&" { return ["and"] }
        if w.hasSuffix("%") {
            let base = String(w.dropLast())
            return (base.isEmpty ? [] : normalize(word: base)) + ["percent"]
        }
        w = w.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "&", with: "")
        if w.isEmpty { return [] }
        if let expanded = contractions[w] { return expanded }
        for (suffix, expansion) in suffixContractions where w.hasSuffix(suffix) && w.count > suffix.count {
            let stem = String(w.dropLast(suffix.count))
            return [stem.replacingOccurrences(of: "'", with: "")] + expansion
        }
        if w.hasSuffix("'s") { w = String(w.dropLast(2)) }  // possessive: "speaker's" -> "speaker"
        w = w.replacingOccurrences(of: "'", with: "")
        if w.isEmpty { return [] }
        if let n = Int(w), w.count <= 9 { return NumberWords.spell(n) }
        if let ordinal = NumberWords.ordinal(w) { return ordinal }
        // Mixed alphanumerics like "4k" -> ["four", "k"].
        if w.contains(where: \.isNumber) && w.contains(where: \.isLetter) {
            var parts: [String] = []
            var buf = ""
            var bufIsDigit: Bool? = nil
            for c in w {
                let d = c.isNumber
                if let b = bufIsDigit, b != d { parts.append(buf); buf = "" }
                buf.append(c); bufIsDigit = d
            }
            if !buf.isEmpty { parts.append(buf) }
            return parts.flatMap { p in Int(p).map(NumberWords.spell) ?? [p] }
        }
        return [w]
    }

    /// Normalizes a recognized-speech string into comparison tokens with fillers removed.
    public static func spokenTokens(_ text: String) -> [String] {
        rawWords(in: text).flatMap { normalize(word: $0.word) }.filter { !fillers.contains($0) }
    }
}

/// Small English cardinal/ordinal speller used so digits and words compare equal.
public enum NumberWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    public static func spell(_ n: Int) -> [String] {
        if n < 0 { return ["minus"] + spell(-n) }
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        // Years such as 1999 or 2025 are usually spoken in pairs ("twenty twenty five")
        // but recognizers render them as digits, which also normalize through here, so
        // both sides land on the same spelling regardless of which reading is used.
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : spell(n % 100)) }
        if n < 1_000_000 { return spell(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : spell(n % 1000)) }
        return spell(n / 1_000_000) + ["million"] + (n % 1_000_000 == 0 ? [] : spell(n % 1_000_000))
    }

    private static let ordinalWords: [Int: String] = [
        1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", 6: "sixth", 7: "seventh",
        8: "eighth", 9: "ninth", 10: "tenth", 11: "eleventh", 12: "twelfth", 20: "twentieth", 30: "thirtieth",
    ]

    /// "1st" -> ["first"], "21st" -> ["twenty", "first"]. Returns nil for non-ordinals.
    public static func ordinal(_ w: String) -> [String]? {
        guard w.count >= 3 else { return nil }
        let suffix = String(w.suffix(2))
        guard ["st", "nd", "rd", "th"].contains(suffix), let n = Int(w.dropLast(2)), n > 0, n < 1000 else { return nil }
        if let word = ordinalWords[n] { return [word] }
        if n < 100, n % 10 != 0, let last = ordinalWords[n % 10] { return spell(n - n % 10) + [last] }
        return spell(n) + ["th"]
    }
}
