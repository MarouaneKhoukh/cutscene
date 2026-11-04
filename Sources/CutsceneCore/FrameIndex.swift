import Foundation
import Synchronization

/// The delivery status of a captured frame, as ScreenCaptureKit reports it
/// (`SCFrameStatus`). An open set rather than an enum so a status a later
/// macOS adds is written and read back as its name instead of refused.
public struct FrameStatus: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// New content was delivered and encoded.
    public static let complete = FrameStatus(rawValue: "complete")
    /// Nothing changed; the frame was counted, not encoded.
    public static let idle = FrameStatus(rawValue: "idle")
    public static let blank = FrameStatus(rawValue: "blank")
    public static let suspended = FrameStatus(rawValue: "suspended")
    public static let started = FrameStatus(rawValue: "started")
    public static let stopped = FrameStatus(rawValue: "stopped")
}

/// The first line of `frames.jsonl`: the format version and the recording
/// the index belongs to.
public struct FrameIndexHeader: Codable, Sendable, Hashable {
    /// The format this build writes.
    public static let currentFormatVersion = 1

    /// Always `currentFormatVersion`: the format this value encodes as.
    public let formatVersion: Int
    public var recordingID: UUID

    public init(recordingID: UUID) {
        formatVersion = Self.currentFormatVersion
        self.recordingID = recordingID
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "k"
        case formatVersion
        case recordingID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.currentFormatVersion).contains(version) else {
            throw RecordingFormatError.unsupportedFrameIndexVersion(version)
        }
        formatVersion = Self.currentFormatVersion
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(FrameIndexLine.Kind.header.rawValue, forKey: .kind)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(recordingID, forKey: .recordingID)
    }
}

/// One screen sample as the recorder saw it (ARCHITECTURE §3): which frame,
/// when it was captured and when it was on screen, whether it was encoded,
/// and the geometry attachments ScreenCaptureKit put on it.
///
/// On disk the geometry fields are sparse: `FrameIndexWriter` writes one
/// only when its value differs from the last one written, so a 10-minute
/// window recording stays a few megabytes. A nil here therefore means
/// "unchanged or unknown", never "absent"; `FrameIndex.frames(carryingGeometryForward:)`
/// fills the gaps back in.
public struct FrameIndexEntry: Sendable, Hashable {
    /// Ordinal of the sample in the stream, from 0, idle samples included.
    public var number: Int
    /// Presentation time on the recording timeline, in seconds: the sample's
    /// own capture stamp, which is also the frame's time in `screen.mp4`.
    public var time: Double
    /// When the window server displayed the frame, on the recording timeline
    /// (`SCStreamFrameInfo.displayTime`); one or two frames before `time`.
    /// Clicks align with this, not with delivery.
    public var displayTime: Double?
    public var status: FrameStatus
    /// Size and location of the content in points, in surface coordinates
    /// (`SCStreamFrameInfo.contentRect`).
    public var contentRect: PointRect?
    /// `SCStreamFrameInfo.contentScale`.
    public var contentScale: Double?
    /// `SCStreamFrameInfo.scaleFactor`.
    public var scaleFactor: Double?
    /// On-screen location of the captured content (`SCStreamFrameInfo.screenRect`).
    public var screenRect: PointRect?
    /// The smallest box around every captured window, in points, surface
    /// coordinates (`SCStreamFrameInfo.boundingRect`); window mode crops to it.
    public var boundingRect: PointRect?

    public init(
        number: Int, time: Double, displayTime: Double? = nil, status: FrameStatus = .complete,
        contentRect: PointRect? = nil, contentScale: Double? = nil, scaleFactor: Double? = nil,
        screenRect: PointRect? = nil, boundingRect: PointRect? = nil
    ) {
        self.number = number
        self.time = time
        self.displayTime = displayTime
        self.status = status
        self.contentRect = contentRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
        self.screenRect = screenRect
        self.boundingRect = boundingRect
    }
}

