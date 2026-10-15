import Foundation

// A small JSON reader that remembers *where* everything is in the text, plus the text edits the
// installer needs. Parsing and re-serialising a settings file would reorder keys, change the
// indentation and escape characters differently: other tools' hooks (Orca's, say) live in the
// same file. So the installer never re-serialises: it splices text at known positions, and every
// byte it does not touch stays exactly as it was.

public struct JSONError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

struct JSONMember {
    var key: String
    var value: JSONNode
}

struct JSONNode {
    enum Kind { case object, array, string, number, bool, null }
    var kind: Kind
    /// Byte range of the whole value in the source.
    var range: Range<Int>
    var members: [JSONMember] = []      // objects
    var elements: [JSONNode] = []       // arrays
    var string: String?                 // decoded text of a string

    func member(_ key: String) -> JSONNode? { members.first { $0.key == key }?.value }
    var count: Int { kind == .object ? members.count : elements.count }
    /// Value of child `i`, whatever the container.
    func child(_ i: Int) -> JSONNode { kind == .object ? members[i].value : elements[i] }
}

struct JSONDocument {
    let bytes: [UInt8]
    let root: JSONNode

    private static let maxDepth = 64

    init(_ text: String) throws {
        bytes = Array(text.utf8)
        var parser = Parser(bytes: bytes)
        root = try parser.parseDocument()
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    // MARK: layout facts used to match the file's own style

    var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// One level of indentation: a tab, or the smallest run of spaces the file indents by.
    var indentUnit: String {
        var smallest = Int.max
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if lead.isEmpty { continue }
            if lead.first == "\t" { return "\t" }
            smallest = min(smallest, lead.count)
        }
        return smallest == Int.max || smallest == 0 ? "  " : String(repeating: " ", count: smallest)
    }

