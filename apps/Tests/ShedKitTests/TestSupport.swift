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

/// Whether `condition` came true within two seconds.
@MainActor func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Answers the store's requests from a script, in place of a connection.
@MainActor
final class ScriptedBridge: BridgeCalling {
    enum Outcome {
        case reply(Any)
        case lost(maybeDelivered: Bool)
    }

    /// What each call of an operation gets, in order. An operation with nothing left succeeds with an empty reply.
    var script: [ClientOp.Name: [Outcome]]
    private(set) var sent: [ClientOp.Name] = []
    /// Each operation as it went on the wire.
    private(set) var messages: [[String: Any]] = []

    init(_ script: [ClientOp.Name: [Outcome]] = [:]) { self.script = script }

    func count(_ name: ClientOp.Name) -> Int { sent.filter { $0 == name }.count }

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