// Short keys, since there is one line per frame; rects are `[x, y, w, h]`.
extension FrameIndexEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case number = "n"
        case time = "t"
        case displayTime = "d"
        case status = "s"
        case contentRect = "cr"
        case contentScale = "cs"
        case scaleFactor = "sf"
        case screenRect = "sr"
        case boundingRect = "br"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        time = try container.decode(Double.self, forKey: .time)
        displayTime = try container.decodeIfPresent(Double.self, forKey: .displayTime)
        status = try container.decode(FrameStatus.self, forKey: .status)
        contentRect = try Self.decodeRect(from: container, forKey: .contentRect)
        contentScale = try container.decodeIfPresent(Double.self, forKey: .contentScale)
        scaleFactor = try container.decodeIfPresent(Double.self, forKey: .scaleFactor)
        screenRect = try Self.decodeRect(from: container, forKey: .screenRect)
        boundingRect = try Self.decodeRect(from: container, forKey: .boundingRect)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(displayTime, forKey: .displayTime)
        try container.encode(status, forKey: .status)
        try Self.encode(contentRect, into: &container, forKey: .contentRect)
        try container.encodeIfPresent(contentScale, forKey: .contentScale)
        try container.encodeIfPresent(scaleFactor, forKey: .scaleFactor)
        try Self.encode(screenRect, into: &container, forKey: .screenRect)
        try Self.encode(boundingRect, into: &container, forKey: .boundingRect)
    }

    private static func decodeRect(
        from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> PointRect? {
        guard let values = try container.decodeIfPresent([Double].self, forKey: key) else { return nil }
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "A rect is [x, y, width, height].")
        }
        return PointRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func encode(
        _ rect: PointRect?, into container: inout KeyedEncodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws {
        guard let rect else { return }
        try container.encode([rect.x, rect.y, rect.width, rect.height], forKey: key)
    }
}

/// One line of `frames.jsonl`.
public enum FrameIndexLine: Sendable, Hashable {
    case header(FrameIndexHeader)
    case frame(FrameIndexEntry)
    /// The writer could not take the sample captured at `time` (its input
    /// was not ready), so the movie has no frame for it.
    case gap(time: Double)
    /// The idle heartbeat re-encoded the last complete frame at `time`, so
    /// the movie has a frame there that no sample produced.
    case hold(time: Double)
    /// A line kind this build does not know, kept as it was read.
    case other(kind: String, raw: [String: JSONValue])

    /// The `k` discriminator of every line that is not a frame.
    enum Kind: String {
        case header
        case gap
        case hold
    }
}

extension FrameIndexLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind = "k"
        case time = "t"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .kind) else {
            self = .frame(try FrameIndexEntry(from: decoder))
            return
        }
        switch Kind(rawValue: name) {
        case .header:
            self = .header(try FrameIndexHeader(from: decoder))
        case .gap:
            self = .gap(time: try container.decode(Double.self, forKey: .time))
        case .hold:
            self = .hold(time: try container.decode(Double.self, forKey: .time))
        case nil:
            guard case .object(let raw) = try JSONValue(from: decoder) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "A frame index line must be a JSON object.")
            }
            self = .other(kind: name, raw: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .header(let header):
            try header.encode(to: encoder)
        case .frame(let entry):
            try entry.encode(to: encoder)
        case .gap(let time):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.gap.rawValue, forKey: .kind)
            try container.encode(time, forKey: .time)
        case .hold(let time):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.hold.rawValue, forKey: .kind)
            try container.encode(time, forKey: .time)
        case .other(let kind, let raw):
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in raw where key != CodingKeys.kind.rawValue {
                try container.encode(value, forKey: JSONCodingKey(key))
            }
            try container.encode(kind, forKey: JSONCodingKey(CodingKeys.kind.rawValue))
        }
    }
}

// MARK: - Writer

public struct FrameIndexWriterSettings: Sendable, Hashable {
    /// Lines held in memory before they are written: about one second at
    /// 60 fps, so a crash loses no more of the index than the movie's own
    /// fragment interval loses of the video.
    public var maximumPendingLines = 60
    /// Seconds after which pending lines are written even when fewer than
    /// `maximumPendingLines` arrived, so a static screen's hold lines reach
    /// the disk within the heartbeat.
    public var flushInterval: TimeInterval = 1.0

    public init(maximumPendingLines: Int = 60, flushInterval: TimeInterval = 1.0) {
        self.maximumPendingLines = maximumPendingLines
        self.flushInterval = flushInterval
    }
}