    /// Whitespace at the start of the line containing byte `offset`.
    func lineIndent(at offset: Int) -> String {
        String(decoding: bytes[lineStart(offset)...].prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
    }

    func lineStart(_ offset: Int) -> Int {
        var i = offset
        while i > 0, bytes[i - 1] != 0x0A { i -= 1 }
        return i
    }

    /// True when only whitespace precedes `offset` on its line (the value starts its own line).
    func startsOwnLine(_ offset: Int) -> Bool {
        bytes[lineStart(offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// An object or array whose children sit on separate lines.
    func isMultiline(_ node: JSONNode) -> Bool {
        let inner = (node.range.lowerBound + 1)..<(node.range.upperBound - 1)
        if node.count == 0 { return bytes[inner].contains(0x0A) }
        let firstStart = node.kind == .object ? keyStart(of: node, 0) : node.elements[0].range.lowerBound
        return bytes[(node.range.lowerBound + 1)..<firstStart].contains(0x0A)
    }

    /// Where the key of member `i` begins (its opening quote).
    func keyStart(of node: JSONNode, _ i: Int) -> Int {
        let valueStart = node.members[i].value.range.lowerBound
        var j = valueStart - 1
        while j >= 0, bytes[j] != 0x3A { j -= 1 }                 // the colon
        j -= 1
        while j >= 0, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D { j -= 1 }
        // j is on the closing quote of the key; walk back to the opening one, skipping escaped quotes
        j -= 1
        while j >= 0 {
            if bytes[j] == 0x22 {
                var slashes = 0, k = j - 1
                while k >= 0, bytes[k] == 0x5C { slashes += 1; k -= 1 }
                if slashes % 2 == 0 { return j }
            }
            j -= 1
        }
        return node.range.lowerBound + 1
    }

    /// Bytes between a member's key and its value (`": "`), reused so new members look like old ones.
    func separator(of node: JSONNode) -> String {
        guard node.kind == .object, node.count > 0 else { return ": " }
        let v = node.members[0].value.range.lowerBound
        var j = v - 1
        while j >= 0, bytes[j] != 0x22 { j -= 1 }
        return String(decoding: bytes[(j + 1)..<v], as: UTF8.self)
    }

    // MARK: text edits (each returns the new text; the caller re-parses before editing again)

    /// Adds `child` (already rendered) at the end of an array, or `"key": child` to an object.
    func appending(to container: JSONNode, key: String? = nil, child: JSONNode.Rendered) -> String {
        let nl = newline
        let multi = container.count == 0 ? true : isMultiline(container)
        let base = lineIndent(at: container.range.lowerBound)
        let inner = container.count == 0 ? base + indentUnit
            : (multi && startsOwnLine(firstChildStart(container)) ? lineIndent(at: firstChildStart(container)) : "")
        let body = child.text(indent: inner, unit: indentUnit, newline: nl, multiline: multi || container.count == 0)
        let item = key.map { JSONNode.quote($0) + separator(of: container) + body } ?? body

        var out = Array(bytes)
        if container.count == 0 {
            // Replace whatever sits between the brackets.
            let open = container.range.lowerBound + 1, close = container.range.upperBound - 1
            let filler = nl + inner + item + nl + base
            out.replaceSubrange(open..<close, with: Array(filler.utf8))
        } else {
            let last = container.child(container.count - 1).range.upperBound
            let glue = multi ? "," + nl + inner : ","
            out.insert(contentsOf: Array((glue + item).utf8), at: last)
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func firstChildStart(_ container: JSONNode) -> Int {
        container.kind == .object ? keyStart(of: container, 0) : container.elements[0].range.lowerBound
    }

    /// Replaces the text of one value.
    func replacing(_ node: JSONNode, with replacement: String) -> String {
        var out = Array(bytes)
        out.replaceSubrange(node.range, with: Array(replacement.utf8))
        return String(decoding: out, as: UTF8.self)
    }

    /// Removes child `i` of a container that has at least two children, together with its comma
    /// and (in a multi-line container) its whole line.
    func removing(child i: Int, of container: JSONNode) -> String {
        precondition(container.count >= 2)
        let multi = isMultiline(container)
        func start(_ k: Int) -> Int { container.kind == .object ? keyStart(of: container, k) : container.elements[k].range.lowerBound }
        var out = Array(bytes)
        if i < container.count - 1 {
            let next = start(i + 1)
            if multi, startsOwnLine(start(i)), startsOwnLine(next) {
                out.removeSubrange(lineStart(start(i))..<lineStart(next))
            } else {
                out.removeSubrange(start(i)..<next)
            }
        } else {
            out.removeSubrange(container.child(i - 1).range.upperBound..<container.child(i).range.upperBound)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: parser

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseDocument() throws -> JSONNode {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw JSONError("file starts with a byte-order mark") }
            skipSpace()
            let v = try value(depth: 0)
            skipSpace()
            guard i == bytes.count else { throw JSONError("unexpected text after the JSON value at byte \(i)") }
            return v
        }

        mutating func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }

        mutating func value(depth: Int) throws -> JSONNode {
            guard depth <= JSONDocument.maxDepth else { throw JSONError("nested too deeply") }
            guard i < bytes.count else { throw JSONError("unexpected end of file") }
            let start = i
            switch bytes[i] {
            case 0x7B: // {
                i += 1
                var node = JSONNode(kind: .object, range: start..<start)
                var seen = Set<String>()
                skipSpace()
                if i < bytes.count, bytes[i] == 0x7D { i += 1; node.range = start..<i; return node }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == 0x22 else { throw JSONError("expected a key at byte \(i)") }
                    let key = try stringToken().1
                    // Programs disagree on which of two equal keys wins (most keep the last). Editing
                    // the wrong one would silently do nothing, so such a file is not touched at all.
                    guard seen.insert(key).inserted else { throw JSONError("the key \"\(key)\" appears twice in the same object") }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == 0x3A else { throw JSONError("expected ':' at byte \(i)") }
                    i += 1; skipSpace()
                    node.members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                    skipSpace()
                    guard i < bytes.count else { throw JSONError("unterminated object") }
                    if bytes[i] == 0x2C { i += 1; continue }
                    if bytes[i] == 0x7D { i += 1; node.range = start..<i; return node }
                    throw JSONError("expected ',' or '}' at byte \(i)")
                }
            case 0x5B: // [
                i += 1
                var node = JSONNode(kind: .array, range: start..<start)
                skipSpace()
                if i < bytes.count, bytes[i] == 0x5D { i += 1; node.range = start..<i; return node }
                while true {
                    skipSpace()
                    node.elements.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw JSONError("unterminated array") }
                    if bytes[i] == 0x2C { i += 1; continue }
                    if bytes[i] == 0x5D { i += 1; node.range = start..<i; return node }
                    throw JSONError("expected ',' or ']' at byte \(i)")
                }
            case 0x22:
                let (range, decoded) = try stringToken()
                var n = JSONNode(kind: .string, range: range); n.string = decoded
                return n
            case 0x74: try literal("true"); return JSONNode(kind: .bool, range: start..<i)
            case 0x66: try literal("false"); return JSONNode(kind: .bool, range: start..<i)
            case 0x6E: try literal("null"); return JSONNode(kind: .null, range: start..<i)
            default:
                guard bytes[i] == 0x2D || (0x30...0x39).contains(bytes[i]) else { throw JSONError("unexpected character at byte \(i)") }
                while i < bytes.count, [0x2D, 0x2B, 0x2E, 0x65, 0x45].contains(bytes[i]) || (0x30...0x39).contains(bytes[i]) { i += 1 }
                return JSONNode(kind: .number, range: start..<i)
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw JSONError("bad literal at byte \(i)") }
            i += w.count
        }

        mutating func stringToken() throws -> (Range<Int>, String) {
            let start = i
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case 0x5C: i += 2
                case 0x22:
                    i += 1
                    let slice = Data(bytes[start..<i])
                    guard let s = try? JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed) as? String
                    else { throw JSONError("invalid string at byte \(start)") }
                    return (start..<i, s)
                case 0x00..<0x20: throw JSONError("control character in a string at byte \(i)")
                default: i += 1
                }
            }
            throw JSONError("unterminated string")
        }
    }
}

