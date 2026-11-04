import Foundation

/// A JSON value held as data rather than as a typed field: what a build keeps
/// from a field it does not know, so the field goes back to disk as it came.
///
/// Numbers keep their integer or floating-point spelling, so a 64-bit
/// identifier survives the trip exactly rather than through a `Double`. An
/// integral floating-point number such as `1.0` reads as the integer 1, which
/// is the same JSON value; byte-identical preservation of foreign number
/// formatting is not a goal (DECISIONS "formats keep EventLog").
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

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

    /// The value as an integer: an integer, or a floating-point number with
    /// no fractional part, when it fits; nil otherwise.
    public var intValue: Int? {
        switch self {
        case .integer(let integer):
            Int(exactly: integer)
        case .number(let number):
            Int(exactly: number)
        case .null, .bool, .string, .array, .object:
            nil
        }
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// The member of an object, or nil for a missing key and for any other
    /// kind of value, so a path can be walked with optional chaining.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The element of an array, or nil when out of range and for any other
    /// kind of value.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: JSONCodingKey.self) {
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
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: JSONCodingKey(key))
            }
        }
    }
}

// Literals, so fixtures and tools can spell a value the way JSON does.
extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
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

// MARK: - JSON data

extension JSONValue {
    /// Parses a JSON document; a bare scalar is accepted as well as an
    /// object or array.
    public init(jsonData data: Data) throws {
        self = try PackageJSON.decoder().decode(JSONValue.self, from: data)
    }

    /// The value as JSON in the package dialect (sorted keys, so two writes
    /// of the same value are byte-identical).
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        try PackageJSON.encode(self, prettyPrinted: prettyPrinted)
    }

    /// The JSON tree a value encodes to, for tools that assemble or inspect a
    /// document without a typed model of it.
    public init(encoding value: some Encodable) throws {
        self = try Self(jsonData: PackageJSON.encode(value))
    }

    /// Decodes this tree as `type`, the inverse of `init(encoding:)`.
    public func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try PackageJSON.decode(type, from: jsonData())
    }
}

// MARK: - Unknown keys

/// A container type whose JSON object may carry fields this build does not
/// know. They are captured into `extra` on decode and written back on encode,
/// so an older build never strips a newer build's fields when it re-saves a
/// manifest, project or kit (ARCHITECTURE §3).
///
/// Adopters hand-write their `Codable` conformance and call `decodeExtra` at
/// the end of `init(from:)` and `encodeExtra` at the end of `encode(to:)`,
/// naming their `CodingKeys` as the known set. `extra` never holds a known
/// key: decoding skips them and encoding ignores any that was set by hand, so
/// a typed field always wins over a stray entry.
public protocol PreservesUnknownKeys {
    /// Fields read from the object that this build has no property for,
    /// keyed by their JSON name.
    var extra: [String: JSONValue] { get set }
}

extension PreservesUnknownKeys {
    /// Reads every member of the object `decoder` is positioned on whose key
    /// is not one of `known`.
    public static func decodeExtra<Known: CodingKey & CaseIterable>(
        from decoder: any Decoder, known: Known.Type
    ) throws -> [String: JSONValue] {
        let knownNames = Set(known.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: JSONCodingKey.self)
        var extra: [String: JSONValue] = [:]
        for key in container.allKeys where !knownNames.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extra
    }

    /// Writes `extra` into the object `encoder` is positioned on, after the
    /// known fields; a key `known` lists is skipped, since its property has
    /// already written it.
    public func encodeExtra<Known: CodingKey & CaseIterable>(to encoder: any Encoder, known: Known.Type) throws {
        guard !extra.isEmpty else { return }
        let knownNames = Set(known.allCases.map(\.stringValue))
        var container = encoder.container(keyedBy: JSONCodingKey.self)
        for (key, value) in extra where !knownNames.contains(key) {
            try container.encode(value, forKey: JSONCodingKey(key))
        }
    }
}

/// A coding key for objects whose keys are only known at run time.
struct JSONCodingKey: CodingKey {
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
