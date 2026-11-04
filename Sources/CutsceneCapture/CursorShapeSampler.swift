import AppKit
import CoreGraphics
import CutsceneCore
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// One reading of the cursor shown on screen.
///
/// System cursors come with several bitmaps (1×, 2× and the large sizes the
/// pointer-size accessibility setting draws from; an arrow has four, up to
/// 280×400 pixels). The smallest identifies the shape at a cost of a few KiB
/// per hash; the largest is what the renderer wants to draw from, since it
/// scales sprites itself.
public struct SystemCursorSnapshot: Sendable {
    /// The smallest bitmap, hashed into the shape id.
    public var fingerprintBitmap: CGImage
    /// The largest bitmap, kept as the sprite.
    public var spriteBitmap: CGImage
    /// The click point in points, top-left origin, within `sizePoints`.
    public var hotspot: CGPoint
    /// The cursor's natural size in points.
    public var sizePoints: CGSize

    public init(fingerprintBitmap: CGImage, spriteBitmap: CGImage, hotspot: CGPoint, sizePoints: CGSize) {
        self.fingerprintBitmap = fingerprintBitmap
        self.spriteBitmap = spriteBitmap
        self.hotspot = hotspot
        self.sizePoints = sizePoints
    }
}

/// Where the sampler reads the on-screen cursor from.
///
/// `NSCursor.currentSystem` is the only API that reports another app's cursor,
/// and Apple has marked it for deprecation with no named successor (research
/// brief §8 Q7). Everything that touches it lives behind this protocol so the
/// replacement, whatever it turns out to be, is one type in this file.
public protocol SystemCursorSource: Sendable {
    /// The cursor currently on screen, or nil when the system reports none.
    func readCursor() -> SystemCursorSnapshot?
}

/// Reads the cursor through `NSCursor.currentSystem`.
public struct AppKitCursorSource: SystemCursorSource {
    public init() {}

    public func readCursor() -> SystemCursorSnapshot? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        var smallest: CGImage?
        var largest: CGImage?
        for representation in image.representations {
            guard let candidate = Self.bitmap(of: representation) else { continue }
            let pixels = candidate.width * candidate.height
            if pixels < (smallest.map { $0.width * $0.height } ?? .max) { smallest = candidate }
            if pixels > (largest.map { $0.width * $0.height } ?? 0) { largest = candidate }
        }
        if smallest == nil {
            var rect = NSRect(origin: .zero, size: size)
            smallest = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            largest = smallest
        }
        guard let smallest, let largest else { return nil }
        return SystemCursorSnapshot(
            fingerprintBitmap: smallest, spriteBitmap: largest, hotspot: cursor.hotSpot, sizePoints: size)
    }

    private static func bitmap(of representation: NSImageRep) -> CGImage? {
        if let bitmap = representation as? NSBitmapImageRep {
            return bitmap.cgImage
        }
        // A rect in pixels under an identity transform asks the representation
        // for its native resolution (NSImage.h).
        var rect = NSRect(x: 0, y: 0, width: representation.pixelsWide, height: representation.pixelsHigh)
        return representation.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform()])
    }
}

/// Polls the system cursor and reports each change of its image as a
/// `cursorShapeChanged` event, keeping a PNG of every distinct shape so the
/// renderer can draw the cursor the user actually saw.
///
/// Shapes are identified by an FNV-1a hash of the bitmap bytes, the approach
/// Cap uses: no table of known cursors to maintain, and a hash of a few KiB
/// costs microseconds at the 16 ms poll, where a cryptographic digest would
/// cost an order of magnitude more for no benefit, since ids only need to tell
/// cursors apart within one recording's sprite table.
///
/// `sample` is meant for one polling thread and does nothing slower than that
/// hash: PNG encoding of a newly seen shape runs on the sampler's own queue.
/// `sprites()` may be read from any thread and waits for pending encodes.
public final class CursorShapeSampler: @unchecked Sendable {
    private struct State {
        var lastHash: UInt64?
        var sprites: [String: Data] = [:]
    }

    public let source: any SystemCursorSource
    private let state = Mutex(State())
    private let encodeQueue = DispatchQueue(label: "app.cutscene.telemetry.sprites", qos: .utility)

    public init(source: any SystemCursorSource = AppKitCursorSource()) {
        self.source = source
    }

    /// Reads the cursor once. Returns a `cursorShapeChanged` event stamped
    /// `time` when the image differs from the previous read, and on the first
    /// read, so a log always opens with a known shape; nil when unchanged or
    /// when the system reports no cursor.
    public func sample(at time: Double) -> InputEvent? {
        guard let snapshot = source.readCursor(), let hash = Self.fingerprint(snapshot.fingerprintBitmap) else {
            return nil
        }
        let id = String(hash, radix: 16).leftPadded(to: 16)
        // nil: same shape as last time. Otherwise whether the sprite table
        // still lacks this id (a cursor can come back after other shapes).
        let needsSprite: Bool? = state.withLock { state in
            guard state.lastHash != hash else { return nil }
            state.lastHash = hash
            return state.sprites[id] == nil
        }
        guard let needsSprite else { return nil }
        if needsSprite {
            // Reserve the id so a shape that flickers back before the encode
            // finishes is not encoded twice.
            state.withLock { $0.sprites[id] = Data() }
            let bitmap = snapshot.spriteBitmap
            encodeQueue.async { [self] in
                guard let png = Self.png(from: bitmap) else { return }
                state.withLock { $0.sprites[id] = png }
            }
        }
        let shape = CursorShape(
            id: id,
            hotspot: NormalizedPoint(
                x: snapshot.hotspot.x / snapshot.sizePoints.width, y: snapshot.hotspot.y / snapshot.sizePoints.height),
            sizePoints: PointSize(width: snapshot.sizePoints.width, height: snapshot.sizePoints.height))
        return .cursorShapeChanged(time: time, shape: shape)
    }

    /// Every distinct shape seen so far, as PNG data at the sprite bitmap's
    /// pixel size, keyed by the id carried in `cursorShapeChanged` events.
    public func sprites() -> [String: Data] {
        encodeQueue.sync {}
        return state.withLock { $0.sprites.filter { !$0.value.isEmpty } }
    }

    /// 64-bit FNV-1a over the dimensions and the raw pixel bytes. Row padding
    /// is included as-is: it is constant for a given image, and skipping it
    /// would mean walking rows for no gain.
    static func fingerprint(_ image: CGImage) -> UInt64? {
        guard let data = image.dataProvider?.data, let start = CFDataGetBytePtr(data) else { return nil }
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for dimension in [image.width, image.height] {
            withUnsafeBytes(of: UInt32(dimension).littleEndian) { header in
                for byte in header { hash = (hash ^ UInt64(byte)) &* prime }
            }
        }
        for byte in UnsafeRawBufferPointer(start: start, count: CFDataGetLength(data)) {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return hash
    }

    private static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension String {
    fileprivate func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
