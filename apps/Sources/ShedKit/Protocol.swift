// Wire types shared with the bridge (bridge/src/protocol.rs).
import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pi, prime
    public var id: String { rawValue }
    public var displayName: String { self == .pi ? "Pi" : "Prime" }
}

public enum ItemKind: String, Codable, Sendable {
    case user, text, thinking, tool, compaction, error, note
}

public enum ToolStatus: String, Codable, Sendable {
    case preparing, pending, running, done, error
}

public struct Item: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var kind: ItemKind
    public var text: String
    public var toolCallId: String?
    public var toolName: String?
    public var args: String?
    public var output: String?
    public var status: ToolStatus?
    public var durationMs: Int?
    /// When the item started, in ms since the epoch.
    public var at: Double?

    public var date: Date? { at.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public struct ItemSet: Codable, Sendable {
    public var text: String?
    public var toolCallId: String?
    public var toolName: String?
    public var args: String?
    public var output: String?
    public var status: ToolStatus?
    public var durationMs: Int?

    func apply(to item: inout Item) {
        if let text { item.text = text }
        if let toolCallId { item.toolCallId = toolCallId }
        if let toolName { item.toolName = toolName }
        if let args { item.args = args }
        if let output { item.output = output }
        if let status { item.status = status }
        if let durationMs { item.durationMs = durationMs }
    }
}

public struct ItemAppend: Codable, Sendable {
    public var text: String?
    public var args: String?
}

public enum SessionStatus: String, Codable, Sendable {
    case starting, idle, running, compacting, done, stopped, error

    public var isBusy: Bool { self == .running || self == .compacting || self == .starting }
}

public enum SessionKind: String, Codable, Sendable {
    case root, subagent
}

public struct ModelInfo: Codable, Hashable, Sendable {
    public let provider: String
    public let id: String
    public let name: String
    public let contextWindow: Int?
    public let reasoning: Bool

    public var key: String { "\(provider)/\(id)" }
}

public struct ContextUsage: Codable, Equatable, Sendable {
    public let tokens: Int?
    public let window: Int
    public let percent: Double?
}

public struct Queue: Codable, Equatable, Sendable {
    public let steering: [String]
    public let followUp: [String]

    public var isEmpty: Bool { steering.isEmpty && followUp.isEmpty }
}

/// A Prime thread goal still in force: the agent keeps resuming work on it until it is complete or cleared.
public struct Goal: Codable, Equatable, Sendable {
    public let objective: String
    /// `active`, `paused` or `budget_limited`.
    public let status: String
    public let tokensUsed: Int
    public let tokenBudget: Int?
    public let timeUsedSeconds: Int
    public let lastReason: String?
}

public struct SessionSummary: Codable, Identifiable, Equatable, Sendable {
    /// Tagged with its environment by the store ("<environment>:<bridge's id>"), so ids stay unique across computers.
    public internal(set) var id: String
    public let agent: AgentKind
    public let kind: SessionKind
    public internal(set) var parentId: String?
    public let name: String?
    public let depth: Int
    public let runningSubagents: Bool
    public let readOnly: Bool
    public let cwd: String
    public let title: String
    public let status: SessionStatus
    public let error: String?
    public let createdAt: Double
    public let model: ModelInfo?
    public let thinkingLevel: String?
    public let thinkingLevels: [String]
    public let context: ContextUsage?
    public let cost: Double
    public let queue: Queue
    public let autoCompaction: Bool
    /// A context window chosen for this session, below the model's. `context` already reports against it.
    public let contextLimit: Int?
    /// The window the session keeps to until it picks its own, when the model's full window costs more past it.
    public let standardWindow: Int?
    /// Background commands still running (Prime's REPL `bash()`, Pi's background-jobs extension). They wake the agent
    /// when they finish.
    public let backgroundJobs: Int
    /// The longest-running of them, usually what the session is waiting for.
    public let waitingOn: WaitingOn?
    /// Its tool call or a background command, when one looks stuck.
    public let stuck: Stuck?
    /// When a subagent last did anything or was sent anything (epoch ms).
    public let lastActiveAt: Double?
    public let goal: Goal?

    public var isSubagent: Bool { kind == .subagent }
    /// A subagent left fully idle for five minutes, nothing waiting for it: taken to be gone, since Prime keeps
    /// finished subagents alive. It shows again as soon as it does anything.
    public func isDormant(at now: Date) -> Bool {
        guard isSubagent, !isActive, !runningSubagents, queue.isEmpty else { return false }
        return now.timeIntervalSince1970 * 1000 - (lastActiveAt ?? createdAt) > 5 * 60 * 1000
    }
    /// Working, or idle with background jobs that will wake it: not finished either way.
    public var isActive: Bool { status.isBusy || backgroundJobs > 0 }
    public var folderName: String { (cwd as NSString).lastPathComponent }
}

/// The background command a session is waiting on.
public struct WaitingOn: Codable, Equatable, Sendable {
    public let command: String
    /// Epoch milliseconds.
    public let startedAt: Double?
}

/// A tool call or background command that stood still long enough to look stuck, and why: macOS's permission
/// prompt, or the verdict of the model the bridge asks when it has an OpenAI key for it.
public struct Stuck: Codable, Equatable, Sendable {
    /// "tool": the agent's current tool call. "command": a background command.
    public let kind: String
    public let command: String
    /// One sentence: "macOS is probably asking for permission to read Documents…".
    public let reason: String
    /// How likely the model judged it stuck, 0 to 1; none when the bridge recognised the permission prompt itself.
    public let probability: Double?
    /// The background command, for cancelling it.
    public let jobId: String?
    /// Epoch milliseconds.
    public let startedAt: Double?

    public var isToolCall: Bool { kind == "tool" }
}

/// A shell command an agent left running in the background, as its own TUI lists it.
public struct BackgroundJob: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let pid: Int?
    /// Epoch milliseconds.
    public let startedAt: Double?
    public let durationMs: Double?
    /// running, finished, or lost (the agent stopped without recording the exit).
    public let status: String
    /// Negative for a signal: -15 is a cancelled command.
    public let exitCode: Int?
    /// Prime's persistent shells.
    public let persistent: Bool
    /// Why it looks stuck, when it does.
    public let stuck: String?

    public var isRunning: Bool { status == "running" }
    public var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// A folder on the bridge's machine, for choosing a working directory.
public struct DirListing: Decodable, Sendable {
    public struct Entry: Decodable, Identifiable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let git: Bool
        /// The checked-out branch, for repositories.
        public let branch: String?
        public let modified: Double?
        public var id: String { path }
    }

    public let path: String
    public let parent: String?
    public let home: String
    public let git: Bool
    public let entries: [Entry]
}

