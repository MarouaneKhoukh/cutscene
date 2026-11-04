import CutsceneCore
import Foundation

// `ZoomTrackSegment` (Core) mirrors `ZoomSegment` field for field and adds
// the editing metadata (ARCHITECTURE §3); these conversions and the replan
// are the one place the two meet.

extension ZoomSegment {
    /// The engine's view of a track segment: its span, focus and amount.
    public init(_ segment: ZoomTrackSegment) {
        self.init(start: segment.start, end: segment.end, focus: segment.focus, amount: segment.amount)
    }
}

extension ZoomTrackSegment {
    /// A planned segment on the track, as `.auto(generation:)` unless told
    /// otherwise; a fresh id, since a planned segment is a new entity.
    public init(
        _ segment: ZoomSegment, source: ZoomSegmentSource, locked: Bool = false, id: UUID = UUID(),
        extra: [String: JSONValue] = [:]
    ) {
        self.init(
            id: id, start: segment.start, end: segment.end, focus: segment.focus, amount: segment.amount,
            source: source, locked: locked, extra: extra)
    }
}

/// Every constant of the replan.
public struct ZoomTrackMergeSettings: Sendable, Hashable {
    /// A planned segment is cut around the segments the user keeps; a
    /// leftover piece shorter than this is dropped, because a sliver of
    /// automatic zoom wedged between two kept segments reads as a flicker
    /// rather than a zoom (the camera spring takes about this long to settle).
    public var minimumAutomaticDuration: Double = 0.5

    public init() {}
}

/// Brings a fresh automatic plan onto a user's zoom track and turns a track
/// back into the engine's segments.
///
/// A replan replaces only what the planner owns: unlocked `.auto` segments.
/// Locked segments, `.manual` ones and segments of a kind this build does not
/// know stay exactly as they are, and the new automatic segments are cut
/// around them, so an edit the user made is never undone by moving a slider.
public enum ZoomTrackMerge {
    /// `track` with its replaceable segments dropped and `planned` (the
    /// planner's output for the same recording) merged in as
    /// `.auto(generation: track.planGeneration + 1)`, trimmed around every
    /// kept segment. The result is sorted by start; `extra` is kept. The
    /// first plan of a project is the replan of an empty track.
    public static func replan(
        _ track: ZoomTrack, with planned: [ZoomSegment], settings: ZoomTrackMergeSettings = ZoomTrackMergeSettings()
    ) -> ZoomTrack {
        let generation = track.planGeneration + 1
        let kept = track.segments.filter { !$0.isReplaceableByReplan }
        let reserved = kept.map { ($0.start, $0.end) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged = kept
        for segment in planned where segment.end > segment.start && segment.start.isFinite && segment.end.isFinite {
            for piece in pieces(of: segment, outside: reserved)
            where piece.end - piece.start >= settings.minimumAutomaticDuration {
                merged.append(ZoomTrackSegment(piece, source: .auto(generation: generation)))
            }
        }
        return ZoomTrack(
            segments: sortedByStart(merged), planGeneration: generation, extra: track.extra)
    }

    /// The track as the camera planner takes it: every segment that spans
    /// any time, sorted by start. Segments overlap only when the user made
    /// them so; the camera planner then lets the earlier one win. A segment
    /// whose end does not pass its start, or with a non-finite bound, is left
    /// out, since it spans nothing the camera could show.
    public static func segments(of track: ZoomTrack) -> [ZoomSegment] {
        let usable = track.segments.filter { $0.end > $0.start && $0.start.isFinite && $0.end.isFinite }
        return sortedByStart(usable).map(ZoomSegment.init)
    }

    /// `segment` minus the `reserved` spans (sorted, each non-empty): the
    /// pieces left over, in time order, keeping the focus and amount.
    private static func pieces(of segment: ZoomSegment, outside reserved: [(Double, Double)]) -> [ZoomSegment] {
        var pieces: [ZoomSegment] = []
        var cursor = segment.start
        for (start, end) in reserved where end > segment.start && start < segment.end {
            if start > cursor {
                pieces.append(ZoomSegment(start: cursor, end: start, focus: segment.focus, amount: segment.amount))
            }
            cursor = max(cursor, end)
            if cursor >= segment.end { break }
        }
        if cursor < segment.end {
            pieces.append(ZoomSegment(start: cursor, end: segment.end, focus: segment.focus, amount: segment.amount))
        }
        return pieces
    }

    /// Sorted by start, equal starts keeping their order; the index is the
    /// tie-breaker because `sort` makes no stability promise.
    private static func sortedByStart<Segment>(_ segments: [Segment]) -> [Segment]
    where Segment: ZoomSpan {
        segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }
}

/// What the two segment types share, for the sort above.
protocol ZoomSpan {
    var start: Double { get }
}

extension ZoomSegment: ZoomSpan {}
extension ZoomTrackSegment: ZoomSpan {}
