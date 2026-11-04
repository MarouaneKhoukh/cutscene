import Foundation

/// A position inside the capture rect, as fractions of its width and height.
///
/// Both coordinates run 0...1 with the origin at the top-left corner (Quartz
/// convention, the opposite of AppKit). Telemetry is stored this way rather
/// than in display points so a trace stays valid when the recording is
/// cropped, scaled or exported at another resolution.
public struct NormalizedPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A point in Quartz global coordinates: display points with the origin at
/// the top-left corner of the main display, the space `CGEvent.location`,
/// `CGDisplayBounds` and `SCDisplay.frame` share.
///
/// Pointer events may carry one beside their normalized position. The
/// normalized position is relative to the capture rect at the moment of the
/// event; the global point lets a consumer re-normalize against the window
/// geometry in the log once the captured area has moved (window mode), which
/// the normalized position alone cannot express.
public struct GlobalPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A size in display points, before the Retina scale is applied.
public struct PointSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in display-local points with a top-left origin, the same
/// space as `SCStreamConfiguration.sourceRect`.
public struct PointRect: Codable, Sendable, Hashable {
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
}

/// The cursor image in effect at some moment of a recording.
///
/// The renderer draws its own cursor from a sprite table keyed by `id`, so
/// the recording never depends on captured pixels. Shapes outside the table
/// carry a hash of the system cursor's image bytes as their id (research
/// brief §5.1), which stays stable across Retina scales.
public struct CursorShape: Sendable, Hashable {
    /// Stable name of the sprite, such as `arrow` or `iBeam`, or a content hash.
    public var id: String
    /// The click point inside the sprite, as fractions of its size, top-left origin.
    public var hotspot: NormalizedPoint
    /// The sprite's natural size in points.
    public var sizePoints: PointSize

    public init(id: String, hotspot: NormalizedPoint, sizePoints: PointSize) {
        self.id = id
        self.hotspot = hotspot
        self.sizePoints = sizePoints
    }
}

/// One timed input observation. The capture module writes these; the engine
/// turns them into cursor paths, zoom segments and click effects.
///
/// `time` is seconds since the recording started, taken from the host clock
/// (`CMClockGetTime(CMClockGetHostTimeClock())`) minus pause offsets, so it
/// lines up with media timestamps from the same clock. Positions are
/// `NormalizedPoint`s within the capture rect; pointer events may also carry
/// a `GlobalPoint`, absent when the recorder did not have one.
///
/// Format 2 of the log added `scroll`, `focus`, `geometry`, the global points
/// and `unknown`. From here on a new kind never bumps the format version: a
/// build that does not know it keeps the row through `unknown` and writes it
/// back unchanged, so recordings move between builds in both directions.
public enum InputEvent: Sendable, Hashable {
    case pointerMoved(time: Double, position: NormalizedPoint, global: GlobalPoint? = nil)
    case buttonDown(time: Double, position: NormalizedPoint, button: Button, global: GlobalPoint? = nil)
    case buttonUp(time: Double, position: NormalizedPoint, button: Button, global: GlobalPoint? = nil)
    case keyDown(time: Double, keyCode: UInt16, modifiers: Modifiers, isRepeat: Bool)
    case keyUp(time: Double, keyCode: UInt16, modifiers: Modifiers)
    case cursorShapeChanged(time: Double, shape: CursorShape)
    /// A take boundary set by the marker hotkey. `label` is free text and usually absent.
    case takeMarker(time: Double, label: String?)
    /// A wheel or trackpad scroll with the pointer at `position`. The deltas
    /// are AppKit's `scrollingDeltaX`/`scrollingDeltaY` as delivered, after
    /// the user's natural-scrolling preference: points on devices with
    /// precise deltas (trackpads), wheel notches otherwise.
    case scroll(
        time: Double, position: NormalizedPoint, deltaX: Double, deltaY: Double, phase: ScrollPhase,
        global: GlobalPoint? = nil)
    /// The frontmost application changed. `windowID` is the `CGWindowID` of
    /// its key window when the recorder knew it; an activation notification
    /// names only the application, so it is often absent.
    case focus(time: Double, bundleID: String, windowID: UInt32?)
    /// The window `windowID` moved or resized: its new frame in display-local
    /// points with a top-left origin, the space of `EventLog.captureRectPoints`.
    case geometry(time: Double, windowID: UInt32, frame: PointRect)
    /// An event of a kind this build does not know, kept so it can be written
    /// back as it was read. `kind` is the row's `type`; `raw` is the whole
    /// row, `type` and `time` included, and encoding re-emits it with `kind`
    /// as its `type`. The row's `time` is read on demand; see `time`.
    case unknown(kind: String, raw: [String: RawJSON])

