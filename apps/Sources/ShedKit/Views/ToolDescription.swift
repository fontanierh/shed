// Human summaries of tool calls: "Fetched river.ai", "Spawned subagents product, details", "Ran ls -la".
import Foundation

struct ToolDescription {
    /// SF Symbol.
    var icon: String
    /// What happened, as a verb phrase: "Fetched", "Ran", "Spawned subagents".
    var title: String
    /// The object: a URL, a command, a path, a code line.
    var detail: String?
    /// Subagents this call started, for links.
    var spawned: [String] = []
    /// Language of the input, for its label.
    var language = "json"

    init(icon: String, title: String, detail: String? = nil, spawned: [String] = [], language: String = "json") {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.spawned = spawned
        self.language = language
    }

    /// Remembered per call: every collapsed activity card asks for each of its steps on every render, and reading
    /// Prime's Python takes a few regex passes over the whole code.
    init(_ item: Item) {
        let key = Call(id: item.id, name: item.toolName, args: item.args?.utf8.count ?? 0)
        if let known = Self.memo.get(key) {
            self = known
            return
        }
        self.init(describing: item)
        Self.memo.set(key, self)
    }

    private init(describing item: Item) {
        let name = item.toolName ?? "tool"
        let args = item.args ?? ""
        if name == "python_repl" || name == "python" {
            self = Self.python(code: Self.pythonCode(args))
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        let string = { (key: String) in (json[key] as? String).map(Self.oneLine) }
        switch name {
        case "bash", "shell":
            self = Self.shell(string("command") ?? Self.oneLine(args))
        case "read":
            self.init(icon: "doc.text", title: "Read", detail: string("path").map { Format.path($0) })
        case "edit":
            self.init(icon: "pencil", title: "Edited", detail: string("path").map { Format.path($0) })
        case "write":
            self.init(icon: "square.and.pencil", title: "Wrote", detail: string("path").map { Format.path($0) })
        case "grep":
            self.init(icon: "magnifyingglass", title: "Searched for", detail: string("pattern"))
        case "find":
            self.init(icon: "doc.text.magnifyingglass", title: "Found files", detail: string("pattern") ?? string("path"))
        case "ls":
            self.init(icon: "folder", title: "Listed", detail: string("path").map { Format.path($0) } ?? ".")
        case "subagent":
            let tasks = (json["tasks"] as? [[String: Any]]) ?? (json["chain"] as? [[String: Any]]) ?? []
            let agents = tasks.compactMap { $0["agent"] as? String } + [json["agent"] as? String].compactMap { $0 }
            self.init(icon: "arrow.triangle.branch", title: agents.count > 1 ? "Ran subagents" : "Ran subagent",
                      detail: agents.joined(separator: ", "), spawned: agents)
        case "web_search", "search":
            self.init(icon: "globe", title: "Searched the web", detail: string("query"))
        case "fetch", "web_fetch":
            self.init(icon: "globe", title: "Fetched", detail: string("url").map(Self.shortURL))
        default:
            let first = json.sorted { $0.key < $1.key }.first { $0.value is String }.map { Self.oneLine($0.value as! String) }
            self.init(icon: "wrench.and.screwdriver", title: name, detail: first ?? (args.isEmpty ? nil : Self.oneLine(args)))
        }
    }

    private static let memo = Memo<Call, ToolDescription>()

    /// A call, as of its arguments so far: they grow while it streams in.
    private struct Call: Hashable {
        let id: String
        let name: String?
        let args: Int
    }
    private static let regexes = Memo<String, NSRegularExpression>()

    // MARK: Prime's Python REPL

    /// The code of a `{"code": "…"}` argument object.
    static func code(fromArgs args: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any], json.count == 1 else { return nil }
        return json["code"] as? String
    }

