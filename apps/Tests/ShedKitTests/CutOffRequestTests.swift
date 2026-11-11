import XCTest
@testable import ShedKit

/// What the store does with a request the connection dropped under: send it again when that is safe, and otherwise
/// say that it may not have happened.
final class CutOffRequestTests: XCTestCase {
    @MainActor private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, agent: .pi, kind: .root, name: nil, runningSubagents: false,
                       readOnly: false, cwd: "/tmp", title: id, status: .idle, error: nil, createdAt: 0,
                       model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                       cost: 0, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                       contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                       stuck: nil, lastActiveAt: nil, goal: nil, question: nil, spend: nil, sites: nil)
    }

    /// A store whose computer "one" is `bridge`, connected, with a session "s".
    @MainActor private func store(_ bridge: ScriptedBridge, connected: Bool = true) -> SessionStore {
        let store = SessionStore(defaults: scratchDefaults())
        store.standIns["one"] = bridge
        if connected { store.connections["one"] = .connected }
        store.apply(.sessions([summary("s")]), from: "one")
        return store
    }

    @MainActor private func created(_ id: String) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary(id)))
    }

    @MainActor func testARenameThatMayHaveArrivedIsNotSentAgainAndIsReported() async {
        let bridge = ScriptedBridge([.renameSession: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        store.rename("one:s", to: "Tests")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(bridge.sent, [.renameSession])
    }

    @MainActor func testADeleteThatCannotHaveArrivedIsSentAgainOnceConnected() async {
        let bridge = ScriptedBridge([.deleteSession: [.lost(maybeDelivered: false)]])
        let store = store(bridge)
        store.delete("one:s")
        let again = await eventually { bridge.sent.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(bridge.sent, [.deleteSession, .deleteSession])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testADeleteCutOffOnItsSecondTryIsReported() async {
        let bridge = ScriptedBridge([.deleteSession: [.lost(maybeDelivered: false), .lost(maybeDelivered: true)]])
        let store = store(bridge)
        store.delete("one:s")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(bridge.sent, [.deleteSession, .deleteSession])
    }

    @MainActor func testARenameThatNeverGotThroughIsReported() async {
        let bridge = ScriptedBridge([.renameSession: [.lost(maybeDelivered: false)]])
        let store = store(bridge, connected: false)
        store.reconnectWait = .milliseconds(20)
        store.rename("one:s", to: "Tests")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(bridge.sent, [.renameSession])
    }

    @MainActor func testACreateThatCannotHaveArrivedIsSentAgain() async throws {
        let bridge = ScriptedBridge([.createSession: [.lost(maybeDelivered: false), .reply(try created("new"))]])
        let store = store(bridge)
        try await store.createSession(in: "one", agent: .pi, cwd: "/tmp", model: nil, thinking: nil)
        XCTAssertEqual(bridge.count(.createSession), 2)
        XCTAssertEqual(store.selectedId, "one:new")
    }

    /// Sent again, it could make a second session.
    @MainActor func testACreateThatMayHaveArrivedTellsTheSheetSo() async {
        let bridge = ScriptedBridge([.createSession: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        do {
            try await store.createSession(in: "one", agent: .pi, cwd: "/tmp", model: nil, thinking: nil)
            XCTFail("created")
        } catch {
            XCTAssertFalse(error is ConnectionLost)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertEqual(bridge.sent, [.createSession])
    }

    @MainActor func testAFirstMessageThatMayHaveArrivedIsReported() async throws {
        let bridge = ScriptedBridge([.createSession: [.reply(try created("new"))], .send: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        try await store.createSession(in: "one", agent: .pi, cwd: "/tmp", model: nil, thinking: nil, firstMessage: "Hello")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(bridge.count(.send), 1)
    }

    @MainActor func testAFirstMessageThatCannotHaveArrivedIsSentAgain() async throws {
        let bridge = ScriptedBridge([.createSession: [.reply(try created("new"))], .send: [.lost(maybeDelivered: false)]])
        let store = store(bridge)
        try await store.createSession(in: "one", agent: .pi, cwd: "/tmp", model: nil, thinking: nil, firstMessage: "Hello")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(bridge.count(.send), 2)
    }

    @MainActor func testAnAnswerAndAKillGoTheSameWay() async {
        let bridge = ScriptedBridge([.answerQuestion: [.lost(maybeDelivered: false)], .killJob: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        await store.answerQuestion("one:s", "q1", picked: [:])
        XCTAssertEqual(bridge.count(.answerQuestion), 2)
        XCTAssertNil(store.errorMessage)
        await store.killJob("one:s", "job-1")
        XCTAssertEqual(bridge.count(.killJob), 1)
        XCTAssertNotNil(store.errorMessage)
    }

    /// Doing it twice does no harm: it is sent again, and nothing needs saying.
    @MainActor func testAnOperationThatMayBeRepeatedIsSentAgainEvenIfItMayHaveArrived() async {
        let bridge = ScriptedBridge([.abort: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        store.select("one:s")
        store.abort()
        let again = await eventually { bridge.count(.abort) == 2 }
        XCTAssertTrue(again)
        XCTAssertNil(store.errorMessage)
    }

    /// Whoever asked shows what it had or asks again; nothing was changed that needs saying.
    @MainActor func testAReadCutOffIsNeitherSentAgainNorReported() async {
        for maybeDelivered in [true, false] {
            let bridge = ScriptedBridge([.listJobs: [.lost(maybeDelivered: maybeDelivered)]])
            let store = store(bridge)
            do {
                _ = try await store.listJobs("one:s")
                XCTFail("listed")
            } catch {
                XCTAssertTrue(error is ConnectionLost)
            }
            XCTAssertEqual(bridge.sent, [.listJobs])
            XCTAssertNil(store.errorMessage)
        }
    }

    @MainActor func testEarlierItemsAreAskedOfTheSameConnection() async throws {
        let earlier: [String: Any] = ["earlier": 0, "items": [["id": "a", "kind": "text", "text": "Before"]]]
        let bridge = ScriptedBridge([.loadEarlier: [.reply(earlier)]])
        let store = store(bridge)
        store.select("one:s")
        store.apply(.snapshot(sessionId: "s", items: [Item(id: "b", kind: .text, text: "After")], earlier: 1), from: "one")
        await store.loadEarlier()
        XCTAssertEqual(store.items.map(\.id), ["a", "b"])
    }

    /// A store with the session "s" of computer "one" open, whose bridge says it understands `level`.
    @MainActor private func open(_ bridge: ScriptedBridge, level: Int) -> SessionStore {
        let store = store(bridge)
        store.apply(.sessions([summary("s")], bridge: level), from: "one")
        store.select("one:s")
        return store
    }

    @MainActor private func sendIds(_ bridge: ScriptedBridge) -> [String?] {
        bridge.messages.filter { $0["op"] as? String == "send" }.map { $0["sendId"] as? String }
    }

    @MainActor func testAMessageCutOffGoesAgainAtOnceUnderItsIdToABridgeThatTakesIds() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: true)]])
        let store = open(bridge, level: 2)
        let start = ContinuousClock.now
        store.send("Carry on")
        let again = await eventually { bridge.count(.send) == 2 }
        XCTAssertTrue(again)
        // No two-second look at the transcript: the bridge tells a repeat by its id.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        let ids = sendIds(bridge)
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])
    }

    @MainActor func testAMessageCutOffWaitsForTheTranscriptOnAnOlderBridge() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: true)]])
        let store = open(bridge, level: 1)
        let start = ContinuousClock.now
        store.send("Carry on")
        var again = false
        for _ in 0..<3 where !again { again = await eventually { bridge.count(.send) == 2 } }
        XCTAssertTrue(again)
        XCTAssertGreaterThan(ContinuousClock.now - start, .milliseconds(1900))
    }

    @MainActor func testTwoMessagesWithTheSameWordsHaveTheirOwnIds() async {
        let bridge = ScriptedBridge()
        let store = open(bridge, level: 2)
        store.send("continue")
        store.send("continue")
        let both = await eventually { bridge.count(.send) == 2 }
        XCTAssertTrue(both)
        let ids = sendIds(bridge)
        XCTAssertNotEqual(ids[0], ids[1])
    }
}
