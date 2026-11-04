import Foundation

// MARK: - Primitives

/// An sRGB color as a brand kit spells it: `#RRGGBB`, or `#RRGGBBAA` when
/// not opaque, 8 bits per channel, the form design tools export. The render
/// module converts it to its own unit-float color.
public struct KitColor: Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// 255 is opaque.
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a packed 24-bit value such as `0x1C2B4B`.
    public init(rgb: UInt32, alpha: UInt8 = 255) {
        self.init(
            red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF), alpha: alpha)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`, either case, with or without the
    /// `#`; nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8, let packed = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(rgb: packed >> 8, alpha: UInt8(packed & 0xFF))
        } else {
            self.init(rgb: packed)
        }
    }

    /// The color packed as `0xRRGGBB`.
    public var rgb: UInt32 {
        UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    /// `#RRGGBB`, with `AA` appended only when the color is not opaque.
    public var hex: String {
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? base : base + String(format: "%02X", alpha)
    }

    public static let white = KitColor(rgb: 0xFF_FF_FF)
    public static let black = KitColor(rgb: 0x00_00_00)
}

extension KitColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = KitColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(text)\" is not a #RRGGBB or #RRGGBBAA color.")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A spring's constants, mirroring the engine's `SpringParameters`
/// (`m·x″ + c·x′ + k·x = 0` with `k = tension`, `m = mass`, `c = friction`)
/// and its presets with the same values.
public struct SpringStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var tension: Double
    public var mass: Double
    public var friction: Double
    public var extra: [String: JSONValue]

    public init(tension: Double, mass: Double, friction: Double, extra: [String: JSONValue] = [:]) {
        self.tension = tension
        self.mass = mass
        self.friction = friction
        self.extra = extra
    }

    /// Ordinary pointer motion: heavy and well damped.
    public static let mellow = SpringStyle(tension: 470, mass: 3.0, friction: 70)
    public static let slow = SpringStyle(tension: 200, mass: 2.25, friction: 40)
    public static let smooth = SpringStyle(tension: 80, mass: 2.5, friction: 28)
    public static let fast = SpringStyle(tension: 380, mass: 1.0, friction: 30)
    /// The last stretch before a click, so the cursor lands on the click point.
    public static let snappy = SpringStyle(tension: 530, mass: 1.0, friction: 40)
    /// While a button is held, so drags track the pointer closely.
    public static let drag = SpringStyle(tension: 1000, mass: 1.0, friction: 40)
    /// The auto-zoom camera channels.
    public static let camera = SpringStyle(tension: 200, mass: 2.25, friction: 40)
}

// MARK: - Background and frame

/// Which background slot is drawn.
public enum BackgroundKind: String, Codable, Sendable, CaseIterable {
    case solid
    case linearGradient
    /// Reserved: `BackgroundStyle.image` has no renderer yet.
    case image
}

/// A two-stop linear gradient. `angleDegrees` follows the CSS convention: 0
/// runs from the bottom (`from`) to the top (`to`), 90 from left to right.
public struct GradientStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var from: KitColor
    public var to: KitColor
    public var angleDegrees: Double
    public var extra: [String: JSONValue]

    public init(from: KitColor, to: KitColor, angleDegrees: Double, extra: [String: JSONValue] = [:]) {
        self.from = from
        self.to = to
        self.angleDegrees = angleDegrees
        self.extra = extra
    }
}

/// What fills the canvas behind the card. Every slot keeps its value while
/// another is selected, so switching kinds in the inspector and back loses
/// nothing. The defaults are `RenderStyle`'s.
public struct BackgroundStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var kind: BackgroundKind = .linearGradient
    public var solid: KitColor = KitColor(rgb: 0x1C_2B_4B)
    public var gradient = GradientStyle(
        from: KitColor(rgb: 0x1C_2B_4B), to: KitColor(rgb: 0x4A_1F_5E), angleDegrees: 45)
    /// Reserved for an image background; nil until a build defines it.
    public var image: JSONValue?
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

