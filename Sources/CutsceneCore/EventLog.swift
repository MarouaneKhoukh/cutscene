import Foundation

/// Why an event log could not be read.
public enum EventLogError: LocalizedError, Sendable, Equatable {
    /// The file declares a format this build does not know, so its fields
    /// cannot be trusted to mean what they mean here.
    case unsupportedFormatVersion(Int)
    /// An event's time is not a finite number, so it has no place in time
    /// order and would break every consumer that walks the log by time.
    case invalidTime(Double)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "This event log uses format version \(version); this build reads versions "
                + "\(EventLog.oldestReadableFormatVersion) through \(EventLog.currentFormatVersion)."
        case .invalidTime(let time):
            "This event log contains an event at time \(time), which is not a finite number."
        }
    }
}

/// The input telemetry recorded alongside a capture: the JSON file the
/// recorder writes next to the media, and the source every effect is computed
/// from at render time.
///
/// The log is an open product format (research brief §3), so its shape is
/// versioned and pinned by a fixture in `cutscene-check`. Adding an event
/// kind never bumps `currentFormatVersion`: a build that does not know the
/// kind keeps its rows through `InputEvent.unknown`. Renaming a field or
/// changing what one means does bump it, with a fixture per version.
///
/// Every event time is a finite number: `append` refuses anything else and
/// decoding fails on it, since one NaN would silently break the sort order.
public struct EventLog: Codable, Sendable, Equatable {
    /// The format this build writes. Format 2 added `scroll`, `focus`,
    /// `geometry`, global points on pointer events and `unknown`.
    public static let currentFormatVersion = 2
    /// The oldest format this build still reads. Every readable format is a
    /// subset of the current one, so a decoded log always carries
    /// `currentFormatVersion` and writes back in it.
    public static let oldestReadableFormatVersion = 1

    /// Always `currentFormatVersion`: the format this value encodes as.
    public let formatVersion: Int
    /// Ties the log to the media files recorded with it.
    public var recordingID: UUID
    /// Host clock reading (`CMClockGetHostTimeClock`, in seconds) at event time
    /// zero. Media timestamps come from the same clock, so this is the offset
    /// that aligns the two.
    public var startHostTimeSeconds: Double
    /// The captured area in display-local points. Event positions are
    /// normalized within it.
    public var captureRectPoints: PointRect
    /// `CGDirectDisplayID` of the captured display.
    public var displayID: UInt32
    /// Pixels per point of the capture, so point sizes in the log map to
    /// captured pixels.
    public var pointPixelScale: Double
    /// Rate of the pointer poll behind `pointerMoved` events. Informational:
    /// consumers interpolate on timestamps, never on this.
    public var samplingRateHz: Double
    /// Every recorded event, always in ascending time order.
    public private(set) var events: [InputEvent]

    /// Events with a non-finite time are left out.
    public init(
        recordingID: UUID = UUID(),
        startHostTimeSeconds: Double,
        captureRectPoints: PointRect,
        displayID: UInt32,
        pointPixelScale: Double,
        samplingRateHz: Double,
        events: [InputEvent] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.recordingID = recordingID
        self.startHostTimeSeconds = startHostTimeSeconds
        self.captureRectPoints = captureRectPoints
        self.displayID = displayID
        self.pointPixelScale = pointPixelScale
        self.samplingRateHz = samplingRateHz
        self.events = Self.sortedByTime(events.filter { $0.time.isFinite })
    }

    /// Adds an event at its place in time order. Events with equal times keep
    /// arrival order, so a click and the move that carried it stay in the
    /// sequence the recorder observed. Returns false, adding nothing, for an
    /// event whose time is not finite.
    @discardableResult
    public mutating func append(_ event: InputEvent) -> Bool {
        guard event.time.isFinite else { return false }
        // The recorder almost always appends in order; only the tap and the
        // poll racing each other produce a late event.
        if let last = events.last, last.time <= event.time {
            events.append(event)
        } else {
            events.insert(event, at: insertionIndex(for: event.time))
        }
        return true
    }

