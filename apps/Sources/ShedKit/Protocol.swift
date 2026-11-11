// Wire types shared with the bridge (bridge/src/protocol.rs). ProtocolFixtureTests reads the messages the bridge's tests
// write to protocol/, so a change on one side fails the other's tests.
import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pi, prime, deepseek
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pi: "Pi"
        case .prime: "Prime"
        case .deepseek: "DeepSeek"
        }
    }
    /// Whether a session's cost already holds what its subagents spent (`spend_includes_subagents` in the bridge's
    /// agent.rs). Otherwise each subagent carries its own, and the app adds them up.
    var spendIncludesSubagents: Bool {
        switch self {
        case .prime: true
        case .pi, .deepseek: false
        }
    }
}

public enum ItemKind: String, Codable, Sendable {
    case user, text, thinking, tool, compaction, error, note
}

public enum ToolStatus: String, Codable, Sendable {
    case preparing, pending, running, done, error
    /// A state this version of the app has no name for. The bridge never sends this word.
    case unknown
}

extension ToolStatus {
    /// A bridge newer than the app may name a state the app does not know. It reads as `unknown`, so the item or
    /// the patch carrying it is kept: a patch dropped for its status would lose the tool's output with it.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct Item: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var kind: ItemKind
    public var text: String
    public var toolName: String?
    public var args: String?
    public var output: String?
    public var status: ToolStatus?
    public var durationMs: Int?
    /// When the item started, in ms since the epoch.
    public var at: Double?

    public var date: Date? { at.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

extension Item {
    static let unreadableText = "This version of Shed can't show this part of the conversation."

    /// The note that stands for an item this app cannot read, in its place. It keeps the item's id when that could
    /// be read, so what the bridge sends about the item later is recognised as being about it.
    static func unreadable(id: String?) -> Item {
        Item(id: id ?? "unreadable-\(UUID().uuidString)", kind: .note, text: unreadableText)
    }

    var isUnreadable: Bool { kind == .note && text == Self.unreadableText }
}

/// An item from the bridge, or the note standing for it: a bridge newer than the app may send a kind of item, or a
/// value in one, that the app does not know.
private struct Shown: Decodable {
    let item: Item

    private enum Keys: CodingKey { case id }

    init(from decoder: Decoder) {
        do {
            item = try Item(from: decoder)
        } catch {
            NSLog("Shed: an item from the bridge couldn't be read: %@", String(describing: error))
            item = .unreadable(id: try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .id))
        }
    }
}

/// A list of items from the bridge, each one read on its own.
struct ShownItems: Decodable {
    let items: [Item]

    init(from decoder: Decoder) throws {
        items = try decoder.singleValueContainer().decode([Shown].self).map(\.item)
    }
}

/// A conversation's mention of a subagent: a call that started it, its report, its exit.
public struct SubagentMention: Equatable, Sendable {
    public var name: String
    public var date: Date?
    /// The call that started it, rather than something it sent later.
    public var spawning = false
    /// That call still running: the subagent may not be listed yet.
    public var running = false

    public init(name: String, date: Date?, spawning: Bool = false, running: Bool = false) {
        self.name = name
        self.date = date
        self.spawning = spawning
        self.running = running
    }
}

/// Where a mention of a subagent leads: its session, nowhere yet, or nowhere any more.
public enum SubagentLink: Equatable, Sendable {
    case open(String)
    case pending
    case ended
}

public struct ItemSet: Codable, Sendable {
    public var text: String?
    public var toolName: String?
    public var args: String?
    public var output: String?
    public var status: ToolStatus?
    public var durationMs: Int?

