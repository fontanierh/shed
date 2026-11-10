// App state: the computers Shed controls, their session trees, the selected session's live transcript, and the
// actions on it.
import Foundation
import Observation

/// A computer running the bridge: this Mac, or another one reached over Tailscale.
public struct BridgeEnvironment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var token: String

    public init(id: String = BridgeEnvironment.newId(), name: String, url: String, token: String) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
    }

    public static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// The bridge on this machine, whose token Shed can read from its config.
    public var isLocal: Bool {
        let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// "jims-macbook-pro" from "wss://jims-macbook-pro.tail362838.ts.net:7878/ws".
    public static func name(for url: String) -> String {
        let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host.split(separator: ".").first.map(String.init) ?? "Computer"
    }
}

/// A site and the session serving it, for the list of every site.
public struct SiteEntry: Identifiable, Equatable {
    public let site: Site
    public let session: SessionSummary
    /// Whether its address opens on this device: it is on the tailnet, or this computer serves it. Unpublished, the
    /// address is the loopback of the computer that serves it.
    public let opens: Bool

    public var id: String { "\(session.id)#\(site.port)" }
}

public struct SessionNode: Identifiable {
    public let session: SessionSummary
    public let children: [SessionNode]?
    public var id: String { session.id }
}

/// The text of replies streaming in, ahead of the store's `items`. Only the view showing a reply reads it, so text
/// arriving redraws that reply alone instead of revisiting every block of the transcript a dozen times a second.
@MainActor
@Observable
public final class LiveText {
    /// By item id: the reply's text so far, while it is newer than the one in `items`.
    public fileprivate(set) var texts: [String: String] = [:]
}

