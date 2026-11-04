import AppKit
import LensPromptCore

/// Renders the script with TextKit and scrolls it so the reading position sits on the
/// active line, near the configured panel edge. The view owns a display link that drives
/// smoothing and fixed-speed scrolling.
final class PromptTextView: NSView {
    weak var model: AppModel?

    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private var builtVersion = -1
    private var builtStyle: PromptStyle?
    private var builtWidth: CGFloat = -1
    private var builtMode: PromptMode?
    private var tokenMidY: [CGFloat] = []
    private var tokenLine: [Int] = []
    private var lineRects: [CGRect] = []
    private var lineCharRanges: [NSRange] = []
    private var coloredLine = -1
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var currentOriginY: CGFloat = 0
    private var scrollAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        layout.allowsNonContiguousLayout = false
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Teleprompter script")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let ts = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, ts - lastTimestamp)
        lastTimestamp = ts
        guard let model else { return }
        let moved = model.tickPrompt(dt: dt)
        let needsRebuild = model.documentVersion != builtVersion || model.settings.style != builtStyle || model.promptMode != builtMode || abs(bounds.width - builtWidth) > 0.5
        if needsRebuild { rebuild() }
        if moved || needsRebuild { updateActiveLineColors(); needsDisplay = true }
    }

    private func rebuild() {
        guard let model else { return }
        let style = model.settings.style
        let font = NSFont.systemFont(ofSize: CGFloat(style.fontSize), weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(style.lineSpacing)
        para.paragraphSpacing = CGFloat(style.lineSpacing) * 2
        storage.setAttributedString(NSAttributedString(string: model.document.text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]))
        let width = max(50, bounds.width - CGFloat(style.horizontalPadding) * 2)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)

        // Line geometry.
        lineRects = []; lineCharRanges = []
        var glyph = 0
        let total = layout.numberOfGlyphs
        while glyph < total {
            var range = NSRange()
            let rect = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
            lineRects.append(rect)
            lineCharRanges.append(layout.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            glyph = NSMaxRange(range)
        }
        // Token → line center.
        let doc = model.document
        tokenMidY = []; tokenLine = []
        tokenMidY.reserveCapacity(doc.tokens.count)
        var line = 0
        for t in doc.tokens {
            while line + 1 < lineCharRanges.count && t.range.location >= NSMaxRange(lineCharRanges[line]) { line += 1 }
            tokenLine.append(line)
            tokenMidY.append(lineRects.isEmpty ? 0 : lineRects[line].midY)
        }
        // Display lines become the manual next/previous stops.
        var starts: [Int] = []
        var lastLine = -1
        for (i, l) in tokenLine.enumerated() where l != lastLine { starts.append(i); lastLine = l }
        model.prompt.lineStarts = starts
        let endY = (tokenMidY.last ?? 0) + (lineRects.last?.height ?? 30)
        model.prompt.installLayout(tokenY: tokenMidY.map(Double.init), endY: Double(endY))
        builtVersion = model.documentVersion
        builtStyle = style
        builtWidth = bounds.width
        builtMode = model.promptMode
        coloredLine = -1
    }

    private func y(for position: Double) -> CGFloat {
        guard !tokenMidY.isEmpty else { return 0 }
        let k = Int(position.rounded(.down))
        let frac = CGFloat(position - Double(k))
        let last = tokenMidY.count - 1
        if k >= last {
            // Past the final word: ease toward one line below the last line.
            let lineH = lineRects.last.map { $0.height } ?? 30
            let y0 = tokenMidY[last]
            return y0 + lineH * CGFloat(min(1, max(0, position - Double(last))))
        }
        let y0 = tokenMidY[max(0, k)], y1 = tokenMidY[k + 1]
        return y0 + (y1 - y0) * frac
    }

    private var anchorY: CGFloat {
        guard let style = model?.settings.style else { return bounds.midY }
        let inset = CGFloat(style.edgeInset)
        let lineH = lineRects.first.map { $0.height + CGFloat(style.lineSpacing) * 0.5 } ?? CGFloat(style.fontSize * 1.3)
        // Voice following always spends the panel height on upcoming text.
        if model?.promptMode == .speech { return min(12, max(0, inset)) + lineH / 2 }
        switch style.activeEdge {
        case .top: return inset + lineH / 2
        case .bottom: return bounds.height - inset - lineH * (0.5 + CGFloat(style.upcomingLinesBelow))
        case .center: return bounds.midY
        }
    }

    private func activeLine() -> Int {
        guard let model, !tokenLine.isEmpty else { return -1 }
        return tokenLine[min(tokenLine.count - 1, max(0, model.prompt.position))]
    }

    /// Dims text already read and slightly dims upcoming lines, using temporary attributes
    /// so no relayout is needed.
    private func updateActiveLineColors() {
        guard let model else { return }
        let line = activeLine()
        guard line != coloredLine, line >= 0, line < lineCharRanges.count else { return }
        coloredLine = line
        let e = CGFloat(model.settings.style.activeLineEmphasis)
        let full = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let activeStart = lineCharRanges[line].location
        let activeEnd = NSMaxRange(lineCharRanges[line])
        if activeStart > 0 {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(1 - 0.65 * e),
                                         forCharacterRange: NSRange(location: 0, length: activeStart))
        }
        if activeEnd < storage.length {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(1 - 0.3 * e),
                                         forCharacterRange: NSRange(location: activeEnd, length: storage.length - activeEnd))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let style = model.settings.style
        NSColor.black.withAlphaComponent(CGFloat(style.backgroundOpacity)).setFill()
        bounds.fill()
        if builtVersion != model.documentVersion || builtStyle != style || builtMode != model.promptMode { rebuild(); updateActiveLineColors() }
        let pad = CGFloat(style.horizontalPadding)
        let scrollY = model.prompt.renderedY.map { CGFloat($0) } ?? y(for: model.prompt.display)
        let originY = anchorY - scrollY
        currentOriginY = originY

        // Active line band.
        let line = activeLine()
        if line >= 0 && line < lineRects.count && style.activeLineEmphasis > 0 {
            let r = lineRects[line]
            let band = NSRect(x: 0, y: originY + r.minY - 2, width: bounds.width, height: r.height + 4)
            NSColor.white.withAlphaComponent(0.06 + 0.06 * CGFloat(style.activeLineEmphasis)).setFill()
            band.fill()
        }
        let visible = NSRect(x: 0, y: -originY, width: container.size.width, height: bounds.height)
        var glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        if model.promptMode == .speech, line >= 0, line < lineCharRanges.count {
            let start = lineCharRanges[line].location
            let upcoming = layout.glyphRange(forCharacterRange: NSRange(location: start, length: storage.length - start), actualCharacterRange: nil)
            glyphs = NSIntersectionRange(glyphs, upcoming)
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: pad, y: originY))

        if model.document.isEmpty {
            let s = NSAttributedString(string: "Paste or open a script in the main window.", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
            s.draw(at: NSPoint(x: pad, y: bounds.midY - 10))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, !model.placementMode else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let pad = CGFloat(model.settings.style.horizontalPadding)
        let inContainer = NSPoint(x: p.x - pad, y: p.y - currentOriginY)
        guard storage.length > 0 else { return }
        let idx = layout.characterIndex(for: inContainer, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        model.resume(fromCharacter: idx)
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling the prompt moves the reading position by lines (manual resync).
        guard let model else { return }
        scrollAccumulator += event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1
        while scrollAccumulator <= -step { model.nextLine(); scrollAccumulator += step }
        while scrollAccumulator >= step { model.previousLine(); scrollAccumulator -= step }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
