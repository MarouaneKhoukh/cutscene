import Foundation

/// A span of the recording timeline, `start...end` in seconds. The recording
/// timeline is source time: the clock the media and the event log share,
/// unaffected by edits.
public struct TimeRange: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public init(_ range: ClosedRange<Double>) {
        self.init(start: range.lowerBound, end: range.upperBound)
    }

    /// Never negative: a range whose end precedes its start is empty.
    public var duration: Double {
        max(end - start, 0)
    }

    /// Whether nothing lies inside: the end does not pass the start.
    public var isEmpty: Bool {
        end <= start
    }

    /// The same span as a standard range, for APIs that take one (the
    /// engine's `disabledRanges`, for instance). An empty range collapses to
    /// its start, since a `ClosedRange` cannot run backwards.
    public var closedRange: ClosedRange<Double> {
        start...max(start, end)
    }

    public func contains(_ time: Double) -> Bool {
        start <= time && time <= end
    }
}

// MARK: - Clips and cuts

/// A stretch of the recording placed on the timeline, in source seconds. A
/// fresh project has one clip spanning the whole recording; takes (M3) add
/// more. Clips play in array order.
public struct Clip: Sendable, Hashable, Identifiable, PreservesUnknownKeys {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var extra: [String: JSONValue]

    public init(id: UUID = UUID(), start: Double, end: Double, extra: [String: JSONValue] = [:]) {
        self.id = id
        self.start = start
        self.end = end
        self.extra = extra
    }

    public var range: TimeRange {
        TimeRange(start: start, end: end)
    }
}

/// Who or what removed a span of the recording. The editor shows and treats
/// each kind differently: a trim is adjusted by its handles, a retake cut
/// belongs to a take decision, transcript cuts to the words they removed.
public enum Provenance: Sendable, Hashable {
    /// The head or tail trimmed off with the handles.
    case trim
    /// A cut the user made anywhere else.
    case manual
    /// Removed by take stitching; the id of the take decision that made it.
    case retake(UUID)
    /// A silence removed or sped past.
    case silence
    /// Words removed in the transcript editor, by their ids.
    case transcriptWords([UUID])
    /// A kind this build does not know, kept so it goes back to disk as it
    /// came: `kind` is the object's `kind`, `raw` the whole object. The cut
    /// still removes its span, since a newer build meant it to.
    case unknown(kind: String, raw: [String: JSONValue])
}

/// A span of the recording left out of the timeline, in source seconds. Cuts
/// apply to every clip they overlap; `Timeline.keptRanges()` subtracts them.
public struct Cut: Sendable, Hashable, Identifiable, PreservesUnknownKeys {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var provenance: Provenance
    public var extra: [String: JSONValue]

    public init(
        id: UUID = UUID(), start: Double, end: Double, provenance: Provenance, extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.provenance = provenance
        self.extra = extra
    }

    public var range: TimeRange {
        TimeRange(start: start, end: end)
    }
}

// MARK: - Zoom track

/// Where a zoom segment came from, which decides what a replan may touch:
/// an automatic replan replaces only unlocked `auto` segments.
public enum ZoomSegmentSource: Sendable, Hashable {
    /// Planned by the engine in the replan numbered `generation`
    /// (`ZoomTrack.planGeneration`), so stale and current plans can be told apart.
    case auto(generation: Int)
    /// Added or taken over by the user.
    case manual
    /// A kind this build does not know, kept verbatim and treated like
    /// `manual`: never replaced by a replan.
    case unknown(kind: String, raw: [String: JSONValue])
}

/// One zoom on the timeline: the engine's `ZoomSegment` (`start`, `end`,
/// `focus`, `amount`, mirrored field for field since Core cannot import the
/// engine) plus the editing metadata around it.
public struct ZoomTrackSegment: Sendable, Hashable, Identifiable, PreservesUnknownKeys {
    public var id: UUID
    /// Seconds since the recording started (source time).
    public var start: Double
    public var end: Double
    /// Where the zoom aims first, in frame coordinates; the camera follows
    /// the cursor from there.
    public var focus: NormalizedPoint
    /// Magnification, at least 1; 2 shows half the frame's width and height.
    public var amount: Double
    public var source: ZoomSegmentSource
    /// A locked segment survives every replan, whatever its source.
    public var locked: Bool
    public var extra: [String: JSONValue]

    public init(
        id: UUID = UUID(), start: Double, end: Double, focus: NormalizedPoint, amount: Double,
        source: ZoomSegmentSource, locked: Bool = false, extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.focus = focus
        self.amount = amount
        self.source = source
        self.locked = locked
        self.extra = extra
    }

