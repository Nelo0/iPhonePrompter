import SwiftUI
import AppKit

enum StudioTheme {
    static let sidebar = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let workspace = Color(red: 0.071, green: 0.071, blue: 0.082)
    static let surface = Color(red: 0.095, green: 0.095, blue: 0.110)
    static let raised = Color(red: 0.125, green: 0.125, blue: 0.145)
    static let border = Color.white.opacity(0.065)
    static let text = Color(red: 0.91, green: 0.91, blue: 0.93)
    static let secondary = Color(red: 0.58, green: 0.58, blue: 0.63)
    static let accent = Color(red: 0.58, green: 0.55, blue: 0.96)
}

struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let danger = destructive || configuration.role == .destructive
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : danger ? Color.red : StudioTheme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(prominent ? (danger ? Color.red : StudioTheme.accent).opacity(configuration.isPressed ? 0.7 : 0.9)
                        : Color.white.opacity(configuration.isPressed ? 0.10 : hovering ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.border))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

struct StudioWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.backgroundColor = NSColor(red: 0.071, green: 0.071, blue: 0.082, alpha: 1)
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                self?.window?.titleVisibility = .hidden
                self?.window?.titlebarAppearsTransparent = true
                func styleScrollers(_ view: NSView) {
                    if let scroll = view as? NSScrollView {
                        scroll.scrollerStyle = .overlay
                        scroll.autohidesScrollers = true
                    }
                    view.subviews.forEach(styleScrollers)
                }
                styleScrollers(root)
            }
        }
    }
}

struct StudioIconToggle: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.65))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(isOn ? StudioTheme.accent.opacity(0.36) : .black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

enum StudioSettingsTab: String, CaseIterable, Identifiable {
    case teleprompter = "Teleprompter", placement = "Phone placement", recording = "Recording"
    var id: String { rawValue }
}

struct StudioSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Studio settings").font(.system(size: 18, weight: .semibold))
                    Text("Fine-tune your recording setup.").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker("Settings", selection: $model.studioSettingsTab) {
                ForEach(StudioSettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            Divider().overlay(StudioTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.studioSettingsTab {
                    case .teleprompter:
                        PromptAppearanceSettings(model: model)
                        SpeechSection(model: model)
                    case .placement: PlacementSection(model: model)
                    case .recording: OutputSection(model: model)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: model.studioSettingsTab == .placement ? 620 : model.studioSettingsTab == .teleprompter ? 470 : 450)
        .background(StudioTheme.workspace)
        .foregroundStyle(StudioTheme.text)
        .tint(StudioTheme.accent)
        .controlSize(.small)
        .buttonStyle(StudioButtonStyle())
        .preferredColorScheme(.dark)
    }
}
