import Foundation

/// The JSON value tree the corpus feed's `data` may contain — per the server
/// spec: strings, ints, null, arrays, objects ONLY (no floats; bools are
/// tolerated defensively). Round-trips the decoded feed back into the exact
/// canonical bytes the server signed: `JSONEncoder` with `.sortedKeys` +
/// `.withoutEscapingSlashes` yields keys asciibetical at every depth,
/// compact separators, and slashes/unicode unescaped — byte-identical to the
/// server's canonicalization for this value domain.
public enum CanonicalJSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    indirect case array([CanonicalJSONValue])
    indirect case object([String: CanonicalJSONValue])
}

extension CanonicalJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? single.decode(Int.self) {
            self = .int(i)
        } else if let s = try? single.decode(String.self) {
            self = .string(s)
        } else if let a = try? single.decode([CanonicalJSONValue].self) {
            self = .array(a)
        } else if let o = try? single.decode([String: CanonicalJSONValue].self) {
            self = .object(o)
        } else {
            // Floats (or anything else) are OUTSIDE the signed value domain —
            // refuse to canonicalize rather than guess at the server's bytes.
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Value outside the canonical feed domain (strings/ints/bools/null/arrays/objects)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let s): try single.encode(s)
        case .int(let i): try single.encode(i)
        case .bool(let b): try single.encode(b)
        case .null: try single.encodeNil()
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }

    /// The canonical bytes of this value — what Ed25519 verification runs
    /// over. Sorted keys at every depth, compact, slashes unescaped.
    public static func canonicalBytes(of value: CanonicalJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
