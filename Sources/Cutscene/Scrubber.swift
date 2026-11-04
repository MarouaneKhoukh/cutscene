import CutsceneCore
import SwiftUI

/// The numbers the scrubber is drawn with.
struct ScrubberSettings: Sendable, Equatable {
    /// Points of margin on each side, so a handle at 0 s can still be grabbed.
    var horizontalInset = 14.0
    /// The time ruler's height at the top.
    var rulerHeight = 18.0
    /// The clip lane: kept, trimmed, and the trim handles.
    var clipLaneHeight = 34.0
    /// The zoom lane under it.
    var zoomLaneHeight = 30.0
    var laneSpacing = 8.0
    var laneCornerRadius = 5.0
    /// Width of a trim handle and of the strip a drag catches it in.
    var handleWidth = 8.0
    var handleHitWidth = 12.0
    /// Points from a zoom segment's edge within which a drag resizes it
    /// rather than moving it.
    var segmentEdgeHitWidth = 6.0
    var playheadWidth = 2.0
    /// Fewest points between two ruler labels.
    var minimumTickSpacing = 70.0
    /// Tick intervals in seconds the ruler picks from, in order.
    var tickIntervals: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
    var keptColor = Color.accentColor.opacity(0.35)
    var trimmedColor = Color.primary.opacity(0.08)
    var handleColor = Color.accentColor
    var automaticSegmentColor = Color.teal.opacity(0.7)
    var manualSegmentColor = Color.orange.opacity(0.8)
    var selectedSegmentOutline = Color.primary
    var lockedOutline = Color.primary.opacity(0.6)
    var playheadColor = Color.red
    var rulerColor = Color.secondary
}

/// What a drag on the scrubber took hold of.
private enum DragTarget: Equatable {
    case playhead
    case trimStart
    case trimEnd
    case segmentStart(UUID)
    case segmentEnd(UUID)
    /// `grabOffset` is seconds from the segment's start to where it was grabbed.
    case segmentBody(UUID, grabOffset: Double)
}

/// The timeline under the preview (PLAN M2-10): a ruler in recording
/// seconds, the clip lane with the trimmed head and tail darkened and a
/// handle at each trim edge, the zoom lane with every segment drawn
/// (automatic and manual in their own colours, locked ones outlined, the
/// selected one highlighted), and the playhead. Dragging a handle trims,
/// dragging a segment's edge resizes it, its body moves it, and anywhere
/// else scrubs. A drag is one undo step.
struct Scrubber: View {
    let model: EditorModel
    var settings = ScrubberSettings()