/// The soft shadow under the card, in output pixels at
/// `FrameStyle.referenceHeight`, scaling with the canvas. The falloff lands on
/// the CSS `box-shadow` curve, so design-tool values transfer one to one.
public struct ShadowStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var offsetX: Double = 0
    /// Positive moves the shadow down, as light from above does.
    public var offsetY: Double = 18
    /// The shadow fades over this distance on each side of the offset card edge.
    public var blurRadius: Double = 48
    /// Peak darkness, `0...1`.
    public var opacity: Double = 0.55
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

/// The card the screen is drawn in.
public struct FrameStyle: Sendable, Hashable, PreservesUnknownKeys {
    /// Space around the card as a fraction of the shorter canvas side, per side.
    public var padding: Double = 0.06
    /// Corner radius in output pixels at `referenceHeight`.
    public var cornerRadius: Double = 18
    /// The canvas height the pixel values of the kit are quoted at; a canvas
    /// of another size scales them by its shorter side over
    /// `referenceHeight`, so 1080p and 4K exports look alike and the 9:16
    /// and 1:1 presets, whose card is as wide as the 1080p one is tall,
    /// keep the 1080p values.
    public var referenceHeight: Double = 1080
    public var shadow = ShadowStyle()
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

// MARK: - Cursor

/// The curve a click ripple grows along.
public enum RippleEasing: String, Codable, Sendable, CaseIterable {
    case linear
    case easeOutCubic
    case easeInOutCubic
    case smoothstep
    case smootherstep
}

/// The ring that spreads from a click. Radii and stroke widths are output
/// pixels at `FrameStyle.referenceHeight`.
public struct ClickRippleStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var enabled: Bool = true
    public var startRadius: Double = 0
    public var endRadius: Double = 44
    /// Seconds from the click to the ripple's end.
    public var duration: Double = 0.5
    public var easing: RippleEasing = .easeOutCubic
    public var startStrokeWidth: Double = 2.5
    public var endStrokeWidth: Double = 0
    public var startOpacity: Double = 0.65
    public var endOpacity: Double = 0
    public var color: KitColor = .white
    /// Ripples alive at once; older ones end early past this.
    public var maximumConcurrent: Int = 4
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

/// The drawn cursor: the engine's `CursorSmootherSettings` mirrored field
/// for field with the same defaults (seconds and fractions of the frame),
/// plus how it is rendered and what a click draws.
public struct CursorStyle: Sendable, Hashable, PreservesUnknownKeys {
    /// Output rate of the cursor timeline.
    public var sampleRate: Double = 60
    /// The spring for ordinary pointer motion.
    public var spring: SpringStyle = .mellow
    /// The spring used from `clickSpringLead` before a click until it happens.
    public var clickSpring: SpringStyle = .snappy
    /// The spring used while a button is held.
    public var dragSpring: SpringStyle = .drag
    /// A direction reversal whose two legs are both shorter than this, within
    /// `shakeWindow`, is accessibility-tool shake and is dropped.
    public var shakeLegThreshold: Double = 0.015
    public var shakeWindow: Double = 0.100
    /// Raw pointer samples are thinned to at most this many per second.
    public var maximumInputRate: Double = 60
    /// Samples that travel less than this from the last kept one are thinned too.
    public var minimumTravel: Double = 1.0 / 1920
    /// The target is read this far ahead to cancel the spring's lag.
    public var leadTimeConstant: Double = 0.130
    /// When the next click is at most this far away, the target becomes the click point.
    public var clickAnticipationWindow: Double = 0.500
    /// `clickSpring` takes over this long before the click.
    public var clickSpringLead: Double = 0.175
    /// Gaps between raw samples longer than this are idle: the position holds.
    public var idleHoldGap: Double = 0.067
    /// After this long without input the spring is forced onto its target.
    public var settleTimeout: Double = 5
    /// Time ranges where smoothing is off and the raw motion passes through.
    public var disabledRanges: [TimeRange] = []
    /// Idle time before the cursor starts to fade.
    public var idleFadeDelay: Double = 2
    public var fadeOutDuration: Double = 0.400
    /// The cursor fades back in this long before input resumes.
    public var fadeInLead: Double = 0.250
    /// Scale reached while a button is held.
    public var pressScale: Double = 0.8
    /// Time to reach `pressScale` after a press and to return after release.
    public var pressScaleDuration: Double = 0.130
    /// Multiplier on the cursor's natural on-screen size (`RenderStyle.cursorScale`);
    /// 1 draws it as the user saw it. The inspector offers `scaleRange`.
    public var scale: Double = 1
    public var click = ClickRippleStyle()
    public var extra: [String: JSONValue] = [:]