    func apply(to item: inout Item) {
        if let text { item.text = text }
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
    /// A state this version of the app has no name for. The bridge never sends this word.
    case unknown

    public var isBusy: Bool { self == .running || self == .compacting || self == .starting }

    /// A state the app does not know reads as `unknown`, so the session is still listed and its updates still land.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
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

/// A working session's spend, measured by the bridge from Open Codex's request history. It covers the session and,
/// for a Prime session, its subagents.
public struct RunSpend: Codable, Equatable, Sendable {
    /// Dollars per minute over the last five minutes, when Open Codex prices the models. Nil until there is enough
    /// history or when nothing is priced.
    public let perMinute: Double?
    public let tokensPerMinute: Double?
    /// Dollars since the run started, when priced.
    public let runCost: Double?
}

public struct SessionSummary: Codable, Identifiable, Equatable, Sendable {
    /// Tagged with its environment by the store ("<environment>:<bridge's id>"), so ids stay unique across computers.
    public internal(set) var id: String
    public let agent: AgentKind
    public let kind: SessionKind
    public internal(set) var parentId: String?
    public let name: String?
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
    /// What the agent asks the user and waits on (DeepSeek's questions and plan review).
    public let question: AgentQuestion?
    /// What the current run costs, from Open Codex's request history, while the session works.
    public let spend: RunSpend?
    /// Web servers the session's processes are listening on. Missing from a bridge older than sites.
    public let sites: [Site]?

    public var isSubagent: Bool { kind == .subagent }
    /// Background commands come from each agent's own tools. Pi's and DeepSeek's subagents run in the parent's
    /// process, so their commands are the parent's.
    public var hasBackgroundCommands: Bool { !(agent != .prime && isSubagent) }
    /// DeepSeek Harness has no fresh conversation in the same session: a new one is started from the app.
    public var startsNewSessionInPlace: Bool { agent != .deepseek }
    /// DeepSeek Harness compacts on its own: it can compact now, but has no switch to stop it.
    public var controlsAutoCompaction: Bool { agent != .deepseek }
    /// A subagent left fully idle for five minutes, nothing waiting for it: taken to be gone, since Prime keeps
    /// finished subagents alive. It shows again as soon as it does anything.
    public func isDormant(at now: Date) -> Bool {
        guard isSubagent, !isActive, !runningSubagents, queue.isEmpty else { return false }
        return now.timeIntervalSince1970 * 1000 - (lastActiveAt ?? createdAt) > 5 * 60 * 1000
    }
    /// Working, or idle with background jobs that will wake it: not finished either way.
    public var isActive: Bool { status.isBusy || backgroundJobs > 0 }
    /// Whether the session serves a site the app can open from another device.
    public var hasSites: Bool { !servedSites.isEmpty }
    public var servedSites: [Site] { sites ?? [] }
    public var folderName: String { (cwd as NSString).lastPathComponent }
}

/// Questions the agent asks the user. Each is answered with the labels picked, or with typed text.
public struct AgentQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let questions: [Item]
    /// The agent stopped waiting and carried on, but still takes the answer.
    public let continued: Bool?

    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let question: String
        public let header: String?
        /// What it asks about at length: a plan to review.
        public let detail: String?
        public let options: [Option]?
        public let multiSelect: Bool?
    }

    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let description: String?
    }
}

/// A web server an agent started in one of its sessions, found by the port its processes listen on.
public struct Site: Codable, Identifiable, Hashable, Sendable {
    public let port: Int
    /// The page's `<title>`, when it has one.
    public let title: String?
    /// What started it, as `ps` reports it.
    public let command: String
    /// Where to open it: its tailnet address once published, else this Mac's.
    public let url: String
    /// On the tailnet, over HTTPS, so another device can open it.
    public let published: Bool
    /// Bound to every interface rather than loopback: reachable from the LAN too, not only this Mac.
    public let exposed: Bool
    /// Why it isn't published, when it isn't (a bridge from before this said nothing).
    public let reason: String?

