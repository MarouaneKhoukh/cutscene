import AppKit
import CutsceneCore
import SwiftUI

/// The ranges the style inspector's sliders offer.
struct StyleInspectorSettings: Sendable, Equatable {
    var gradientAngle: ClosedRange<Double> = 0...360
    /// Padding as a fraction of the shorter canvas side.
    var padding: ClosedRange<Double> = 0...0.2
    /// Pixels at the kit's reference height.
    var cornerRadius: ClosedRange<Double> = 0...64
    var shadowOpacity: ClosedRange<Double> = 0...1
    var shadowBlur: ClosedRange<Double> = 0...128
    var shadowOffsetY: ClosedRange<Double> = -64...64
    var cursorScale = CursorStyle.scaleRange
    var rippleRadius: ClosedRange<Double> = 8...120
    var zoomAmount: ClosedRange<Double> = 1...4
    var zoomLeadIn: ClosedRange<Double> = 0...1
    var zoomHoldAfter: ClosedRange<Double> = 0...6
}

/// The look (PLAN M2-10): background, frame, cursor and the automatic
/// zoom's settings, every change an edit of the project's `style`. A zoom
/// setting change replans the automatic segments once the slider is let go.
struct StyleInspector: View {
    let model: EditorModel
    var settings = StyleInspectorSettings()

    private var style: BrandKit { model.project.style }

    var body: some View {
        Form {
            Section("Background") {
                Picker(
                    "Kind",
                    selection: Binding(
                        get: { style.background.kind == .solid ? BackgroundKind.solid : .linearGradient },
                        set: { kind in model.editStyle("Background") { $0.background.kind = kind } })
                ) {
                    Text("Gradient").tag(BackgroundKind.linearGradient)
                    Text("Solid").tag(BackgroundKind.solid)
                }
                if style.background.kind == .solid {
                    color("Color", style.background.solid) { $0.background.solid = $1 }
                } else {
                    color("From", style.background.gradient.from) { $0.background.gradient.from = $1 }
                    color("To", style.background.gradient.to) { $0.background.gradient.to = $1 }
                    slider(
                        "Angle", style.background.gradient.angleDegrees, settings.gradientAngle, "%.0f°",
                        "Gradient Angle"
                    ) { $0.background.gradient.angleDegrees = $1 }
                }
            }
            Section("Frame") {
                slider("Padding", style.frame.padding, settings.padding, "%.3f", "Padding") { $0.frame.padding = $1 }
                slider("Corner radius", style.frame.cornerRadius, settings.cornerRadius, "%.0f px", "Corner Radius") {
                    $0.frame.cornerRadius = $1
                }
                slider("Shadow opacity", style.frame.shadow.opacity, settings.shadowOpacity, "%.2f", "Shadow") {
                    $0.frame.shadow.opacity = $1
                }
                slider("Shadow blur", style.frame.shadow.blurRadius, settings.shadowBlur, "%.0f px", "Shadow") {
                    $0.frame.shadow.blurRadius = $1
                }
                slider("Shadow offset", style.frame.shadow.offsetY, settings.shadowOffsetY, "%.0f px", "Shadow") {
                    $0.frame.shadow.offsetY = $1
                }
            }
            Section("Cursor") {
                slider("Size", style.cursor.scale, settings.cursorScale, "%.2f×", "Cursor Size") {
                    $0.cursor.scale = $1
                }
                Toggle(
                    "Click ripples",
                    isOn: Binding(
                        get: { style.cursor.click.enabled },
                        set: { enabled in model.editStyle("Click Ripples") { $0.cursor.click.enabled = enabled } }))
                slider("Ripple radius", style.cursor.click.endRadius, settings.rippleRadius, "%.0f px", "Ripple Radius")
                {
                    $0.cursor.click.endRadius = $1
                }
            }
            Section("Automatic zoom") {
                slider("Amount", style.zoom.amount, settings.zoomAmount, "%.2f×", "Zoom Amount", replans: true) {
                    $0.zoom.amount = $1
                }
                slider("Lead-in", style.zoom.leadIn, settings.zoomLeadIn, "%.2f s", "Zoom Lead-in", replans: true) {
                    $0.zoom.leadIn = $1
                }
                slider("Hold after", style.zoom.holdAfter, settings.zoomHoldAfter, "%.2f s", "Zoom Hold", replans: true)
                {
                    $0.zoom.holdAfter = $1
                }
                Toggle(
                    "Zoom on typing",
                    isOn: Binding(
                        get: { style.zoom.detectsTypingBursts },
                        set: { on in
                            model.beginTransaction("Zoom on Typing")
                            model.editStyle("Zoom on Typing") { $0.zoom.detectsTypingBursts = on }
                            model.replanZoom()
                            model.endTransaction()
                        }))
            }
        }
        .formStyle(.grouped)
    }

    /// A slider over one field of the style; the drag is one undo step, and
    /// one that `replans` runs the zoom planner again when it ends.
    private func slider(
        _ title: String, _ value: Double, _ range: ClosedRange<Double>, _ format: String, _ name: String,
        replans: Bool = false, set: @escaping (inout BrandKit, Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Slider(
                    value: Binding(get: { value }, set: { new in model.editStyle(name) { set(&$0, new) } }), in: range,
                    onEditingChanged: { editing in
                        if editing {
                            model.beginTransaction(name)
                        } else {
                            if replans { model.replanZoom() }
                            model.endTransaction()
                        }
                    })
                Text(String(format: format, value)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ title: String, _ value: KitColor, set: @escaping (inout BrandKit, KitColor) -> Void)
        -> some View
    {
        ColorPicker(
            title,
            selection: Binding(
                get: { Color(kit: value) },
                set: { color in
                    guard let kit = KitColor(color) else { return }
                    model.editStyle(title) { set(&$0, kit) }
                }), supportsOpacity: false)
    }
}

extension Color {
    /// The kit's sRGB colour.
    init(kit: KitColor) {
        self.init(
            .sRGB, red: Double(kit.red) / 255, green: Double(kit.green) / 255, blue: Double(kit.blue) / 255,
            opacity: Double(kit.alpha) / 255)
    }
}

extension KitColor {
    /// The colour in sRGB at 8 bits per channel; nil for one that cannot be
    /// expressed in sRGB.
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8(min(max(value, 0), 1) * 255 + 0.5)
        }
        self.init(
            red: channel(srgb.redComponent), green: channel(srgb.greenComponent), blue: channel(srgb.blueComponent),
            alpha: channel(srgb.alphaComponent))
    }
}