    @State private var target: DragTarget?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, size: size) }
                    .onEnded { _ in dragEnded() }
            )
        }
    }

    // MARK: Geometry

    private func trackWidth(_ size: CGSize) -> Double {
        max(size.width - 2 * settings.horizontalInset, 1)
    }

    private func x(forTime time: Double, size: CGSize) -> Double {
        let duration = max(model.recordingDuration, 1e-9)
        return settings.horizontalInset + time / duration * trackWidth(size)
    }

    private func time(forX x: Double, size: CGSize) -> Double {
        let fraction = (x - settings.horizontalInset) / trackWidth(size)
        return min(max(fraction, 0), 1) * model.recordingDuration
    }

    private var clipLaneY: Double { settings.rulerHeight + settings.laneSpacing }
    private var zoomLaneY: Double { clipLaneY + settings.clipLaneHeight + settings.laneSpacing }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawRuler(in: &context, size: size)
        drawClipLane(in: &context, size: size)
        drawZoomLane(in: &context, size: size)
        let playheadX = x(forTime: model.playheadSourceTime, size: size)
        let playhead = CGRect(
            x: playheadX - settings.playheadWidth / 2, y: settings.rulerHeight, width: settings.playheadWidth,
            height: size.height - settings.rulerHeight)
        context.fill(Path(playhead), with: .color(settings.playheadColor))
    }

    private func drawRuler(in context: inout GraphicsContext, size: CGSize) {
        let duration = model.recordingDuration
        guard duration > 0 else { return }
        let pointsPerSecond = trackWidth(size) / duration
        let interval =
            settings.tickIntervals.first { $0 * pointsPerSecond >= settings.minimumTickSpacing }
            ?? settings.tickIntervals.last ?? 1
        var tick = 0.0
        while tick <= duration + 1e-9 {
            let tickX = x(forTime: tick, size: size)
            context.fill(
                Path(CGRect(x: tickX - 0.5, y: settings.rulerHeight - 6, width: 1, height: 6)),
                with: .color(settings.rulerColor))
            let label = Text(TransportBar.clock(tick)).font(.caption2).foregroundStyle(settings.rulerColor)
            context.draw(label, at: CGPoint(x: tickX, y: settings.rulerHeight / 2 - 3), anchor: .center)
            tick += interval
        }
    }

    private func drawClipLane(in context: inout GraphicsContext, size: CGSize) {
        let lane = CGRect(
            x: settings.horizontalInset, y: clipLaneY, width: trackWidth(size), height: settings.clipLaneHeight)
        context.fill(
            Path(roundedRect: lane, cornerRadius: settings.laneCornerRadius), with: .color(settings.trimmedColor))
        for range in model.timeline.keptRanges() {
            let kept = CGRect(
                x: x(forTime: range.start, size: size), y: lane.minY,
                width: x(forTime: range.end, size: size) - x(forTime: range.start, size: size), height: lane.height)
            context.fill(Path(kept), with: .color(settings.keptColor))
        }
        for time in [model.trimStart, model.trimEnd] {
            let handle = CGRect(
                x: x(forTime: time, size: size) - settings.handleWidth / 2, y: lane.minY, width: settings.handleWidth,
                height: lane.height)
            context.fill(
                Path(roundedRect: handle, cornerRadius: settings.handleWidth / 3), with: .color(settings.handleColor))
            let grip = CGRect(
                x: handle.midX - 0.5, y: handle.minY + handle.height * 0.3, width: 1, height: handle.height * 0.4)
            context.fill(Path(grip), with: .color(.white.opacity(0.8)))
        }
    }

    private func drawZoomLane(in context: inout GraphicsContext, size: CGSize) {
        let lane = CGRect(
            x: settings.horizontalInset, y: zoomLaneY, width: trackWidth(size), height: settings.zoomLaneHeight)
        context.fill(
            Path(roundedRect: lane, cornerRadius: settings.laneCornerRadius), with: .color(settings.trimmedColor))
        for segment in model.timeline.zoom.segments {
            let startX = x(forTime: segment.start, size: size)
            let endX = x(forTime: segment.end, size: size)
            let rect = CGRect(x: startX, y: lane.minY + 3, width: max(endX - startX, 2), height: lane.height - 6)
            let path = Path(roundedRect: rect, cornerRadius: settings.laneCornerRadius)
            let color: Color
            switch segment.source {
            case .auto: color = settings.automaticSegmentColor
            case .manual, .unknown: color = settings.manualSegmentColor
            }
            context.fill(path, with: .color(color))
            if segment.id == model.selectedSegmentID {
                context.stroke(path, with: .color(settings.selectedSegmentOutline), lineWidth: 2)
            } else if segment.locked {
                context.stroke(path, with: .color(settings.lockedOutline), lineWidth: 1)
            }
            let label = Text(
                (segment.locked ? "🔒 " : "") + String(format: "%.1f×", segment.amount)
            ).font(.caption2).foregroundStyle(.white)
            if rect.width > 40 {
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
        let time = time(forX: value.location.x, size: size)
        if target == nil {
            let hit = hitTest(value.startLocation, size: size)
            target = hit
            switch hit {
            case .playhead:
                model.preview.pause()
            case .trimStart, .trimEnd:
                model.beginTransaction("Trim")
            case .segmentStart(let id), .segmentEnd(let id):
                model.select(segment: id)
                model.beginTransaction("Resize Zoom")
            case .segmentBody(let id, _):
                model.select(segment: id)
                model.beginTransaction("Move Zoom")
            }
        }
        switch target {
        case .playhead, nil:
            model.scrub(toSourceTime: time)
        case .trimStart:
            model.setTrim(start: time, end: model.trimEnd, movingEdge: .start)
        case .trimEnd:
            model.setTrim(start: model.trimStart, end: time, movingEdge: .end)
        case .segmentStart(let id):
            model.resizeSegment(id, edge: .start, to: time)
        case .segmentEnd(let id):
            model.resizeSegment(id, edge: .end, to: time)
        case .segmentBody(let id, let grabOffset):
            model.moveSegment(id, toStart: time - grabOffset)
        }
    }

    private func dragEnded() {
        model.endTransaction()
        target = nil
    }

    /// What lies under `point`: a trim handle, a segment's edge or body, or
    /// the bare timeline. A click on the zoom lane's empty part clears the
    /// selection.
    private func hitTest(_ point: CGPoint, size: CGSize) -> DragTarget {
        let y = point.y
        if y >= clipLaneY, y < clipLaneY + settings.clipLaneHeight {
            for (time, target) in [(model.trimStart, DragTarget.trimStart), (model.trimEnd, .trimEnd)]
            where abs(point.x - x(forTime: time, size: size)) <= settings.handleHitWidth {
                return target
            }
            return .playhead
        }
        if y >= zoomLaneY, y < zoomLaneY + settings.zoomLaneHeight {
            // The topmost drawn segment wins, so an overlap is grabbed as it is seen.
            for segment in model.timeline.zoom.segments.reversed() {
                let startX = x(forTime: segment.start, size: size)
                let endX = x(forTime: segment.end, size: size)
                guard point.x >= startX - settings.segmentEdgeHitWidth, point.x <= endX + settings.segmentEdgeHitWidth
                else { continue }
                if abs(point.x - startX) <= settings.segmentEdgeHitWidth { return .segmentStart(segment.id) }
                if abs(point.x - endX) <= settings.segmentEdgeHitWidth { return .segmentEnd(segment.id) }
                return .segmentBody(segment.id, grabOffset: time(forX: point.x, size: size) - segment.start)
            }
            model.select(segment: nil)
        }
        return .playhead
    }
}
