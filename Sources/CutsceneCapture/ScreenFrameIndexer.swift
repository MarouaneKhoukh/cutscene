import CoreGraphics
import CoreMedia
import CutsceneCore
import Foundation
import ScreenCaptureKit
import Synchronization

/// What ScreenCaptureKit attached to one screen sample (`SCStreamFrameInfo`,
/// ARCHITECTURE §2), read into a value the session can keep after the sample
/// buffer has gone back to the stream.
public struct ScreenFrameInfo: Sendable, Equatable {
    public var status: FrameStatus
    /// The `SCFrameStatus` number behind `status`; nil when the sample
    /// carried no status attachment at all.
    public var rawStatus: Int?
    /// When the window server displayed the frame, on the host clock
    /// (`SCStreamFrameInfo.displayTime` is mach absolute time, converted with
    /// `CMClockMakeHostTimeFromSystemUnits`). One or two frames before the
    /// sample's presentation time, and what a click lines up with.
    public var displayHostTime: CMTime?
    /// `SCStreamFrameInfo.contentRect`, in points, surface coordinates.
    public var contentRect: PointRect?
    public var contentScale: Double?
    public var scaleFactor: Double?
    /// `SCStreamFrameInfo.screenRect` (13.1).
    public var screenRect: PointRect?
    /// `SCStreamFrameInfo.boundingRect` (14.0).
    public var boundingRect: PointRect?
    /// How many dirty rects the sample listed; nil without the attachment.
    public var dirtyRectCount: Int?
    /// Whether the sample carries an image buffer at all.
    public var hasImage: Bool

    /// Whether the sample brings new pixels. `started` counts: it is the
    /// first frame after the stream starts and carries the screen as it is,
    /// so a take of a static screen would otherwise show nothing until the
    /// first change.
    public var carriesContent: Bool {
        hasImage && (status == .complete || status == .started)
    }

    public init(
        status: FrameStatus, rawStatus: Int? = nil, displayHostTime: CMTime? = nil, contentRect: PointRect? = nil,
        contentScale: Double? = nil, scaleFactor: Double? = nil, screenRect: PointRect? = nil,
        boundingRect: PointRect? = nil, dirtyRectCount: Int? = nil, hasImage: Bool
    ) {
        self.status = status
        self.rawStatus = rawStatus
        self.displayHostTime = displayHostTime
        self.contentRect = contentRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
        self.screenRect = screenRect
        self.boundingRect = boundingRect
        self.dirtyRectCount = dirtyRectCount
        self.hasImage = hasImage
    }

    /// Reads the attachments of a `.screen` sample. A sample without a status
    /// attachment is recorded as `unknown`, never guessed to be content.
    public init(sampleBuffer: CMSampleBuffer) {
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first ?? [:]
        let raw = info[.status] as? Int
        self.init(
            status: raw.map { FrameStatus(screenCaptureKitStatus: $0) } ?? FrameStatus(rawValue: "unknown"),
            rawStatus: raw,
            displayHostTime: (info[.displayTime] as? UInt64).map { CMClockMakeHostTimeFromSystemUnits($0) },
            contentRect: Self.rect(info[.contentRect]),
            contentScale: info[.contentScale] as? Double,
            scaleFactor: info[.scaleFactor] as? Double,
            screenRect: Self.rect(info[.screenRect]),
            boundingRect: Self.rect(info[.boundingRect]),
            dirtyRectCount: (info[.dirtyRects] as? NSArray)?.count,
            hasImage: CMSampleBufferGetImageBuffer(sampleBuffer) != nil)
    }

    /// The rect attachments arrive as `CGRect` dictionary representations.
    private static func rect(_ value: Any?) -> PointRect? {
        guard let dictionary = value as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dictionary) else {
            return nil
        }
        return PointRect(rect)
    }
}