    public var id: Int { port }
    public var name: String { title ?? command }
    /// `https://my-mac.tailnet.ts.net:8890/` → `my-mac.tailnet.ts.net:8890`.
    public var host: String {
        guard let components = URLComponents(string: url) else { return url }
        return [components.host, components.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }
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
    public let kind: StuckKind
    public let command: String
    /// One sentence: "macOS is probably asking for permission to read Documents…".
    public let reason: String
    /// How likely the model judged it stuck, 0 to 1; none when the bridge recognised the permission prompt itself.
    public let probability: Double?
    /// The background command, for cancelling it.
    public let jobId: String?
    /// Epoch milliseconds.
    public let startedAt: Double?

    public var isToolCall: Bool { kind == .tool }
}

/// What a session is stuck on: the agent's current tool call, or a background command.
public enum StuckKind: String, Codable, Sendable {
    case tool, command
    /// A kind this version of the app has no name for. The bridge never sends this word.
    case unknown
}

extension StuckKind {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Where a background command is. An agent may add a status of its own, which the bridge passes on: it reads as
/// `unknown`, and the command is still listed.
public enum JobStatus: String, Decodable, Hashable, Sendable {
    case running, finished
    /// The agent stopped without recording the exit.
    case lost
    case unknown
}

extension JobStatus {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A shell command an agent left running in the background, as its own TUI lists it.
public struct BackgroundJob: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let pid: Int?
    /// Epoch milliseconds.
    public let startedAt: Double?
    public let durationMs: Double?
    public let status: JobStatus
    /// Negative for a signal: -15 is a cancelled command.
    public let exitCode: Int?
    /// Prime's persistent shells.
    public let persistent: Bool
    /// Why it looks stuck, when it does.
    public let stuck: String?

    public var isRunning: Bool { status == .running }
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
    public let entries: [Entry]
}

/// A page of the items before the ones a client has.
public struct EarlierItems: Decodable, Sendable {
    public let items: [Item]
    /// Older items still left out.
    public let earlier: Int

    private enum CodingKeys: CodingKey { case items, earlier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode(ShownItems.self, forKey: .items).items
        earlier = try c.decode(Int.self, forKey: .earlier)
    }
}

/// Messages pushed by the bridge (replies are handled by `BridgeClient`).
public enum ServerMessage: Sendable {
    /// `bridge` is what the bridge says it understands (`BRIDGE` in the bridge's protocol.rs). One that says nothing is 1.
    case sessions([SessionSummary], bridge: Int = 1)
    case session(SessionSummary)
    case sessionRemoved(String)
    /// `earlier`: older items left out, to fetch with `load_earlier`.
    case snapshot(sessionId: String, items: [Item], earlier: Int)
    case itemAdd(sessionId: String, item: Item)
    case itemPatch(sessionId: String, itemId: String, set: ItemSet?, append: ItemAppend?)
}

/// What can be read of a list: one element the app can't decode must not hide all the others.
struct Readable<Value: Decodable>: Decodable {
    var values: [Value] = []
    var skipped = 0

    private struct Skipped: Decodable {}

    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        while !list.isAtEnd {
            do {
                values.append(try list.decode(Value.self))
            } catch {
                NSLog("Shed: a %@ in a list couldn't be read: %@", String(describing: Value.self), String(describing: error))
                // A failed decode leaves the list where it was: step over the element.
                _ = try list.decode(Skipped.self)
                skipped += 1
            }
        }
    }
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, bridge, session, sessionId, items, earlier, item, itemId, set, append
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        // A session of an agent the app does not know is left out of the list, and an update to one is dropped with
        // a line in the log: the app has no way to draw or drive it. A status it does not know reads as `unknown`.
        case "sessions":
            self = .sessions(try c.decode(Readable<SessionSummary>.self, forKey: .sessions).values,
                             bridge: (try? c.decode(Int.self, forKey: .bridge)) ?? 1)
        case "session": self = .session(try c.decode(SessionSummary.self, forKey: .session))
        case "session_removed": self = .sessionRemoved(try c.decode(String.self, forKey: .sessionId))
        case "snapshot":
            self = .snapshot(sessionId: try c.decode(String.self, forKey: .sessionId),
                             items: try c.decode(ShownItems.self, forKey: .items).items,
                             earlier: try c.decodeIfPresent(Int.self, forKey: .earlier) ?? 0)
        case "item_add":
            self = .itemAdd(sessionId: try c.decode(String.self, forKey: .sessionId),
                            item: (try? c.decode(Shown.self, forKey: .item))?.item ?? .unreadable(id: nil))
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
