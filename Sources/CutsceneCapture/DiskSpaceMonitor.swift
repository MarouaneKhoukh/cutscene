import Foundation
import Synchronization

/// The numbers the disk guard of a take runs on (ARCHITECTURE §2 `disk.*`).
public struct DiskSpaceMonitorSettings: Sendable, Equatable {
    /// Seconds between readings of the volume. Two seconds is the writer's
    /// fragment interval on internal storage: a reading per fragment is as
    /// often as the file can change the picture, and a stat call at that
    /// rate costs nothing beside the encoder.
    public var pollInterval: TimeInterval = 2
    /// Recording time left at the current write rate under which the take
    /// is warned (`disk.warningRemaining`): ten minutes is enough to finish
    /// a thought and stop by hand rather than be stopped.
    public var warningRemainingSeconds: TimeInterval = 600
    /// Free bytes under which the take stops itself (`disk.autoStop`). The
    /// writer fails hard on a full volume and loses everything after its
    /// last fragment; 300 MB keeps the last fragment, the frame index, the
    /// telemetry sidecar and the manifest rewrite clear of that edge.
    public var autoStopBytes: Int64 = 300_000_000
    /// How many times the take's own size is kept free on top of
    /// `autoStopBytes`: the finish path rewrites each fragmented movie as a
    /// faststart MP4 beside it, so for a moment the take occupies twice its
    /// size, and a stop that waits for the last 300 MB would leave a movie
    /// nothing can finalize until space is freed by hand. One copy.
    public var finalizeReserveFactor: Double = 1
    /// Seconds of readings the write rate is averaged over. Long enough that
    /// a 2 s fragment flush or a burst of screen changes does not swing the
    /// estimate, short enough to follow a change of content within a minute.
    public var rateWindowSeconds: TimeInterval = 30
    /// Span the readings in the window must cover before the measured rate
    /// replaces the nominal one: a rate over a few hundred milliseconds is
    /// noise.
    public var minimumRateSpanSeconds: TimeInterval = 1
    /// Readings in a row under the warning line before the warning is
    /// raised, so one poll that caught another process writing does not
    /// flash it.
    public var warningConfirmations: Int = 2
    /// The warning clears only once the remaining time is this many times
    /// the warning line: a take hovering on the line would otherwise toggle
    /// the pill every reading.
    public var warningClearFactor: Double = 1.5
    /// Leeway of the poll timer, a fraction of `pollInterval`.
    public var timerLeewayFraction: Double = 0.1

    public init() {}
}

/// One reading of the destination volume against the take on it.
public struct DiskSpaceReading: Sendable, Equatable {
    /// What the reading asks of the take.
    public enum Level: String, Sendable, Codable, CaseIterable {
        case ok
        /// Less than `warningRemainingSeconds` of recording left; the take
        /// goes on and the pill says so.
        case low
        /// The free space is down to the floor; the take must stop now.
        case full
    }

    public var level: Level
    /// Free bytes for important usage on the volume; nil when the volume
    /// did not say, in which case `level` is carried over from the last
    /// reading that had a number.
    public var freeBytes: Int64?
    /// The take's own files, in allocated bytes.
    public var bytesWritten: Int64
    /// Bytes per second the estimate runs on: the measured rate once the
    /// window spans enough, the nominal one before.
    public var writeBytesPerSecond: Double
    /// Whether `writeBytesPerSecond` was measured rather than taken from the
    /// nominal rate.
    public var rateIsMeasured: Bool
    /// Seconds of recording left before the floor at the current rate; nil
    /// when the rate is zero (a still screen) or the free space is unknown.
    public var remainingSeconds: TimeInterval?
    /// Free bytes the take must keep: `autoStopBytes` plus the finalize
    /// reserve for what it has written so far.
    public var floorBytes: Int64
    /// Readings taken so far, this one included.
    public var readings: Int
    /// Readings whose free space could not be read.
    public var unreadableReadings: Int

