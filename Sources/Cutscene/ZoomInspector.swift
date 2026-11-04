import CutsceneCore
import SwiftUI

/// The selected zoom segment's amount, focus and lock, Delete, Add at the
/// playhead, and Replan (PLAN M2-10). Slider drags are one undo step each.
struct ZoomInspector: View {
    let model: EditorModel

    var body: some View {
        Form {
            Section("Zoom track") {
                LabeledContent("Segments", value: "\(model.timeline.zoom.segments.count)")
                LabeledContent("Plan generation", value: "\(model.timeline.zoom.planGeneration)")
                Button("Add Zoom at Playhead") { model.addZoomAtPlayhead() }
                Button("Replan Automatic Zoom") { model.replanZoom() }
                    .help("Plans the automatic segments again; locked and manual ones stay.")
            }
            if let segment = model.selectedSegment {
                Section("Selected segment") {
                    LabeledContent("Source", value: Self.describe(segment.source))
                    LabeledContent(
                        "Span",
                        value: "\(TransportBar.clock(segment.start)) – \(TransportBar.clock(segment.end))"
                            + String(format: " (%.2f s)", segment.duration))
                    slider(
                        "Amount", value: segment.amount, in: model.settings.zoomAmountRange,
                        format: String(format: "%.2f×", segment.amount), name: "Zoom Amount"
                    ) { model.setSegmentAmount(segment.id, $0) }
                    slider(
                        "Focus X", value: segment.focus.x, in: 0...1, format: String(format: "%.2f", segment.focus.x),
                        name: "Zoom Focus"
                    ) { model.setSegmentFocus(segment.id, NormalizedPoint(x: $0, y: segment.focus.y)) }
                    slider(
                        "Focus Y", value: segment.focus.y, in: 0...1, format: String(format: "%.2f", segment.focus.y),
                        name: "Zoom Focus"
                    ) { model.setSegmentFocus(segment.id, NormalizedPoint(x: segment.focus.x, y: $0)) }
                    Toggle(
                        "Locked",
                        isOn: Binding(
                            get: { segment.locked }, set: { model.setSegmentLocked(segment.id, $0) })
                    )
                    .help("A locked segment survives every replan.")
                    Button("Delete Segment", role: .destructive) { model.deleteSegment(segment.id) }
                }
            } else {
                Section {
                    Text("Select a segment on the zoom lane to edit it; drag its edges to resize, its body to move.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A slider whose drag is one undo step and whose label shows the value.
    private func slider(
        _ title: String, value: Double, in range: ClosedRange<Double>, format: String, name: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Slider(
                    value: Binding(get: { value }, set: { set($0) }), in: range,
                    onEditingChanged: { editing in
                        if editing {
                            model.beginTransaction(name)
                        } else {
                            model.endTransaction()
                        }
                    })
                Text(format).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ source: ZoomSegmentSource) -> String {
        switch source {
        case .auto(let generation): "Automatic (plan \(generation))"
        case .manual: "Manual"
        case .unknown(let kind, _): "Unknown (\(kind))"
        }
    }
}
