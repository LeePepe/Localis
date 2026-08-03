import Foundation

/// A decoded JSON value, read by key rather than by struct shape.
///
/// The bridge protocol is explicitly forward-compatible: unknown fields are
/// ignored, unknown values are tolerated, and new keys appear without a version
/// bump (constitution IV). `Codable` structs model the opposite contract — they
/// describe a fixed shape, and every optional field becomes a decision about
/// whether a whole frame is valid. Reading keys off a tree keeps "I did not
/// recognise this" local to the one field instead of failing the frame.
///
/// It also keeps the wire out of the domain: nothing above `StreamEventMapper`
/// ever sees a `JSONValue`, so a re-encoding on the bridge side does not ripple
/// upward (plan §1.1).
///
/// Numbers are `Double` because JSON has one numeric type; `intValue` narrows
/// where a whole number is what the contract promises.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses `text`, returning nil if it is not valid JSON.
    ///
    /// Nil rather than throwing: the caller's response to a corrupt frame is to
    /// skip it and keep reading, and an error value would only be discarded.
    init?(jsonText: String) {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        self.init(jsonData: data)
    }

    init?(jsonData: Data) {
        guard let parsed = try? JSONSerialization.jsonObject(
            with: jsonData,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }
        self.init(any: parsed)
    }

    private init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // NSNumber erases Bool into a number; the ObjC type encoding is the
            // only way back, and losing it would turn `true` into `1`.
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    // MARK: - Access

    /// Reads a key, or nil when this is not an object, the key is absent, or
    /// its value is JSON `null`.
    ///
    /// Collapsing those three is deliberate: for every field in this protocol
    /// they mean the same thing — the bridge did not supply it — and keeping
    /// them apart would only invite call sites to handle a distinction that
    /// carries no information.
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self, let value = fields[key], value != .null else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    /// A whole number, or nil if the value is fractional or out of range.
    ///
    /// A silently truncated `seq` would corrupt the resume cursor, so a
    /// non-integral number is treated as absent rather than rounded.
    var intValue: Int? {
        guard case .number(let value) = self,
              value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    /// The scalar form used by the open telemetry envelope, or nil for shapes a
    /// readout cannot render (arrays, nested objects, null).
    var telemetryValue: TelemetryValue? {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .boolean(value)
        case .null, .array, .object: return nil
        }
    }
}
