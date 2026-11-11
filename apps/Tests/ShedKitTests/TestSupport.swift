import XCTest
@testable import ShedKit

/// Settings held in memory, for one test: a store under test never reads or writes the app's, and nothing is left
/// on disk. The typed readers of `UserDefaults` all go through `object(forKey:)`.
final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

func scratchDefaults() -> UserDefaults { ScratchDefaults() }

/// Whether `condition` came true once the tasks the store started had their turns. No clock is read: a store made
/// with `SessionStore(on:)` waits for nothing in real time, so its tasks only need the main actor.
@MainActor func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Stands in for the connection to a computer: answers the store's requests from a script, connects or not as it
/// was told, and notes how long the store asked to wait instead of waiting.
@MainActor
final class ScriptedBridge: BridgeConnection {
    enum Outcome {
        case reply(Any)
        case lost(maybeDelivered: Bool)
    }

    var onMessage: (ServerMessage) -> Void = { _ in }
    var onState: (BridgeClient.State) -> Void = { _ in }

    /// What each call of an operation gets, in order. An operation with nothing left succeeds with an empty reply.
    var script: [ClientOp.Name: [Outcome]]
    /// Whether connecting to it succeeds.
    let reachable: Bool
    private(set) var sent: [ClientOp.Name] = []
    /// Each operation as it went on the wire.
    private(set) var messages: [[String: Any]] = []
    /// Every wait the store asked for, in order. Each one was over at once.
    private(set) var waits: [Duration] = []

    init(_ script: [ClientOp.Name: [Outcome]] = [:], reachable: Bool = true) {
        self.script = script
        self.reachable = reachable
    }

    func count(_ name: ClientOp.Name) -> Int { sent.filter { $0 == name }.count }

    func connect(to url: URL, token: String) { onState(reachable ? .connected : .disconnected("Out of reach")) }
    func disconnect() { onState(.disconnected(nil)) }
    func checkAlive() {}

    func wait(_ time: Duration) async {
        waits.append(time)
        await Task.yield()
    }

    func call(_ op: ClientOp) async throws -> Data {
        sent.append(op.name)
        messages.append((try? JSONSerialization.jsonObject(with: Data(op.message(id: "c").utf8)) as? [String: Any]) ?? [:])
        let outcome = script[op.name]?.isEmpty == false ? script[op.name]!.removeFirst() : .reply(NSNull())
        switch outcome {
        case .reply(let data): return try JSONSerialization.data(withJSONObject: ["type": "reply", "ok": true, "data": data])
        case .lost(let maybeDelivered): throw ConnectionLost(maybeDelivered: maybeDelivered)
        }
    }
}

extension SessionStore {
    /// A store with one computer, "one", whose connection is `bridge` and whose waits `bridge` notes. The computer
    /// has an address elsewhere and a token of its own, so connecting it reads nothing from this machine.
    convenience init(on bridge: ScriptedBridge) {
        self.init(defaults: scratchDefaults(), connection: { bridge }, pause: { await bridge.wait($0) })
        save(BridgeEnvironment(id: "one", name: "Desk", url: "wss://desk.example:7878/ws", token: "t-one"))
    }
}