/// Appends `frames.jsonl` during a take: the header first, then one line per
/// sample, gap or hold. Geometry fields are written only when they change
/// from the last written value, which is what keeps the file small on a
/// window recording whose geometry is attached to every frame.
///
/// Lock-guarded rather than an actor so the capture session can call it
/// from its sample queue without a hop. The file is append-only, so a crash
/// can tear at most the last line, which `FrameIndex.read(from:)` drops.
public final class FrameIndexWriter: @unchecked Sendable {
    public let url: URL
    public let settings: FrameIndexWriterSettings

    private struct State: Sendable {
        var pending = Data()
        var pendingLines = 0
        var lastFlush: ContinuousClock.Instant
        var lastContentRect: PointRect?
        var lastContentScale: Double?
        var lastScaleFactor: Double?
        var lastScreenRect: PointRect?
        var lastBoundingRect: PointRect?
        var linesWritten = 0
        var isClosed = false
    }

    private let handle: FileHandle
    private let state: Mutex<State>
    /// Only used under the lock.
    private let encoder = PackageJSON.encoder()

    /// Creates (or truncates) the file and writes the header line at once,
    /// so the index exists from the first moment of the take.
    public init(url: URL, header: FrameIndexHeader, settings: FrameIndexWriterSettings = FrameIndexWriterSettings())
        throws
    {
        self.url = url
        self.settings = settings
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        state = Mutex(State(lastFlush: .now))
        try append(.header(header))
        try flush()
    }

    deinit {
        // Best effort: the session closes the writer; a dropped one should
        // not take its last second of lines with it.
        try? close()
    }

    /// Lines written so far, the header included; pending lines count.
    public var linesWritten: Int {
        state.withLock { $0.linesWritten }
    }

    /// Appends one sample. Geometry fields equal to the last written value
    /// are left out of the line; a nil field is treated as unchanged.
    public func append(_ entry: FrameIndexEntry) throws {
        try state.withLock { state in
            var sparse = entry
            sparse.contentRect = Self.changed(entry.contentRect, from: &state.lastContentRect)
            sparse.contentScale = Self.changed(entry.contentScale, from: &state.lastContentScale)
            sparse.scaleFactor = Self.changed(entry.scaleFactor, from: &state.lastScaleFactor)
            sparse.screenRect = Self.changed(entry.screenRect, from: &state.lastScreenRect)
            sparse.boundingRect = Self.changed(entry.boundingRect, from: &state.lastBoundingRect)
            try write(.frame(sparse), state: &state)
        }
    }

    /// Records that the sample captured at `time` was not written to the movie.
    public func appendGap(at time: Double) throws {
        try append(.gap(time: time))
    }

    /// Records a heartbeat frame encoded at `time`.
    public func appendHold(at time: Double) throws {
        try append(.hold(time: time))
    }

    /// Appends any line, geometry deduplication included for a frame.
    public func append(_ line: FrameIndexLine) throws {
        if case .frame(let entry) = line {
            try append(entry)
            return
        }
        try state.withLock { state in
            try write(line, state: &state)
        }
    }

    /// Writes every pending line now.
    public func flush() throws {
        try state.withLock { state in
            try flushPending(state: &state)
        }
    }

    /// Writes every pending line and closes the file; later calls do nothing.
    public func close() throws {
        try state.withLock { state in
            guard !state.isClosed else { return }
            state.isClosed = true
            try flushPending(state: &state)
            try handle.close()
        }
    }

    /// `value` when it differs from `last` (which it then replaces), else nil.
    private static func changed<T: Equatable>(_ value: T?, from last: inout T?) -> T? {
        guard let value, value != last else { return nil }
        last = value
        return value
    }

    private func write(_ line: FrameIndexLine, state: inout State) throws {
        guard !state.isClosed else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        state.pending.append(try encoder.encode(line))
        state.pending.append(UInt8(ascii: "\n"))
        state.pendingLines += 1
        state.linesWritten += 1
        let now = ContinuousClock.Instant.now
        if state.pendingLines >= settings.maximumPendingLines
            || now - state.lastFlush >= .seconds(settings.flushInterval)
        {
            try flushPending(state: &state)
        }
    }

    private func flushPending(state: inout State) throws {
        state.lastFlush = .now
        guard !state.pending.isEmpty else { return }
        try handle.write(contentsOf: state.pending)
        state.pending.removeAll(keepingCapacity: true)
        state.pendingLines = 0
    }
}

