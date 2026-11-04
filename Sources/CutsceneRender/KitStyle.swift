import CutsceneCore
import Foundation

// The brand kit's `background` and `frame` groups and `cursor.scale` mirror
// `RenderStyle` (ARCHITECTURE §3); these adapters bring them across for one
// canvas. A kit quotes its pixel values at `FrameStyle.referenceHeight`, so
// the same kit looks alike at 1080p and 4K.

// MARK: - Colors and background

extension RenderColor {
    /// The unit-float form of a kit's 8-bit color; 255 maps to exactly 1.
    public init(_ color: KitColor) {
        self.init(
            red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255,
            alpha: Double(color.alpha) / 255)
    }
}

extension RenderBackground {
    /// The slot `style.kind` selects. `.image` is reserved and has no renderer
    /// yet, so it draws the solid slot: the color an image background sits
    /// on, as CSS draws `background-color` under a `background-image` that
    /// did not load.
    public init(style: BackgroundStyle) {
        switch style.kind {
        case .solid, .image:
            self = .solid(RenderColor(style.solid))
        case .linearGradient:
            self = .linearGradient(
                from: RenderColor(style.gradient.from), to: RenderColor(style.gradient.to),
                angleDegrees: style.gradient.angleDegrees)
        }
    }
}

// MARK: - Shadow

extension RenderShadow {
    /// The kit's shadow with its pixel distances multiplied by `scale`
    /// (`RenderStyle.pixelScale(forCanvasHeight:referenceHeight:)`); the
    /// opacity is a fraction and stays.
    public init(style: ShadowStyle, scale: Double) {
        self.init(
            offsetX: style.offsetX * scale, offsetY: style.offsetY * scale, blurRadius: style.blurRadius * scale,
            opacity: style.opacity)
    }
}

// MARK: - Camera bubble

extension RenderCameraBubble {
    /// The renderer's share of a kit's camera group: mirroring, the border
    /// colour and the shadow choice. The geometry (`shape`, `size`, `inset`,
    /// `position`, `borderWidth`) reaches the renderer through the engine's
    /// `BubbleSettings(style:)` and the per-frame `BubblePlacement`.
    public init(style: CameraBubbleStyle) {
        self.init(
            mirrorsBuiltInCameras: style.mirrorsBuiltInCameras, borderColor: RenderColor(style.borderColor),
            usesFrameShadow: style.usesFrameShadow)
    }
}

// MARK: - Style

extension RenderStyle {
    /// The look of `kit` on `canvas`: its background, padding, corner radius,
    /// shadow, cursor scale, ripple colour and camera bubble, with the pixel
    /// values scaled from the kit's reference height to the canvas's
    /// shorter side (`pixelScale(forCanvasWidth:height:referenceHeight:)`).
    /// The default kit at 1080p is `RenderStyle()`, and at 4K
    /// `RenderStyle().scaled(by: 2)` with the output size doubled; the
    /// canvas's frame rate plays no part.
    public init(kit: BrandKit, canvas: CanvasSpec) {
        self.init()
        outputWidth = canvas.width
        outputHeight = canvas.height
        background = RenderBackground(style: kit.background)
        padding = kit.frame.padding
        let scale = Self.pixelScale(
            forCanvasWidth: canvas.width, height: canvas.height, referenceHeight: kit.frame.referenceHeight)
        cornerRadius = kit.frame.cornerRadius * scale
        shadow = RenderShadow(style: kit.frame.shadow, scale: scale)
        cursorScale = kit.cursor.scale
        rippleColor = RenderColor(kit.cursor.click.color)
        camera = RenderCameraBubble(style: kit.camera)
    }

    /// What a kit's pixel values are multiplied by on a `width` × `height`
    /// canvas: the shorter side over `referenceHeight`, the side the
    /// padding is a fraction of too (`LayoutSolver`), so the 1080×1920 and
    /// 1080×1080 presets, whose card is as wide as the 1080p card is tall,
    /// draw the radius, the shadow and the ripples at the 1080p size rather
    /// than 1.78× it on a card half the size. `LayoutSolver.solve` and
    /// `RenderPlan.frameState(at:canvas:)` apply the same rule. A reference
    /// height that is not a finite positive number cannot scale anything,
    /// so the values are taken as they are.
    public static func pixelScale(forCanvasWidth width: Int, height: Int, referenceHeight: Double) -> Double {
        guard referenceHeight.isFinite, referenceHeight > 0 else { return 1 }
        return Double(min(width, height)) / referenceHeight
    }
}
