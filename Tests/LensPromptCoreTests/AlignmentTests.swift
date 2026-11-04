import XCTest
@testable import LensPromptCore

/// Simulates a progressive recognizer: each word arrives as a growing volatile
/// hypothesis, then the utterance is finalized.
func speak(_ aligner: ScriptAligner, _ utterance: String, finalize: Bool = true, finalText: String? = nil) -> [AlignmentOutcome] {
    var outcomes: [AlignmentOutcome] = []
    let words = utterance.split(separator: " ").map(String.init)
    for i in 1...max(1, words.count) where !words.isEmpty {
        outcomes.append(aligner.ingest(Hypothesis(text: words.prefix(i).joined(separator: " "), isFinal: false)))
    }
    if finalize { outcomes.append(aligner.ingest(Hypothesis(text: finalText ?? utterance, isFinal: true))) }
    return outcomes
}

/// Token index just after the first occurrence of `phrase` (normalized) at or after `from`.
func endIndex(of phrase: String, in doc: ScriptDocument, from: Int = 0) -> Int {
    let p = TextNormalizer.spokenTokens(phrase)
    let t = doc.tokens.map(\.text)
    var i = from
    while i + p.count <= t.count {
        if Array(t[i..<(i + p.count)]) == p { return i + p.count }
        i += 1
    }
    XCTFail("phrase not found: \(phrase)")
    return -1
}

final class NormalizerTests: XCTestCase {
    func testPunctuationCaseAndContractions() {
        XCTAssertEqual(TextNormalizer.spokenTokens("Don't STOP, it's fine!"), ["do", "not", "stop", "it", "is", "fine"])
        XCTAssertEqual(TextNormalizer.spokenTokens("We're here; they'll go — I'd say"),
                       ["we", "are", "here", "they", "will", "go", "i", "would", "say"])
        XCTAssertEqual(TextNormalizer.spokenTokens("can’t won’t"), ["can", "not", "will", "not"])
    }

    func testNumbersMatchWords() {
        XCTAssertEqual(TextNormalizer.spokenTokens("10 apples"), TextNormalizer.spokenTokens("ten apples"))
        XCTAssertEqual(TextNormalizer.spokenTokens("21"), ["twenty", "one"])
        XCTAssertEqual(TextNormalizer.spokenTokens("50%"), ["fifty", "percent"])
        XCTAssertEqual(TextNormalizer.spokenTokens("the 3rd time"), ["the", "third", "time"])
        XCTAssertEqual(TextNormalizer.spokenTokens("4K video"), ["four", "k", "video"])
    }

    func testFillersRemovedFromSpeechOnly() {
        XCTAssertEqual(TextNormalizer.spokenTokens("um so uh this"), ["so", "this"])
        let doc = ScriptDocument(text: "Um, this is literal.")
        XCTAssertEqual(doc.tokens.first?.text, "um")
    }

    func testScriptTokensMapToOriginalRanges() {
        let text = "# Intro\n\nHello, world! Don't panic."
        let doc = ScriptDocument(text: text)
        let ns = text as NSString
        XCTAssertEqual(doc.tokens.map(\.text), ["intro", "hello", "world", "do", "not", "panic"])
        XCTAssertEqual(ns.substring(with: doc.tokens[1].range), "Hello")
        XCTAssertEqual(ns.substring(with: doc.tokens[3].range), "Don't")
        XCTAssertEqual(doc.tokens[3].range, doc.tokens[4].range)
        XCTAssertEqual(doc.sentenceStarts, [0, 1, 3])
        XCTAssertEqual(doc.tokenIndex(atCharacter: ns.range(of: "panic").location + 2), 5)
        XCTAssertEqual(doc.tokenIndex(atCharacter: ns.range(of: "Don't").location + 3), 3)
    }
}

final class AlignmentTests: XCTestCase {
    let script = """
    Hello everyone, and welcome back to the channel. Today I want to show you how I record videos \
    with my phone on a tripod. The phone sits right in front of the screen. The script scrolls \
    while I talk, so I never lose my place. Let's get started with the setup.
    """

