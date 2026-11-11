import XCTest
@testable import ShedKit

@MainActor
private final class FakeSocket: WebSocketTransport {
    let request: URLRequest
    private(set) var sent: [[String: Any]] = []
    private(set) var cancelled = false
    var sendError: Error?
    var pingError: Error?
    private var incoming: [Result<Data, Error>] = []
    private var waiter: CheckedContinuation<Data, Error>?

    init(_ request: URLRequest) {
        self.request = request
    }

    func push(_ json: String) {
        let item: Result<Data, Error> = .success(Data(json.utf8))
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(with: item)
        } else {
            self.incoming.append(item)
        }
    }

    func fail(_ error: Error) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        } else {
            self.incoming.append(.failure(error))
        }
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            self.sent.append(obj)
        }
        completion(self.sendError)
    }

    func receive() async throws -> Data {
        if !self.incoming.isEmpty {
            return try self.incoming.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        completion(self.pingError)
    }

    func cancel() {
        self.cancelled = true
    }
}

final class BridgeClientTests: XCTestCase {
    private struct Dropped: LocalizedError {
        var errorDescription: String? { "socket closed" }
    }

    @MainActor func testSendsTokenInHeaderMatchesRepliesAndPushesMessages() async throws {
        var sockets: [FakeSocket] = []
        let client = BridgeClient(
            socket: { req in
                let s = FakeSocket(req)
                sockets.append(s)
                return s
            },
            pause: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        var states: [BridgeClient.State] = []
        var pushed: [ServerMessage] = []
        client.onState = { states.append($0) }
        client.onMessage = { pushed.append($0) }

        let url = URL(string: "wss://desk.example:7878/ws")!
        client.connect(to: url, token: "secret-token")
        XCTAssertEqual(states, [.connecting])
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertNil(sockets[0].request.url?.query)

        // Calling before the bridge has spoken fails without sending.
        do {
            try await client.call(.ping)
            XCTFail("expected ConnectionLost before greeting")
        } catch let lost as ConnectionLost {
            XCTAssertFalse(lost.maybeDelivered)
        }

        sockets[0].push(#"{"type":"sessions","sessions":[],"bridge":2}"#)
        _ = await eventually { states.last == .connected && pushed.count == 1 }

        let branchTask = Task { try await client.call(.gitBranch(path: "/work")) }
        _ = await eventually { sockets[0].sent.count == 1 }
        let id1 = try XCTUnwrap(sockets[0].sent[0]["id"] as? String)
        sockets[0].push(#"{"type":"reply","id":"\#(id1)","ok":true,"data":{"branch":"main"}}"#)
        let data = try await branchTask.value
        let parsed = try JSONDecoder().decode(Reply<[String: String]>.self, from: data)
        XCTAssertEqual(parsed.data["branch"], "main")

        // Structured failure code is decoded onto BridgeError.
        let failTask = Task { try await client.call(.attach(sessionId: "gone")) }
        _ = await eventually { sockets[0].sent.count == 2 }
        let id2 = try XCTUnwrap(sockets[0].sent[1]["id"] as? String)
        sockets[0].push(#"{"type":"reply","id":"\#(id2)","ok":false,"error":"session ended","code":"session_ended"}"#)
        do {
            _ = try await failTask.value
            XCTFail("expected BridgeError")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, .sessionEnded)
            XCTAssertTrue(error.isSessionEnded)
        }

        client.disconnect()
        XCTAssertTrue(sockets[0].cancelled)
        XCTAssertEqual(states.last, .disconnected(nil))
    }

    @MainActor func testReconnectsAfterDropAndIgnoresStaleSocketGeneration() async throws {
        var sockets: [FakeSocket] = []
        var reconnectSteps: [CheckedContinuation<Void, Error>] = []
        let client = BridgeClient(
            socket: { req in
                let s = FakeSocket(req)
                sockets.append(s)
                return s
            },
            pause: { duration in
                if duration == .seconds(2) {
                    try await withCheckedThrowingContinuation { reconnectSteps.append($0) }
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        )
        var states: [BridgeClient.State] = []
        client.onState = { states.append($0) }

        client.connect(to: URL(string: "wss://desk.example:7878/ws")!, token: "t")
        sockets[0].push(#"{"type":"sessions","sessions":[],"bridge":2}"#)
        _ = await eventually { states.last == .connected }

        // A call in flight when the socket drops fails with maybeDelivered == true, then reconnects after the 2 s backoff.
        let inFlight = Task { try await client.call(.abort(sessionId: "s1")) }
        _ = await eventually { sockets[0].sent.count == 1 }
        sockets[0].fail(Dropped())
        do {
            _ = try await inFlight.value
            XCTFail("expected ConnectionLost")
        } catch let lost as ConnectionLost {
            XCTAssertTrue(lost.maybeDelivered)
        }
        _ = await eventually { reconnectSteps.count == 1 }
        reconnectSteps.removeFirst().resume()
        _ = await eventually { sockets.count == 2 }

        // Failing ping replaces socket[1] with socket[2]; a late error from socket[1] must not disturb socket[2].
        sockets[1].push(#"{"type":"sessions","sessions":[],"bridge":2}"#)
        _ = await eventually { states.last == .connected }
        sockets[1].pingError = Dropped()
        client.checkAlive()
        _ = await eventually { sockets.count == 3 }
        sockets[2].push(#"{"type":"sessions","sessions":[],"bridge":2}"#)
        _ = await eventually { states.last == .connected }

        sockets[1].fail(Dropped())
        await Task.yield()
        XCTAssertEqual(states.last, .connected)
        XCTAssertEqual(sockets.count, 3)

        client.disconnect()
    }
}