    public init(
        level: Level, freeBytes: Int64?, bytesWritten: Int64, writeBytesPerSecond: Double, rateIsMeasured: Bool,
        remainingSeconds: TimeInterval?, floorBytes: Int64, readings: Int, unreadableReadings: Int
    ) {
        self.level = level
        self.freeBytes = freeBytes
        self.bytesWritten = bytesWritten
        self.writeBytesPerSecond = writeBytesPerSecond
        self.rateIsMeasured = rateIsMeasured
        self.remainingSeconds = remainingSeconds
        self.floorBytes = floorBytes
        self.readings = readings
        self.unreadableReadings = unreadableReadings
    }
}

/// Watches the volume a take is written to and says when the take should
/// warn and when it should stop (ARCHITECTURE §2 "Dropped frames and
/// pacing": preflight 2 GB, warn under 10 min remaining, auto-stop under
/// 300 MB; the preflight is the session's).
///
/// Every `pollInterval` the monitor reads the volume's free space and the
/// take's own size and turns them into a `DiskSpaceReading`. The write rate
/// is the larger of two measurements over the last `rateWindowSeconds`: how
/// fast the take's files grow and how fast the volume's free space shrinks.
/// The first is the take itself; the second also counts whoever else is
/// writing to the volume, which is just as much a reason to run out. Until
/// the window spans `minimumRateSpanSeconds` the nominal rate the caller
/// hands in (the encoders' configured bit rates) stands in, so the first
/// reading already carries an estimate.
///
/// The floor is `autoStopBytes` plus `finalizeReserveFactor` times what the
/// take has written: the finish path needs room for the MP4 beside the
/// fragmented movie, and a take that is stopped only when the last 300 MB
/// are left cannot be finished. The remaining time solves for the moment
/// the free space meets the growing floor.
///
/// Lock-guarded rather than an actor, like the writer and the indexer: the
/// timer fires on the queue the caller names (the session's own, so the
/// handler enters the actor without a hop), and `record(freeBytes:
/// bytesWritten:at:)` is pure so the estimate can be driven without a
/// volume.
public final class DiskSpaceMonitor: @unchecked Sendable {
    /// The take's directory; the volume is the one holding it.
    public let url: URL
    public let settings: DiskSpaceMonitorSettings
    /// Bytes per second assumed until the rate is measured.
    public let nominalBytesPerSecond: Double

    private struct Sample {
        var time: TimeInterval
        var freeBytes: Int64?
        var bytesWritten: Int64
    }

    private struct State {
        var samples: [Sample] = []
        var reading: DiskSpaceReading?
        var timer: (any DispatchSourceTimer)?
        /// Readings in a row under the warning line.
        var lowReadings = 0
        var readings = 0
        var unreadableReadings = 0
    }

    private let state = Mutex(State())

    public init(
        url: URL, settings: DiskSpaceMonitorSettings = DiskSpaceMonitorSettings(), nominalBytesPerSecond: Double
    ) {
        self.url = url
        self.settings = settings
        self.nominalBytesPerSecond = max(0, nominalBytesPerSecond)
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    /// The latest reading; nil before the first poll.
    public var reading: DiskSpaceReading? {
        state.withLock { $0.reading }
    }

    /// Starts polling on `queue`, the first reading right away, and hands
    /// every reading to `handler` on that queue. Starting twice replaces the
    /// timer.
    public func start(queue: DispatchQueue, handler: @escaping @Sendable (DiskSpaceReading) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            handler(self.poll())
        }
        let leeway = DispatchTimeInterval.milliseconds(
            Int(settings.pollInterval * settings.timerLeewayFraction * 1000))
        timer.schedule(deadline: .now(), repeating: settings.pollInterval, leeway: leeway)
        state.withLock { state in
            state.timer?.cancel()
            state.timer = timer
        }
        timer.activate()
    }

