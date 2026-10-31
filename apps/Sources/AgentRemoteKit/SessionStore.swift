// App state: the session tree, the selected session's live transcript, and the actions on it.
import Foundation
import Observation

public struct SessionNode: Identifiable {
    public let session: SessionSummary
    public let children: [SessionNode]?
    public var id: String { session.id }
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
    public private(set) var connection: BridgeClient.State = .disconnected(nil)
    public private(set) var models: [ModelInfo] = []
    public var errorMessage: String?
    /// Unsent composer text per session, kept while switching between sessions and across launches.
    public private(set) var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]

    public func setDraft(_ text: String, for id: String) {
        drafts[id] = text.isEmpty ? nil : text
        UserDefaults.standard.set(drafts, forKey: "drafts")
    }

    public var bridgeURL: String {
        didSet { UserDefaults.standard.set(bridgeURL, forKey: "bridgeURL") }
    }
    public var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "bridgeToken") }
    }

    /// Moves on every half minute, so subagents left idle drop out of the lists.
    public private(set) var clock = Date.now

    @ObservationIgnored private let client = BridgeClient()
    @ObservationIgnored private var itemIndex: [String: Int] = [:]

    public init() {
        bridgeURL = UserDefaults.standard.string(forKey: "bridgeURL") ?? "ws://127.0.0.1:7878/ws"
        token = UserDefaults.standard.string(forKey: "bridgeToken") ?? ""
        client.onMessage = { [weak self] in self?.apply($0) }
        client.onState = { [weak self] state in self?.connectionChanged(state) }
    }

    // MARK: Connection

    public func start() {
        #if os(macOS)
        // On the Mac running the bridge, pick up its token automatically.
        if token.isEmpty, let local = Self.localBridgeToken() { token = local }
        #endif
        connect()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.clock = .now
            }
        }
        // `open -a Shed --args -select <session id>` opens a session directly.
        if let id = UserDefaults.standard.string(forKey: "select") { select(id) }
    }

    /// Where the transcript loads embedded media from.
    public var media: MediaSource { MediaSource(bridgeURL: bridgeURL, token: token) }

    public func connect() {
        guard var components = URLComponents(string: bridgeURL.trimmingCharacters(in: .whitespaces)) else {
            connection = .disconnected("Invalid bridge URL")
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }
        client.connect(to: url)
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

    private func connectionChanged(_ state: BridgeClient.State) {
        connection = state
        if state == .connected, let selectedId {
            Task { await attach(selectedId) }
        }
    }

    // MARK: Session tree

    public var selected: SessionSummary? { selectedId.flatMap { sessions[$0] } }

    public var tree: [SessionNode] {
        let roots = sessions.values.filter { s in s.parentId.map { sessions[$0] == nil } ?? true }
        return roots.sorted { $0.createdAt > $1.createdAt }.map(node)
    }

    private func node(_ session: SessionSummary) -> SessionNode {
        let kids = children(of: session.id).map(node)
        return SessionNode(session: session, children: kids.isEmpty ? nil : kids)
    }

    /// This session's subagents, leaving out the ones long idle (unless one is open).
    public func children(of id: String) -> [SessionSummary] {
        allChildren(of: id).filter { !$0.isDormant(at: clock) || $0.id == selectedId }
    }

    private func allChildren(of id: String) -> [SessionSummary] {
        sessions.values.filter { $0.parentId == id }.sorted { $0.createdAt < $1.createdAt }
    }

    public func parent(of session: SessionSummary) -> SessionSummary? {
        session.parentId.flatMap { sessions[$0] }
    }

    /// Every subagent still at work (running, or idle with background jobs), across all sessions.
    public var activeSubagents: [SessionSummary] {
        sessions.values.filter { $0.isSubagent && $0.isActive }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Subagents below this session (any depth) still at work. Prime parents keep going while these run.
    public func activeDescendants(of id: String) -> Int {
        children(of: id).reduce(0) { $0 + ($1.isActive ? 1 : 0) + activeDescendants(of: $1.id) }
    }

    /// A subagent of this session by its name, as child notes refer to it (`child:<name>`).
    public func child(of id: String, named name: String) -> SessionSummary? {
        allChildren(of: id).first { $0.name == name }
    }

    public func select(_ id: String?) {
        guard id != selectedId else { return }
        if let old = selectedId { Task { try? await client.call("detach", ["sessionId": old]) } }
        selectedId = id
        loadedId = nil
        items = []
        itemIndex = [:]
        earlier = 0
        models = []
        if let id { Task { await attach(id) } }
    }

    private func attach(_ id: String) async {
        do {
            try await call("attach", ["sessionId": id], repeatable: true)
        } catch {
            // The session ended while the app was away (e.g. the one it reopens at launch): just leave it.
            if sessions[id] == nil {
                if selectedId == id { select(nil) }
                return
            }
            report(error)
        }
    }

    // MARK: Incoming messages

    private func apply(_ message: ServerMessage) {
        switch message {
        case .sessions(let list):
            sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            snapshots += 1
            if let selectedId, sessions[selectedId] == nil { select(nil) }
        case .session(let summary):
            sessions[summary.id] = summary
        case .sessionRemoved(let id):
            sessions[id] = nil
            if selectedId == id { select(nil) }
        case .snapshot(let sessionId, let snapshot, let earlier):
            guard sessionId == selectedId else { return }
            loadedId = sessionId
            self.earlier = earlier
            items = snapshot
            itemIndex = Dictionary(uniqueKeysWithValues: snapshot.enumerated().map { ($1.id, $0) })
            for item in snapshot.suffix(20) where item.kind == .user { arrived(item.text, in: sessionId) }
        case .itemAdd(let sessionId, let item):
            guard sessionId == selectedId, itemIndex[item.id] == nil else { return }
            // The agent's copy of a message on its way: it takes the sending one's place in the same update.
            if item.kind == .user { arrived(item.text, in: sessionId) }
            itemIndex[item.id] = items.count
            items.append(item)
        case .itemPatch(let sessionId, let itemId, let set, let append):
            guard sessionId == selectedId, let index = itemIndex[itemId] else { return }
            var item = items[index]
            set?.apply(to: &item)
            if let text = append?.text { item.text += text }
            if let args = append?.args { item.args = (item.args ?? "") + args }
            items[index] = item
        }
    }

    /// The page of history before the first loaded item.
    public func loadEarlier() async {
        guard let id = selectedId, let first = items.first, earlier > 0, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await client.call("load_earlier", ["sessionId": id, "before": first.id], as: EarlierItems.self)
            // A snapshot may have replaced the transcript meanwhile.
            guard selectedId == id, items.first?.id == first.id else { return }
            let older = page.items.filter { itemIndex[$0.id] == nil }
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
        if case .disconnected = connection { connect() } else { client.checkAlive() }
    }

    /// Waits for the bridge connection to come back, up to `timeout`.
    private func reconnected(timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while connection != .connected {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// `op`, sent again once the connection is back if a drop cut it off: when it can't have arrived, or when
    /// doing it twice is harmless.
    private func call(_ op: String, _ payload: [String: Any], repeatable: Bool) async throws {
        do {
            try await client.call(op, payload)
        } catch let lost as ConnectionLost where !lost.maybeDelivered || repeatable {
            guard await reconnected() else { throw lost }
            try await client.call(op, payload)
        }
    }

    private static let repeatable: Set<String> = [
        "abort", "stop_tool", "set_thinking", "set_auto_compaction", "set_context_limit", "set_model", "resume_session", "close_session", "clear_goal",
    ]

    private func perform(_ op: String, _ fields: [String: Any] = [:]) {
        guard let id = selectedId else { return }
        var payload = fields
        payload["sessionId"] = id
        Task {
            do { try await call(op, payload, repeatable: Self.repeatable.contains(op)) } catch { report(error) }
        }
    }

    public func createSession(agent: AgentKind, cwd: String, model: String?, thinking: String?, firstMessage: String? = nil) async -> Bool {
        var fields: [String: Any] = ["agent": agent.rawValue, "cwd": cwd]
        if let model, !model.isEmpty { fields["model"] = model }
        if let thinking, !thinking.isEmpty { fields["thinking"] = thinking }
        do {
            let summary = try await client.call("create_session", fields, as: SessionSummary.self)
            sessions[summary.id] = summary
            select(summary.id)
            if let firstMessage, !firstMessage.isEmpty {
                try await client.call("send", ["sessionId": summary.id, "text": firstMessage])
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Prompt when idle; the bridge turns it into a steer while the agent is working.
    public func send(_ text: String) {
        guard let id = selectedId else { return }
        // While it works the message waits in its queue (shown above the composer), not in the conversation.
        let busy = sessions[id]?.status.isBusy ?? false
        let local = Item(id: "sending-\(UUID().uuidString)", kind: .user, text: text, status: .pending, at: Date.now.timeIntervalSince1970 * 1000)
        if !busy { sending[id, default: []].append(local) }
        Task {
            do {
                do {
                    try await client.call("send", ["sessionId": id, "text": text])
                } catch let lost as ConnectionLost {
                    // Cut off by a dropped connection: send it again once back, unless the session's transcript, sent
                    // afresh on reconnecting, shows it arrived after all.
                    guard await reconnected() else { throw lost }
                    if lost.maybeDelivered {
                        try? await Task.sleep(for: .seconds(2))
                        let queued = sessions[id]?.queue
                        let landed = busy ? (queued?.steering.contains(text) == true || queued?.followUp.contains(text) == true)
                                          : sending[id]?.contains { $0.id == local.id } != true
                        if landed { return }
                    }
                    try await client.call("send", ["sessionId": id, "text": text])
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
    public func compact(instructions: String? = nil) {
        perform("compact", instructions.map { ["instructions": $0] } ?? [:])
    }
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
            do { try await client.call("rename_session", ["sessionId": id, "name": name]) } catch { report(error) }
        }
    }
    public func setModel(_ model: ModelInfo) { perform("set_model", ["provider": model.provider, "modelId": model.id]) }
    public func resume() { perform("resume_session") }
    public func close() { perform("close_session") }

    public func delete(_ id: String) {
        Task {
            do { try await client.call("delete_session", ["sessionId": id]) } catch { report(error) }
        }
    }

    /// Folders on the bridge's machine; nil path means the home folder.
    public func listDir(_ path: String?, hidden: Bool = false) async throws -> DirListing {
        var fields: [String: Any] = ["hidden": hidden]
        if let path { fields["path"] = path }
        return try await client.call("list_dir", fields, as: DirListing.self)
    }

    // MARK: Background commands

    public func listJobs(_ sessionId: String) async throws -> [BackgroundJob] {
        try await client.call("list_jobs", ["sessionId": sessionId], as: [BackgroundJob].self)
    }

    public func jobOutput(_ sessionId: String, _ jobId: String, lines: Int = 200) async throws -> String {
        struct Tail: Decodable { let tail: String }
        return try await client.call("job_output", ["sessionId": sessionId, "jobId": jobId, "lines": lines], as: Tail.self).tail
    }

    public func killJob(_ sessionId: String, _ jobId: String) async {
        do {
            _ = try await client.call("kill_job", ["sessionId": sessionId, "jobId": jobId])
        } catch {
            report(error)
        }
    }

    public func loadModels() async {
        guard let id = selectedId else { return }
        do {
            models = try await client.call("list_models", ["sessionId": id], as: [ModelInfo].self)
        } catch {
            report(error)
        }
    }
}