// MARK: building new values

extension JSONNode {
    /// A value to be written, with enough structure to be laid out in the file's own style.
    indirect enum Rendered {
        case object([(String, Rendered)])
        case array([Rendered])
        case string(String)
        case int(Int)
        case bool(Bool)

        func text(indent: String, unit: String, newline: String, multiline: Bool) -> String {
            switch self {
            case .string(let s): return JSONNode.quote(s)
            case .int(let n): return String(n)
            case .bool(let b): return b ? "true" : "false"
            case .array(let items):
                if items.isEmpty { return "[]" }
                if !multiline { return "[" + items.map { $0.text(indent: "", unit: unit, newline: newline, multiline: false) }.joined(separator: ",") + "]" }
                let inner = indent + unit
                return "[" + newline + items.map { inner + $0.text(indent: inner, unit: unit, newline: newline, multiline: true) }.joined(separator: "," + newline) + newline + indent + "]"
            case .object(let pairs):
                if pairs.isEmpty { return "{}" }
                if !multiline { return "{" + pairs.map { JSONNode.quote($0.0) + ":" + $0.1.text(indent: "", unit: unit, newline: newline, multiline: false) }.joined(separator: ",") + "}" }
                let inner = indent + unit
                return "{" + newline + pairs.map { inner + JSONNode.quote($0.0) + ": " + $0.1.text(indent: inner, unit: unit, newline: newline, multiline: true) }.joined(separator: "," + newline) + newline + indent + "}"
            }
        }

        /// The same value as plain Foundation objects, for comparing with what is in a file.
        var foundation: Any {
            switch self {
            case .string(let s): return s
            case .int(let n): return n
            case .bool(let b): return b
            case .array(let a): return a.map(\.foundation)
            case .object(let o): return Dictionary(uniqueKeysWithValues: o.map { ($0.0, $0.1.foundation) })
            }
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
