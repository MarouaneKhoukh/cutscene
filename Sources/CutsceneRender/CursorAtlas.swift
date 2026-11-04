import CoreGraphics
import CutsceneCore
import CutsceneEngine
import Foundation
import ImageIO

/// The cursor sprites of one recording: `recording/cursors/<CursorShape.id>.png`
/// as the recorder wrote them at stop, each paired with the hotspot and point
/// size the event log reported for that shape, and `fallback` (the procedural
/// arrow) for any shape whose file is missing or unreadable.
///
/// Every sprite is made once here and shared by every frame, because the
/// compositor caches GPU textures by sprite identity: a sprite built per
/// request would upload its image and mip chain again every frame.
public struct CursorAtlas: Sendable {
    /// Drawn for a nil shape (nothing recorded yet) and for shapes without a usable file.
    public let fallback: CursorSprite
    /// Ids of the shapes that fell back, in first-seen order; a recording
    /// whose recorder wrote no sprites lists every shape here.
    public let missingShapeIDs: [String]
    private let sprites: [CursorShape: CursorSprite]

    /// Loads one sprite per distinct shape from `cursorsDirectory`. Shapes
    /// that share an id share the decoded image but keep their own hotspot
    /// and size, since those come from the log, not the file.
    public init(shapes: some Sequence<CursorShape>, cursorsDirectory: URL, fallback: CursorSprite = .arrow) {
        var sprites: [CursorShape: CursorSprite] = [:]
        var images: [String: CGImage?] = [:]
        var missing: [String] = []
        for shape in shapes where sprites[shape] == nil {
            let image: CGImage?
            if let loaded = images[shape.id] {
                image = loaded
            } else {
                image = Self.image(at: cursorsDirectory.appendingPathComponent(shape.id).appendingPathExtension("png"))
                images[shape.id] = image
                if image == nil { missing.append(shape.id) }
            }
            guard let image else { continue }
            sprites[shape] = CursorSprite(image: image, hotspot: shape.hotspot, sizePoints: shape.sizePoints)
        }
        self.init(sprites: sprites, fallback: fallback, missingShapeIDs: missing)
    }

    private init(sprites: [CursorShape: CursorSprite], fallback: CursorSprite, missingShapeIDs: [String]) {
        self.sprites = sprites
        self.fallback = fallback
        self.missingShapeIDs = missingShapeIDs
    }

    /// The sprites for every shape change the plan carries, from the package's `cursors/`.
    public static func load(for plan: RenderPlan, in package: RecordingPackage, fallback: CursorSprite = .arrow)
        -> CursorAtlas
    {
        CursorAtlas(
            shapes: plan.cursorShapeChanges.map(\.shape), cursorsDirectory: package.cursorsDirectory, fallback: fallback
        )
    }

    /// An atlas that draws `fallback` for everything, for recordings without
    /// shape telemetry and for tests.
    public static func fallbackOnly(_ fallback: CursorSprite = .arrow) -> CursorAtlas {
        CursorAtlas(sprites: [:], fallback: fallback, missingShapeIDs: [])
    }

    /// Shapes with a sprite of their own, in no particular order.
    public var shapes: [CursorShape] { Array(sprites.keys) }

    public var count: Int { sprites.count }

    /// The sprite for `shape`: its own when the atlas has one, else `fallback`.
    public func sprite(for shape: CursorShape?) -> CursorSprite {
        guard let shape, let sprite = sprites[shape] else { return fallback }
        return sprite
    }

    /// Decodes a PNG without ImageIO's cache, since each file is read once.
    private static func image(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
            image.width > 0, image.height > 0
        else { return nil }
        return image
    }
}