    /// A mouse button. `other` carries the Quartz button number, where 2 is the middle button.
    public enum Button: Sendable, Hashable {
        case left
        case right
        case other(Int)
    }

    /// Modifier keys held during a key event.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
        public static let capsLock = Modifiers(rawValue: 1 << 5)
    }

    /// Where a scroll event sits in its gesture: AppKit's `phase` and
    /// `momentumPhase` folded into one value, which loses nothing because
    /// an event never carries both.
    public enum ScrollPhase: String, Sendable, Hashable, Codable {
        /// No gesture phase at all: a wheel notch, or any device that reports
        /// none (`phase` and `momentumPhase` both empty).
        case discrete
        /// Fingers touched the trackpad; a scroll may follow. The deltas are zero.
        case mayBegin
        case began
        case changed
        case ended
        case cancelled
        /// Inertial scrolling after the fingers lifted.
        case momentumBegan
        case momentumChanged
        case momentumEnded
    }

    /// Seconds since the recording started. For `unknown` it is the row's
    /// `time` field, or `.nan` when the row has no numeric one, which
    /// `EventLog.append` refuses: such a row has no place in time order.
    public var time: Double {
        switch self {
        case .pointerMoved(let time, _, _), .buttonDown(let time, _, _, _), .buttonUp(let time, _, _, _),
            .keyDown(let time, _, _, _), .keyUp(let time, _, _), .cursorShapeChanged(let time, _),
            .takeMarker(let time, _), .scroll(let time, _, _, _, _, _), .focus(let time, _, _),
            .geometry(let time, _, _):
            time
        case .unknown(_, let raw):
            raw["time"]?.doubleValue ?? .nan
        }
    }

    /// Where the pointer was, for the events that carry a position. Nil for
    /// an unknown kind, whose fields have no agreed meaning here.
    public var position: NormalizedPoint? {
        switch self {
        case .pointerMoved(_, let position, _), .buttonDown(_, let position, _, _), .buttonUp(_, let position, _, _),
            .scroll(_, let position, _, _, _, _):
            position
        case .keyDown, .keyUp, .cursorShapeChanged, .takeMarker, .focus, .geometry, .unknown:
            nil
        }
    }

    /// The pointer's global point, for the pointer events whose recorder
    /// wrote one.
    public var globalPosition: GlobalPoint? {
        switch self {
        case .pointerMoved(_, _, let global), .buttonDown(_, _, _, let global), .buttonUp(_, _, _, let global),
            .scroll(_, _, _, _, _, let global):
            global
        case .keyDown, .keyUp, .cursorShapeChanged, .takeMarker, .focus, .geometry, .unknown:
            nil
        }
    }
}

// MARK: - Raw JSON

extension InputEvent {
    /// A JSON value as read from a row this build cannot interpret, carried
    /// so the row can be written back as it was. Numbers keep their integer
    /// or floating-point spelling, so a 64-bit identifier survives the trip
    /// exactly rather than through a `Double`.
    public enum RawJSON: Sendable, Hashable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([RawJSON])
        case object([String: RawJSON])

        /// The value as a number: integers and floating-point numbers alike;
        /// nil for anything else.
        public var doubleValue: Double? {
            switch self {
            case .integer(let integer):
                Double(integer)
            case .number(let number):
                number
            case .null, .bool, .string, .array, .object:
                nil
            }
        }
    }
}

extension InputEvent.RawJSON: Codable {
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: Self] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(Self.self, forKey: key)
            }
            self = .object(object)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [Self] = []
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(Self.self))
            }
            self = .array(array)
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let bool = try? single.decode(Bool.self) {
                self = .bool(bool)
            } else if let integer = try? single.decode(Int64.self) {
                self = .integer(integer)
            } else if let number = try? single.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try single.decode(String.self))
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .integer(let integer):
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicKey(key))
            }
        }
    }
}

// Literals, so fixtures and tools can spell a raw row the way JSON does.
extension InputEvent.RawJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) {
        self = .null
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(arrayLiteral elements: Self...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A coding key for rows whose keys are only known at run time.
private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

// MARK: - JSON encoding

// Each event is one flat JSON object with a `type` discriminator, for example
// `{"time":0.5,"type":"buttonDown","x":0.5,"y":0.25,"button":"left"}`. The
// synthesized enum encoding (`{"buttonDown":{"time":…,"position":{…}}}`) is
// avoided because the log is an open format read by other tools, and a flat
// row per event is what they expect (research brief §3).
extension InputEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case time
        case x
        case y
        case gx
        case gy
        case button
        case buttonNumber
        case keyCode
        case modifiers
        case isRepeat
        case shapeID
        case hotspotX
        case hotspotY
        case widthPoints
        case heightPoints
        case label
        case deltaX
        case deltaY
        case phase
        case bundleID
        case windowID
        case frameX
        case frameY
        case frameWidth
        case frameHeight
    }

