import CoreMedia
import Foundation
import ScreenCaptureKit

/// The object ScreenCaptureKit talks to on behalf of a `CaptureSession`
/// (ARCHITECTURE §1 "Swift 6 strict concurrency").
///
/// `SCStream` wants an `NSObject` for its outputs and its delegate, and an
/// actor is not one, so this shim stands in. Every sample is handed to the
/// stream with the session's own `DispatchSerialQueue` as the sample-handler
/// queue, which is also the actor's executor, so `assumeIsolated` lets the
/// session take the `CMSampleBuffer` without a hop and without the buffer
/// crossing an isolation boundary: it is consumed before this method returns.
/// The stream's stop notification arrives on a queue of ScreenCaptureKit's
/// choosing, so that one hops through a task.
///
/// The session is held weakly: the session owns the take, the take owns the
/// stream, and the stream owns this shim, so a strong reference back would
/// keep a session abandoned without `stop` alive, capturing, for the life
/// of the process. The reference is set once and only read, which is what
/// makes the class safe to share with the stream's queues.
final class StreamOutputShim: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// One sample on its way into the session. `CMSampleBuffer` carries no
    /// Sendable annotation, and the region checker treats a callback's
    /// parameter as one the caller may still be using, so even a synchronous
    /// call into the isolated session is refused. The box says what is true
    /// instead: the buffer is consumed on the delivery queue before the
    /// callback returns, and the only thing the session keeps from it is a
    /// retained `CVPixelBuffer`, whose reference count is thread-safe.
    struct DeliveredSample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let type: SCStreamOutputType
    }

    private weak var session: CaptureSession?

    init(session: CaptureSession) {
        self.session = session
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let session else { return }
        let sample = DeliveredSample(buffer: sampleBuffer, type: type)
        session.assumeIsolated { session in
            session.handleSample(sample)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard let session else { return }
        Task {
            await session.streamDidStop(with: error)
        }
    }
}