@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [String: SessionSummary] = [:]
    /// Full session lists received, one per (re)connection: totals may have been recounted since the last one.
    public private(set) var snapshots = 0
    public private(set) var selectedId: String?
    public private(set) var items: [Item] = []
    /// Older items of the open session not loaded yet (its history before the last compaction).
    public private(set) var earlier = 0
    public private(set) var loadingEarlier = false
    /// Messages sent but not yet back from the agent, per session: shown at once, as sending, until the agent's own
    /// copy arrives.
    public private(set) var sending: [String: [Item]] = [:]
    /// The session whose transcript has arrived since it was opened. Until then an empty transcript means nothing yet,
    /// not an empty conversation.
    private var loadedId: String?
    public var transcriptLoaded: Bool { selectedId != nil && loadedId == selectedId }
    /// The open session's transcript with its messages still on their way.
    public var transcript: [Item] { items + (selectedId.flatMap { sending[$0] } ?? []) }
    public private(set) var environments: [BridgeEnvironment] = []
    /// Each environment's connection to its bridge.
    public private(set) var connections: [String: BridgeClient.State] = [:]
    public private(set) var models: [ModelInfo] = []
    public var errorMessage: String?
    /// Subagents the bridge still lists but that can't be opened any more, found out by trying. They leave the
    /// lists, and what mentions them in a conversation stops leading anywhere.
    public private(set) var ended: Set<String> = []
    /// Unsent composer text per session, kept while switching between sessions and across launches.
    public private(set) var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]

    public func setDraft(_ text: String, for id: String) {
        // The Mac's text field writes its text back on every update. Writing the same draft would still count as a
        // change, redraw the composer, and get written back again, every frame.
        let draft = text.isEmpty ? nil : text
        guard drafts[id] != draft else { return }
        drafts[id] = draft
        UserDefaults.standard.set(drafts, forKey: "drafts")
    }

    /// Moves on every half minute, so subagents left idle drop out of the lists.
    public private(set) var clock = Date.now

    @ObservationIgnored private var clients: [String: BridgeClient] = [:]
    @ObservationIgnored private var itemIndex: [String: Int] = [:]
    /// Streamed changes not yet in `items`: applying each piece as it comes redraws the transcript dozens of times a second.
    @ObservationIgnored private var patched: [Int: Item] = [:]
    /// Where a reply already on screen grows while it streams; `items` catches up on transcript or state changes.
    public let live = LiveText()
    @ObservationIgnored private var flushing: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "environments"),
           let saved = try? JSONDecoder().decode([BridgeEnvironment].self, from: data) {
            environments = saved
        } else {
            migrate()
        }
    }

    /// From the single bridge Shed used to know: it becomes the first environment, and on the Mac this Mac's own bridge
    /// is always there. Drafts were keyed by bare session ids; they belong to that first environment.
    private func migrate() {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: "bridgeURL").map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let token = defaults.string(forKey: "bridgeToken") ?? ""
        var found: [BridgeEnvironment] = []
        #if os(macOS)
        found.append(BridgeEnvironment(name: "This Mac", url: "ws://127.0.0.1:7878/ws", token: ""))
        #endif
        if !url.isEmpty, !token.isEmpty {
            let old = BridgeEnvironment(name: BridgeEnvironment.name(for: url), url: url, token: token)
            if !old.isLocal || found.isEmpty { found.append(old) }
        }
        environments = found
        saveEnvironments()
        if let first = found.first {
            drafts = Dictionary(uniqueKeysWithValues: drafts.map { (Self.split($0.key) == nil ? Self.tag(first.id, $0.key) : $0.key, $0.value) })
            defaults.set(drafts, forKey: "drafts")
        }
    }

    private func saveEnvironments() {
        UserDefaults.standard.set(try? JSONEncoder().encode(environments), forKey: "environments")
    }

    // MARK: Session ids

    /// Session ids carry their environment: "<environment>:<the bridge's id>".
    static func tag(_ env: String, _ id: String) -> String { "\(env):\(id)" }

    static func split(_ id: String) -> (env: String, raw: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    private func tagged(_ summary: SessionSummary, _ env: String) -> SessionSummary {
        var summary = summary
        summary.id = Self.tag(env, summary.id)
        summary.parentId = summary.parentId.map { Self.tag(env, $0) }
        return summary
    }

    /// The environment a session runs in.
    public func environment(of sessionId: String) -> BridgeEnvironment? {
        Self.split(sessionId).flatMap { split in environments.first { $0.id == split.env } }
    }

    // MARK: Connection

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
        if let id = UserDefaults.standard.string(forKey: "select") { select(id) }
    }

    /// The selected session's connection; with none selected, the best of them all.
    public var connection: BridgeClient.State {
        if let env = selectedId.flatMap(Self.split)?.env { return connection(of: env) }
        let states = environments.map { connection(of: $0.id) }
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        return states.first ?? .disconnected("No computers added")
    }

    public func connection(of env: String) -> BridgeClient.State { connections[env] ?? .disconnected(nil) }

    /// Where a session's transcript loads embedded media from: its own computer.
    public func media(for sessionId: String) -> MediaSource {
        guard let env = environment(of: sessionId) else { return MediaSource(bridgeURL: "", token: "") }
        return MediaSource(bridgeURL: env.url, token: token(of: env), cwd: sessions[sessionId]?.cwd ?? "")
    }

    private func token(of env: BridgeEnvironment, fresh: Bool = false) -> String {
        #if os(macOS)
        // This Mac's own bridge: its token, from its config. Read again on each connection, so it never goes stale,
        // and kept in between: media links ask for it on every update of the conversation.
        if env.token.isEmpty, env.isLocal {
            if fresh || localToken == nil { localToken = Self.localBridgeToken() }
            if let localToken { return localToken }
        }
        #endif
        return env.token
    }

    #if os(macOS)
    @ObservationIgnored private var localToken: String?
    #endif

    /// Every environment, connected afresh.
    public func connect() {
        for env in environments { connect(env.id) }
    }

    public func connect(_ envId: String) {
        guard let env = environments.first(where: { $0.id == envId }) else { return }
        let client = clients[env.id] ?? makeClient(env.id)
        guard var components = URLComponents(string: env.url.trimmingCharacters(in: .whitespaces)), components.host != nil else {
            connections[env.id] = .disconnected("Invalid bridge URL")
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token(of: env, fresh: true))]
        guard let url = components.url else { return }
        client.connect(to: url)
    }

    private func makeClient(_ env: String) -> BridgeClient {
        let client = BridgeClient()
        client.onMessage = { [weak self] in self?.apply($0, from: env) }
        client.onState = { [weak self] state in self?.connectionChanged(state, env) }
        clients[env] = client
        return client
    }

    // MARK: Environments

    /// Adds an environment, or updates one already there, and (re)connects it.
    public func save(_ env: BridgeEnvironment) {
        var env = env
        env.name = env.name.trimmingCharacters(in: .whitespacesAndNewlines)
        env.url = env.url.trimmingCharacters(in: .whitespacesAndNewlines)
        env.token = env.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if env.name.isEmpty { env.name = BridgeEnvironment.name(for: env.url) }
        if let index = environments.firstIndex(where: { $0.id == env.id }) {
            environments[index] = env
        } else {
            environments.append(env)
        }
        saveEnvironments()
        connect(env.id)
    }

    public func remove(_ envId: String) {
        let client = clients.removeValue(forKey: envId)
        client?.onState = { _ in }
        client?.onMessage = { _ in }
        client?.disconnect()
        connections[envId] = nil
        environments.removeAll { $0.id == envId }
        saveEnvironments()
        if let selectedId, Self.split(selectedId)?.env == envId { select(nil) }
        sessions = sessions.filter { Self.split($0.key)?.env != envId }
    }

    public func moveEnvironments(from source: IndexSet, to destination: Int) {
        environments.move(fromOffsets: source, toOffset: destination)
        saveEnvironments()
    }

    #if os(macOS)
    private static func localBridgeToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agent-remote/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["token"] as? String
    }
    #endif

    private func connectionChanged(_ state: BridgeClient.State, _ env: String) {
        connections[env] = state
        if state == .connected, let selectedId, Self.split(selectedId)?.env == env {
            Task { await attach(selectedId) }
        }
    }

    // MARK: Session tree

    public var selected: SessionSummary? { selectedId.flatMap { sessions[$0] } }

    /// The session tree of one environment, or of all of them.
    public func tree(in env: String?) -> [SessionNode] {
        let roots = sessions.values.filter { s in
            (env == nil || Self.split(s.id)?.env == env) && (s.parentId.map { sessions[$0] == nil } ?? true)
        }
        return roots.sorted { $0.createdAt > $1.createdAt }.map(node)
    }

    private func node(_ session: SessionSummary) -> SessionNode {
        let kids = children(of: session.id).map(node)
        return SessionNode(session: session, children: kids.isEmpty ? nil : kids)
    }

    /// This session's subagents, leaving out the ones long idle or ended (unless one is open).
    public func children(of id: String) -> [SessionSummary] {
        allChildren(of: id).filter { (!$0.isDormant(at: clock) && !ended.contains($0.id)) || $0.id == selectedId }
    }

    /// This session's subagents that have ended: still named, no longer somewhere to go.
    public func endedChildren(of id: String) -> [SessionSummary] {
        allChildren(of: id).filter { ended.contains($0.id) && $0.id != selectedId }
    }

    private func allChildren(of id: String) -> [SessionSummary] {
        sessions.values.filter { $0.parentId == id }.sorted { $0.createdAt < $1.createdAt }
    }

    public func parent(of session: SessionSummary) -> SessionSummary? {
        session.parentId.flatMap { sessions[$0] }
    }

    /// Every subagent still at work (running, or idle with background jobs), across all sessions.
    public var activeSubagents: [SessionSummary] {
        sessions.values.filter { $0.isSubagent && $0.isActive && !ended.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The sites a session serves.
    public func sites(of session: SessionSummary) -> [SiteEntry] {
        let local = environment(of: session.id)?.isLocal == true
        return session.servedSites.map { SiteEntry(site: $0, session: session, opens: $0.published || local) }
    }

    /// Every site any session serves, newest session first, so the app can list them all in one place.
    public var allSites: [SiteEntry] {
        sessions.values
            .flatMap { sites(of: $0) }
            .sorted { a, b in
                if a.session.createdAt != b.session.createdAt { return a.session.createdAt > b.session.createdAt }
                return a.site.port < b.site.port
            }
    }

    /// Subagents below this session (any depth) still at work. Prime parents keep going while these run.
    public func activeDescendants(of id: String) -> Int {
        children(of: id).reduce(0) { $0 + ($1.isActive ? 1 : 0) + activeDescendants(of: $1.id) }
    }

    /// The subagent a conversation mentions by its name, as child notes do (`child:<name>`). A session may give the
    /// same name to one subagent after another: the mention's time tells which. `spawning` is the call that started
    /// it, so the subagent is the first to come after; anything else (a report, an exit) comes from one that was
    /// already there.
    private func child(of id: String, named name: String, near date: Date?, spawning: Bool) -> SessionSummary? {
        let named = allChildren(of: id).filter { $0.name == name }
        guard let at = date.map({ $0.timeIntervalSince1970 * 1000 }) else { return named.last }
        // The agent's clock and the bridge's stamps are a moment apart.
        let slack = 2000.0
        return spawning ? named.first { $0.createdAt >= at - slack } ?? named.last
                        : named.last { $0.createdAt <= at + slack } ?? named.first
    }

    /// Where a mention of a subagent leads.
    public func link(of id: String, to mention: SubagentMention) -> SubagentLink {
        guard let child = child(of: id, named: mention.name, near: mention.date, spawning: mention.spawning) else {
            // Just mentioned: the bridge may not have listed it yet.
            let recent = mention.date.map { clock.timeIntervalSince($0) < 30 } ?? false
            return mention.running || recent ? .pending : .ended
        }
        return ended.contains(child.id) ? .ended : .open(child.id)
    }

    public func select(_ id: String?) {
        // An id from before Shed knew several computers (a Live Activity's link): the first one's.
        let id = id.map { Self.split($0) == nil && !environments.isEmpty ? Self.tag(environments[0].id, $0) : $0 }
        guard id != selectedId else { return }
        if let old = selectedId, let (env, raw) = Self.split(old), let client = clients[env] {
            Task { try? await client.call("detach", ["sessionId": raw]) }
        }
        flushing?.cancel()
        flushing = nil
        selectedId = id
        loadedId = nil
        patched = [:]
        live.texts = [:]
        items = []
        itemIndex = [:]
        earlier = 0
        models = []
        if let id { Task { await attach(id) } }
    }

    private func attach(_ id: String) async {
        do {
            guard let (env, raw) = Self.split(id) else { return }
            try await call(env, "attach", ["sessionId": raw], repeatable: true)
        } catch {
            await attachFailed(id, error)
        }
    }

    func attachFailed(_ id: String, _ error: Error) async {
        // The session ended while the app was away (e.g. the one it reopens at launch): just leave it.
        if sessions[id] == nil {
            if selectedId == id { select(nil) }
            return
        }
        // A subagent its agent has let go of, which is the one thing the bridge answers with these words. It may
        // list it a while longer, but there is nothing to open: no alert, its screen says so for a moment, then
        // gives way to its parent. Any other failure (a bridge out of reach) says nothing about the subagent.
        if (error as? BridgeError)?.message == "session ended", let parent = sessions[id]?.parentId {
            ended.insert(id)
            try? await Task.sleep(for: .milliseconds(1400))
            if selectedId == id { select(sessions[parent] == nil ? nil : parent) }
            return
        }
        report(error)
    }

    // MARK: Incoming messages

    func apply(_ message: ServerMessage, from env: String) {
        switch message {
        case .sessions(let list):
            var all = sessions.filter { Self.split($0.key)?.env != env }
            for summary in list.map({ replayed(tagged($0, env)) }) { all[summary.id] = summary }
            if let selectedId, sessions[selectedId]?.status != all[selectedId]?.status { flush() }
            sessions = all
            snapshots += 1
            ended.formIntersection(all.keys)
            if let selectedId, sessions[selectedId] == nil, Self.split(selectedId)?.env == env { select(nil) }
        case .session(let summary):
            let summary = replayed(tagged(summary, env))
            // Summary traffic must not commit streamed text; only a state change can stop the reply reading `live`.
            if summary.id == selectedId, sessions[summary.id]?.status != summary.status { flush() }
            // An ended subagent that does something again is back.
            if ended.contains(summary.id), summary.status.isBusy || (summary.lastActiveAt ?? 0) > (sessions[summary.id]?.lastActiveAt ?? 0) {
                ended.remove(summary.id)
            }
            sessions[summary.id] = summary
        case .sessionRemoved(let id):
            let id = Self.tag(env, id)
            // An open subagent that goes gives way to its parent, as when its agent lets go of it.
            let parent = sessions[id]?.parentId.flatMap { sessions[$0] == nil ? nil : $0 }
            sessions[id] = nil
            ended.remove(id)
            if selectedId == id { select(parent) }
        case .snapshot(let raw, var snapshot, let earlier):
            let sessionId = Self.tag(env, raw)
            guard sessionId == selectedId else { return }
            let held = holdForReplay(&snapshot, of: sessionId)
            defer { if !held.isEmpty { replay(held, of: raw, in: env) } }
            loadedId = sessionId
            ended.remove(sessionId)
            self.earlier = earlier
            flushing?.cancel()
            flushing = nil
            patched = [:]
            live.texts = [:]
            items = snapshot
            itemIndex = Dictionary(uniqueKeysWithValues: snapshot.enumerated().map { ($1.id, $0) })
            for item in snapshot.suffix(20) where item.kind == .user { arrived(item.text, in: sessionId) }
        case .itemAdd(let sessionId, let item):
            let sessionId = Self.tag(env, sessionId)
            guard sessionId == selectedId, itemIndex[item.id] == nil else { return }
            flush()
            // The agent's copy of a message on its way: it takes the sending one's place in the same update.
            if item.kind == .user { arrived(item.text, in: sessionId) }
            itemIndex[item.id] = items.count
            items.append(item)
        case .itemPatch(let sessionId, let itemId, let set, let append):
            let sessionId = Self.tag(env, sessionId)
            guard sessionId == selectedId, let index = itemIndex[itemId] else { return }
            var item = patched[index] ?? items[index]
            set?.apply(to: &item)
            if let text = append?.text { item.text += text }
            if let args = append?.args { item.args = (item.args ?? "") + args }
            patched[index] = item
            // A change of state (a tool finishing, a reply ending) shows at once; streamed text a few times a second.
            // Keep one deadline through the burst. Replacing it on each delta would starve a fast stream.
            if set != nil { flush() } else if flushing == nil {
                flushing = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.flush(streamed: true)
                }
            }
        }
    }

    /// Applies the changes held back. `streamed`: only text has arrived since the last time, so a reply already on
    /// screen just grows, in `live`, and stays held back here until a transcript or state change.
    private func flush(streamed: Bool = false) {
        flushing?.cancel()
        flushing = nil
        guard !patched.isEmpty else { return }
        var changes = patched
        if streamed {
            var texts = live.texts
            for (index, item) in changes where index < items.count && item.kind == .text && !items[index].text.isEmpty {
                texts[item.id] = item.text
                changes[index] = nil
            }
            if texts != live.texts { live.texts = texts }
        }
        patched = patched.filter { changes[$0.key] == nil }
        guard !changes.isEmpty else { return }
        var all = items
        for (index, item) in changes where index < all.count { all[index] = item }
        items = all
        if changes.values.contains(where: { live.texts[$0.id] != nil }) {
            live.texts = live.texts.filter { id, _ in !changes.values.contains { $0.id == id } }
        }
    }

    // MARK: Replay, for measuring the conversation while it streams

    /// `-replay YES` (and `-replayCount N`, 30 by default): each session opened holds its last items back and streams
    /// them in again, through the same deltas the bridge sends, as if the agent were writing them now. Nothing is sent
    /// to the agent: it's for measuring a streaming conversation in the simulator.
    @ObservationIgnored private static let replays = UserDefaults.standard.bool(forKey: "replay")
    @ObservationIgnored private var replaying: String?
    @ObservationIgnored private var replayedIds: Set<String> = []

    private func holdForReplay(_ snapshot: inout [Item], of sessionId: String) -> [Item] {
        guard Self.replays, !replayedIds.contains(sessionId), replaying == nil else { return [] }
        replayedIds.insert(sessionId)
        let count = UserDefaults.standard.integer(forKey: "replayCount")
        let held = Array(snapshot.suffix(count > 0 ? count : 30))
        snapshot.removeLast(held.count)
        return held
    }

    /// While a session replays it shows as running, whatever the bridge says.
    private func replayed(_ summary: SessionSummary) -> SessionSummary {
        guard replaying == summary.id, summary.status != .running,
              var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))) as? [String: Any]
        else { return summary }
        json["status"] = SessionStatus.running.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let running = try? JSONDecoder().decode(SessionSummary.self, from: data) else { return summary }
        return running
    }

    private func replay(_ held: [Item], of raw: String, in env: String) {
        let sessionId = Self.tag(env, raw)
        replaying = sessionId
        if let summary = sessions[sessionId] { sessions[sessionId] = replayed(summary) }
        Task { @MainActor [weak self] in
            /// About what a model streams: a few characters every 25 ms.
            @MainActor func stream(_ text: String?, _ itemId: String, args: Bool) async {
                var rest = Substring(text ?? "")
                while !rest.isEmpty {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard let self, self.selectedId == sessionId else { return }
                    let chunk = String(rest.prefix(Int.random(in: 4...12)))
                    rest = rest.dropFirst(chunk.count)
                    let append = args ? ItemAppend(text: nil, args: chunk) : ItemAppend(text: chunk, args: nil)
                    self.apply(.itemPatch(sessionId: raw, itemId: itemId, set: nil, append: append), from: env)
                }
            }
            for item in held {
                guard let self, self.selectedId == sessionId else { break }
                if item.kind == .user {
                    try? await Task.sleep(for: .milliseconds(400))
                    self.apply(.itemAdd(sessionId: raw, item: item), from: env)
                    continue
                }
                var start = item
                start.text = ""
                if item.kind == .tool { start.args = ""; start.output = nil; start.status = .running; start.durationMs = nil }
                self.apply(.itemAdd(sessionId: raw, item: start), from: env)
                await stream(item.text, item.id, args: false)
                if item.kind == .tool {
                    await stream(item.args, item.id, args: true)
                    try? await Task.sleep(for: .milliseconds(300))
                    let done = ItemSet(output: item.output, status: item.status ?? .done, durationMs: item.durationMs)
                    self.apply(.itemPatch(sessionId: raw, itemId: item.id, set: done, append: nil), from: env)
                }
            }
            guard let self, self.replaying == sessionId else { return }
            self.replaying = nil
            self.connect(env)
        }
    }

    /// The page of history before the first loaded item.
    public func loadEarlier() async {
        flush()
        guard let id = selectedId, let (env, raw) = Self.split(id), let client = clients[env],
              let first = items.first, earlier > 0, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await client.call("load_earlier", ["sessionId": raw, "before": first.id], as: EarlierItems.self)
            // A snapshot may have replaced the transcript meanwhile.
            guard selectedId == id, items.first?.id == first.id else { return }
            let older = page.items.filter { itemIndex[$0.id] == nil }
            flush()
            items = older + items
            itemIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
            earlier = page.earlier
        } catch {
            report(error)
        }
    }

    // MARK: Actions

    private func report(_ error: Error) {
        // A dropped connection shows as the connection state, and the client is already reconnecting.
        if error is ConnectionLost || (error as NSError).domain == NSPOSIXErrorDomain { return }
        errorMessage = error.localizedDescription
    }

    /// Back from the background: replace a socket iOS killed meanwhile.
    public func resumed() {
        for env in environments {
            if case .disconnected = connection(of: env.id) { connect(env.id) } else { clients[env.id]?.checkAlive() }
        }
    }

    /// Waits for an environment's bridge connection to come back, up to `timeout`.
    private func reconnected(_ env: String, timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while connection(of: env) != .connected {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// `op`, sent again once the connection is back if a drop cut it off: when it can't have arrived, or when
    /// doing it twice is harmless.
    private func call(_ env: String, _ op: String, _ payload: [String: Any], repeatable: Bool) async throws {
        do {
            try await client(env).call(op, payload)
        } catch let lost as ConnectionLost where !lost.maybeDelivered || repeatable {
            guard await reconnected(env) else { throw lost }
            try await client(env).call(op, payload)
        }
    }

    private func client(_ env: String) throws -> BridgeClient {
        guard let client = clients[env] else { throw BridgeError("That computer is no longer in Shed") }
        return client
    }

    /// The client a session's ops go to, and the id its bridge knows it by.
    private func route(_ sessionId: String) throws -> (client: BridgeClient, env: String, raw: String) {
        guard let (env, raw) = Self.split(sessionId) else { throw BridgeError("Unknown session") }
        return (try client(env), env, raw)
    }

    private static let repeatable: Set<String> = [
        "abort", "stop_tool", "set_thinking", "set_auto_compaction", "set_context_limit", "set_model", "resume_session", "close_session", "clear_goal",
    ]

    private func perform(_ op: String, _ fields: [String: Any] = [:]) {
        guard let id = selectedId, let (env, raw) = Self.split(id) else { return }
        var payload = fields
        payload["sessionId"] = raw
        Task {
            do { try await call(env, op, payload, repeatable: Self.repeatable.contains(op)) } catch { report(error) }
        }
    }

    /// Throws to the sheet that asked, which shows why: an alert behind a sheet never appears on the Mac.
    public func createSession(in env: String, agent: AgentKind, cwd: String, model: String?, thinking: String?, firstMessage: String? = nil) async throws {
        var fields: [String: Any] = ["agent": agent.rawValue, "cwd": cwd]
        if let model, !model.isEmpty { fields["model"] = model }
        if let thinking, !thinking.isEmpty { fields["thinking"] = thinking }
        let client = try client(env)
        let created = try await client.call("create_session", fields, as: SessionSummary.self)
        let summary = tagged(created, env)
        sessions[summary.id] = summary
        select(summary.id)
        if let firstMessage, !firstMessage.isEmpty {
            do { try await client.call("send", ["sessionId": created.id, "text": firstMessage]) } catch { report(error) }
        }
    }

    /// Prompt when idle; the bridge turns it into a steer while the agent is working.
    public func send(_ text: String) {
        guard let id = selectedId, let (env, raw) = Self.split(id) else { return }
        // While it works the message waits in its queue (shown above the composer), not in the conversation.
        let busy = sessions[id]?.status.isBusy ?? false
        let local = Item(id: "sending-\(UUID().uuidString)", kind: .user, text: text, status: .pending, at: Date.now.timeIntervalSince1970 * 1000)
        if !busy { sending[id, default: []].append(local) }
        Task {
            do {
                do {
                    try await client(env).call("send", ["sessionId": raw, "text": text])
                } catch let lost as ConnectionLost {
                    // Cut off by a dropped connection: send it again once back, unless the session's transcript, sent
                    // afresh on reconnecting, shows it arrived after all.
                    guard await reconnected(env) else { throw lost }
                    if lost.maybeDelivered {
                        try? await Task.sleep(for: .seconds(2))
                        let queued = sessions[id]?.queue
                        let landed = busy ? (queued?.steering.contains(text) == true || queued?.followUp.contains(text) == true)
                                          : sending[id]?.contains { $0.id == local.id } != true
                        if landed { return }
                    }
                    try await client(env).call("send", ["sessionId": raw, "text": text])
                }
                // Never echoed (it went to the queue after all): don't leave it sending forever.
                try? await Task.sleep(for: .seconds(60))
                sending[id]?.removeAll { $0.id == local.id }
            } catch {
                sending[id]?.removeAll { $0.id == local.id }
                if drafts[id, default: ""].isEmpty { setDraft(text, for: id) }
                report(error)
            }
        }
    }

    private func arrived(_ text: String, in sessionId: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = sending[sessionId]?.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }) else { return }
        sending[sessionId]?.remove(at: index)
    }
    public func followUp(_ text: String) { perform("follow_up", ["text": text]) }
    public func abort() { perform("abort") }
    /// Stops a stuck tool call and delivers what was queued behind it.
    public func stopTool() { perform("stop_tool") }
    /// Kills the session's Python kernel, for one stuck past what Stop can interrupt; Prime starts a fresh one.
    public func restartKernel() { perform("restart_kernel") }
    public func compact() { perform("compact") }
    public func newSession() { perform("new_session") }
    public func clearGoal() { perform("clear_goal") }
    public func setThinking(_ level: String) { perform("set_thinking", ["level": level]) }
    public func setAutoCompaction(_ enabled: Bool) { perform("set_auto_compaction", ["enabled": enabled]) }
    /// `nil` goes back to the model's own window.
    public func setContextLimit(_ limit: Int?) { perform("set_context_limit", ["limit": limit.map { $0 as Any } ?? NSNull()]) }

    public func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let to = try route(id)
                try await to.client.call("rename_session", ["sessionId": to.raw, "name": name])
            } catch { report(error) }
        }
    }
    public func setModel(_ model: ModelInfo) { perform("set_model", ["provider": model.provider, "modelId": model.id]) }
    public func resume() { perform("resume_session") }
    public func close() { perform("close_session") }

    public func delete(_ id: String) {
        Task {
            do {
                let to = try route(id)
                try await to.client.call("delete_session", ["sessionId": to.raw])
            } catch { report(error) }
        }
    }

    /// The models `agent` has set up on that computer, as "provider/id"; empty when its bridge can't tell.
    public func agentModels(in env: String, _ agent: AgentKind) async throws -> [String] {
        struct Listed: Decodable {
            struct Model: Decodable { let provider: String; let id: String }
            let models: [Model]
        }
        let listed = try await client(env).call("list_agent_models", ["agent": agent.rawValue], as: Listed.self)
        return listed.models.map { "\($0.provider)/\($0.id)" }
    }

    /// Folders on an environment's computer; nil path means the home folder.
    public func listDir(in env: String, _ path: String?, hidden: Bool = false) async throws -> DirListing {
        var fields: [String: Any] = ["hidden": hidden]
        if let path { fields["path"] = path }
        return try await client(env).call("list_dir", fields, as: DirListing.self)
    }

    /// The GitHub account signed in with `gh` on that computer: contributions and open pull requests.
    public func githubOverview(in env: String) async throws -> GitHubOverview {
        try await client(env).call("github_overview", [:], as: GitHubOverview.self)
    }

    /// The branch of the repository `folder` is in on that computer, read with its `git`. Nil when it is detached or in
    /// no repository.
    public func gitBranch(in env: String, of folder: String) async throws -> String? {
        struct Reply: Decodable { let branch: String? }
        return try await client(env).call("git_branch", ["path": folder], as: Reply.self).branch
    }

    // MARK: Background commands

    public func listJobs(_ sessionId: String) async throws -> [BackgroundJob] {
        let to = try route(sessionId)
        return try await to.client.call("list_jobs", ["sessionId": to.raw], as: [BackgroundJob].self)
    }

    public func jobOutput(_ sessionId: String, _ jobId: String, lines: Int = 200) async throws -> String {
        struct Tail: Decodable { let tail: String }
        let to = try route(sessionId)
        return try await to.client.call("job_output", ["sessionId": to.raw, "jobId": jobId, "lines": lines], as: Tail.self).tail
    }

    /// Labels picked per question id; no answers dismisses the question.
    public func answerQuestion(_ sessionId: String, _ questionId: String, picked: [String: [String]]) async {
        do {
            let to = try route(sessionId)
            let answers = picked.map { ["id": $0.key, "selected": $0.value] as [String: Any] }
            _ = try await to.client.call("answer_question", ["sessionId": to.raw, "questionId": questionId, "answers": answers])
        } catch {
            report(error)
        }
    }

    public func killJob(_ sessionId: String, _ jobId: String) async {
        do {
            let to = try route(sessionId)
            _ = try await to.client.call("kill_job", ["sessionId": to.raw, "jobId": jobId])
        } catch {
            report(error)
        }
    }

    public func loadModels() async {
        guard let id = selectedId else { return }
        do {
            let to = try route(id)
            models = try await to.client.call("list_models", ["sessionId": to.raw], as: [ModelInfo].self)
        } catch {
            report(error)
        }
    }
}