    /// The scales the inspector offers.
    public static let scaleRange: ClosedRange<Double> = 1...3

    public init() {}
}

// MARK: - Zoom

/// The auto-zoom camera's motion: the engine's `CameraPlannerSettings`
/// mirrored field for field with the same defaults.
public struct CameraMotionStyle: Sendable, Hashable, PreservesUnknownKeys {
    /// Output rate of the camera timeline.
    public var sampleRate: Double = 120
    /// How often the spring targets are recomputed from the segments and the cursor.
    public var retargetInterval: Double = 0.008
    /// Constants shared by the center, amount and activity channels.
    public var spring: SpringStyle = .camera
    /// The dead zone's size as fractions of the zoomed viewport: the camera
    /// stays put while the cursor moves inside a box this large.
    public var deadZoneWidth: Double = 0.5
    public var deadZoneHeight: Double = 0.7
    /// While the amount is at most this, the center may jump unseen.
    public var preAimThreshold: Double = 1.0005
    /// Where the camera rests before the first segment.
    public var fallbackFocus = NormalizedPoint(x: 0.5, y: 0.5)
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

/// Automatic zoom: the engine's `ZoomPlannerSettings` mirrored field for
/// field with the same defaults, and the camera that carries it out.
public struct ZoomStyle: Sendable, Hashable, PreservesUnknownKeys {
    /// How long before a click its zoom begins.
    public var leadIn: Double = 0.3
    /// How long after a click (or the last key of a burst) its zoom holds.
    public var holdAfter: Double = 2.5
    /// Zooms separated by at most this much merge into one.
    public var mergeGap: Double = 2.5
    /// Events in the last stretch of the recording are ignored: the stop click.
    public var trailingIgnore: Double = 1.0
    /// Magnification of every generated segment, at least 1.
    public var amount: Double = 2.0
    /// Typing bursts become zoom anchors at the pointer's last position.
    public var detectsTypingBursts: Bool = true
    /// A burst is at least this many non-modifier key-downs …
    public var typingBurstMinimumKeys: Int = 3
    /// … each less than this long after the previous one.
    public var typingBurstMaximumGap: Double = 0.5
    /// Where a typing burst aims when the pointer has not been seen yet.
    public var fallbackFocus = NormalizedPoint(x: 0.5, y: 0.5)
    public var camera = CameraMotionStyle()
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

// MARK: - Camera bubble

/// The outline the camera picture is clipped to.
public enum BubbleShape: String, Codable, Sendable, CaseIterable {
    case circle
    /// Corners at the frame's radius.
    case roundedRectangle
}

/// Where the bubble sits on a 16:9 canvas; the layout solver moves it above
/// or below the card on 9:16 and 1:1.
public enum BubblePosition: String, Codable, Sendable, CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing
}

/// The camera bubble over the card.
public struct CameraBubbleStyle: Sendable, Hashable, PreservesUnknownKeys {
    public var shape: BubbleShape = .circle
    /// Diameter (or height) as a fraction of the canvas height.
    public var size: Double = 0.20
    /// Distance from the canvas edges as a fraction of the canvas height.
    public var inset: Double = 0.03
    public var position: BubblePosition = .bottomTrailing
    /// Built-in cameras face the user, so their picture is flipped to read
    /// like a mirror.
    public var mirrorsBuiltInCameras: Bool = true
    /// Output pixels at `FrameStyle.referenceHeight`; 0 draws no border.
    public var borderWidth: Double = 0
    public var borderColor: KitColor = .white
    /// Whether the bubble casts the frame's shadow.
    public var usesFrameShadow: Bool = true
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

// MARK: - Kit

/// A brand kit (schema 1): every look-and-feel knob of a project, grouped as
/// ARCHITECTURE §3 lists them. A kit file (`<name>.cutscenekit.json`) and a
/// project's `kit` snapshot and edited `style` all carry one.
///
/// The defaults are the implemented ones: `RenderStyle`'s for the background
/// and frame, the engine settings structs' for cursor and zoom, so one set of
/// defaults exists (M1-05 pins the adapters). A sparse kit takes the defaults
/// for whatever it leaves out, fields this build does not know ride in
/// `extra`, and a newer schema is refused rather than misread.
public struct BrandKit: Sendable, Hashable, PreservesUnknownKeys {
    /// The schema this build writes.
    public static let currentSchemaVersion = 1

