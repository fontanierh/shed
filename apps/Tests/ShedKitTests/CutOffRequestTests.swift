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

    /// A store whose computer "one" is `bridge`, connected if it can be reached, with a session "s".
    @MainActor private func store(_ bridge: ScriptedBridge) -> SessionStore {
        let store = SessionStore(on: bridge)
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
        let bridge = ScriptedBridge([.renameSession: [.lost(maybeDelivered: false)]], reachable: false)
        let store = store(bridge)
        store.rename("one:s", to: "Tests")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(bridge.sent, [.renameSession])
        // It waited a minute for the connection, in short steps, and no longer.
        XCTAssertEqual(bridge.waits.reduce(.zero, +), .seconds(60))
        XCTAssertEqual(Set(bridge.waits), [.milliseconds(250)])
    }

    @MainActor func testARequestCutOffGoesAgainAsSoonAsTheConnectionIsBack() async {
        let bridge = ScriptedBridge([.deleteSession: [.lost(maybeDelivered: false)]])
        let store = store(bridge)
        bridge.disconnect()
        store.delete("one:s")
        let waiting = await eventually { bridge.waits.count >= 3 }
        XCTAssertTrue(waiting)
        XCTAssertEqual(bridge.sent, [.deleteSession])
        store.connect("one")
        let again = await eventually { bridge.sent.count == 2 }
        XCTAssertTrue(again)
        // It did not wait out its minute first.
        XCTAssertLessThan(bridge.waits.reduce(.zero, +), .seconds(60))
        XCTAssertNil(store.errorMessage)
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

    /// The bridge tells a repeat by its id, so the first message of a new session goes again like any other.
    @MainActor func testAFirstMessageThatMayHaveArrivedIsSentAgainUnderItsIdToABridgeThatTakesIds() async throws {
        let bridge = ScriptedBridge([.createSession: [.reply(try created("new"))], .send: [.lost(maybeDelivered: true)]])
        let store = store(bridge)
        store.apply(.sessions([summary("s")], bridge: 2), from: "one")
        try await store.createSession(in: "one", agent: .pi, cwd: "/tmp", model: nil, thinking: nil, firstMessage: "Hello")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(bridge.count(.send), 2)
        let ids = sendIds(bridge)
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])
    }

    /// An older bridge would run it twice, and a session this new has no transcript to tell whether it arrived.
    @MainActor func testAFirstMessageThatMayHaveArrivedIsReportedOnAnOlderBridge() async throws {
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

    private let notDone = "That computer could not be reached, so this was not done."
    private let maybeDone = "The connection to that computer dropped, so this may not have been done. Check before trying again."

    /// The user asked for it and it did not happen: the connection state alone does not say so.
    @MainActor func testAnOperationThatMayBeRepeatedIsReportedWhenTheComputerIsNotReached() async {
        let bridge = ScriptedBridge([.abort: [.lost(maybeDelivered: false)]])
        let store = store(bridge)
        store.select("one:s")
        bridge.disconnect()
        store.abort()
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(store.errorMessage, notDone)
        XCTAssertEqual(bridge.count(.abort), 1)
    }

    @MainActor func testAnOperationThatMayBeRepeatedCutOffTwiceIsReportedAsMaybeDone() async {
        let bridge = ScriptedBridge([.abort: [.lost(maybeDelivered: false), .lost(maybeDelivered: true)]])
        let store = store(bridge)
        store.select("one:s")
        store.abort()
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(store.errorMessage, maybeDone)
        XCTAssertEqual(bridge.count(.abort), 2)
    }

    /// The connection state says the computer is out of reach, and the session is attached again on reconnecting.
    @MainActor func testOpeningASessionOfAComputerOutOfReachRaisesNoError() async {
        let bridge = ScriptedBridge([.attach: [.lost(maybeDelivered: false), .lost(maybeDelivered: false)]], reachable: false)
        let store = store(bridge)
        await store.attach("one:s")
        XCTAssertEqual(bridge.sent, [.attach])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testAMessageCutOffTwiceComesBackAsADraftAndIsReported() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: true), .lost(maybeDelivered: true)]])
        let store = open(bridge, level: 2)
        store.send("Carry on")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(store.errorMessage, maybeDone)
        XCTAssertEqual(bridge.count(.send), 2)
        XCTAssertEqual(store.drafts["one:s"], "Carry on")
        XCTAssertEqual(store.transcript, [])
    }

    @MainActor func testAMessageToAComputerThatIsNotReachedComesBackAsADraftAndIsReported() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: false)]])
        let store = open(bridge, level: 2)
        bridge.disconnect()
        store.send("Carry on")
        let reported = await eventually { store.errorMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(store.errorMessage, notDone)
        XCTAssertEqual(bridge.count(.send), 1)
        XCTAssertEqual(store.drafts["one:s"], "Carry on")
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
        store.send("Carry on")
        let again = await eventually { bridge.count(.send) == 2 }
        XCTAssertTrue(again)
        // No two-second look at the transcript: the bridge tells a repeat by its id.
        XCTAssertFalse(bridge.waits.contains(.seconds(2)))
        let ids = sendIds(bridge)
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])
    }

    @MainActor func testAMessageCutOffWaitsForTheTranscriptOnAnOlderBridge() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: true)]])
        let store = open(bridge, level: 1)
        store.send("Carry on")
        let again = await eventually { bridge.count(.send) == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(bridge.waits.first, .seconds(2))
        XCTAssertEqual(bridge.waits.filter { $0 == .seconds(2) }.count, 1)
    }

    /// The transcript sent on reconnecting holds the message: it arrived, and going again would run it twice.
    @MainActor func testAMessageCutOffThatTheTranscriptShowsIsNotSentAgainToAnOlderBridge() async {
        let bridge = ScriptedBridge([.send: [.lost(maybeDelivered: true)]])
        let store = open(bridge, level: 1)
        store.send("Carry on")
        store.apply(.snapshot(sessionId: "s", items: [Item(id: "u", kind: .user, text: "Carry on")], earlier: 0), from: "one")
        let looked = await eventually { bridge.waits.contains(.seconds(2)) }
        XCTAssertTrue(looked)
        let again = await eventually { bridge.count(.send) == 2 }
        XCTAssertFalse(again)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.drafts["one:s"])
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