extension FrameStatus {
    /// The index's name for an `SCFrameStatus` value. A status this build has
    /// no name for keeps its number, so the index never refuses a frame a
    /// later macOS adds a status for.
    public init(screenCaptureKitStatus raw: Int) {
        switch SCFrameStatus(rawValue: raw) {
        case .complete: self = .complete
        case .idle: self = .idle
        case .blank: self = .blank
        case .suspended: self = .suspended
        case .started: self = .started
        case .stopped: self = .stopped
        case nil: self = FrameStatus(rawValue: "unknown\(raw)")
        @unknown default: self = FrameStatus(rawValue: "unknown\(raw)")
        }
    }
}

extension PointRect {
    /// A Quartz rect as the index and the manifest spell it.
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

/// Counters for the status pill and the end-of-take report.
public struct ScreenFrameIndexerStatistics: Sendable, Equatable {
    /// Screen samples seen, whatever their status or time.
    public var samples = 0
    /// Samples that carried new pixels on the recording timeline
    /// (`complete` and `started`).
    public var contentFrames = 0
    public var idleFrames = 0
    public var blankFrames = 0
    public var suspendedFrames = 0
    public var startedFrames = 0
    public var stoppedFrames = 0
    /// Samples with a status this build has no name for.
    public var otherFrames = 0
    /// Samples the clock placed outside the recording (before the origin,
    /// inside a pause, after the stop); not indexed.
    public var outsideRecording = 0
    /// Heartbeat frames recorded.
    public var holds = 0
    /// Samples the writer could not take.
    public var gaps = 0
    public var writeFailures = 0
    public var lastWriteError: String?
    /// Recording time of the first and the latest content frame.
    public var firstContentTime: Double?
    public var lastContentTime: Double?
    /// Indexed samples that carried each geometry attachment at all. On a
    /// display stream every sample carries `contentRect`; `boundingRect` is
    /// what a window stream attaches (ARCHITECTURE §2), so a window take
    /// with none here has nothing for the engine's crop to follow.
    public var samplesWithContentRect = 0
    public var samplesWithScreenRect = 0
    public var samplesWithBoundingRect = 0
    /// Times each attachment arrived with a value other than the last one
    /// seen, the first value included: how often the window moved, resized
    /// or grew a child window (menu, popover), as the index records it.
    public var contentRectChanges = 0
    public var screenRectChanges = 0
    public var boundingRectChanges = 0
    /// The attachments as last seen; nil until a sample carried them.
    public var lastContentRect: PointRect?
    public var lastScreenRect: PointRect?
    public var lastBoundingRect: PointRect?
    public var lastContentScale: Double?
    public var lastScaleFactor: Double?
}

/// The session's front to `frames.jsonl` (ARCHITECTURE §2 "Outputs and frame
/// index"): one line per screen sample on the recording timeline, the
/// geometry attachments when they change, and the `hold` and `gap` lines the
/// heartbeat and the writer produce.
///
/// Lock-guarded rather than an actor, like the writer and the encoder, so the
/// session can call it from its sample queue and the encoder's output path can
/// add a gap from VideoToolbox's thread without a hop. Write failures are
/// counted, not thrown: a broken index must not end a take whose movie and
/// telemetry are fine.
public final class ScreenFrameIndexer: @unchecked Sendable {
    public let url: URL
    /// The timeline the index is on; shared with the encoder and the writer.
    public let clock: RecordingClock

    private struct State {
        var statistics = ScreenFrameIndexerStatistics()
        /// Ordinal of the next sample in the stream. Every sample advances
        /// it, indexed or not, so a frame number is the stream's own count
        /// and a hole in the numbers marks a pause.
        var nextNumber = 0
    }

    private let writer: FrameIndexWriter
    private let state = Mutex(State())

    /// Creates the file with its header line, so the index exists from the
    /// first moment of the take.
    public init(
        url: URL, recordingID: UUID, clock: RecordingClock,
        settings: FrameIndexWriterSettings = FrameIndexWriterSettings()
    ) throws {
        self.url = url
        self.clock = clock
        writer = try FrameIndexWriter(url: url, header: FrameIndexHeader(recordingID: recordingID), settings: settings)
    }

    public var statistics: ScreenFrameIndexerStatistics {
        state.withLock { $0.statistics }
    }

