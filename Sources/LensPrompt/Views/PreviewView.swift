import SwiftUI
import AVFoundation
import AppKit

final class PreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect   // fit without cropping
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    /// Preview-only mirroring; the recorded output connection is configured separately.
    func setMirrored(_ mirrored: Bool) {
        guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        if c.isVideoMirrored != mirrored { c.isVideoMirrored = mirrored }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView(session: session)
        v.setMirrored(mirrored)
        return v
    }
    func updateNSView(_ v: PreviewNSView, context: Context) { v.setMirrored(mirrored) }
}

/// Rule-of-thirds guides drawn over the fitted video rectangle (preview only).
struct FramingGuides: View {
    let aspect: CGFloat
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let w = min(size.width, size.height * aspect), h = w / aspect
            let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
            Path { p in
                for i in 1...2 {
                    let x = x0 + w * CGFloat(i) / 3, y = y0 + h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y0 + h))
                    p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x0 + w, y: y))
                }
            }
            .stroke(.white.opacity(0.7), lineWidth: 1)
            .shadow(color: .black.opacity(0.9), radius: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
