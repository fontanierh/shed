// App state: the computers Shed controls, their sessions, and the open session's live transcript. Here are the state
// itself, session ids and which session is open. The extensions in the files beside this one do the rest.
import Foundation
import Observation

/// The text of replies streaming in, ahead of the store's `items`. Only the view showing a reply reads it, so text
/// arriving redraws that reply alone instead of revisiting every block of the transcript a dozen times a second.
@MainActor
@Observable
public final class LiveText {
    /// By item id: the reply's text so far, while it is newer than the one in `items`.
    public internal(set) var texts: [String: String] = [:]
}

@MainActor
@Observable
public final class SessionStore {
    /// Everything kept for the single session currently open on screen, replaced whole when switching sessions.
    @MainActor
    @Observable
    final class OpenSession {
        let id: String
        var items: [Item] = []
        /// Older items of the open session not loaded yet (its history before the last compaction).
        var earlier = 0
        var loadingEarlier = false
        /// Whether this open session's snapshot has arrived since it was opened.
        var loaded = false
        var models: [ModelInfo] = []
        @ObservationIgnored var itemIndex: [String: Int] = [:]
        /// Streamed changes not yet in `items`: applying each piece as it comes redraws the transcript dozens of times a second.
        @ObservationIgnored var patched: [Int: Item] = [:]
        @ObservationIgnored var flushing: Task<Void, Never>?

        init(id: String) {
            self.id = id
        }
    }
    public internal(set) var sessions: [String: SessionSummary] = [:]
    /// Full session lists received, one per (re)connection: totals may have been recounted since the last one.
    public internal(set) var snapshots = 0
    var open: OpenSession?
    public var selectedId: String? { open?.id }
    public var items: [Item] { open?.items ?? [] }
    public var earlier: Int { open?.earlier ?? 0 }
    public var loadingEarlier: Bool { open?.loadingEarlier ?? false }
    public var transcriptLoaded: Bool { open?.loaded == true }
    public var models: [ModelInfo] { open?.models ?? [] }
    /// Messages sent but not yet back from the agent, per session: shown at once, as sending, until the agent's own
    /// copy arrives.
    var sending: [String: [Item]] = [:]
    /// The open session's transcript with its messages still on their way.
    public var transcript: [Item] { items + (selectedId.flatMap { sending[$0] } ?? []) }
    public internal(set) var environments: [BridgeEnvironment] = []
    /// Each environment's connection to its bridge.
    var connections: [String: BridgeClient.State] = [:]
    public var errorMessage: String?
    /// Subagents the bridge still lists but that can't be opened any more, found out by trying. They leave the
    /// lists, and what mentions them in a conversation stops leading anywhere.
    public internal(set) var ended: Set<String> = []
    /// Unsent composer text per session, kept while switching between sessions and across launches.
    public internal(set) var drafts: [String: String] = [:]

    public func setDraft(_ text: String, for id: String) {
        // The Mac's text field writes its text back on every update. Writing the same draft would still count as a
        // change, redraw the composer, and get written back again, every frame.
        let draft = text.isEmpty ? nil : text
        guard drafts[id] != draft else { return }
        drafts[id] = draft
        defaults.set(drafts, forKey: "drafts")
    }

    /// Moves on every half minute, so subagents left idle drop out of the lists.
    public private(set) var clock = Date.now

    @ObservationIgnored let defaults: UserDefaults
    /// The saved list of computers as found, when not all of it could be read. The first save of the list files it
    /// under a key of its own, so that what replaces it holds less but nothing is lost.
    @ObservationIgnored var unreadEnvironments: Data?
    @ObservationIgnored var clients: [String: any BridgeConnection] = [:]
    /// Makes the connection to a computer the first time it is connected: a `BridgeClient`, unless a test gave its own.
    @ObservationIgnored let makeConnection: @MainActor () -> any BridgeConnection
    /// Lets that long pass. The requests wait through it, so a test gives one that returns at once.
    @ObservationIgnored let pause: @MainActor (Duration) async -> Void
    /// How long a request cut off waits for its connection to come back.
    static let reconnectWait = Duration.seconds(60)
    /// What each computer's bridge says it understands. From 2 on it takes a message once per id.
    @ObservationIgnored var bridgeLevel: [String: Int] = [:]
    /// Where a reply already on screen grows while it streams; `items` catches up on transcript or state changes.
    public let live = LiveText()
    @ObservationIgnored private var started = false
    #if os(macOS)
    @ObservationIgnored var localToken: String?
    #endif
    /// For `-replay`: the session streaming in again, and the ones already replayed.
    @ObservationIgnored var replaying: String?
    @ObservationIgnored var replayedIds: Set<String> = []

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, connection: { BridgeClient() }, pause: { try? await Task.sleep(for: $0) })
    }

    init(defaults: UserDefaults, connection: @escaping @MainActor () -> any BridgeConnection,
         pause: @escaping @MainActor (Duration) async -> Void) {
        self.defaults = defaults
        makeConnection = connection
        self.pause = pause
        drafts = defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        let saved = defaults.data(forKey: "environments")
        if let read = Self.readEnvironments(saved) {
            environments = read.environments
            if !read.complete {
                unreadEnvironments = saved
                errorMessage = "Some of the computers saved in Shed could not be read, and are not listed. What was saved has been kept."
            }
        } else {
            migrate()
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        connect()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.clock = .now
            }
        }
        // `open -a Shed --args -select <session id>` opens a session directly (untagged: in the first environment).
        if let id = defaults.string(forKey: "select") { select(id) }
    }

    // MARK: Session ids

    /// Session ids carry their environment: "<environment>:<the bridge's id>".
    static func tag(_ env: String, _ id: String) -> String { "\(env):\(id)" }

    static func split(_ id: String) -> (env: String, raw: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    func tagged(_ summary: SessionSummary, _ env: String) -> SessionSummary {
        var summary = summary
        summary.id = Self.tag(env, summary.id)
        summary.parentId = summary.parentId.map { Self.tag(env, $0) }
        return summary
    }

    public func environment(of sessionId: String) -> BridgeEnvironment? {
        Self.split(sessionId).flatMap { split in environments.first { $0.id == split.env } }
    }

    // MARK: The open session

    public var selected: SessionSummary? { selectedId.flatMap { sessions[$0] } }

    public func select(_ id: String?) {
        // An id from before Shed knew several computers (a Live Activity's link): the first one's.
        let id = id.map { Self.split($0) == nil && !environments.isEmpty ? Self.tag(environments[0].id, $0) : $0 }
        guard id != selectedId else { return }
        if let old = selectedId, let (env, raw) = Self.split(old), let client = clients[env] {
            Task { try? await client.call(.detach(sessionId: raw)) }
        }
        open?.flushing?.cancel()
        live.texts = [:]
        open = id.map(OpenSession.init)
        if let id { Task { await attach(id) } }
    }
}