    /// Lines written so far, the header included.
    public var linesWritten: Int {
        writer.linesWritten
    }

    /// Indexes one screen sample stamped `presentationHostTime` on the host
    /// clock. Returns its recording time, or nil when the clock places it
    /// outside the recording, in which case nothing is written: the index is
    /// on the recording timeline, and a sample with no place on it has no
    /// frame in the movie either.
    @discardableResult
    public func record(_ info: ScreenFrameInfo, presentationHostTime: CMTime) -> Double? {
        let time = clock.recordingTime(forHostTime: presentationHostTime)?.seconds
        let displayTime = info.displayHostTime.flatMap { clock.recordingTime(forHostTime: $0)?.seconds }
        state.withLock { state in
            state.statistics.samples += 1
            let number = state.nextNumber
            state.nextNumber += 1
            Self.count(info.status, in: &state.statistics)
            guard let time else {
                state.statistics.outsideRecording += 1
                return
            }
            if info.carriesContent {
                state.statistics.contentFrames += 1
                state.statistics.firstContentTime = state.statistics.firstContentTime ?? time
                state.statistics.lastContentTime = time
            }
            Self.noteGeometry(of: info, in: &state.statistics)
            let entry = FrameIndexEntry(
                number: number, time: time, displayTime: displayTime, status: info.status,
                contentRect: info.contentRect, contentScale: info.contentScale, scaleFactor: info.scaleFactor,
                screenRect: info.screenRect, boundingRect: info.boundingRect)
            write({ try writer.append(entry) }, state: &state)
        }
        return time
    }

    /// Records that the heartbeat encoded the last complete frame at `time`.
    public func recordHold(at time: Double) {
        state.withLock { state in
            state.statistics.holds += 1
            write({ try writer.appendHold(at: time) }, state: &state)
        }
    }

    /// Records that the frame stamped `time` never reached the movie.
    public func recordGap(at time: Double) {
        state.withLock { state in
            state.statistics.gaps += 1
            write({ try writer.appendGap(at: time) }, state: &state)
        }
    }

    /// Writes every pending line and closes the file.
    public func close() {
        state.withLock { state in
            write({ try writer.close() }, state: &state)
        }
    }

    private func write(_ operation: () throws -> Void, state: inout State) {
        do {
            try operation()
        } catch {
            state.statistics.writeFailures += 1
            state.statistics.lastWriteError = error.localizedDescription
        }
    }

    /// Counts the geometry attachments the way the writer stores them: a
    /// value counts as a change when it differs from the last one seen, so
    /// the counters say how often `frames.jsonl` carries each key.
    private static func noteGeometry(of info: ScreenFrameInfo, in statistics: inout ScreenFrameIndexerStatistics) {
        if let rect = info.contentRect {
            statistics.samplesWithContentRect += 1
            if rect != statistics.lastContentRect {
                statistics.contentRectChanges += 1
                statistics.lastContentRect = rect
            }
        }
        if let rect = info.screenRect {
            statistics.samplesWithScreenRect += 1
            if rect != statistics.lastScreenRect {
                statistics.screenRectChanges += 1
                statistics.lastScreenRect = rect
            }
        }
        if let rect = info.boundingRect {
            statistics.samplesWithBoundingRect += 1
            if rect != statistics.lastBoundingRect {
                statistics.boundingRectChanges += 1
                statistics.lastBoundingRect = rect
            }
        }
        if let scale = info.contentScale { statistics.lastContentScale = scale }
        if let factor = info.scaleFactor { statistics.lastScaleFactor = factor }
    }

    private static func count(_ status: FrameStatus, in statistics: inout ScreenFrameIndexerStatistics) {
        switch status {
        case .complete: break
        case .idle: statistics.idleFrames += 1
        case .blank: statistics.blankFrames += 1
        case .suspended: statistics.suspendedFrames += 1
        case .started: statistics.startedFrames += 1
        case .stopped: statistics.stoppedFrames += 1
        default: statistics.otherFrames += 1
        }
    }
}
