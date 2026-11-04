import AppKit
import LensPromptCore

/// Calibration overlay: a landscape phone outline, a camera-cluster hint and a draggable
/// lens target. It shows where to put the real phone; it does not detect the phone.
final class PhoneGuideView: NSView {
    weak var model: AppModel?
    var onGeometryCommitted: (() -> Void)?

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    private enum Drag { case none, move(NSPoint, NSPoint), resize(Corner, NSRect, NSPoint), lens }
    private var drag: Drag = .none
    private let handleSize: CGFloat = 22

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var interactive: Bool { (model?.placementMode ?? false) && !(model?.settings.layoutLocked ?? true) }
    private var outlineRect: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    private func lensPoint() -> NSPoint {
        guard let m = model else { return .zero }
        let r = outlineRect
        return NSPoint(x: r.minX + r.width * m.settings.lensOffset.x, y: r.maxY - r.height * m.settings.lensOffset.y)
    }

    // On-outline buttons (placement mode only).
    private var rotateButtonRect: NSRect {
        let r = outlineRect
        return NSRect(x: r.midX - 118, y: r.midY - 14, width: 110, height: 28)
    }
    private var flipButtonRect: NSRect {
        let r = outlineRect
        return NSRect(x: r.midX + 8, y: r.midY - 14, width: 110, height: 28)
    }

