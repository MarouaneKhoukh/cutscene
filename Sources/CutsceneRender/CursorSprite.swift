import CoreGraphics
import CutsceneCore

/// A cursor image with its click point, drawn by the compositor at the
/// smoothed cursor position.
///
/// A class rather than a struct so the compositor can cache the GPU texture by
/// identity: a recording reuses a handful of shapes across thousands of frames,
/// and the cache entry keeps the sprite alive, so an identifier is never reused
/// for a different image while it is cached.
public final class CursorSprite: Sendable {
    public let image: CGImage
    /// The click point as fractions of the image, top-left origin.
    public let hotspot: NormalizedPoint
    /// The size the cursor is drawn at in display points before any scaling.
    /// The image may be larger; it is scaled down, so it stays crisp when the
    /// camera or `RenderStyle.cursorScale` enlarges it.
    public let sizePoints: PointSize

    public init(image: CGImage, hotspot: NormalizedPoint, sizePoints: PointSize) {
        self.image = image
        self.hotspot = hotspot
        self.sizePoints = sizePoints
    }

    /// The macOS arrow pointer drawn procedurally, for recordings without a
    /// captured cursor shape and for tests. 17×23 points with the tip at
    /// (0.30, 0.23), the geometry the system reports for its own arrow.
    public static let arrow: CursorSprite = makeArrow()

    /// Pixels per point of the procedural arrow's bitmap; 8× keeps the edges
    /// clean when a 2× zoom and a 2× cursor scale compound, and the
    /// compositor's mip chain keeps them clean when the card shrinks it.
    private static let arrowOversampling = 8.0
    private static let arrowSizePoints = PointSize(width: 17, height: 23)
    private static let arrowHotspot = NormalizedPoint(x: 0.30, y: 0.23)

    private static func makeArrow() -> CursorSprite {
        let scale = arrowOversampling
        let width = Int(arrowSizePoints.width * scale)
        let height = Int(arrowSizePoints.height * scale)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            // Only an out-of-memory condition gets here; there is no cursor to fall back to.
            preconditionFailure("CoreGraphics could not allocate a \(width)×\(height) bitmap for the arrow cursor.")
        }
        // Top-left origin in points, so the outline below reads like the
        // hotspot and the sprite table do.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let tip = CGPoint(x: arrowHotspot.x * arrowSizePoints.width, y: arrowHotspot.y * arrowSizePoints.height)
        // Clockwise from the tip: the 45° right edge, the barb, the tail's two
        // long edges (parallel, 2.5 points apart), the left barb and the
        // vertical left edge.
        let outline: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 9.8, y: 9.8), CGPoint(x: 5.8, y: 9.8), CGPoint(x: 8.2, y: 15.4),
            CGPoint(x: 6.0, y: 16.4), CGPoint(x: 3.6, y: 11.0), CGPoint(x: 0, y: 14.0),
        ].map { CGPoint(x: tip.x + $0.x, y: tip.y + $0.y) }
        context.addLines(between: outline)
        context.closePath()
        // The white rim is a stroke centred on the edge under the black fill,
        // so exactly half its width, one point, shows outside the body.
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.strokePath()
        context.addLines(between: outline)
        context.closePath()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath()

        guard let image = context.makeImage() else {
            preconditionFailure("CoreGraphics could not read back the arrow cursor bitmap.")
        }
        return CursorSprite(image: image, hotspot: arrowHotspot, sizePoints: arrowSizePoints)
    }
}
