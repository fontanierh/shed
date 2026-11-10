// WebSocket connection to the bridge: request/reply correlation and automatic reconnects.
import Foundation

public struct BridgeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A request cut off by the connection dropping (iOS kills the socket while the app is suspended). The client
/// reconnects on its own, so this is no failure of the request itself.
public struct ConnectionLost: Error, Sendable {
    /// Whether the request may have reached the bridge before the connection went.
    public let maybeDelivered: Bool
}

@MainActor
public final class BridgeClient {
    public enum State: Equatable, Sendable {
        case disconnected(String?)
        case connecting
        case connected
    }

    public var onMessage: (ServerMessage) -> Void = { _ in }
    public var onState: (State) -> Void = { _ in }

    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var endpoint: URL?
    private var generation = 0
    private var connected = false
    private var nextId = 0
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    /// When the bridge last sent anything, for telling a quiet connection from a dead one.
    private var lastHeard = ContinuousClock.now

    public init() {}

    public func connect(to url: URL) {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        failPending(ConnectionLost(maybeDelivered: true))
        endpoint = url
        connected = false
        onState(.connecting)
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        self.task = task
        task.resume()
        Task { await receiveLoop(task, gen) }
        Task { await heartbeat(gen) }
    }

    /// A connection can die without an error (a network change, a Mac asleep behind Tailscale): the socket stays open
    /// and nothing arrives. After 15 quiet seconds, ask the bridge for a reply; none within 10 more, and the socket is
    /// replaced, which also brings a fresh snapshot of the open session.
    private func heartbeat(_ gen: Int) async {
        while gen == generation {
            try? await Task.sleep(for: .seconds(5))
            guard gen == generation, connected, let endpoint, ContinuousClock.now - lastHeard > .seconds(15) else { continue }
            let asked = ContinuousClock.now
            Task { _ = try? await call("ping") }
            try? await Task.sleep(for: .seconds(10))
            guard gen == generation, connected, lastHeard < asked else { continue }
            connect(to: endpoint)
        }
    }

    public func disconnect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(ConnectionLost(maybeDelivered: true))
        onState(.disconnected(nil))
    }

    /// Send an operation and wait for its reply; returns the raw reply JSON.
    @discardableResult
    public func call(_ op: String, _ fields: [String: Any] = [:]) async throws -> Data {
        guard let task, connected else { throw ConnectionLost(maybeDelivered: false) }
        nextId += 1
        let id = "c\(nextId)"
        var payload = fields
        payload["id"] = id
        payload["op"] = op
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(text)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: ConnectionLost(maybeDelivered: false)) }
            }
        }
    }

    public func call<T: Decodable>(_ op: String, _ fields: [String: Any] = [:], as type: T.Type) async throws -> T {
        let data = try await call(op, fields)
        return try JSONDecoder().decode(Reply<T>.self, from: data).data
    }

    private struct Reply<T: Decodable>: Decodable { let data: T }

    private struct Head: Decodable {
        let type: String
        let id: String?
        let ok: Bool?
        let error: String?
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, _ gen: Int) async {
        do {
            while true {
                let message = try await task.receive()
                guard gen == generation else { return }
                switch message {
                case .string(let text): handle(Data(text.utf8))
                case .data(let data): handle(data)
                @unknown default: break
                }
            }
        } catch {
            guard gen == generation else { return }
            failPending(ConnectionLost(maybeDelivered: true))
            connected = false
            onState(.disconnected(error.localizedDescription))
            try? await Task.sleep(for: .seconds(2))
            if gen == generation, let endpoint { connect(to: endpoint) }
        }
    }

    /// After the app was suspended: a socket that no longer answers a ping is replaced at once, rather than when the
    /// next request fails on it.
    public func checkAlive() {
        guard let task, let endpoint else { return }
        let gen = generation
        task.sendPing { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.connect(to: endpoint)
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
            guard let id = head.id, let continuation = pending.removeValue(forKey: id) else { return }
            if head.ok == true {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: BridgeError(head.error ?? "Request failed"))
            }
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

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