    /// Always `currentSchemaVersion`: the schema this value encodes as.
    public let schemaVersion: Int
    public var background = BackgroundStyle()
    public var frame = FrameStyle()
    public var cursor = CursorStyle()
    public var zoom = ZoomStyle()
    public var camera = CameraBubbleStyle()
    /// Reserved groups; nil until a build defines them.
    public var typography: JSONValue?
    public var captions: JSONValue?
    public var callout: JSONValue?
    public var intro: JSONValue?
    public var outro: JSONValue?
    public var extra: [String: JSONValue] = [:]

    public init() {
        schemaVersion = Self.currentSchemaVersion
    }

    /// The built-in look.
    public static let `default` = BrandKit()
}

// MARK: - Codable

extension SpringStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tension
        case mass
        case friction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tension = try container.decode(Double.self, forKey: .tension)
        mass = try container.decode(Double.self, forKey: .mass)
        friction = try container.decode(Double.self, forKey: .friction)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tension, forKey: .tension)
        try container.encode(mass, forKey: .mass)
        try container.encode(friction, forKey: .friction)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension GradientStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case from
        case to
        case angleDegrees
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(KitColor.self, forKey: .from)
        to = try container.decode(KitColor.self, forKey: .to)
        angleDegrees = try container.decode(Double.self, forKey: .angleDegrees)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(angleDegrees, forKey: .angleDegrees)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension BackgroundStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case solid
        case gradient
        case image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        kind = try container.decode(.kind, or: defaults.kind)
        solid = try container.decode(.solid, or: defaults.solid)
        gradient = try container.decode(.gradient, or: defaults.gradient)
        image = try container.decodeIfPresent(JSONValue.self, forKey: .image)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(solid, forKey: .solid)
        try container.encode(gradient, forKey: .gradient)
        try container.encodeIfPresent(image, forKey: .image)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ShadowStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case offsetX
        case offsetY
        case blurRadius
        case opacity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        offsetX = try container.decode(.offsetX, or: defaults.offsetX)
        offsetY = try container.decode(.offsetY, or: defaults.offsetY)
        blurRadius = try container.decode(.blurRadius, or: defaults.blurRadius)
        opacity = try container.decode(.opacity, or: defaults.opacity)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
        try container.encode(blurRadius, forKey: .blurRadius)
        try container.encode(opacity, forKey: .opacity)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension FrameStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case padding
        case cornerRadius
        case referenceHeight
        case shadow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        padding = try container.decode(.padding, or: defaults.padding)
        cornerRadius = try container.decode(.cornerRadius, or: defaults.cornerRadius)
        referenceHeight = try container.decode(.referenceHeight, or: defaults.referenceHeight)
        shadow = try container.decode(.shadow, or: defaults.shadow)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(referenceHeight, forKey: .referenceHeight)
        try container.encode(shadow, forKey: .shadow)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ClickRippleStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case startRadius
        case endRadius
        case duration
        case easing
        case startStrokeWidth
        case endStrokeWidth
        case startOpacity
        case endOpacity
        case color
        case maximumConcurrent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = try container.decode(.enabled, or: defaults.enabled)
        startRadius = try container.decode(.startRadius, or: defaults.startRadius)
        endRadius = try container.decode(.endRadius, or: defaults.endRadius)
        duration = try container.decode(.duration, or: defaults.duration)
        easing = try container.decode(.easing, or: defaults.easing)
        startStrokeWidth = try container.decode(.startStrokeWidth, or: defaults.startStrokeWidth)
        endStrokeWidth = try container.decode(.endStrokeWidth, or: defaults.endStrokeWidth)
        startOpacity = try container.decode(.startOpacity, or: defaults.startOpacity)
        endOpacity = try container.decode(.endOpacity, or: defaults.endOpacity)
        color = try container.decode(.color, or: defaults.color)
        maximumConcurrent = try container.decode(.maximumConcurrent, or: defaults.maximumConcurrent)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(startRadius, forKey: .startRadius)
        try container.encode(endRadius, forKey: .endRadius)
        try container.encode(duration, forKey: .duration)
        try container.encode(easing, forKey: .easing)
        try container.encode(startStrokeWidth, forKey: .startStrokeWidth)
        try container.encode(endStrokeWidth, forKey: .endStrokeWidth)
        try container.encode(startOpacity, forKey: .startOpacity)
        try container.encode(endOpacity, forKey: .endOpacity)
        try container.encode(color, forKey: .color)
        try container.encode(maximumConcurrent, forKey: .maximumConcurrent)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension CursorStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleRate
        case spring
        case clickSpring
        case dragSpring
        case shakeLegThreshold
        case shakeWindow
        case maximumInputRate
        case minimumTravel
        case leadTimeConstant
        case clickAnticipationWindow
        case clickSpringLead
        case idleHoldGap
        case settleTimeout
        case disabledRanges
        case idleFadeDelay
        case fadeOutDuration
        case fadeInLead
        case pressScale
        case pressScaleDuration
        case scale
        case click
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        sampleRate = try container.decode(.sampleRate, or: defaults.sampleRate)
        spring = try container.decode(.spring, or: defaults.spring)
        clickSpring = try container.decode(.clickSpring, or: defaults.clickSpring)
        dragSpring = try container.decode(.dragSpring, or: defaults.dragSpring)
        shakeLegThreshold = try container.decode(.shakeLegThreshold, or: defaults.shakeLegThreshold)
        shakeWindow = try container.decode(.shakeWindow, or: defaults.shakeWindow)
        maximumInputRate = try container.decode(.maximumInputRate, or: defaults.maximumInputRate)
        minimumTravel = try container.decode(.minimumTravel, or: defaults.minimumTravel)
        leadTimeConstant = try container.decode(.leadTimeConstant, or: defaults.leadTimeConstant)
        clickAnticipationWindow = try container.decode(.clickAnticipationWindow, or: defaults.clickAnticipationWindow)
        clickSpringLead = try container.decode(.clickSpringLead, or: defaults.clickSpringLead)
        idleHoldGap = try container.decode(.idleHoldGap, or: defaults.idleHoldGap)
        settleTimeout = try container.decode(.settleTimeout, or: defaults.settleTimeout)
        disabledRanges = try container.decode(.disabledRanges, or: defaults.disabledRanges)
        idleFadeDelay = try container.decode(.idleFadeDelay, or: defaults.idleFadeDelay)
        fadeOutDuration = try container.decode(.fadeOutDuration, or: defaults.fadeOutDuration)
        fadeInLead = try container.decode(.fadeInLead, or: defaults.fadeInLead)
        pressScale = try container.decode(.pressScale, or: defaults.pressScale)
        pressScaleDuration = try container.decode(.pressScaleDuration, or: defaults.pressScaleDuration)
        scale = try container.decode(.scale, or: defaults.scale)
        click = try container.decode(.click, or: defaults.click)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(spring, forKey: .spring)
        try container.encode(clickSpring, forKey: .clickSpring)
        try container.encode(dragSpring, forKey: .dragSpring)
        try container.encode(shakeLegThreshold, forKey: .shakeLegThreshold)
        try container.encode(shakeWindow, forKey: .shakeWindow)
        try container.encode(maximumInputRate, forKey: .maximumInputRate)
        try container.encode(minimumTravel, forKey: .minimumTravel)
        try container.encode(leadTimeConstant, forKey: .leadTimeConstant)
        try container.encode(clickAnticipationWindow, forKey: .clickAnticipationWindow)
        try container.encode(clickSpringLead, forKey: .clickSpringLead)
        try container.encode(idleHoldGap, forKey: .idleHoldGap)
        try container.encode(settleTimeout, forKey: .settleTimeout)
        try container.encode(disabledRanges, forKey: .disabledRanges)
        try container.encode(idleFadeDelay, forKey: .idleFadeDelay)
        try container.encode(fadeOutDuration, forKey: .fadeOutDuration)
        try container.encode(fadeInLead, forKey: .fadeInLead)
        try container.encode(pressScale, forKey: .pressScale)
        try container.encode(pressScaleDuration, forKey: .pressScaleDuration)
        try container.encode(scale, forKey: .scale)
        try container.encode(click, forKey: .click)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension CameraMotionStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleRate
        case retargetInterval
        case spring
        case deadZoneWidth
        case deadZoneHeight
        case preAimThreshold
        case fallbackFocus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        sampleRate = try container.decode(.sampleRate, or: defaults.sampleRate)
        retargetInterval = try container.decode(.retargetInterval, or: defaults.retargetInterval)
        spring = try container.decode(.spring, or: defaults.spring)
        deadZoneWidth = try container.decode(.deadZoneWidth, or: defaults.deadZoneWidth)
        deadZoneHeight = try container.decode(.deadZoneHeight, or: defaults.deadZoneHeight)
        preAimThreshold = try container.decode(.preAimThreshold, or: defaults.preAimThreshold)
        fallbackFocus = try container.decode(.fallbackFocus, or: defaults.fallbackFocus)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(retargetInterval, forKey: .retargetInterval)
        try container.encode(spring, forKey: .spring)
        try container.encode(deadZoneWidth, forKey: .deadZoneWidth)
        try container.encode(deadZoneHeight, forKey: .deadZoneHeight)
        try container.encode(preAimThreshold, forKey: .preAimThreshold)
        try container.encode(fallbackFocus, forKey: .fallbackFocus)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ZoomStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case leadIn
        case holdAfter
        case mergeGap
        case trailingIgnore
        case amount
        case detectsTypingBursts
        case typingBurstMinimumKeys
        case typingBurstMaximumGap
        case fallbackFocus
        case camera
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        leadIn = try container.decode(.leadIn, or: defaults.leadIn)
        holdAfter = try container.decode(.holdAfter, or: defaults.holdAfter)
        mergeGap = try container.decode(.mergeGap, or: defaults.mergeGap)
        trailingIgnore = try container.decode(.trailingIgnore, or: defaults.trailingIgnore)
        amount = try container.decode(.amount, or: defaults.amount)
        detectsTypingBursts = try container.decode(.detectsTypingBursts, or: defaults.detectsTypingBursts)
        typingBurstMinimumKeys = try container.decode(.typingBurstMinimumKeys, or: defaults.typingBurstMinimumKeys)
        typingBurstMaximumGap = try container.decode(.typingBurstMaximumGap, or: defaults.typingBurstMaximumGap)
        fallbackFocus = try container.decode(.fallbackFocus, or: defaults.fallbackFocus)
        camera = try container.decode(.camera, or: defaults.camera)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leadIn, forKey: .leadIn)
        try container.encode(holdAfter, forKey: .holdAfter)
        try container.encode(mergeGap, forKey: .mergeGap)
        try container.encode(trailingIgnore, forKey: .trailingIgnore)
        try container.encode(amount, forKey: .amount)
        try container.encode(detectsTypingBursts, forKey: .detectsTypingBursts)
        try container.encode(typingBurstMinimumKeys, forKey: .typingBurstMinimumKeys)
        try container.encode(typingBurstMaximumGap, forKey: .typingBurstMaximumGap)
        try container.encode(fallbackFocus, forKey: .fallbackFocus)
        try container.encode(camera, forKey: .camera)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension CameraBubbleStyle: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case shape
        case size
        case inset
        case position
        case mirrorsBuiltInCameras
        case borderWidth
        case borderColor
        case usesFrameShadow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        shape = try container.decode(.shape, or: defaults.shape)
        size = try container.decode(.size, or: defaults.size)
        inset = try container.decode(.inset, or: defaults.inset)
        position = try container.decode(.position, or: defaults.position)
        mirrorsBuiltInCameras = try container.decode(.mirrorsBuiltInCameras, or: defaults.mirrorsBuiltInCameras)
        borderWidth = try container.decode(.borderWidth, or: defaults.borderWidth)
        borderColor = try container.decode(.borderColor, or: defaults.borderColor)
        usesFrameShadow = try container.decode(.usesFrameShadow, or: defaults.usesFrameShadow)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shape, forKey: .shape)
        try container.encode(size, forKey: .size)
        try container.encode(inset, forKey: .inset)
        try container.encode(position, forKey: .position)
        try container.encode(mirrorsBuiltInCameras, forKey: .mirrorsBuiltInCameras)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(borderColor, forKey: .borderColor)
        try container.encode(usesFrameShadow, forKey: .usesFrameShadow)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension BrandKit: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case background
        case frame
        case cursor
        case zoom
        case camera
        case typography
        case captions
        case callout
        case intro
        case outro
    }

    // Hand-written so a newer schema is refused before its fields are
    // misread, a sparse kit takes the defaults, and unknown keys are kept. A
    // kit with no `schemaVersion` is read as schema 1, the only one whose
    // fields an untagged file can have meant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(.schemaVersion, or: 1)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw ProjectFormatError.unsupportedKitSchemaVersion(version)
        }
        schemaVersion = Self.currentSchemaVersion
        let defaults = Self()
        background = try container.decode(.background, or: defaults.background)
        frame = try container.decode(.frame, or: defaults.frame)
        cursor = try container.decode(.cursor, or: defaults.cursor)
        zoom = try container.decode(.zoom, or: defaults.zoom)
        camera = try container.decode(.camera, or: defaults.camera)
        typography = try container.decodeIfPresent(JSONValue.self, forKey: .typography)
        captions = try container.decodeIfPresent(JSONValue.self, forKey: .captions)
        callout = try container.decodeIfPresent(JSONValue.self, forKey: .callout)
        intro = try container.decodeIfPresent(JSONValue.self, forKey: .intro)
        outro = try container.decodeIfPresent(JSONValue.self, forKey: .outro)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(background, forKey: .background)
        try container.encode(frame, forKey: .frame)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(camera, forKey: .camera)
        try container.encodeIfPresent(typography, forKey: .typography)
        try container.encodeIfPresent(captions, forKey: .captions)
        try container.encodeIfPresent(callout, forKey: .callout)
        try container.encodeIfPresent(intro, forKey: .intro)
        try container.encodeIfPresent(outro, forKey: .outro)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

// MARK: - JSON files

extension BrandKit {
    /// Builds a kit from its JSON encoding, a kit file or a project's snapshot.
    public init(jsonData data: Data) throws {
        self = try PackageJSON.decode(BrandKit.self, from: data)
    }

    /// The kit as JSON with sorted keys, so two writes of the same kit are
    /// byte-identical and a kit file diffs cleanly in git.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        try PackageJSON.encode(self, prettyPrinted: prettyPrinted)
    }
}
