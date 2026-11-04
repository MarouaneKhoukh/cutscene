import Foundation

/// Where an export is, in the order the phases run.
public enum ExportPhase: String, Sendable, Hashable, CaseIterable {
    /// Building the composition, naming the file, checking the disk.
    case preparing
    /// Frames and audio flowing from the reader into the writer.
    case encoding
    /// `finishWriting`: the writer closes the file and moves `moov` to the front.
    case finishing
    /// The self-check on the written file and the move into place.
    case verifying
    case done
}

/// A snapshot of an export for a progress bar: written time over duration,
/// frames, elapsed wall time, and the speed and remaining time those imply.
public struct ExportProgress: Sendable, Hashable {
    public var phase: ExportPhase
    /// Seconds of output written so far: the end of the last appended frame.
    public var writtenSeconds: Double
    /// Seconds the export will be long: the composition's duration.
    public var durationSeconds: Double
    public var framesWritten: Int
    /// `durationSeconds × fps`, rounded up.
    public var expectedFrames: Int
    /// Wall seconds since the export started.
    public var elapsedSeconds: Double

    public init(
        phase: ExportPhase, writtenSeconds: Double, durationSeconds: Double, framesWritten: Int, expectedFrames: Int,
        elapsedSeconds: Double
    ) {
        self.phase = phase
        self.writtenSeconds = writtenSeconds
        self.durationSeconds = durationSeconds
        self.framesWritten = framesWritten
        self.expectedFrames = expectedFrames
        self.elapsedSeconds = elapsedSeconds
    }

    /// Written time over duration, `0...1`; 1 once the phase is past encoding.
    public var fraction: Double {
        switch phase {
        case .preparing: return 0
        case .finishing, .verifying, .done: return 1
        case .encoding:
            guard durationSeconds > 0 else { return 0 }
            return min(max(writtenSeconds / durationSeconds, 0), 1)
        }
    }

    /// Multiples of real time the encoding is running at; nil before the
    /// first frame.
    public var speed: Double? {
        guard elapsedSeconds > 0, writtenSeconds > 0 else { return nil }
        return writtenSeconds / elapsedSeconds
    }

    /// Seconds of encoding left at the current speed; nil while unknown.
    public var estimatedRemainingSeconds: Double? {
        guard phase == .encoding, let speed, speed > 0 else { return nil }
        return max(durationSeconds - writtenSeconds, 0) / speed
    }
}
