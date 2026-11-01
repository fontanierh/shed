import Foundation

/// Lays Prime's Python out for a narrow screen. Agents write `a = f(x); print(a, b)` one-liners hundreds of characters
/// long: this puts each statement on its own line and breaks long calls, lists and dicts one item per line. Only
/// whitespace changes (and `;` becomes a line break), so it reads as the same code. Lines that already span several
/// (a triple-quoted string, a bracket left open across lines) are left as they are.
enum PythonLayout {
    static func readable(_ code: String, width: Int) -> String {
        let width = max(width, 24)
        var out: [String] = []
        for line in logicalLines(Array(code)) {
            let text = String(line)
            let indent = String(text.prefix { $0 == " " || $0 == "\t" })
            let body = Array(text.dropFirst(indent.count))
            for (index, statement) in statements(body).enumerated() {
                let statement = String(statement).trimmingCharacters(in: .whitespaces)
                if statement.isEmpty { continue }
                // `if x: a; b` keeps a and b in the body, so they move under the header together.
                let level = index > 0 && compoundHeader(body) != nil ? indent + "    " : indent
                if index == 0, let header = compoundHeader(body), header < statement.count {
                    let chars = Array(statement)
                    out.append(indent + String(chars[...header]))
                    let rest = String(chars[(header + 1)...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { out += wrap(Array(rest), indent: indent + "    ", width: width) }
                } else if statement.contains("\n") {
                    out.append(level + statement)
                } else {
                    out += wrap(Array(statement), indent: level, width: width)
                }
            }
            if body.isEmpty { out.append("") }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Scanning

    /// Walks the code and reports every character outside strings and comments with the bracket depth before it.
    private static func scan(_ chars: [Character], _ visit: (Int, Character, Int) -> Void) {
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "'" || c == "\"" {
                let triple = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                i += triple ? 3 : 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if triple, chars[i] == c, i + 2 < chars.count, chars[i + 1] == c, chars[i + 2] == c { i += 3; break }
                    if !triple, chars[i] == c || chars[i] == "\n" { i += 1; break }
                    i += 1
                }
                continue
            }
            visit(i, c, depth)
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) { depth = max(0, depth - 1) }
            i += 1
        }
    }

    /// Splits at newlines that end a statement: not inside brackets or a string.
    private static func logicalLines(_ chars: [Character]) -> [ArraySlice<Character>] {
        var cuts: [Int] = []
        scan(chars) { i, c, depth in if c == "\n", depth == 0 { cuts.append(i) } }
        var lines: [ArraySlice<Character>] = []
        var start = 0
        for cut in cuts {
            lines.append(chars[start..<cut])
            start = cut + 1
        }
        lines.append(chars[start...])
        return lines
    }

    private static func statements(_ chars: [Character]) -> [ArraySlice<Character>] {
        var cuts: [Int] = []
        scan(chars) { i, c, depth in if c == ";", depth == 0 { cuts.append(i) } }
        var parts: [ArraySlice<Character>] = []
        var start = 0
        for cut in cuts {
            parts.append(chars[start..<cut])
            start = cut + 1
        }
        parts.append(chars[start...])
        return parts
    }

    private static let compound: Set<String> = ["if", "elif", "else", "for", "while", "with", "try", "except", "finally", "def",
                                                 "class", "async"]

    /// Where the colon closing `if …:`, `for …:` and the like sits, when the body follows on the same line.
    private static func compoundHeader(_ chars: [Character]) -> Int? {
        let word = String(chars.prefix { $0.isLetter })
        guard compound.contains(word) else { return nil }
        var colon: Int?
        var lambdas = 0
        scan(chars) { i, c, depth in
            guard colon == nil, depth == 0 else { return }
            // `lambda x: …` in a header has its own colon.
            if c == "l", chars[i...].starts(with: "lambda"), i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") { lambdas += 1 }
            // `while chunk := read():` has a walrus first.
            if c == ":", i + 1 == chars.count || chars[i + 1] != "=" { if lambdas > 0 { lambdas -= 1 } else { colon = i } }
        }
        guard let colon, chars[(colon + 1)...].contains(where: { !$0.isWhitespace }) else { return nil }
        // Only when there is a body after it; `x: int = 1` isn't a compound statement anyway.
        return colon
    }

    // MARK: Breaking long lines

    /// One statement as lines no wider than `width` where it can. The longest bracketed group with several items (or a
    /// comprehension's clauses) opens up, one a line; a group with a single item opens only if that item breaks further.
    /// What still doesn't fit, a long string, is left to wrap on screen.
    private static func wrap(_ chars: [Character], indent: String, width: Int) -> [String] {
        let line = indent + String(chars)
        guard line.count > width else { return [line] }
        var groups: [(open: Int, close: Int)] = []
        var opens: [Int] = []
        scan(chars) { i, c, depth in
            if "([{".contains(c) { opens.append(i) }
            if ")]}".contains(c), let open = opens.popLast(), depth == 1 { groups.append((open, i)) }
        }
        let deeper = indent + "    "
        let split = groups.map { group in (group, parts(Array(chars[(group.open + 1)..<group.close]))) }
        func around(_ group: (open: Int, close: Int), _ inner: [String]) -> [String] {
            wrap(Array(chars[...group.open]), indent: indent, width: width) + inner
                + wrap(Array(chars[group.close...]), indent: indent, width: width)
        }
        if let (group, parts) = split.filter({ $0.1.count > 1 }).max(by: { $0.0.close - $0.0.open < $1.0.close - $1.0.open }) {
            // Short plain items (`"model", "effort", 3`) share lines up to the width rather than taking one each.
            let plain = parts.allSatisfy { part in part.count <= 24 && part.hasSuffix(",") || part == parts.last }
                && parts.allSatisfy { part in part.count <= 24 && !part.contains(where: { "([{".contains($0) }) }
                && !parts.contains(where: { $0.hasPrefix("for ") || $0.hasPrefix("if ") || $0.hasPrefix("async for ") })
            if plain {
                var lines: [String] = []
                for part in parts {
                    if let last = lines.last, last.count + 1 + part.count <= width { lines[lines.count - 1] = last + " " + part }
                    else { lines.append(deeper + part) }
                }
                return around(group, lines)
            }
            return around(group, parts.flatMap { wrap(Array($0), indent: deeper, width: width) })
        }
        for (group, parts) in split.sorted(by: { $0.0.close - $0.0.open > $1.0.close - $1.0.open }) {
            guard let item = parts.first else { continue }
            let inner = wrap(Array(item), indent: deeper, width: width)
            guard inner.count > 1 else { continue }
            // `print([` … `])` rather than a level of indentation for each bracket.
            let head = indent + String(chars[...group.open])
            if inner.count > 2, inner[0].count == deeper.count + 1, let last = inner.last, last.hasPrefix(deeper),
               head.count + 1 <= width || head.count < indent.count + 12 {
                let middle = inner.dropFirst().dropLast().map { $0.hasPrefix(deeper + "    ") ? String($0.dropFirst(4)) : $0 }
                return [head + inner[0].dropFirst(deeper.count)] + middle
                    + [indent + String(last.dropFirst(deeper.count)) + String(chars[group.close...])]
            }
            return around(group, inner)
        }
        return [line]
    }

    /// A group's items, each with its comma, or a comprehension's clauses: `x`, `for x in xs`, `if x`.
    private static func parts(_ inner: [Character]) -> [String] {
        var commas: [Int] = []
        var clauses: [Int] = []
        scan(inner) { i, c, depth in
            guard depth == 0 else { return }
            if c == "," { commas.append(i) }
            let before = i == 0 || inner[i - 1].isWhitespace
            for word in ["for", "if"] where before && inner[i...].starts(with: word) {
                let end = i + word.count
                // `a if b else c` before the first `for` is an expression, not a clause.
                if end < inner.count, inner[end].isWhitespace, word == "for" || !clauses.isEmpty {
                    // `async for` stays together.
                    let async = i >= 6 && String(inner[(i - 6)..<i]) == "async "
                    clauses.append(async ? i - 6 : i)
                }
            }
        }
        if !commas.isEmpty {
            var items: [String] = []
            var start = 0
            for cut in commas + [inner.count] {
                let item = String(inner[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { items.append(cut < inner.count ? item + "," : item) }
                start = cut + 1
            }
            return items
        }
        var items: [String] = []
        var start = 0
        for cut in clauses + [inner.count] where cut > start {
            let item = String(inner[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { items.append(item) }
            start = cut
        }
        return items
    }
}
