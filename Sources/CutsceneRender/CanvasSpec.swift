import CoreGraphics
import CoreMedia

/// The output frame of a composition: its size in pixels and its rate, the
/// numbers the composition builder, the export presets and the preview all
/// agree on.
///
/// Sizes are kept even because the hardware encoders and 4:2:0 chroma need
/// them so; an odd value is rounded down. The rate is a whole number of
/// frames per second so `frameDuration` is exact.
public struct CanvasSpec: Sendable, Hashable {
    /// The smallest side the compositor will render.
    public static let minimumSide = 2
    /// The slowest rate a composition can run at.
    public static let minimumFrameRate = 1

    public let width: Int
    public let height: Int
    public let frameRate: Int

    public init(width: Int, height: Int, frameRate: Int) {
        self.width = Self.even(width)
        self.height = Self.even(height)
        self.frameRate = max(frameRate, Self.minimumFrameRate)
    }

    /// The M1 export default: 1080p at 60 fps (ARCHITECTURE §6).
    public static let hd1080p60 = CanvasSpec(width: 1920, height: 1080, frameRate: 60)
    public static let hd1080p30 = CanvasSpec(width: 1920, height: 1080, frameRate: 30)
    public static let uhd2160p60 = CanvasSpec(width: 3840, height: 2160, frameRate: 60)
    public static let uhd2160p30 = CanvasSpec(width: 3840, height: 2160, frameRate: 30)

    /// What `AVVideoComposition.renderSize` takes.
    public var renderSize: CGSize { CGSize(width: width, height: height) }

    /// One frame as `AVVideoComposition.frameDuration` takes it: `1 / frameRate`, exact.
    public var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(frameRate)) }

    public var pixelCount: Int { width * height }

    public var aspectRatio: Double { Double(width) / Double(height) }

    /// How many frames a constant-rate composition of `seconds` produces:
    /// one at every multiple of the frame duration below the end, which is
    /// the ceiling of the product.
    public func frameCount(forDuration seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * Double(frameRate)).rounded(.up))
    }

    /// The same aspect ratio and rate at no more than `maximumPixels`, for a
    /// preview that caps its render area; the canvas itself when it already fits.
    public func fitting(maximumPixels: Int) -> CanvasSpec {
        guard maximumPixels > 0, pixelCount > maximumPixels else { return self }
        let factor = (Double(maximumPixels) / Double(pixelCount)).squareRoot()
        return CanvasSpec(
            width: Int((Double(width) * factor).rounded(.down)), height: Int((Double(height) * factor).rounded(.down)),
            frameRate: frameRate)
    }

    private static func even(_ side: Int) -> Int {
        max(side - side % 2, minimumSide)
    }
}