    /// Adds every event in `newEvents`, each at its place in time order and
    /// those with equal times in the order given; events with a non-finite
    /// time are left out. A batch that is not already in order is merged with
    /// one sort rather than one insertion per event, so a late batch of
    /// thousands costs milliseconds, not seconds.
    public mutating func append(contentsOf newEvents: some Sequence<InputEvent>) {
        let additions = newEvents.filter { $0.time.isFinite }
        guard !additions.isEmpty else { return }
        var inOrder = events.last.map { $0.time <= additions[0].time } ?? true
        if inOrder {
            for index in additions.indices.dropFirst() where additions[index - 1].time > additions[index].time {
                inOrder = false
                break
            }
        }
        if inOrder {
            events.append(contentsOf: additions)
        } else {
            events = Self.sortedByTime(events + additions)
        }
    }

    /// Drops every event, keeping the metadata; the recorder writes this as
    /// the header of its incremental sidecar.
    public mutating func removeAllEvents() {
        events.removeAll()
    }

    /// First index whose time is greater than `time`, so insertion lands after
    /// any event with the same time.
    private func insertionIndex(for time: Double) -> Int {
        var low = events.startIndex
        var high = events.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if events[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Reorders by time while keeping equal times in their original order.
    /// `sort` makes no stability promise, so the index is the tie-breaker.
    private static func sortedByTime(_ events: [InputEvent]) -> [InputEvent] {
        var isSorted = true
        for index in events.indices.dropFirst() where events[index - 1].time > events[index].time {
            isSorted = false
            break
        }
        if isSorted { return events }
        return events.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case recordingID
        case startHostTimeSeconds
        case captureRectPoints
        case displayID
        case pointPixelScale
        case samplingRateHz
        case events
    }

    // Decoding is hand-written (encoding stays synthesized) so an unknown
    // version is refused before its fields are misread, so a non-finite time
    // is refused rather than silently misplaced, and so a log edited or merged
    // by another tool comes back sorted.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (Self.oldestReadableFormatVersion...Self.currentFormatVersion).contains(version) else {
            throw EventLogError.unsupportedFormatVersion(version)
        }
        // An older file is a valid current one with fewer kinds, so it is
        // upgraded on the way in and written back in the current format.
        formatVersion = Self.currentFormatVersion
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        startHostTimeSeconds = try container.decode(Double.self, forKey: .startHostTimeSeconds)
        captureRectPoints = try container.decode(PointRect.self, forKey: .captureRectPoints)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        pointPixelScale = try container.decode(Double.self, forKey: .pointPixelScale)
        samplingRateHz = try container.decode(Double.self, forKey: .samplingRateHz)
        let decoded = try container.decode([InputEvent].self, forKey: .events)
        if let invalid = decoded.first(where: { !$0.time.isFinite }) {
            throw EventLogError.invalidTime(invalid.time)
        }
        events = Self.sortedByTime(decoded)
    }
}

// MARK: - JSON files

extension EventLog {
    /// Builds a log from its JSON encoding.
    public init(jsonData data: Data) throws {
        self = try JSONDecoder().decode(EventLog.self, from: data)
    }

    /// The log as JSON. Keys are sorted so two writes of the same log are
    /// byte-identical and diff cleanly in git; `prettyPrinted` is for people
    /// reading the file, not for storage.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        return try encoder.encode(self)
    }

    /// Reads a log written by `write(to:)`.
    public static func read(from url: URL) throws -> EventLog {
        try EventLog(jsonData: Data(contentsOf: url))
    }

    /// Writes the log as JSON, atomically: the recorder writes the log at the
    /// end of a take and its header at the start, and a crash mid-write must
    /// leave the previous complete file rather than a truncated one.
    public func write(to url: URL, prettyPrinted: Bool = false) throws {
        try jsonData(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }
}