    public var duration: Double {
        end - start
    }

    public func contains(_ time: Double) -> Bool {
        start <= time && time <= end
    }

    /// Whether an automatic replan may drop this segment: planned, not
    /// locked, not the user's.
    public var isReplaceableByReplan: Bool {
        guard !locked, case .auto = source else { return false }
        return true
    }
}

/// The zoom segments of a project, planned and edited.
public struct ZoomTrack: Sendable, Hashable, PreservesUnknownKeys {
    public var segments: [ZoomTrackSegment]
    /// Number of automatic replans so far; the generation the newest `auto`
    /// segments carry. Zero before the first plan.
    public var planGeneration: Int
    public var extra: [String: JSONValue]

    public init(segments: [ZoomTrackSegment] = [], planGeneration: Int = 0, extra: [String: JSONValue] = [:]) {
        self.segments = segments
        self.planGeneration = planGeneration
        self.extra = extra
    }
}

// MARK: - Timeline

/// Every edit of a project, in source time: which stretches of the recording
/// play (`clips` minus `cuts`), and the tracks laid over them.
/// `keptRanges()` is the one mapping between source and timeline time; every
/// other conversion derives from it, so trim, retake and transcript cuts all
/// reach the composition the same way.
public struct Timeline: Sendable, Hashable, PreservesUnknownKeys {
    public var clips: [Clip]
    public var cuts: [Cut]
    public var zoom: ZoomTrack
    /// Reserved for the camera-bubble track; nil until a build defines it.
    public var camera: JSONValue?
    /// Reserved for captions.
    public var captions: JSONValue?
    /// Reserved for callouts.
    public var callouts: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        clips: [Clip] = [], cuts: [Cut] = [], zoom: ZoomTrack = ZoomTrack(), camera: JSONValue? = nil,
        captions: JSONValue? = nil, callouts: JSONValue? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.clips = clips
        self.cuts = cuts
        self.zoom = zoom
        self.camera = camera
        self.captions = captions
        self.callouts = callouts
        self.extra = extra
    }

    /// The timeline a new recording starts with: one clip over all of it and
    /// nothing cut.
    public static func wholeRecording(duration: Double, clipID: UUID = UUID()) -> Timeline {
        Timeline(clips: [Clip(id: clipID, start: 0, end: duration)])
    }

    /// The stretches of source time that play, in timeline order: each clip
    /// with every overlapping cut removed. Cuts may overlap each other and
    /// reach outside a clip; empty results are dropped, so the composition
    /// gets one insert per range and never a zero-length one.
    public func keptRanges() -> [TimeRange] {
        let removed = Self.merged(cuts.map(\.range).filter { !$0.isEmpty })
        var kept: [TimeRange] = []
        for clip in clips where clip.end > clip.start {
            var cursor = clip.start
            for cut in removed where cut.end > clip.start && cut.start < clip.end {
                if cut.start > cursor {
                    kept.append(TimeRange(start: cursor, end: cut.start))
                }
                cursor = max(cursor, cut.end)
                if cursor >= clip.end { break }
            }
            if cursor < clip.end {
                kept.append(TimeRange(start: cursor, end: clip.end))
            }
        }
        return kept
    }

    /// Seconds the timeline plays for: the kept ranges end to end.
    public var duration: Double {
        keptRanges().reduce(0) { $0 + $1.duration }
    }

    /// Where a moment of the recording plays on the timeline; nil when it is
    /// cut. A source time inside two clips maps to the first.
    public func timelineTime(forSourceTime sourceTime: Double) -> Double? {
        Self.timelineTime(forSourceTime: sourceTime, keptRanges: keptRanges())
    }

    /// Which moment of the recording plays at `timelineTime`; nil outside
    /// `0...duration`. A boundary shared by two ranges maps to the earlier one.
    public func sourceTime(forTimelineTime timelineTime: Double) -> Double? {
        Self.sourceTime(forTimelineTime: timelineTime, keptRanges: keptRanges())
    }

    /// `timelineTime(forSourceTime:)` over any kept ranges (sorted, disjoint,
    /// as `keptRanges()` returns them): for a consumer that maps against the
    /// ranges a composition was built from rather than the timeline as it
    /// stands now, which an edit may have changed since.
    public static func timelineTime(forSourceTime sourceTime: Double, keptRanges: [TimeRange]) -> Double? {
        var offset = 0.0
        for range in keptRanges {
            if range.contains(sourceTime) { return offset + (sourceTime - range.start) }
            offset += range.duration
        }
        return nil
    }

    /// `sourceTime(forTimelineTime:)` over any kept ranges.
    public static func sourceTime(forTimelineTime timelineTime: Double, keptRanges: [TimeRange]) -> Double? {
        guard timelineTime >= 0 else { return nil }
        var offset = 0.0
        for range in keptRanges {
            if timelineTime <= offset + range.duration { return range.start + (timelineTime - offset) }
            offset += range.duration
        }
        return nil
    }

    /// `ranges` sorted and overlapping or touching ones joined.
    static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var result: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                result[result.count - 1] = last
            } else {
                result.append(range)
            }
        }
        return result
    }
}