    private func cornerRect(_ c: Corner) -> NSRect {
        let s = handleSize
        switch c {
        case .topLeft: return NSRect(x: bounds.minX, y: bounds.maxY - s, width: s, height: s)
        case .topRight: return NSRect(x: bounds.maxX - s, y: bounds.maxY - s, width: s, height: s)
        case .bottomLeft: return NSRect(x: bounds.minX, y: bounds.minY, width: s, height: s)
        case .bottomRight: return NSRect(x: bounds.maxX - s, y: bounds.minY, width: s, height: s)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let placing = m.placementMode
        let r = outlineRect
        let radius = min(r.width, r.height) * 0.14
        let body = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(placing ? 0.35 : 0.15).setFill()
        body.fill()
        (placing ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.8)).setStroke()
        body.lineWidth = placing ? 3 : 2
        body.stroke()

        // Camera cluster hint at the chosen corner.
        let cs = r.height * 0.42
        let inset = r.height * 0.06
        let cx = m.settings.clusterSide == .left ? r.minX + inset : r.maxX - inset - cs
        let cy = m.settings.clusterAtBottom ? r.minY + inset : r.maxY - inset - cs
        let cluster = NSRect(x: cx, y: cy, width: cs, height: cs)
        let cpath = NSBezierPath(roundedRect: cluster, xRadius: cs * 0.22, yRadius: cs * 0.22)
        NSColor.white.withAlphaComponent(0.1).setFill(); cpath.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke(); cpath.lineWidth = 1.5; cpath.stroke()
        let lensR = cs * 0.17
        for (fx, fy) in [(0.3, 0.7), (0.3, 0.3), (0.72, 0.5)] {
            // Mirror the triangle so it matches the cluster's corner.
            let x = m.settings.clusterSide == .left ? fx : 1 - fx
            let y = m.settings.clusterAtBottom ? 1 - fy : fy
            let c = NSPoint(x: cluster.minX + cluster.width * x, y: cluster.minY + cluster.height * y)
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - lensR, y: c.y - lensR, width: lensR * 2, height: lensR * 2))
            NSColor.white.withAlphaComponent(0.4).setStroke(); circle.lineWidth = 1; circle.stroke()
        }

        // Active lens target.
        let lp = lensPoint()
        let tr: CGFloat = 13
        let target = NSBezierPath(ovalIn: NSRect(x: lp.x - tr, y: lp.y - tr, width: tr * 2, height: tr * 2))
        NSColor.systemGreen.setStroke(); target.lineWidth = 2.5; target.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: lp.x - tr - 6, y: lp.y)); cross.line(to: NSPoint(x: lp.x + tr + 6, y: lp.y))
        cross.move(to: NSPoint(x: lp.x, y: lp.y - tr - 6)); cross.line(to: NSPoint(x: lp.x, y: lp.y + tr + 6))
        cross.lineWidth = 1.5; cross.stroke()

        guard placing else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let lensLabel = NSAttributedString(string: "Lens", attributes: attrs)
        let labelX = m.settings.clusterSide == .left ? lp.x + tr + 4 : lp.x - tr - 4 - lensLabel.size().width
        lensLabel.draw(at: NSPoint(x: labelX, y: lp.y - tr - 16))

        if m.settings.layoutLocked {
            NSAttributedString(string: "Layout locked — unlock in the main window to adjust.", attributes: small)
                .draw(at: NSPoint(x: r.midX - 140, y: r.minY + 10))
            return
        }
        drawButton(rotateButtonRect, "⟲ Rotate 180°")
        drawButton(flipButtonRect, "⇆ Flip sides")
        let lines = ["Drag to move · drag any corner to resize to your phone",
                     "Drag the green target onto the real lens",
                     "Size: \(Int(bounds.width)) × \(Int(bounds.height)) pt (match the real phone)"]
        var y = r.minY + 10
        for line in lines.reversed() {
            let s = NSAttributedString(string: line, attributes: small)
            s.draw(at: NSPoint(x: r.midX - s.size().width / 2, y: y)); y += 15
        }
        NSColor.systemOrange.setFill()
        for c in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let h = cornerRect(c).insetBy(dx: 5, dy: 5)
            NSBezierPath(roundedRect: h, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawButton(_ rect: NSRect, _ title: String) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.7).setFill(); path.fill()
        NSColor.systemOrange.setStroke(); path.lineWidth = 1.5; path.stroke()
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive, let window, let m = model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if rotateButtonRect.contains(p) { m.rotatePhone180(); return }
        if flipButtonRect.contains(p) { m.flipPhoneSides(); return }
        let lp = lensPoint()
        if hypot(p.x - lp.x, p.y - lp.y) < 20 { drag = .lens; return }
        for c in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] where cornerRect(c).insetBy(dx: -6, dy: -6).contains(p) {
            drag = .resize(c, window.frame, NSEvent.mouseLocation); return
        }
        drag = .move(window.frame.origin, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, let window, let m = model else { return }
        let mouse = NSEvent.mouseLocation
        switch drag {
        case .move(let origin, let start):
            window.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
        case .resize(let corner, let f, let start):
            let dx = mouse.x - start.x, dy = mouse.y - start.y
            var minX = f.minX, maxX = f.maxX, minY = f.minY, maxY = f.maxY
            switch corner {
            case .topLeft: minX += dx; maxY += dy
            case .topRight: maxX += dx; maxY += dy
            case .bottomLeft: minX += dx; minY += dy
            case .bottomRight: maxX += dx; minY += dy
            }
            if maxX - minX < 160 { if corner == .topLeft || corner == .bottomLeft { minX = maxX - 160 } else { maxX = minX + 160 } }
            if maxY - minY < 70 { if corner == .bottomLeft || corner == .bottomRight { minY = maxY - 70 } else { maxY = minY + 70 } }
            window.setFrame(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), display: true)
        case .lens:
            let p = convert(event.locationInWindow, from: nil)
            let r = outlineRect
            m.settings.lensOffset = CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)),
                                            y: min(1, max(0, (r.maxY - p.y) / r.height)))
            needsDisplay = true
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = drag { return }
        drag = .none
        onGeometryCommitted?()
    }

    override func resetCursorRects() {
        guard interactive else { return }
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(rotateButtonRect, cursor: .pointingHand)
        addCursorRect(flipButtonRect, cursor: .pointingHand)
        for c in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] { addCursorRect(cornerRect(c), cursor: .crosshair) }
        let lp = lensPoint()
        addCursorRect(NSRect(x: lp.x - 16, y: lp.y - 16, width: 32, height: 32), cursor: .crosshair)
    }
}

/// Full-screen overlay for drawing the phone outline: drag a box where the real phone
/// covers the screen. Esc cancels.
final class OutlineDrawingView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let msg = NSAttributedString(string: "Drag a box around where the iPhone covers the screen · Esc to cancel",
                                     attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
        let size = msg.size()
        msg.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80))
        if let a = start, let b = current {
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            NSColor.systemOrange.withAlphaComponent(0.2).setFill(); r.fill()
            let p = NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) * 0.14, yRadius: min(r.width, r.height) * 0.14)
            NSColor.systemOrange.setStroke(); p.lineWidth = 3; p.stroke()
            NSAttributedString(string: "\(Int(r.width)) × \(Int(r.height)) pt",
                               attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: r.minX + 6, y: r.maxY + 6))
        }
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let a = start, let window else { return }
        let b = convert(event.locationInWindow, from: nil)
        start = nil; current = nil
        guard let local = LayoutGeometry.rectFromDrag(a, b) else { needsDisplay = true; return }  // too small: keep drawing
        onFinish?(window.convertToScreen(convert(local, to: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

final class KeyableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
