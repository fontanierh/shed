// WebSocket connection to the bridge: request/reply correlation and automatic reconnects.
import Foundation

public struct BridgeError: LocalizedError, Sendable {
    /// The failures the app does something about, as the bridge names them in a reply's `code`
    /// (`ErrorCode` in the bridge's protocol.rs). A bridge from before the codes sends none.
    public enum Code: String, Sendable {
        case sessionEnded = "session_ended"
        case noSuchDirectory = "no_such_directory"
    }

    public let message: String
    /// Nil for a failure with no code, and for a code this version of the app does not know.
    public let code: Code?
    public init(_ message: String, code: Code? = nil) {
        self.message = message
        self.code = code
    }
    public var errorDescription: String? { message }

    /// Whether it is that failure: by its code, or, from a bridge that sends none, by the words that bridge used.
    public func isFailure(_ code: Code, orSays words: (String) -> Bool) -> Bool {
        self.code == code || (self.code == nil && words(message))
    }
}

extension Error {
    /// A subagent its agent has let go of: the one thing the bridge answers this way.
    var isSessionEnded: Bool {
        (self as? BridgeError)?.isFailure(.sessionEnded) { $0 == "session ended" } ?? false
    }

    /// The bridge refused a folder because it is gone.
    var isMissingFolder: Bool {
        (self as? BridgeError)?.isFailure(.noSuchDirectory) { $0.contains("No such file or directory") } ?? false
    }
}

/// A request cut off by the connection dropping (iOS kills the socket while the app is suspended). The client
/// reconnects on its own, so this is no failure of the request itself.
public struct ConnectionLost: Error, Sendable {
    /// Whether the request may have reached the bridge before the connection went.
    public let maybeDelivered: Bool
}

/// The bridge did not answer a request within its limit, on a connection that still carries replies. Nothing is
/// sent again, and the store shows it: the user cannot tell whether what was asked was done.
struct Unanswered: LocalizedError {
    var errorDescription: String? { "That computer did not answer in time, so this may not have been done." }
}

/// What the store asks of its connection to a computer, so a test can stand in for one.
@MainActor
protocol BridgeConnection: AnyObject {
    var onMessage: (ServerMessage) -> Void { get set }
    var onState: (BridgeClient.State) -> Void { get set }
    func connect(to url: URL, token: String)
    func disconnect()
    func checkAlive()
    /// Send an operation and wait for its reply; returns the raw reply JSON.
    @discardableResult
    func call(_ op: ClientOp) async throws -> Data
}

struct Reply<T: Decodable>: Decodable { let data: T }

/// One WebSocket connection, so `BridgeClient` can be driven over a scripted fake in tests.
@MainActor
protocol WebSocketTransport: AnyObject {
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> Data
    func sendPing(completion: @escaping @Sendable (Error?) -> Void)
    func cancel()
}

@MainActor
private final class LiveWebSocket: WebSocketTransport {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        task.maximumMessageSize = 64 << 20
        self.task = task
        task.resume()
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        self.task.send(.string(text), completionHandler: completion)
    }

    func receive() async throws -> Data {
        switch try await self.task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        self.task.sendPing(pongReceiveHandler: completion)
    }

    func cancel() {
        self.task.cancel(with: .goingAway, reason: nil)
    }
}

@MainActor
public final class BridgeClient: BridgeConnection {
    public enum State: Equatable, Sendable {
        case disconnected(String?)
        case connecting
        case connected
    }

    public var onMessage: (ServerMessage) -> Void = { _ in }
    public var onState: (State) -> Void = { _ in }

    private let makeSocket: @MainActor (URLRequest) -> any WebSocketTransport
    private let pause: @MainActor (Duration) async throws -> Void
    private var socket: (any WebSocketTransport)?
    private var endpoint: URL?
    private var token = ""
    private var generation = 0
    private var connected = false
    private var nextId = 0
    private let replies: PendingReplies
    /// When the bridge last sent anything, for telling a quiet connection from a dead one.
    private var lastHeard = ContinuousClock.now

    public convenience init() {
        let session = URLSession(configuration: .default)
        self.init(
            socket: { LiveWebSocket(session.webSocketTask(with: $0)) },
            pause: { try await Task.sleep(for: $0) }
        )
    }

    init(
        socket: @escaping @MainActor (URLRequest) -> any WebSocketTransport,
        pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.makeSocket = socket
        self.pause = pause
        self.replies = PendingReplies(pause: pause)
    }

    /// The token goes in a header, as for media and uploads: a URL is what proxies and logs keep.
    public func connect(to url: URL, token: String) {
        self.token = token
        generation += 1
        let gen = generation
        socket?.cancel()
        failPending(ConnectionLost(maybeDelivered: true))
        endpoint = url
        connected = false
        onState(.connecting)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = makeSocket(request)
        self.socket = socket
        Task { await self.receiveLoop(socket, gen) }
        Task { await self.heartbeat(gen) }
    }

