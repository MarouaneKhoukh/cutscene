import CutsceneCore
import Foundation

/// The output frame's size in pixels, what a layout is solved for. The frame
/// rate lives with the render module's `CanvasSpec`; the engine needs only
/// the shape.
public struct CanvasSize: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Width over height; the layout's one aspect decision keys off it.
    public var aspectRatio: Double {
        height > 0 ? width / height : 0
    }

    /// The 16:9 reference canvas, which `RenderPlan.frameState(at:)` lays out for.
    public static let hd1080 = CanvasSize(width: 1920, height: 1080)
    public static let uhd2160 = CanvasSize(width: 3840, height: 2160)
    /// The 9:16 preset (PLAN M2-08 `vertical1080`).
    public static let vertical1080 = CanvasSize(width: 1080, height: 1920)
    /// The 1:1 preset (`square1080`).
    public static let square1080 = CanvasSize(width: 1080, height: 1080)
}

/// A rectangle in canvas pixels, origin at the top-left.
public struct PixelRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// Whether the two share any area; touching edges do not count.
    public func intersects(_ other: PixelRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    /// Whether `other` lies inside, edges included.
    public func contains(_ other: PixelRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

/// The outline the camera bubble is clipped to; the kit's `BubbleShape`.
public enum BubbleOutline: Sendable, Hashable, CaseIterable {
    case circle
    /// Corners at the card's radius.
    case roundedRectangle
}

/// Which canvas corner the bubble takes when it overlays the card, and
/// whether it goes above or below the card when stacked; the kit's
/// `BubblePosition`.
public enum BubbleCorner: Sendable, Hashable, CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing

    public var isTop: Bool {
        self == .topLeading || self == .topTrailing
    }

    public var isLeading: Bool {
        self == .bottomLeading || self == .topLeading
    }
}

/// The camera bubble's constants (ARCHITECTURE §3 `camera`), present in a
/// `LayoutSettings` only when the recording has a camera track.
public struct BubbleSettings: Sendable, Hashable {
    public var outline: BubbleOutline = .circle
    /// Diameter (or height) as a fraction of the canvas height.
    public var size: Double = 0.20
    /// Distance from the canvas edges as a fraction of the canvas height,
    /// when the bubble overlays the card.
    public var inset: Double = 0.03
    public var corner: BubbleCorner = .bottomTrailing
    /// Output pixels at `LayoutSettings.referenceHeight`; 0 draws no border.
    public var borderWidth: Double = 0

    public init() {}
}

/// Every constant of the frame layout: the card's padding and radius as the
/// kit's `frame` group quotes them, the bubble, and the two numbers that
/// decide how the bubble and the card share a canvas.
public struct LayoutSettings: Sendable, Hashable {
    /// Space around the card as a fraction of the shorter canvas side, per
    /// side; the same rule as `RenderStyle.padding`.
    public var padding: Double = 0.06
    /// Corner radius in output pixels at `referenceHeight`.
    public var cornerRadius: Double = 18
    /// The canvas height the pixel values are quoted at (`FrameStyle.referenceHeight`).
    public var referenceHeight: Double = 1080
    /// The bubble to place; nil lays out the card alone.
    public var bubble: BubbleSettings?
    /// A canvas at least this wide for its height (width / height) has room
    /// beside the content for a bubble over the card's corner, so the bubble
    /// overlays; a narrower one (1:1, 9:16) stacks it above or below the
    /// card instead. 4:3 is the first aspect that still overlays.
    public var minimumOverlayAspect: Double = 4.0 / 3.0
    /// Space between the card and a stacked bubble, as a fraction of the
    /// canvas height.
    public var stackGap: Double = 0.03
    /// The most of the shorter side one side's padding may take, so the card
    /// keeps a positive size however a kit is edited; `Compositor` clamps the same.
    public var maximumPadding: Double = 0.49
    /// The content aspect a plan assumes when its log's capture rect is empty
    /// (a hand-built log): the common display shape.
    public var fallbackContentAspectRatio: Double = 16.0 / 9.0

    public init() {}
}

/// How the bubble shares the canvas with the card.
public enum BubbleArrangement: Sendable, Hashable {
    /// In a corner of the canvas, over the card (16:9).
    case overlay
    /// Above the card, the two centred as one stack (9:16 and 1:1 with a top corner).
    case aboveCard
    /// Below the card, likewise.
    case belowCard
}

/// Where and how the camera bubble is drawn.
public struct BubblePlacement: Sendable, Hashable {
    /// The bubble's bounds in canvas pixels; a circle is inscribed.
    public var rect: PixelRect
    public var outline: BubbleOutline
    /// The radius of a rounded-rectangle outline, in canvas pixels: the card's.
    public var cornerRadius: Double
    /// In canvas pixels; 0 draws no border.
    public var borderWidth: Double
    public var arrangement: BubbleArrangement

    public init(
        rect: PixelRect, outline: BubbleOutline, cornerRadius: Double, borderWidth: Double,
        arrangement: BubbleArrangement
    ) {
        self.rect = rect
        self.outline = outline
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.arrangement = arrangement
    }
}

/// The geometry of one output frame in canvas pixels: the card the content is
/// drawn in and, when there is a camera, the bubble.
public struct FrameLayout: Sendable, Hashable {
    public var canvas: CanvasSize
    /// The content card: the visible content aspect-fitted inside the padding.
    public var card: PixelRect
    /// The card's corner radius in canvas pixels.
    public var cornerRadius: Double
    /// What the kit's reference-height pixel values were multiplied by:
    /// the canvas's shorter side over `referenceHeight`, the rule
    /// `RenderStyle(kit:canvas:)` uses.
    public var pixelScale: Double
    public var bubble: BubblePlacement?

    public init(canvas: CanvasSize, card: PixelRect, cornerRadius: Double, pixelScale: Double, bubble: BubblePlacement?)
    {
        self.canvas = canvas
        self.card = card
        self.cornerRadius = cornerRadius
        self.pixelScale = pixelScale
        self.bubble = bubble
    }
}

/// Lays the card and the bubble out on a canvas. Pure arithmetic, solved per
/// frame because the content's aspect changes with the crop and the viewport.
///
/// The card rule is `Compositor`'s (M1): padding on every side, the visible
/// content aspect-fitted inside and centred. With a bubble on a wide canvas
/// the bubble sits in a corner of the canvas over the card, as on 16:9; on a
/// narrow canvas the card gives up a band for it and the two are centred as
/// one stack, so the bubble never covers the content.
public enum LayoutSolver {
    /// The layout for `canvas` showing content whose visible slice is
    /// `contentAspectRatio` wide for its height (the source's aspect times the
    /// crop's). A canvas side or aspect that is not a finite positive number
    /// solves as a 1-pixel card at the origin rather than NaN geometry.
    public static func solve(
        canvas: CanvasSize, contentAspectRatio: Double, settings: LayoutSettings = LayoutSettings()
    )
        -> FrameLayout
    {
        let width = finitePositive(canvas.width) ?? 1
        let height = finitePositive(canvas.height) ?? 1
        let aspect = finitePositive(contentAspectRatio) ?? 1
        // The shorter side, the side the padding is a fraction of: a 9:16 or
        // 1:1 canvas is as wide as the 16:9 one is tall and gets its card
        // at that size, so the kit's pixel values keep the 16:9 size too
        // (`RenderStyle.pixelScale(forCanvasWidth:height:referenceHeight:)`).
        let pixelScale = finitePositive(settings.referenceHeight).map { min(width, height) / $0 } ?? 1
        let cornerRadius = max(settings.cornerRadius, 0) * pixelScale

        let padding = min(max(settings.padding, 0), settings.maximumPadding) * min(width, height)
        let availableWidth = max(width - 2 * padding, 1)
        let availableHeight = max(height - 2 * padding, 1)

        guard let bubble = settings.bubble else {
            let card = fitted(aspect, inWidth: availableWidth, height: availableHeight, atX: padding, y: padding)
            return FrameLayout(
                canvas: canvas, card: card, cornerRadius: cornerRadius, pixelScale: pixelScale, bubble: nil)
        }

        let diameter = (finitePositive(bubble.size) ?? 0) * height
        let borderWidth = max(bubble.borderWidth, 0) * pixelScale
        func placement(_ rect: PixelRect, _ arrangement: BubbleArrangement) -> BubblePlacement {
            BubblePlacement(
                rect: rect, outline: bubble.outline, cornerRadius: cornerRadius, borderWidth: borderWidth,
                arrangement: arrangement)
        }

        if width / height >= settings.minimumOverlayAspect {
            let card = fitted(aspect, inWidth: availableWidth, height: availableHeight, atX: padding, y: padding)
            let inset = max(bubble.inset, 0) * height
            let rect = PixelRect(
                x: bubble.corner.isLeading ? inset : width - inset - diameter,
                y: bubble.corner.isTop ? inset : height - inset - diameter, width: diameter, height: diameter)
            return FrameLayout(
                canvas: canvas, card: card, cornerRadius: cornerRadius, pixelScale: pixelScale,
                bubble: placement(rect, .overlay))
        }

        // Stacked: the card is fitted into what the band leaves, then the
        // card, the gap and the bubble are centred together in the available
        // height, so neither hugs the padding while the other floats.
        let gap = max(settings.stackGap, 0) * height
        var card = fitted(
            aspect, inWidth: availableWidth, height: max(availableHeight - diameter - gap, 1), atX: padding, y: 0)
        let stackTop = padding + (availableHeight - (card.height + gap + diameter)) / 2
        let bubbleX = card.x + (card.width - diameter) / 2
        let bubbleRect: PixelRect
        if bubble.corner.isTop {
            bubbleRect = PixelRect(x: bubbleX, y: stackTop, width: diameter, height: diameter)
            card.y = stackTop + diameter + gap
        } else {
            card.y = stackTop
            bubbleRect = PixelRect(x: bubbleX, y: stackTop + card.height + gap, width: diameter, height: diameter)
        }
        return FrameLayout(
            canvas: canvas, card: card, cornerRadius: cornerRadius, pixelScale: pixelScale,
            bubble: placement(bubbleRect, bubble.corner.isTop ? .aboveCard : .belowCard))
    }

    /// The largest rectangle of `aspect` inside `width` × `height`, centred in it.
    private static func fitted(_ aspect: Double, inWidth width: Double, height: Double, atX x: Double, y: Double)
        -> PixelRect
    {
        let scale = min(width / aspect, height)
        let cardWidth = scale * aspect
        let cardHeight = scale
        return PixelRect(
            x: x + (width - cardWidth) / 2, y: y + (height - cardHeight) / 2, width: cardWidth, height: cardHeight)
    }

    private static func finitePositive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
}

// MARK: - Kit adapters

extension BubbleOutline {
    public init(style: BubbleShape) {
        switch style {
        case .circle: self = .circle
        case .roundedRectangle: self = .roundedRectangle
        }
    }
}

extension BubbleCorner {
    public init(style: BubblePosition) {
        switch style {
        case .bottomLeading: self = .bottomLeading
        case .bottomTrailing: self = .bottomTrailing
        case .topLeading: self = .topLeading
        case .topTrailing: self = .topTrailing
        }
    }
}

extension BubbleSettings {
    /// The bubble's constants from a kit's camera group. Mirroring and the
    /// border color are the renderer's.
    public init(style: CameraBubbleStyle) {
        self.init()
        outline = BubbleOutline(style: style.shape)
        size = style.size
        inset = style.inset
        corner = BubbleCorner(style: style.position)
        borderWidth = style.borderWidth
    }
}

extension LayoutSettings {
    /// The layout constants from `kit.frame` and, when the recording has a
    /// camera (`hasCamera`), `kit.camera`. The engine's own layout rules
    /// (`minimumOverlayAspect`, `stackGap`, `maximumPadding`) keep their defaults.
    public init(kit: BrandKit, hasCamera: Bool) {
        self.init()
        padding = kit.frame.padding
        cornerRadius = kit.frame.cornerRadius
        referenceHeight = kit.frame.referenceHeight
        bubble = hasCamera ? BubbleSettings(style: kit.camera) : nil
    }
}