    func testFollowsProgressivePartialsWithoutDoubleAdvance() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back")
        XCTAssertEqual(a.position, endIndex(of: "hello everyone and welcome back", in: doc))
        XCTAssertEqual(a.status, .following)
        // Re-sending the same final text (recognizer re-emits) must not advance again.
        let before = a.position
        _ = a.ingest(Hypothesis(text: "", isFinal: false))
        XCTAssertEqual(a.position, before)
        _ = speak(a, "to the channel")
        XCTAssertEqual(a.position, endIndex(of: "to the channel", in: doc))
    }

    func testPartialRevisionDoesNotMoveBackwardOrTwice() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = a.ingest(Hypothesis(text: "Hello everyone and welcome", isFinal: false))
        let p1 = a.position
        XCTAssertEqual(p1, endIndex(of: "hello everyone and welcome", in: doc))
        // The recognizer withdraws the last word, then revises it.
        _ = a.ingest(Hypothesis(text: "Hello everyone and", isFinal: false))
        XCTAssertEqual(a.position, p1, "withdrawn partial must not move backward")
        _ = a.ingest(Hypothesis(text: "Hello everyone and well come", isFinal: false))
        XCTAssertEqual(a.position, p1)
        _ = a.ingest(Hypothesis(text: "Hello everyone and welcome back", isFinal: true))
        XCTAssertEqual(a.position, endIndex(of: "hello everyone and welcome back", in: doc))
        // Final with punctuation differences: no movement.
        let p2 = a.position
        _ = a.ingest(Hypothesis(text: "", isFinal: true))
        XCTAssertEqual(a.position, p2)
    }

    func testIncompleteLastWordPrefix() {
        let doc = ScriptDocument(text: "We are going to talk about teleprompters today.")
        let a = ScriptAligner(document: doc)
        _ = a.ingest(Hypothesis(text: "we are going to talk about telep", isFinal: false))
        XCTAssertEqual(a.position, endIndex(of: "we are going to talk about teleprompters", in: doc))
    }

    func testSilenceAndNoMatchesHoldPosition() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        let p = a.position
        // Silence: nothing ingested -> unchanged. Off-script chatter: hold.
        _ = speak(a, "sorry let me grab some water real quick")
        XCTAssertEqual(a.position, p)
        XCTAssertEqual(a.status, .uncertain)
        // Back on script resumes.
        _ = speak(a, "Today I want to show you")
        XCTAssertEqual(a.position, endIndex(of: "today i want to show you", in: doc))
        XCTAssertEqual(a.status, .following)
    }

    func testFillersAndRepeatedWordsTolerated() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone um and uh welcome welcome back to the the channel")
        XCTAssertEqual(a.position, endIndex(of: "to the channel", in: doc))
    }

    func testSmallSkipAdvances() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        // Skips "Today I want to show you how I record videos"
        _ = speak(a, "with my phone on a tripod")
        XCTAssertEqual(a.position, endIndex(of: "with my phone on a tripod", in: doc))
    }

    func testShortCorrectionRestartsSentenceWithoutJumpingAhead() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        _ = speak(a, "Today I want to show you how I")
        // Speaker stumbles and restarts the sentence.
        _ = speak(a, "today I want to show you how I record videos")
        XCTAssertEqual(a.position, endIndex(of: "how i record videos", in: doc))
    }

    func testRepeatedPhraseUsesContextAndDoesNotJumpToLaterCopy() {
        let text = """
        We did it. We did it together. Then the team went home and rested for the night. \
        In the morning the team met again. We did it. Everyone cheered loudly.
        """
        let doc = ScriptDocument(text: text)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "We did it")
        XCTAssertEqual(a.position, 3)
        _ = speak(a, "We did it together")
        XCTAssertEqual(a.position, endIndex(of: "we did it together", in: doc))
        _ = speak(a, "Then the team went home")
        let p = a.position
        XCTAssertEqual(p, endIndex(of: "then the team went home", in: doc))
        // Saying a phrase that also occurs later must not jump to the later copy
        // when the nearby text matches.
        _ = speak(a, "and rested for the night")
        XCTAssertEqual(a.position, endIndex(of: "and rested for the night", in: doc))
        _ = speak(a, "In the morning the team met again")
        _ = speak(a, "We did it")
        XCTAssertEqual(a.position, endIndex(of: "met again we did it", in: doc))
    }

    func testCommonWordsAloneDoNotJump() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        let p = a.position
        _ = speak(a, "the")
        _ = speak(a, "and the")
        XCTAssertEqual(a.position, p)
    }

    func testNoLargeBackwardJump() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        _ = speak(a, "Today I want to show you how I record videos with my phone on a tripod")
        _ = speak(a, "The phone sits right in front of the screen")
        _ = speak(a, "The script scrolls while I talk so I never lose my place")
        let p = a.position
        // A short weak phrase from the beginning must not pull the position back.
        _ = speak(a, "hello everyone")
        XCTAssertEqual(a.position, p)
    }

    func testManualResetClearsState() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel")
        let target = endIndex(of: "the phone sits right in front of the screen", in: doc)
        a.reset(to: target)
        XCTAssertEqual(a.position, target)
        XCTAssertEqual(a.status, .idle)
        _ = speak(a, "The script scrolls while I talk")
        XCTAssertEqual(a.position, endIndex(of: "the script scrolls while i talk", in: doc))
        // Reset to the start: earlier words track again from the beginning.
        a.reset(to: 0)
        _ = speak(a, "Hello everyone and welcome")
        XCTAssertEqual(a.position, endIndex(of: "hello everyone and welcome", in: doc))
    }

    func testReplacingScriptResetsMatching() {
        let a = ScriptAligner(document: ScriptDocument(text: script))
        _ = speak(a, "Hello everyone and welcome back")
        let doc2 = ScriptDocument(text: "A completely different script about cooking pasta at home.")
        a.replace(document: doc2)
        XCTAssertEqual(a.position, 0)
        _ = speak(a, "a completely different script")
        XCTAssertEqual(a.position, 4)
    }

    func testNumbersAndContractionsAcrossRecognizerAndScript() {
        let doc = ScriptDocument(text: "I've recorded 10 videos and I do not plan to stop. It's day twenty one.")
        let a = ScriptAligner(document: doc)
        _ = speak(a, "I have recorded ten videos and I don't plan to stop")
        XCTAssertEqual(a.position, endIndex(of: "plan to stop", in: doc))
        _ = speak(a, "it is day 21")
        XCTAssertEqual(a.position, doc.tokens.count)
    }

    func testSkipBeyondWindowReportsLostThenReacquiresOnStrongMatch() {
        let paragraphs = [
            "Rivers carve valleys over thousands of years and carry sediment toward the sea.",
            "Mountains rise when tectonic plates collide and push rock upward slowly.",
            "Forests store carbon in trunks, roots and the soil beneath fallen leaves.",
            "Deserts receive very little rain yet many animals thrive there at night.",
            "Oceans cover most of the planet and regulate weather across every continent.",
            "Glaciers advance and retreat, leaving moraines and polished bedrock behind them.",
            "Volcanoes vent molten rock, ash and gas from chambers deep underground.",
            "Wetlands filter water naturally and shelter migrating birds every spring season.",
            "Coral reefs host astonishing biodiversity in warm, shallow tropical waters.",
            "Grasslands feed enormous herds of grazing animals across open plains.",
            "Caves form when acidic groundwater dissolves limestone over long periods.",
            "Islands appear through volcanic activity or rising coral platforms offshore.",
        ]
        let doc = ScriptDocument(text: paragraphs.joined(separator: "\n\n"))
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Rivers carve valleys over thousands of years")
        let p = a.position
        XCTAssertEqual(p, endIndex(of: "rivers carve valleys over thousands of years", in: doc))
        // The speaker skips to paragraph 10, far beyond the forward window.
        _ = speak(a, "Grasslands feed")
        XCTAssertEqual(a.position, p, "must not jump on weak distant evidence")
        _ = speak(a, "enormous herds of grazing animals across open plains")
        XCTAssertTrue([.uncertain, .lost].contains(a.status))
        XCTAssertEqual(a.position, p, "a distant phrase beyond the window is not matched locally")
        // Continued reading of the distant paragraph reacquires on a long unique match.
        _ = speak(a, "Caves form when acidic groundwater dissolves limestone")
        XCTAssertEqual(a.position, endIndex(of: "caves form when acidic groundwater dissolves limestone", in: doc))
        XCTAssertEqual(a.status, .following)
    }

    func testOffScriptLongSpeechBecomesLost() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back")
        _ = speak(a, "now I am going to improvise for a while about my favorite sandwich which contains pickles mustard cheese and bread")
        XCTAssertEqual(a.status, .lost)
        XCTAssertEqual(a.position, endIndex(of: "hello everyone and welcome back", in: doc))
    }

    func testLongScriptReadThroughStaysOnTrackAndIsFast() {
        // ~5,000 words with repeated boilerplate sentences.
        var sentences: [String] = []
        let nouns = ["camera", "tripod", "script", "lens", "microphone", "studio", "light", "editor", "audience", "story"]
        let verbs = ["frames", "records", "captures", "follows", "guides", "shapes", "lights", "trims", "watches", "tells"]
        for i in 0..<500 {
            sentences.append("Section \(i % 50) the \(nouns[i % 10]) \(verbs[(i / 10) % 10]) the \(nouns[(i * 7) % 10]) carefully.")
            if i % 5 == 0 { sentences.append("Thanks for watching.") }
        }
        let text = sentences.joined(separator: " ")
        let doc = ScriptDocument(text: text)
        XCTAssertGreaterThan(doc.tokens.count, 3500)
        let a = ScriptAligner(document: doc)
        let start = Date()
        var maxBackward = 0
        var last = 0
        for s in sentences {
            let spoken = s.replacingOccurrences(of: ".", with: "")
            _ = speak(a, spoken)
            maxBackward = max(maxBackward, last - a.position)
            last = a.position
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(a.position, doc.tokens.count - 8, "should reach the end")
        XCTAssertEqual(maxBackward, 0)
        XCTAssertLessThan(elapsed, 10, "alignment must be fast enough for real-time use")
    }

    func testClickToResumeFromEarlierPosition() {
        let doc = ScriptDocument(text: script)
        let a = ScriptAligner(document: doc)
        _ = speak(a, "Hello everyone and welcome back to the channel today I want to show you")
        let earlier = doc.tokenIndex(atCharacter: (script as NSString).range(of: "welcome").location)
        a.reset(to: earlier)
        _ = speak(a, "welcome back to the channel")
        XCTAssertEqual(a.position, endIndex(of: "hello everyone and welcome back to the channel", in: doc))
    }
}