// MARK: - Codable

extension Clip: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

// Written as `{"kind":"trim"}`, `{"kind":"retake","takeID":"…"}` or
// `{"kind":"transcriptWords","wordIDs":["…"]}`: a discriminator plus the
// payload, like `CaptureSource`; an unknown kind keeps its whole object.
extension Provenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case takeID
        case wordIDs
    }

    private enum Kind: String, Codable {
        case trim
        case manual
        case retake
        case silence
        case transcriptWords
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: name) {
        case .trim:
            self = .trim
        case .manual:
            self = .manual
        case .retake:
            self = .retake(try container.decode(UUID.self, forKey: .takeID))
        case .silence:
            self = .silence
        case .transcriptWords:
            self = .transcriptWords(try container.decode([UUID].self, forKey: .wordIDs))
        case nil:
            guard case .object(let raw) = try JSONValue(from: decoder) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "A provenance must be an object.")
            }
            self = .unknown(kind: name, raw: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .trim:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.trim, forKey: .kind)
        case .manual:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.manual, forKey: .kind)
        case .retake(let takeID):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.retake, forKey: .kind)
            try container.encode(takeID, forKey: .takeID)
        case .silence:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.silence, forKey: .kind)
        case .transcriptWords(let wordIDs):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.transcriptWords, forKey: .kind)
            try container.encode(wordIDs, forKey: .wordIDs)
        case .unknown(let kind, let raw):
            var object = raw
            object[CodingKeys.kind.stringValue] = .string(kind)
            try JSONValue.object(object).encode(to: encoder)
        }
    }
}

extension Cut: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case start
        case end
        case provenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(provenance, forKey: .provenance)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

// Written as `{"kind":"auto","generation":3}` or `{"kind":"manual"}`.
extension ZoomSegmentSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case generation
    }

    private enum Kind: String, Codable {
        case auto
        case manual
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: name) {
        case .auto:
            self = .auto(generation: try container.decode(Int.self, forKey: .generation))
        case .manual:
            self = .manual
        case nil:
            guard case .object(let raw) = try JSONValue(from: decoder) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "A zoom segment source must be an object.")
            }
            self = .unknown(kind: name, raw: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .auto(let generation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.auto, forKey: .kind)
            try container.encode(generation, forKey: .generation)
        case .manual:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.manual, forKey: .kind)
        case .unknown(let kind, let raw):
            var object = raw
            object[CodingKeys.kind.stringValue] = .string(kind)
            try JSONValue.object(object).encode(to: encoder)
        }
    }
}

extension ZoomTrackSegment: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case start
        case end
        case focus
        case amount
        case source
        case locked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        focus = try container.decode(NormalizedPoint.self, forKey: .focus)
        amount = try container.decode(Double.self, forKey: .amount)
        source = try container.decode(ZoomSegmentSource.self, forKey: .source)
        locked = try container.decode(.locked, or: false)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(focus, forKey: .focus)
        try container.encode(amount, forKey: .amount)
        try container.encode(source, forKey: .source)
        try container.encode(locked, forKey: .locked)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ZoomTrack: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case segments
        case planGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode(.segments, or: [])
        planGeneration = try container.decode(.planGeneration, or: 0)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(planGeneration, forKey: .planGeneration)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension Timeline: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clips
        case cuts
        case zoom
        case camera
        case captions
        case callouts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clips = try container.decode(.clips, or: [])
        cuts = try container.decode(.cuts, or: [])
        zoom = try container.decode(.zoom, or: ZoomTrack())
        camera = try container.decodeIfPresent(JSONValue.self, forKey: .camera)
        captions = try container.decodeIfPresent(JSONValue.self, forKey: .captions)
        callouts = try container.decodeIfPresent(JSONValue.self, forKey: .callouts)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        try container.encode(cuts, forKey: .cuts)
        try container.encode(zoom, forKey: .zoom)
        try container.encodeIfPresent(camera, forKey: .camera)
        try container.encodeIfPresent(captions, forKey: .captions)
        try container.encodeIfPresent(callouts, forKey: .callouts)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}