    private enum Kind: String, Codable {
        case pointerMoved
        case buttonDown
        case buttonUp
        case keyDown
        case keyUp
        case cursorShapeChanged
        case takeMarker
        case scroll
        case focus
        case geometry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every row needs a numeric time, whatever its kind: without one it
        // could not be placed in the log, so it is refused here rather than
        // carried as an `unknown` that `append` would then drop.
        let time = try container.decode(Double.self, forKey: .time)
        let typeName = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: typeName) else {
            guard case .object(let raw) = try RawJSON(from: decoder) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "An event must be a JSON object.")
            }
            self = .unknown(kind: typeName, raw: raw)
            return
        }
        switch kind {
        case .pointerMoved:
            self = .pointerMoved(
                time: time, position: try Self.decodePosition(from: container),
                global: try Self.decodeGlobal(from: container))
        case .buttonDown:
            self = .buttonDown(
                time: time, position: try Self.decodePosition(from: container),
                button: try Self.decodeButton(from: container), global: try Self.decodeGlobal(from: container))
        case .buttonUp:
            self = .buttonUp(
                time: time, position: try Self.decodePosition(from: container),
                button: try Self.decodeButton(from: container), global: try Self.decodeGlobal(from: container))
        case .keyDown:
            self = .keyDown(
                time: time, keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                modifiers: try container.decode(Modifiers.self, forKey: .modifiers),
                isRepeat: try container.decode(Bool.self, forKey: .isRepeat))
        case .keyUp:
            self = .keyUp(
                time: time, keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                modifiers: try container.decode(Modifiers.self, forKey: .modifiers))
        case .cursorShapeChanged:
            let shape = try CursorShape(
                id: container.decode(String.self, forKey: .shapeID),
                hotspot: NormalizedPoint(
                    x: container.decode(Double.self, forKey: .hotspotX),
                    y: container.decode(Double.self, forKey: .hotspotY)),
                sizePoints: PointSize(
                    width: container.decode(Double.self, forKey: .widthPoints),
                    height: container.decode(Double.self, forKey: .heightPoints)))
            self = .cursorShapeChanged(time: time, shape: shape)
        case .takeMarker:
            self = .takeMarker(time: time, label: try container.decodeIfPresent(String.self, forKey: .label))
        case .scroll:
            self = .scroll(
                time: time, position: try Self.decodePosition(from: container),
                deltaX: try container.decode(Double.self, forKey: .deltaX),
                deltaY: try container.decode(Double.self, forKey: .deltaY),
                phase: try container.decode(ScrollPhase.self, forKey: .phase),
                global: try Self.decodeGlobal(from: container))
        case .focus:
            self = .focus(
                time: time, bundleID: try container.decode(String.self, forKey: .bundleID),
                windowID: try container.decodeIfPresent(UInt32.self, forKey: .windowID))
        case .geometry:
            let frame = try PointRect(
                x: container.decode(Double.self, forKey: .frameX),
                y: container.decode(Double.self, forKey: .frameY),
                width: container.decode(Double.self, forKey: .frameWidth),
                height: container.decode(Double.self, forKey: .frameHeight))
            self = .geometry(time: time, windowID: try container.decode(UInt32.self, forKey: .windowID), frame: frame)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .unknown(let kind, let raw) = self {
            // The row goes back as it came, down to fields this build has
            // never heard of; only `type` is taken from `kind`, which is the
            // same string for a decoded row and the authority for a built one.
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in raw where key != CodingKeys.type.rawValue {
                try container.encode(value, forKey: DynamicKey(key))
            }
            try container.encode(kind, forKey: DynamicKey(CodingKeys.type.rawValue))
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        switch self {
        case .pointerMoved(_, let position, let global):
            try container.encode(Kind.pointerMoved, forKey: .type)
            try Self.encode(position, into: &container)
            try Self.encode(global, into: &container)
        case .buttonDown(_, let position, let button, let global):
            try container.encode(Kind.buttonDown, forKey: .type)
            try Self.encode(position, into: &container)
            try Self.encode(button, into: &container)
            try Self.encode(global, into: &container)
        case .buttonUp(_, let position, let button, let global):
            try container.encode(Kind.buttonUp, forKey: .type)
            try Self.encode(position, into: &container)
            try Self.encode(button, into: &container)
            try Self.encode(global, into: &container)
        case .keyDown(_, let keyCode, let modifiers, let isRepeat):
            try container.encode(Kind.keyDown, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
            try container.encode(isRepeat, forKey: .isRepeat)
        case .keyUp(_, let keyCode, let modifiers):
            try container.encode(Kind.keyUp, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .cursorShapeChanged(_, let shape):
            try container.encode(Kind.cursorShapeChanged, forKey: .type)
            try container.encode(shape.id, forKey: .shapeID)
            try container.encode(shape.hotspot.x, forKey: .hotspotX)
            try container.encode(shape.hotspot.y, forKey: .hotspotY)
            try container.encode(shape.sizePoints.width, forKey: .widthPoints)
            try container.encode(shape.sizePoints.height, forKey: .heightPoints)
        case .takeMarker(_, let label):
            try container.encode(Kind.takeMarker, forKey: .type)
            try container.encodeIfPresent(label, forKey: .label)
        case .scroll(_, let position, let deltaX, let deltaY, let phase, let global):
            try container.encode(Kind.scroll, forKey: .type)
            try Self.encode(position, into: &container)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
            try container.encode(phase, forKey: .phase)
            try Self.encode(global, into: &container)
        case .focus(_, let bundleID, let windowID):
            try container.encode(Kind.focus, forKey: .type)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encodeIfPresent(windowID, forKey: .windowID)
        case .geometry(_, let windowID, let frame):
            try container.encode(Kind.geometry, forKey: .type)
            try container.encode(windowID, forKey: .windowID)
            try container.encode(frame.x, forKey: .frameX)
            try container.encode(frame.y, forKey: .frameY)
            try container.encode(frame.width, forKey: .frameWidth)
            try container.encode(frame.height, forKey: .frameHeight)
        case .unknown:
            // Handled above: an unknown row never passes through the known keys.
            break
        }
    }

    private static func decodePosition(from container: KeyedDecodingContainer<CodingKeys>) throws -> NormalizedPoint {
        try NormalizedPoint(x: container.decode(Double.self, forKey: .x), y: container.decode(Double.self, forKey: .y))
    }

    private static func encode(_ position: NormalizedPoint, into container: inout KeyedEncodingContainer<CodingKeys>)
        throws
    {
        try container.encode(position.x, forKey: .x)
        try container.encode(position.y, forKey: .y)
    }

    // The global point is optional as a pair: one coordinate without the
    // other is a torn row, not a point, and is refused like a bad button.
    private static func decodeGlobal(from container: KeyedDecodingContainer<CodingKeys>) throws -> GlobalPoint? {
        let x = try container.decodeIfPresent(Double.self, forKey: .gx)
        let y = try container.decodeIfPresent(Double.self, forKey: .gy)
        switch (x, y) {
        case (nil, nil):
            return nil
        case (let x?, let y?):
            return GlobalPoint(x: x, y: y)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: x == nil ? .gx : .gy, in: container,
                debugDescription: "A global point needs both gx and gy.")
        }
    }

    private static func encode(_ global: GlobalPoint?, into container: inout KeyedEncodingContainer<CodingKeys>)
        throws
    {
        guard let global else { return }
        try container.encode(global.x, forKey: .gx)
        try container.encode(global.y, forKey: .gy)
    }

    // `button` is always a name so typed consumers see one field type; the
    // number rides in its own field only for buttons beyond left and right.
    private static func decodeButton(from container: KeyedDecodingContainer<CodingKeys>) throws -> Button {
        let name = try container.decode(String.self, forKey: .button)
        switch name {
        case "left":
            return .left
        case "right":
            return .right
        case "other":
            return .other(try container.decode(Int.self, forKey: .buttonNumber))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .button, in: container, debugDescription: "Unknown mouse button \"\(name)\".")
        }
    }

    private static func encode(_ button: Button, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch button {
        case .left:
            try container.encode("left", forKey: .button)
        case .right:
            try container.encode("right", forKey: .button)
        case .other(let number):
            try container.encode("other", forKey: .button)
            try container.encode(number, forKey: .buttonNumber)
        }
    }
}

// Modifiers are written as an array of names, `["shift","command"]`, in a
// fixed order, so the file reads without a bit table and encodes identically
// for the same set.
extension InputEvent.Modifiers: Codable {
    private static let names: [(InputEvent.Modifiers, String)] = [
        (.shift, "shift"), (.control, "control"), (.option, "option"),
        (.command, "command"), (.function, "function"), (.capsLock, "capsLock"),
    ]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        var modifiers = InputEvent.Modifiers()
        for name in try container.decode([String].self) {
            guard let match = Self.names.first(where: { $0.1 == name }) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unknown key modifier \"\(name)\".")
            }
            modifiers.insert(match.0)
        }
        self = modifiers
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.names.filter { contains($0.0) }.map(\.1))
    }
}
