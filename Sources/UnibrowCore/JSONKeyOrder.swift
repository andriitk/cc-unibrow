public import Foundation

/// Reads the order of an object's keys straight from JSON text.
///
/// Decoded JSON objects are dictionaries and forget their order, but an MCP
/// elicitation form should list its fields as the server wrote them. The relay
/// still has the raw hook input, so it reads the order there and sends it
/// along. Any surprise returns `nil`, and the form falls back to a stable
/// order of its own.
public enum JSONKeyOrder {
    /// Keys of the object at `path` (object keys from the root), in order.
    public static func keys(in data: Data, at path: [String]) -> [String]? {
        var scanner = Scanner(bytes: Array(data))
        return try? scanner.keys(at: path[...])
    }

    private struct Malformed: Error {}

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        /// Expects an object at the current position and walks `path` down it.
        mutating func keys(at path: ArraySlice<String>) throws -> [String]? {
            skipWhitespace()
            guard peek() == UInt8(ascii: "{") else { return nil }
            index += 1
            var found: [String] = []
            var result: [String]?
            while true {
                skipWhitespace()
                if peek() == UInt8(ascii: "}") { index += 1; break }
                let key = try string()
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { throw Malformed() }
                index += 1
                found.append(key)
                skipWhitespace()
                if let first = path.first, key == first, result == nil, peek() == UInt8(ascii: "{") {
                    // Consumes the whole nested object.
                    result = try keys(at: path.dropFirst())
                } else {
                    try skipValue()
                }
                skipWhitespace()
                if peek() == UInt8(ascii: ",") { index += 1; continue }
                if peek() == UInt8(ascii: "}") { index += 1; break }
                throw Malformed()
            }
            return path.isEmpty ? found : result
        }

        mutating func skipValue() throws {
            skipWhitespace()
            guard let byte = peek() else { throw Malformed() }
            switch byte {
            case UInt8(ascii: "\""):
                _ = try string()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while let current = peek() {
                    if current == UInt8(ascii: "\"") { _ = try string(); continue }
                    index += 1
                    if current == UInt8(ascii: "{") || current == UInt8(ascii: "[") { depth += 1 }
                    if current == UInt8(ascii: "}") || current == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { return }
                    }
                }
                throw Malformed()
            default:
                // Number, true, false, null.
                while let current = peek(), !",}] \n\r\t".utf8.contains(current) { index += 1 }
            }
        }

        mutating func string() throws -> String {
            guard peek() == UInt8(ascii: "\"") else { throw Malformed() }
            let start = index
            index += 1
            while let byte = peek() {
                index += 1
                if byte == UInt8(ascii: "\\") { index += 1; continue }
                if byte == UInt8(ascii: "\"") {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
            }
            throw Malformed()
        }

        mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
        }

        func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }
    }
}