// MARK: - Reader

/// `frames.jsonl` as read back: the header and every line after it, in file
/// order. A take that never reached stop leaves a last line torn mid-write;
/// the reader keeps every complete line before it and reports where it
/// stopped, so recovery and the editor work from what is there.
public struct FrameIndex: Sendable, Hashable {
    public var header: FrameIndexHeader
    /// Every line after the header, as stored (geometry sparse).
    public var lines: [FrameIndexLine]
    /// Zero-based index in the file of the first line that could not be
    /// read, after which nothing was; nil when every line was intact.
    public var truncatedAtLine: Int?

    public init(header: FrameIndexHeader, lines: [FrameIndexLine] = [], truncatedAtLine: Int? = nil) {
        self.header = header
        self.lines = lines
        self.truncatedAtLine = truncatedAtLine
    }

    /// The frame entries in order. With `carryingGeometryForward`, a field
    /// the writer left out as unchanged is filled from the last frame that
    /// carried it, so each entry stands on its own.
    public func frames(carryingGeometryForward: Bool = true) -> [FrameIndexEntry] {
        var frames: [FrameIndexEntry] = []
        var last: FrameIndexEntry?
        for case .frame(var entry) in lines {
            if carryingGeometryForward, let last {
                entry.contentRect = entry.contentRect ?? last.contentRect
                entry.contentScale = entry.contentScale ?? last.contentScale
                entry.scaleFactor = entry.scaleFactor ?? last.scaleFactor
                entry.screenRect = entry.screenRect ?? last.screenRect
                entry.boundingRect = entry.boundingRect ?? last.boundingRect
            }
            frames.append(entry)
            last = entry
        }
        return frames
    }

    /// Times of the heartbeat frames, in order.
    public var holdTimes: [Double] {
        lines.compactMap {
            if case .hold(let time) = $0 { return time }
            return nil
        }
    }

    /// Times of the samples the movie is missing, in order.
    public var gapTimes: [Double] {
        lines.compactMap {
            if case .gap(let time) = $0 { return time }
            return nil
        }
    }

    /// How many frames the movie should hold: every sample that carried
    /// content (`complete`, and `started`, the first frame after the stream
    /// starts, which the recorder encodes too), plus the holds, minus the gaps.
    public var expectedMovieFrameCount: Int {
        var count = 0
        for line in lines {
            switch line {
            case .frame(let entry) where entry.status == .complete || entry.status == .started: count += 1
            case .hold: count += 1
            case .gap: count -= 1
            case .frame, .header, .other: break
            }
        }
        return count
    }

    /// Parses JSON Lines as `FrameIndexWriter` writes them. The first line
    /// must be the header; after it, the first line that does not parse
    /// (torn by a crash) ends the read.
    public init(jsonLines data: Data) throws {
        let decoder = PackageJSON.decoder()
        var header: FrameIndexHeader?
        var lines: [FrameIndexLine] = []
        var truncatedAtLine: Int?
        var number = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            defer { number += 1 }
            if line.isEmpty { continue }
            let decoded: FrameIndexLine
            do {
                decoded = try decoder.decode(FrameIndexLine.self, from: line)
            } catch let error as RecordingFormatError {
                // A refused version is a verdict on the whole file, not a tear.
                throw error
            } catch {
                if header == nil { throw RecordingFormatError.missingFrameIndexHeader }
                truncatedAtLine = number
                break
            }
            if header == nil {
                guard case .header(let first) = decoded else { throw RecordingFormatError.missingFrameIndexHeader }
                header = first
            } else {
                lines.append(decoded)
            }
        }
        guard let header else { throw RecordingFormatError.missingFrameIndexHeader }
        self.init(header: header, lines: lines, truncatedAtLine: truncatedAtLine)
    }

    /// Reads an index written by `FrameIndexWriter`.
    public static func read(from url: URL) throws -> FrameIndex {
        try FrameIndex(jsonLines: Data(contentsOf: url))
    }

    /// The index as JSON Lines, the header first, exactly as the writer
    /// lays it out.
    public func jsonLines() throws -> Data {
        let encoder = PackageJSON.encoder()
        var data = try encoder.encode(FrameIndexLine.header(header))
        data.append(UInt8(ascii: "\n"))
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