    /// A connection can die without an error (a network change, a Mac asleep behind Tailscale): the socket stays open
    /// and nothing arrives. After 15 quiet seconds, ask the bridge for a reply; none within 10 more, and the socket is
    /// replaced, which also brings a fresh snapshot of the open session.
    private func heartbeat(_ gen: Int) async {
        while gen == generation {
            guard (try? await pause(.seconds(5))) != nil else { return }
            guard gen == generation, connected, let endpoint, ContinuousClock.now - lastHeard > .seconds(15) else { continue }
            let asked = ContinuousClock.now
            Task { _ = try? await self.call(.ping) }
            guard (try? await pause(.seconds(10))) != nil else { return }
            guard gen == generation, connected, lastHeard < asked else { continue }
            connect(to: endpoint, token: token)
        }
    }

    public func disconnect() {
        generation += 1
        socket?.cancel()
        socket = nil
        connected = false
        failPending(ConnectionLost(maybeDelivered: true))
        onState(.disconnected(nil))
    }

    @discardableResult
    func call(_ op: ClientOp) async throws -> Data {
        guard let socket, connected else { throw ConnectionLost(maybeDelivered: false) }
        nextId += 1
        let id = "c\(nextId)"
        let text = try op.message(id: id)
        return try await replies.reply(to: id, within: op.replyLimit) {
            socket.send(text) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.replies.settle(id, .failure(ConnectionLost(maybeDelivered: false))) }
            }
        }
    }

    private struct Head: Decodable {
        let type: String
        let id: String?
        let ok: Bool?
        let error: String?
        let code: String?
    }

    private func receiveLoop(_ socket: any WebSocketTransport, _ gen: Int) async {
        do {
            while true {
                let data = try await socket.receive()
                guard gen == generation else { return }
                handle(data)
            }
        } catch {
            guard gen == generation else { return }
            failPending(ConnectionLost(maybeDelivered: true))
            connected = false
            onState(.disconnected(error.localizedDescription))
            guard (try? await pause(.seconds(2))) != nil else { return }
            if gen == generation, let endpoint { connect(to: endpoint, token: token) }
        }
    }

    /// After the app was suspended: a socket that no longer answers a ping is replaced at once, rather than when the
    /// next request fails on it.
    public func checkAlive() {
        guard let socket, let endpoint else { return }
        let gen = generation
        socket.sendPing { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.connect(to: endpoint, token: self.token)
            }
        }
    }

    private func handle(_ data: Data) {
        lastHeard = .now
        if !connected {
            connected = true
            onState(.connected)
        }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return }
        if head.type == "reply" {
            guard let id = head.id else { return }
            replies.settle(id, head.ok == true ? .success(data) : .failure(BridgeError(head.error ?? "Request failed", code: head.code.flatMap(BridgeError.Code.init))))
            return
        }
        do {
            onMessage(try JSONDecoder().decode(ServerMessage.self, from: data))
        } catch {
            // Said in the log: a message the app can't read was dropped without a trace, and a list or a
            // conversation simply stayed as it was.
            NSLog("Shed: a %@ message from the bridge couldn't be read: %@", head.type, String(describing: error))
        }
    }

    private func failPending(_ error: Error) { replies.failAll(error) }
}

/// The requests waiting for their replies, each for no longer than its limit.
@MainActor
final class PendingReplies {
    private var waiting: [String: (asker: CheckedContinuation<Data, Error>, limit: Task<Void, Never>)] = [:]
    /// Lets that long pass, or throws when called off. A test gives its own, so no limit takes real time.
    private let pause: @MainActor (Duration) async throws -> Void

    init(pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pause = pause
    }

    /// Waits for the reply to the request `id`, which `send` puts on the wire once the wait is noted. With no reply
    /// within `limit` it throws `Unanswered`, and a reply that comes later is dropped.
    func reply(to id: String, within limit: Duration, send: () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { asker in
            let limit = Task { [weak self, pause] in
                guard (try? await pause(limit)) != nil else { return }
                self?.settle(id, .failure(Unanswered()))
            }
            waiting[id] = (asker, limit)
            send()
        }
    }

    /// Gives the request `id` its outcome. One that no longer waits has had another, and this one is dropped.
    func settle(_ id: String, _ outcome: Result<Data, Error>) {
        guard let request = waiting.removeValue(forKey: id) else { return }
        request.limit.cancel()
        request.asker.resume(with: outcome)
    }

    func failAll(_ error: Error) {
        for id in Array(waiting.keys) { settle(id, .failure(error)) }
    }
}
