import XCTest
@testable import LensPromptCore

final class LayoutTests: XCTestCase {
    let main = ScreenDescriptor(id: "MAIN", name: "Built-in Retina Display",
                                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
    let external = ScreenDescriptor(id: "EXT", name: "Studio Display",
                                    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                    visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    func testRestoresOnSameDisplayAfterRearrangement() {
        let rect = CGRect(x: 1512 + 900, y: 600, width: 700, height: 160)
        let saved = SavedFrame(rect: rect, on: external)
        // External display moved to the left of the laptop.
        var moved = external
        moved.frame.origin.x = -2560; moved.visibleFrame.origin.x = -2560
        let (r, s) = LayoutGeometry.resolve(saved, screens: [main, moved])!
        XCTAssertEqual(s.id, "EXT")
        XCTAssertEqual(r, CGRect(x: -2560 + 900, y: 600, width: 700, height: 160))
    }

    func testFallsBackToVisibleMainDisplayWhenDisconnected() {
        let saved = SavedFrame(rect: CGRect(x: 1512 + 2000, y: 1300, width: 700, height: 160), on: external)
        let (r, s) = LayoutGeometry.resolve(saved, screens: [main])!
        XCTAssertEqual(s.id, "MAIN")
        XCTAssertTrue(main.visibleFrame.contains(r), "\(r) must be fully visible")
        XCTAssertEqual(r.size, CGSize(width: 700, height: 160))
    }

    func testOversizedFrameShrinksToFit() {
        let r = LayoutGeometry.clamp(CGRect(x: -100, y: -100, width: 5000, height: 3000), into: main.visibleFrame)
        XCTAssertEqual(r, main.visibleFrame)
    }

    func testRescalesWhenResolutionChanges() {
        let saved = SavedFrame(rect: CGRect(x: 1000, y: 400, width: 300, height: 100), on: main)
        var scaled = main
        scaled.frame.size = CGSize(width: 1800, height: 1169); scaled.visibleFrame.size = CGSize(width: 1800, height: 1131)
        let (r, _) = LayoutGeometry.resolve(saved, screens: [scaled])!
        XCTAssertEqual(r.minX, 1000 * 1800 / 1512, accuracy: 0.5)
        XCTAssertTrue(scaled.visibleFrame.contains(r))
    }

    func testPromptSnapsAboveLensForPhoneBelowText() {
        let phone = CGRect(x: 500, y: 100, width: 520, height: 250)
        let lens = CGPoint(x: 0.13, y: 0.24)
        let prompt = CGRect(x: 0, y: 0, width: 600, height: 150)
        let r = LayoutGeometry.promptFrame(current: prompt, phone: phone, lensOffset: lens,
                                           arrangement: .phoneBelowText, gap: 6, bounds: main.visibleFrame)
        let lp = LayoutGeometry.lensPoint(phone: phone, lensOffset: lens)
        XCTAssertEqual(r.minY, phone.maxY + 6)
        XCTAssertEqual(r.midX, lp.x, accuracy: 0.5)
        XCTAssertEqual(LayoutGeometry.activeEdge(for: .phoneBelowText, current: .center), .bottom)
        // Phone above text: prompt goes below the phone; active line at the top edge.
        let phoneTop = CGRect(x: 500, y: 600, width: 520, height: 250)
        let r2 = LayoutGeometry.promptFrame(current: prompt, phone: phoneTop, lensOffset: CGPoint(x: 0.13, y: 0.76),
                                            arrangement: .phoneAboveText, gap: 6, bounds: main.visibleFrame)
        XCTAssertEqual(r2.maxY, phoneTop.minY - 6)
        XCTAssertEqual(LayoutGeometry.activeEdge(for: .phoneAboveText, current: .center), .top)
        // Free: unchanged.
        XCTAssertEqual(LayoutGeometry.promptFrame(current: prompt, phone: phone, lensOffset: lens, arrangement: .free, bounds: main.visibleFrame), prompt)
    }

    func testSnapClampsAtScreenEdge() {
        let phone = CGRect(x: 0, y: 700, width: 520, height: 250)  // phone near top-left
        let r = LayoutGeometry.promptFrame(current: CGRect(x: 0, y: 0, width: 600, height: 150), phone: phone,
                                           lensOffset: CGPoint(x: 0.05, y: 0.2), arrangement: .phoneBelowText, bounds: main.visibleFrame)
        XCTAssertTrue(main.visibleFrame.contains(r))
    }

    func testInitialPhoneSizeFromPhysicalDisplay() {
        // 14" MacBook Pro: ~302 mm wide at 1512 points -> ~5 pt/mm
        let s = LayoutGeometry.initialPhoneSize(screenWidthPoints: 1512, screenWidthMM: 302)
        XCTAssertEqual(s.width, 801, accuracy: 2)
        XCTAssertEqual(LayoutGeometry.initialPhoneSize(screenWidthPoints: 1512, screenWidthMM: nil), CGSize(width: 520, height: 250))
    }
}

final class StorageTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-store-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testRoundTripsSettingsScriptPresetsTakes() throws {
        let store = LocalStore(root: root)
        var s = AppSettings()
        s.microphoneID = "mic-uid"; s.audioOffsetMs = -180; s.promptMode = .fixedSpeed
        s.style.fontSize = 42; s.arrangement = .phoneAboveText; s.layoutLocked = true
        try store.saveSettings(s)
        try store.saveScript("Hello — “quoted” ✨ script")
        let screen = ScreenDescriptor(id: "A", name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let f = SavedFrame(rect: CGRect(x: 1, y: 2, width: 30, height: 40), on: screen)
        let preset = LayoutPreset(name: "Desk", screenID: "A", screenName: "A", phoneFrame: f, lensOffset: CGPoint(x: 0.1, y: 0.2),
                                  clusterSide: .right, promptFrame: f, arrangement: .phoneBelowText, style: PromptStyle(),
                                  guideOpacity: 0.5, locked: true)
        try store.savePresets([preset])
        let take = TakeRecord(fileURL: URL(fileURLWithPath: "/tmp/x.mov"), createdAt: Date(timeIntervalSince1970: 100), duration: 3, status: .complete)
        try store.saveTakes([take])

        let reloaded = LocalStore(root: root)
        XCTAssertEqual(reloaded.loadSettings(), s)
        XCTAssertEqual(reloaded.loadScript(), "Hello — “quoted” ✨ script")
        XCTAssertEqual(reloaded.loadPresets(), [preset])
        XCTAssertEqual(reloaded.loadTakes(), [take])
    }

    func testCorruptSettingsFallBackToDefaultsAndAreKept() throws {
        let store = LocalStore(root: root)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("settings.json"))
        XCTAssertEqual(store.loadSettings(), AppSettings())
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    func testPartialSettingsKeepDefaultsForMissingKeys() throws {
        let store = LocalStore(root: root)
        try Data(#"{"audioOffsetMs": 5000, "promptMode": "manual"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        let s = store.loadSettings()
        XCTAssertEqual(s.audioOffsetMs, 1000, "clamped to the supported range")
        XCTAssertEqual(s.promptMode, .manual)
        XCTAssertEqual(s.style, PromptStyle())
    }

    func testReadScriptFileRejectsNonUTF8AndStripsBOM() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = root.appendingPathComponent("s.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("# Title".utf8)).write(to: good)
        XCTAssertEqual(try LocalStore.readScriptFile(good), "# Title")
        let bad = root.appendingPathComponent("bad.txt")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: bad)
        XCTAssertThrowsError(try LocalStore.readScriptFile(bad))
    }
}

final class AudioMeterTests: XCTestCase {
    func testRMSAndPeak() {
        let full = [Float](repeating: 1, count: 100)
        XCTAssertEqual(AudioLevels.measure(full).rms, 0, accuracy: 0.01)
        let half = (0..<480).map { Float(sin(Double($0) / 480 * 2 * .pi * 10)) * 0.5 }
        let m = AudioLevels.measure(half)
        XCTAssertEqual(m.peak, -6.02, accuracy: 0.1)
        XCTAssertEqual(m.rms, -9.03, accuracy: 0.2)
        XCTAssertEqual(AudioLevels.measure([Float](repeating: 0, count: 10)).rms, AudioLevels.floorDB)
    }

    func testClippingSilenceAndNoInput() {
        var meter = LevelMeterModel()
        meter.update(rms: -20, peak: -0.1, at: 0)
        XCTAssertTrue(meter.clipping)
        meter.update(rms: -20, peak: -10, at: 1)
        XCTAssertTrue(meter.clipping, "clip indicator holds briefly")
        meter.update(rms: -20, peak: -10, at: 2)
        XCTAssertFalse(meter.clipping)
        XCTAssertEqual(meter.health(at: 2.1), .ok)
        for t in stride(from: 2.5, through: 8, by: 0.5) { meter.update(rms: -75, peak: -70, at: t) }
        XCTAssertEqual(meter.health(at: 8), .silent)
        XCTAssertEqual(meter.health(at: 10), .noInput)
    }
}

final class PromptControllerTests: XCTestCase {
    func doc() -> ScriptDocument {
        ScriptDocument(text: "One two three. Four five six seven. Eight nine ten.")
    }

    func testFixedSpeedAdvancesOnlyWhenRunning() {
        var p = PromptController()
        p.load(document: doc())
        p.mode = .fixedSpeed
        p.wordsPerMinute = 60  // one word per second
        p.tick(dt: 1)
        XCTAssertEqual(p.target, 0, "paused prompt does not move")
        p.isRunning = true
        p.tick(dt: 2.5)
        XCTAssertEqual(p.target, 2.5, accuracy: 0.001)
        XCTAssertEqual(p.display, p.target)
        p.tick(dt: 100)
        XCTAssertEqual(p.target, 10)
        XCTAssertTrue(p.isAtEnd)
    }

    func testSpeechFollowIgnoredOutsideSpeechModeAndSmooths() {
        var p = PromptController()
        p.load(document: doc())
        p.mode = .manual
        p.follow(alignedPosition: 5)
        XCTAssertEqual(p.target, 0)
        p.mode = .speech
        p.follow(alignedPosition: 5)
        XCTAssertEqual(p.target, 5)
        XCTAssertEqual(p.display, 0)
        for _ in 0..<60 { p.tick(dt: 1.0 / 60) }
        XCTAssertGreaterThan(p.display, 4.9)
        XCTAssertLessThanOrEqual(p.display, 5)
    }

    func testManualLineNavigation() {
        var p = PromptController()
        p.load(document: doc())  // sentence starts: 0, 3, 7
        p.nextLine(); XCTAssertEqual(p.position, 3)
        p.nextLine(); XCTAssertEqual(p.position, 7)
        p.nextLine(); XCTAssertEqual(p.position, 10)
        p.previousLine(); XCTAssertEqual(p.position, 7)
        p.jump(to: 5)
        p.previousLine(); XCTAssertEqual(p.position, 3, "from mid-line goes to the line start first")
        p.previousLine(); XCTAssertEqual(p.position, 0)
        p.previousLine(); XCTAssertEqual(p.position, 0)
        p.adjustSpeed(by: 1000); XCTAssertEqual(p.wordsPerMinute, 400)
    }
}

final class OrientationAndSizingTests: XCTestCase {
    func testRotate180MovesClusterAndLensToOppositeCorner() {
        let o = PhoneOrientation(side: .left, atBottom: false, lensOffset: CGPoint(x: 0.13, y: 0.24))
        let r = o.rotated180()
        XCTAssertEqual(r.side, .right)
        XCTAssertTrue(r.atBottom)
        XCTAssertEqual(r.lensOffset.x, 0.87, accuracy: 1e-9)
        XCTAssertEqual(r.lensOffset.y, 0.76, accuracy: 1e-9)
        XCTAssertEqual(r.rotated180(), o)
        let f = o.flippedHorizontally()
        XCTAssertEqual(f.side, .right); XCTAssertFalse(f.atBottom)
        XCTAssertEqual(f.lensOffset.x, 0.87, accuracy: 1e-9); XCTAssertEqual(f.lensOffset.y, 0.24, accuracy: 1e-9)
    }

    func testDefaultsPutClusterTopRight() {
        let s = AppSettings()
        XCTAssertEqual(s.clusterSide, .right)
        XCTAssertFalse(s.clusterAtBottom)
        XCTAssertGreaterThan(s.lensOffset.x, 0.5)
    }

    func testDrawnRectIsNormalizedAndRejectsTinyDrags() {
        XCTAssertEqual(LayoutGeometry.rectFromDrag(CGPoint(x: 500, y: 300), CGPoint(x: 100, y: 100)),
                       CGRect(x: 100, y: 100, width: 400, height: 200))
        XCTAssertNil(LayoutGeometry.rectFromDrag(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)))
    }

    func testResizeKeepsCenterAndPhoneSideEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let r = CGRect(x: 400, y: 500, width: 600, height: 150)
        let wider = LayoutGeometry.resized(r, to: CGSize(width: 900, height: 200), keeping: .bottom, bounds: bounds)
        XCTAssertEqual(wider.midX, r.midX); XCTAssertEqual(wider.minY, r.minY); XCTAssertEqual(wider.height, 200)
        let top = LayoutGeometry.resized(r, to: CGSize(width: 300, height: 100), keeping: .top, bounds: bounds)
        XCTAssertEqual(top.maxY, r.maxY); XCTAssertEqual(top.midX, r.midX)
        let huge = LayoutGeometry.resized(r, to: CGSize(width: 5000, height: 100), keeping: .bottom, bounds: bounds)
        XCTAssertTrue(bounds.contains(huge))
    }

    func testOldPresetWithoutRotationStillDecodes() throws {
        let screen = ScreenDescriptor(id: "A", name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let f = SavedFrame(rect: CGRect(x: 1, y: 2, width: 30, height: 40), on: screen)
        let p = LayoutPreset(name: "Old", screenID: "A", screenName: "A", phoneFrame: f, lensOffset: .zero, clusterSide: .left,
                             promptFrame: f, arrangement: .free, style: PromptStyle(), guideOpacity: 1, locked: false)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "clusterAtBottom")
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.clusterAtBottom ?? false, false)
    }
}