    /// Stops polling; the last reading stays readable.
    public func stop() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
        }
    }

    /// Reads the volume and the take now and returns the reading, outside
    /// the timer.
    @discardableResult
    public func poll() -> DiskSpaceReading {
        record(
            freeBytes: Self.freeBytes(at: url), bytesWritten: Self.allocatedBytes(under: url),
            at: ProcessInfo.processInfo.systemUptime)
    }

    /// Folds one observation into the estimate and returns the reading it
    /// yields. `time` is any monotonic clock in seconds; the readings must
    /// come in time order.
    @discardableResult
    public func record(freeBytes: Int64?, bytesWritten: Int64, at time: TimeInterval) -> DiskSpaceReading {
        state.withLock { state in
            state.readings += 1
            if freeBytes == nil { state.unreadableReadings += 1 }
            state.samples.append(Sample(time: time, freeBytes: freeBytes, bytesWritten: bytesWritten))
            state.samples.removeAll { time - $0.time > settings.rateWindowSeconds }

            let (rate, measured) = Self.rate(over: state.samples, settings: settings, nominal: nominalBytesPerSecond)
            let floor =
                settings.autoStopBytes + Int64((Double(bytesWritten) * settings.finalizeReserveFactor).rounded())
            var remaining: TimeInterval?
            if let freeBytes, rate > 0 {
                // The floor rises with every byte written: free − rate·r
                // meets autoStop + reserve·(written + rate·r) at r.
                let headroom = Double(freeBytes - floor)
                remaining = max(0, headroom / (rate * (1 + settings.finalizeReserveFactor)))
            }

            let previous = state.reading?.level ?? .ok
            var level = previous
            if let freeBytes {
                let underLine = remaining.map { $0 < settings.warningRemainingSeconds } ?? false
                if freeBytes <= floor || previous == .full {
                    // Once asked for, the stop stands: space that comes back
                    // while the take finishes changes nothing.
                    level = .full
                } else if underLine {
                    state.lowReadings += 1
                    level = previous == .low || state.lowReadings >= settings.warningConfirmations ? .low : .ok
                } else {
                    state.lowReadings = 0
                    // A warning clears only well above the line, and never on
                    // an unbounded estimate: a still screen writes nothing,
                    // and the next change on it brings the rate back.
                    let clears = remaining.map { $0 >= settings.warningRemainingSeconds * settings.warningClearFactor }
                    level = previous == .low && clears != true ? .low : .ok
                }
            }
            let reading = DiskSpaceReading(
                level: level, freeBytes: freeBytes, bytesWritten: bytesWritten, writeBytesPerSecond: rate,
                rateIsMeasured: measured, remainingSeconds: remaining, floorBytes: floor, readings: state.readings,
                unreadableReadings: state.unreadableReadings)
            state.reading = reading
            return reading
        }
    }

    /// The write rate over the window: the larger of the take's growth and
    /// the volume's loss, or the nominal rate while the window is short.
    private static func rate(over samples: [Sample], settings: DiskSpaceMonitorSettings, nominal: Double) -> (
        Double, Bool
    ) {
        guard let first = samples.first, let last = samples.last,
            last.time - first.time >= settings.minimumRateSpanSeconds
        else { return (nominal, false) }
        let span = last.time - first.time
        let own = Double(last.bytesWritten - first.bytesWritten) / span
        var volume = 0.0
        if let firstFree = first.freeBytes, let lastFree = last.freeBytes {
            volume = Double(firstFree - lastFree) / span
        }
        return (max(0, own, volume), true)
    }

    // MARK: Volume and take

    /// Free bytes for important usage on the volume holding `url`
    /// (`volumeAvailableCapacityForImportantUsageKey`, 10.13), the plain
    /// capacity when the volume does not report that, and nil when it
    /// reports neither. When `url` does not exist yet the nearest existing
    /// ancestor's volume answers.
    public static func freeBytes(at url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        guard
            let values = try? candidate.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            ])
        else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    /// Allocated bytes of every file under `url` (the take's package); zero
    /// when it does not exist. Allocated rather than logical size, since
    /// that is what the volume loses.
    public static func allocatedBytes(under url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
