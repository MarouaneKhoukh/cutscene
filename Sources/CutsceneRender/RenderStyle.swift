import Foundation

/// An sRGB color with straight (not premultiplied) alpha, components in `0...1`.
public struct RenderColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a packed 24-bit value such as `0x1E1E2E`, the form brand kits will carry.
    public init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255, alpha: alpha)
    }

    public static let black = RenderColor(red: 0, green: 0, blue: 0)
    public static let white = RenderColor(red: 1, green: 1, blue: 1)
}

/// What fills the frame behind the screen card.
public enum RenderBackground: Sendable, Hashable {
    case solid(RenderColor)
    /// A two-stop linear gradient. `angleDegrees` follows the CSS convention:
    /// 0 runs from the bottom (`from`) to the top (`to`), 90 from left to
    /// right, and the gradient line is long enough for both colors to reach
    /// the frame's corners, so the look does not depend on the output size.
    case linearGradient(from: RenderColor, to: RenderColor, angleDegrees: Double)
}

/// The soft shadow under the screen card. Distances are in output pixels; see
/// `RenderStyle.scaled(by:)` for keeping 1080p and 4K exports alike.
///
/// The falloff is a smoothstep over `blurRadius` on each side of the offset
/// card edge rather than a Gaussian blur, but it lands on the same curve as
/// a CSS or Figma `box-shadow` (whose blur radius is twice the Gaussian's
/// σ): half darkness at the edge, 16 % at half the radius outside, nothing
/// at the radius. Design-tool values therefore transfer one to one,
/// `offset`, `blur` and `alpha` to `offsetX`/`offsetY`, `blurRadius` and
/// `opacity`.
public struct RenderShadow: Sendable, Hashable {
    /// Horizontal offset of the shadow from the card.
    public var offsetX: Double = 0
    /// Vertical offset; positive moves the shadow down, as light from above does.
    public var offsetY: Double = 18
    /// The shadow fades over this distance on each side of the (offset) card
    /// edge; 0 is a hard edge.
    public var blurRadius: Double = 48
    /// Peak darkness, `0...1`, reached `blurRadius` inside the shadow's edge.
    /// The edge itself is half as dark, and the visible part fades to nothing
    /// `blurRadius` outside it.
    public var opacity: Double = 0.55

    public init(offsetX: Double = 0, offsetY: Double = 18, blurRadius: Double = 48, opacity: Double = 0.55) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.opacity = opacity
    }
}

/// How the camera bubble is drawn, beyond the geometry: the bubble's shape,
/// size, corner and border width are solved per frame by the engine's
/// `LayoutSolver` and arrive as a `BubblePlacement`, so what stays with the
/// renderer is the mirroring rule, the border's colour and whether the
/// bubble casts the frame's shadow (ARCHITECTURE §3 `camera`).
public struct RenderCameraBubble: Sendable, Hashable {
    /// Built-in cameras face the user, so their picture is flipped to read
    /// like a mirror; an external camera pointed at a desk is not.
    public var mirrorsBuiltInCameras: Bool = true
    /// The colour of a border the placement gives a width; its alpha applies.
    public var borderColor: RenderColor = .white
    /// Whether the bubble casts the same shadow as the card (`RenderStyle.shadow`).
    public var usesFrameShadow: Bool = true

    public init(mirrorsBuiltInCameras: Bool = true, borderColor: RenderColor = .white, usesFrameShadow: Bool = true) {
        self.mirrorsBuiltInCameras = mirrorsBuiltInCameras
        self.borderColor = borderColor
        self.usesFrameShadow = usesFrameShadow
    }
}

/// Every knob of the composed frame. The defaults are a neutral Screen Studio
/// look; a brand kit sets the same stored properties later.
public struct RenderStyle: Sendable, Hashable {
    /// Output size in pixels. `Compositor.render(_:style:)` sizes its pool from
    /// this; `render(_:style:to:)` takes the size from the target texture.
    public var outputWidth: Int = 1920
    public var outputHeight: Int = 1080
    /// Behind the card. The alpha of these colors is ignored for now: frames are opaque.
    public var background: RenderBackground = .linearGradient(
        from: RenderColor(rgb: 0x1C_2B_4B), to: RenderColor(rgb: 0x4A_1F_5E), angleDegrees: 45)
    /// Space around the card as a fraction of the shorter output side; 0 fills the frame.
    public var padding: Double = 0.06
    /// Card corner radius in output pixels.
    public var cornerRadius: Double = 18
    public var shadow = RenderShadow()
    /// Multiplier on the cursor's natural on-screen size; 1 draws it as the user saw it.
    public var cursorScale: Double = 1
    /// The click rings' colour; their size, fade and timing are the engine's
    /// `ClickRippleSettings`, and the rings arrive per frame already in
    /// output pixels (ARCHITECTURE §3 `cursor.click`).
    public var rippleColor: RenderColor = .white
    public var camera = RenderCameraBubble()

    public init() {}

    /// The same look at another resolution: every pixel-valued property is
    /// multiplied by `factor` and the fractions stay. A 4K export of a 1080p
    /// style is `scaled(by: 2)` with the output size doubled.
    public func scaled(by factor: Double) -> RenderStyle {
        var copy = self
        copy.cornerRadius *= factor
        copy.shadow.offsetX *= factor
        copy.shadow.offsetY *= factor
        copy.shadow.blurRadius *= factor
        return copy
    }
}
