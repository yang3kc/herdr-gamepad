import Foundation

/// A deliberately small TOML reader.
///
/// This covers exactly what `gamepad.toml` needs and nothing more:
/// comments, `[table]`, `[[array of tables]]`, `key = value`, inline tables
/// and single-line arrays. Multi-line strings, dotted keys and datetimes are
/// out of scope — if a config needs them, it has outgrown this plugin.
///
/// Values come back as `String`, `Int`, `Double`, `Bool`, `[Any]` or
/// `[String: Any]`, so callers can use the `TOMLTable` helpers below instead
/// of casting by hand.
enum TOML {

    struct ParseError: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { "gamepad.toml line \(line): \(reason)" }
    }

    static func parse(_ text: String) throws -> [String: Any] {
        var root: [String: Any] = [:]
        // Path of the table that bare `key = value` lines currently land in.
        var path: [String] = []

        for (idx, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = idx + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw ParseError(line: lineNo, reason: "unterminated [[table]] header")
                }
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                let keys = splitKeyPath(name)
                guard !keys.isEmpty else { throw ParseError(line: lineNo, reason: "empty [[table]] name") }
                appendToArrayTable(&root, keys)
                path = keys
                continue
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError(line: lineNo, reason: "unterminated [table] header")
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let keys = splitKeyPath(name)
                guard !keys.isEmpty else { throw ParseError(line: lineNo, reason: "empty [table] name") }
                ensureTable(&root, keys)
                path = keys
                continue
            }

            guard let eq = firstTopLevelEquals(line) else {
                throw ParseError(line: lineNo, reason: "expected `key = value`, got `\(line)`")
            }
            let key = unquote(String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces))
            let rhs = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ParseError(line: lineNo, reason: "empty key") }
            guard !rhs.isEmpty else { throw ParseError(line: lineNo, reason: "missing value for `\(key)`") }

            let value = try parseValue(rhs, line: lineNo)
            setValue(&root, path: path, key: key, value: value)
        }
        return root
    }

    // MARK: - Line handling

    /// Strips a trailing `#` comment while respecting quoted strings.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character? = nil
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                break
            }
            out.append(ch)
        }
        return out
    }

    /// Finds the `=` that separates key from value, ignoring any inside quotes.
    private static func firstTopLevelEquals(_ line: String) -> String.Index? {
        var quote: Character? = nil
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "=" {
                return i
            }
            i = line.index(after: i)
        }
        return nil
    }

    private static func splitKeyPath(_ s: String) -> [String] {
        s.split(separator: ".").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Values

    private static func parseValue(_ raw: String, line: Int) throws -> Any {
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            return unescape(unquote(raw))
        }
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else { throw ParseError(line: line, reason: "unterminated array") }
            let inner = String(raw.dropFirst().dropLast())
            return try splitTopLevel(inner, separator: ",").map { try parseValue($0, line: line) }
        }
        if raw.hasPrefix("{") {
            guard raw.hasSuffix("}") else { throw ParseError(line: line, reason: "unterminated inline table") }
            let inner = String(raw.dropFirst().dropLast())
            var table: [String: Any] = [:]
            for pair in try splitTopLevel(inner, separator: ",") {
                guard let eq = firstTopLevelEquals(pair) else {
                    throw ParseError(line: line, reason: "bad inline table entry `\(pair)`")
                }
                let k = unquote(String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces))
                let v = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                table[k] = try parseValue(v, line: line)
            }
            return table
        }
        // Numbers. `0x` is accepted because USB vendor/product ids read better in hex.
        let cleaned = raw.replacingOccurrences(of: "_", with: "")
        if cleaned.lowercased().hasPrefix("0x"), let n = Int(cleaned.dropFirst(2), radix: 16) { return n }
        if let n = Int(cleaned) { return n }
        if let d = Double(cleaned) { return d }
        throw ParseError(line: line, reason: "cannot parse value `\(raw)`")
    }

    /// Splits on a separator that appears outside quotes, brackets and braces.
    private static func splitTopLevel(_ s: String, separator: Character) throws -> [String] {
        var parts: [String] = []
        var cur = ""
        var depth = 0
        var quote: Character? = nil
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
                cur.append(ch)
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "[", "{": depth += 1; cur.append(ch)
            case "]", "}": depth -= 1; cur.append(ch)
            case separator where depth == 0:
                parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.filter { !$0.isEmpty }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\t", with: "\t")
         .replacingOccurrences(of: "\\\"", with: "\"")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Nested writes

    private static func ensureTable(_ root: inout [String: Any], _ keys: [String]) {
        guard let first = keys.first else { return }
        var child = root[first] as? [String: Any] ?? [:]
        if keys.count == 1 {
            root[first] = child
        } else {
            ensureTable(&child, Array(keys.dropFirst()))
            root[first] = child
        }
    }

    private static func appendToArrayTable(_ root: inout [String: Any], _ keys: [String]) {
        guard let first = keys.first else { return }
        if keys.count == 1 {
            var arr = root[first] as? [Any] ?? []
            arr.append([String: Any]())
            root[first] = arr
        } else {
            var child = root[first] as? [String: Any] ?? [:]
            appendToArrayTable(&child, Array(keys.dropFirst()))
            root[first] = child
        }
    }

    /// Writes `key = value` into the table (or last array element) at `path`.
    private static func setValue(_ root: inout [String: Any], path: [String], key: String, value: Any) {
        guard let first = path.first else {
            root[key] = value
            return
        }
        if path.count == 1 {
            if var arr = root[first] as? [Any], var last = arr.last as? [String: Any] {
                last[key] = value
                arr[arr.count - 1] = last
                root[first] = arr
            } else {
                var t = root[first] as? [String: Any] ?? [:]
                t[key] = value
                root[first] = t
            }
        } else {
            var t = root[first] as? [String: Any] ?? [:]
            setValue(&t, path: Array(path.dropFirst()), key: key, value: value)
            root[first] = t
        }
    }
}

// MARK: - Convenience accessors

extension Dictionary where Key == String, Value == Any {
    func table(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func tables(_ key: String) -> [[String: Any]] { (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        return nil
    }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
}