/// A page of the items before the ones a client has.
public struct EarlierItems: Decodable, Sendable {
    public let items: [Item]
    /// Older items still left out.
    public let earlier: Int
}

/// Messages pushed by the bridge (replies are handled by `BridgeClient`).
public enum ServerMessage: Sendable {
    case sessions([SessionSummary])
    case session(SessionSummary)
    case sessionRemoved(String)
    /// `earlier`: older items left out, to fetch with `load_earlier`.
    case snapshot(sessionId: String, items: [Item], earlier: Int)
    case itemAdd(sessionId: String, item: Item)
    case itemPatch(sessionId: String, itemId: String, set: ItemSet?, append: ItemAppend?)
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, session, sessionId, items, earlier, item, itemId, set, append
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "sessions": self = .sessions(try c.decode([SessionSummary].self, forKey: .sessions))
        case "session": self = .session(try c.decode(SessionSummary.self, forKey: .session))
        case "session_removed": self = .sessionRemoved(try c.decode(String.self, forKey: .sessionId))
        case "snapshot":
            self = .snapshot(sessionId: try c.decode(String.self, forKey: .sessionId), items: try c.decode([Item].self, forKey: .items),
                             earlier: try c.decodeIfPresent(Int.self, forKey: .earlier) ?? 0)
        case "item_add":
            self = .itemAdd(sessionId: try c.decode(String.self, forKey: .sessionId), item: try c.decode(Item.self, forKey: .item))
        case "item_patch":
            self = .itemPatch(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId),
                set: try c.decodeIfPresent(ItemSet.self, forKey: .set),
                append: try c.decodeIfPresent(ItemAppend.self, forKey: .append)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message type \(other)")
        }
    }
}