    /// Prime sends `{"code": "…"}`; older events carry the code itself.
    private static func pythonCode(_ args: String) -> String {
        if args.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any],
           let code = json["code"] as? String {
            return code
        }
        return args
    }

    /// The images a call loaded into the model's context: Prime's `attach_image`, by the paths its answer names, or
    /// before it answers, the ones its code passes.
    static func attachedImages(_ item: Item) -> [String] {
        guard item.toolName == "python_repl" || item.toolName == "python" else { return [] }
        let code = pythonCode(item.args ?? "")
        guard code.contains("attach_image(") else { return [] }
        // The answer comes as Python's repr of a string: newlines escaped and quotes around it.
        if let output = item.output,
           let listed = matches(#"Loaded \d+ image\(s\) into context: (.+?)(?:\\n|\n|['"]|$)"#, in: output).first {
            return listed.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return imagePaths(in: code)
    }

    /// The image paths written out in the code's `attach_image(...)` calls.
    private static func imagePaths(in code: String) -> [String] {
        matches(#"attach_image\(([^)]*)\)"#, in: code).flatMap { call in
            matches(#"['"]([^'"\n]+\.(?:png|jpe?g|gif|webp|heic|bmp|tiff?))['"]"#, in: call)
        }
    }

    static func python(code: String) -> ToolDescription {
        if code.contains("attach_image(") {
            let names = imagePaths(in: code).map { ($0 as NSString).lastPathComponent }
            return .init(icon: "photo.on.rectangle", title: names.count > 1 ? "Looked at images" : "Looked at image",
                         detail: names.isEmpty ? nil : names.joined(separator: ", "), language: "python")
        }
        let spawned = matches(#"rlm\.spawn\([\s\S]*?name\s*=\s*['"]([^'"]+)['"]"#, in: code)
        if !spawned.isEmpty {
            return .init(icon: "arrow.triangle.branch", title: spawned.count > 1 ? "Spawned subagents" : "Spawned subagent",
                         detail: spawned.joined(separator: ", "), spawned: spawned, language: "python")
        }
        if code.contains("agent_message.send(") {
            let receivers = matches(#"receiver_name\s*=\s*['"]([^'"]+)['"]"#, in: code)
            let target = receivers.isEmpty ? (code.contains("receiver_role='parent'") || code.contains("receiver_role=\"parent\"") ? "parent" : nil)
                : Array(NSOrderedSet(array: receivers)).compactMap { $0 as? String }.joined(separator: ", ")
            let message = matches(#"agent_message\.send\(\s*['"]{1,3}([^'"]+)"#, in: code).first
            return .init(icon: "paperplane", title: target.map { "Messaged \($0)" } ?? "Sent a message", detail: message.map(oneLine), language: "python")
        }
        if code.contains("rlm.collect(") || code.contains("rlm.list_subagents(") || code.contains("rlm.wait(") {
            return .init(icon: "person.2", title: "Checked on subagents", language: "python")
        }
        if let command = matches(#"bash\(\s*f?('''|"""|'|")([\s\S]*?)\1"#, in: code, group: 2).first {
            var description = shell(oneLine(command))
            description.language = "python"
            return description
        }
        let urls = matches(#"https?://[^\s'"\)\]]+"#, in: code)
        if urls.count > 1, code.contains("gather") || code.contains("for ") {
            return .init(icon: "globe", title: "Fetched \(urls.count) pages", detail: Array(NSOrderedSet(array: urls.map(shortURL))).compactMap { $0 as? String }.joined(separator: ", "), language: "python")
        }
        let line = code.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("import ") && !$0.hasPrefix("from ") }
        return .init(icon: "chevron.left.forwardslash.chevron.right", title: "Ran Python", detail: line.map(oneLine), language: "python")
    }

    /// curl → "Fetched host/path"; anything else → "Ran <command>".
    static func shell(_ command: String) -> ToolDescription {
        if command.hasPrefix("curl") || command.hasPrefix("wget"), let url = matches(#"https?://[^\s'"]+"#, in: command).first {
            if let components = URLComponents(string: url), components.path.hasSuffix("/search"),
               let query = components.queryItems?.first(where: { $0.name == "q" })?.value {
                return .init(icon: "magnifyingglass", title: "Searched the web",
                             detail: query.replacingOccurrences(of: "+", with: " "), language: "bash")
            }
            return .init(icon: "globe", title: "Fetched", detail: shortURL(url), language: "bash")
        }
        return .init(icon: "terminal", title: "Ran", detail: command, language: "bash")
    }

    static func shortURL(_ url: String) -> String {
        url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The part of a command worth reading in a short line: "cd /Users/me/dev/project && git -C /Users/me/dev/project
    /// -c lfs.concurrenttransfers=4 lfs pull --include=…" is "git lfs pull --include=…".
    static func shortCommand(_ command: String, limit: Int = 48) -> String {
        let line = oneLine(command)
            .replacingOccurrences(of: #"^cd \S+ && "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(git)((?: -[Cc] \S+)+)"#, with: "$1", options: .regularExpression)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = regexes.get(pattern) ?? (try? NSRegularExpression(pattern: pattern)).map({ regexes.set(pattern, $0); return $0 })
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let range = match.numberOfRanges > group ? match.range(at: group) : match.range
            return Range(range, in: text).map { String(text[$0]) }
        }
    }
}

/// A reasoning summary split into its bold title and body: "**Inspecting documentation**\n\nI need to…".
struct Reasoning {
    let title: String?
    let body: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("**"), let end = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.endIndex),
           !trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound].contains("\n") {
            title = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound])
            body = trimmed[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = nil
            body = trimmed
        }
    }
}

/// A small thread-safe cache. Emptied when it grows past its limit: a transcript holds a few thousand calls at most.
final class Memo<K: Hashable, V>: @unchecked Sendable {
    private var values: [K: V] = [:]
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 20_000) { self.limit = limit }

    func get(_ key: K) -> V? { lock.withLock { values[key] } }

    func set(_ key: K, _ value: V) {
        lock.withLock {
            if values.count >= limit { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
}
