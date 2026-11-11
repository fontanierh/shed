// The computers Shed controls: the saved list of them, and the connection to each one's bridge.
import Foundation

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

    /// A saved computer needs its id, which drafts and the open session are filed under, and its address. Anything
    /// else that is missing takes a default, so a list saved by another version of the app is still read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.name(for: url)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    /// The bridge on this machine, whose token Shed can read from its config.
    public var isLocal: Bool {
        let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// "my-mac" from "wss://my-mac.tailnet.ts.net:7878/ws".
    public static func name(for url: String) -> String {
        let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host.split(separator: ".").first.map(String.init) ?? "Computer"
    }
}

/// The saved list of computers, as far as it could be read.
struct SavedEnvironments: Equatable {
    var environments: [BridgeEnvironment]
    /// Whether that is all of them.
    var complete: Bool
}

extension SessionStore {
    /// Nil when no list was ever saved.
    static func readEnvironments(_ data: Data?) -> SavedEnvironments? {
        guard let data else { return nil }
        guard let list = try? JSONDecoder().decode(Readable<BridgeEnvironment>.self, from: data) else {
            return SavedEnvironments(environments: [], complete: false)
        }
        return SavedEnvironments(environments: list.values, complete: list.skipped == 0)
    }

    /// From the single bridge Shed used to know: it becomes the first environment, and on the Mac this Mac's own bridge
    /// is always there. Drafts were keyed by bare session ids; they belong to that first environment.
    func migrate() {
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
        if let unreadEnvironments {
            // A copy kept before stays: this list was saved from what could be read then, so that one holds more.
            if defaults.data(forKey: "environmentsUnread") == nil { defaults.set(unreadEnvironments, forKey: "environmentsUnread") }
            self.unreadEnvironments = nil
        }
        defaults.set(try? JSONEncoder().encode(environments), forKey: "environments")
    }

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

    // MARK: Connections

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

    /// Every environment, connected afresh.
    public func connect() {
        for env in environments { connect(env.id) }
    }

    public func connect(_ envId: String) {
        guard let env = environments.first(where: { $0.id == envId }) else { return }
        let client = clients[env.id] ?? makeClient(env.id)
        guard let components = URLComponents(string: env.url.trimmingCharacters(in: .whitespaces)), components.host != nil,
              let url = components.url
        else {
            connections[env.id] = .disconnected("Invalid bridge URL")
            return
        }
        client.connect(to: url, token: token(of: env, fresh: true))
    }

    private func makeClient(_ env: String) -> any BridgeConnection {
        let client = makeConnection()
        client.onMessage = { [weak self] in self?.apply($0, from: env) }
        client.onState = { [weak self] state in self?.connectionChanged(state, env) }
        clients[env] = client
        return client
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

    /// Back from the background: replace a socket iOS killed meanwhile.
    public func resumed() {
        for env in environments {
            if case .disconnected = connection(of: env.id) { connect(env.id) } else { clients[env.id]?.checkAlive() }
        }
    }

    /// Waits for an environment's bridge connection to come back, up to `reconnectWait`. The time is what it paused
    /// for, added up.
    func reconnected(_ env: String) async -> Bool {
        let step = Duration.milliseconds(250)
        var waited = Duration.zero
        while connection(of: env) != .connected {
            guard waited < Self.reconnectWait else { return false }
            await pause(step)
            waited += step
        }
        return true
    }
}
