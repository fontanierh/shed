import XCTest
@testable import ShedKit

/// A bridge newer than the app may send an item the app cannot read. The rest of the conversation still shows.
final class UnreadableItemTests: XCTestCase {
    private func message(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    private func items(_ message: ServerMessage) throws -> [Item] {
        guard case .snapshot(_, let items, _) = message else { throw XCTSkip("not a snapshot") }
        return items
    }

    @MainActor private func open(_ snapshot: ServerMessage) -> SessionStore {
        let store = SessionStore(defaults: scratchDefaults())
        store.select("one:s")
        store.apply(snapshot, from: "one")
        return store
    }

    private let unknownKind = #"{"id":"b","kind":"diagram","text":"graph","nodes":[1,2]}"#

    @MainActor func testAnItemOfAnUnknownKindShowsAsANoteAmongTheOthers() throws {
        let snapshot = try message(#"""
        {"type":"snapshot","sessionId":"s","earlier":2,"items":[
            {"id":"a","kind":"user","text":"Draw it"},
            \#(unknownKind),
            {"id":"c","kind":"text","text":"Done"}]}
        """#)
        let read = try items(snapshot)
        XCTAssertEqual(read.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(read.map(\.kind), [.user, .note, .text])
        XCTAssertEqual(read[0].text, "Draw it")
        XCTAssertEqual(read[2].text, "Done")
        XCTAssertFalse(read[1].text.isEmpty)
        XCTAssertNotEqual(read[1].text, "graph")

        let store = open(snapshot)
        XCTAssertTrue(store.transcriptLoaded)
        XCTAssertEqual(store.items, read)
        XCTAssertEqual(store.earlier, 2)
    }

    @MainActor func testMalformedItemsDoNotDropTheirNeighbours() throws {
        let snapshot = try message(#"""
        {"type":"snapshot","sessionId":"s","items":[
            {"id":"a","kind":"text","text":"Before"},
            42,
            null,
            {"kind":"text","text":"No id"},
            {"id":"m","kind":"text"},
            {"id":"t","kind":"tool","text":"","status":"levitating"},
            [],
            {"id":"z","kind":"text","text":"After"}]}
        """#)
        let read = try items(snapshot)
        XCTAssertEqual(read.count, 8)
        XCTAssertEqual(read[0], Item(id: "a", kind: .text, text: "Before"))
        XCTAssertEqual(read[7], Item(id: "z", kind: .text, text: "After"))
        XCTAssertEqual(read[1...6].map(\.kind), [.note, .note, .note, .note, .tool, .note])
        XCTAssertEqual(read[4].id, "m")
        // A tool call in a state the app does not know is still a tool call.
        XCTAssertEqual(read[5], Item(id: "t", kind: .tool, text: "", status: .unknown))
        XCTAssertEqual(Set(read.map(\.id)).count, 8)

        XCTAssertEqual(open(snapshot).items, read)
    }

    /// The rest of the patch is the tool's output, and must not go with the status.
    @MainActor func testAPatchWithAnUnknownToolStatusStillBringsTheRest() throws {
        let store = open(try message(#"""
        {"type":"snapshot","sessionId":"s","items":[{"id":"t","kind":"tool","text":"","toolName":"bash","status":"running"}]}
        """#))
        store.apply(try message(#"""
        {"type":"item_patch","sessionId":"s","itemId":"t","set":{"status":"levitating","output":"out","durationMs":12}}
        """#), from: "one")

        XCTAssertEqual(store.items[0].output, "out")
        XCTAssertEqual(store.items[0].durationMs, 12)
        XCTAssertEqual(store.items[0].status, .unknown)
        XCTAssertEqual(store.items[0].toolName, "bash")
    }

    /// A session as the bridge sends it, with `changes` over it.
    @MainActor private func session(_ id: String, _ changes: [String: Any] = [:]) throws -> String {
        let summary = SessionSummary(id: id, agent: .pi, kind: .root, name: nil, runningSubagents: false,
                                     readOnly: false, cwd: "/tmp", title: id, status: .idle, error: nil, createdAt: 0,
                                     model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                                     cost: 0, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                                     contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                                     stuck: nil, lastActiveAt: nil, goal: nil, question: nil, spend: nil, sites: nil)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        json.merge(changes) { $1 }
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    @MainActor func testASessionInAStateTheAppDoesNotKnowIsStillListedAndUpdated() throws {
        let store = SessionStore(defaults: scratchDefaults())
        let listed = try message(#"{"type":"sessions","sessions":[\#(try session("a")),\#(try session("b", ["status": "hibernating"]))]}"#)
        store.apply(listed, from: "one")
        XCTAssertEqual(Set(store.sessions.keys), ["one:a", "one:b"])
        XCTAssertEqual(store.sessions["one:b"]?.status, .unknown)
        XCTAssertEqual(store.sessions["one:b"]?.isActive, false)

        store.apply(try message(#"{"type":"session","session":\#(try session("a", ["status": "hibernating", "title": "Renamed"]))}"#), from: "one")
        XCTAssertEqual(store.sessions["one:a"]?.status, .unknown)
        XCTAssertEqual(store.sessions["one:a"]?.title, "Renamed")
    }

    /// The app has no way to draw or drive an agent it does not know, so its sessions are not listed.
    @MainActor func testASessionOfAnAgentTheAppDoesNotKnowIsLeftOutOfTheList() throws {
        let store = SessionStore(defaults: scratchDefaults())
        let listed = try message(#"{"type":"sessions","sessions":[\#(try session("a")),\#(try session("b", ["agent": "hal"]))]}"#)
        store.apply(listed, from: "one")
        XCTAssertEqual(Set(store.sessions.keys), ["one:a"])
        XCTAssertThrowsError(try message(#"{"type":"session","session":\#(try session("b", ["agent": "hal"]))}"#))
    }

    /// Only what the bridge sends is read as unknown: asked by name, a state the app does not know is none at all.
    func testAnUnknownValueIsNotAValueByName() {
        XCTAssertNil(ToolStatus(rawValue: "levitating"))
        XCTAssertNil(SessionStatus(rawValue: "hibernating"))
    }

    @MainActor func testAnAddedItemTheAppCannotReadIsAddedAsANote() throws {
        let store = open(try message(#"{"type":"snapshot","sessionId":"s","items":[{"id":"a","kind":"text","text":"Before"}]}"#))
        store.apply(try message(#"{"type":"item_add","sessionId":"s","item":\#(unknownKind)}"#), from: "one")
        store.apply(try message(#"{"type":"item_add","sessionId":"s","item":"nothing like an item"}"#), from: "one")
        store.apply(try message(#"{"type":"item_add","sessionId":"s","item":{"kind":"text"}}"#), from: "one")
        store.apply(try message(#"{"type":"item_add","sessionId":"s","item":{"id":"z","kind":"text","text":"After"}}"#), from: "one")

        XCTAssertEqual(store.items.count, 5)
        XCTAssertEqual(store.items.map(\.kind), [.text, .note, .note, .note, .text])
        XCTAssertEqual(store.items[1].id, "b")
        XCTAssertEqual(store.items[4].text, "After")
    }

    /// The bridge goes on patching the item it sent. None of that belongs in the note standing for it.
    @MainActor func testPatchesToAnItemShownAsANoteLeaveTheNoteAsItIs() throws {
        let store = open(try message(#"{"type":"snapshot","sessionId":"s","items":[\#(unknownKind),{"id":"c","kind":"text","text":"Done"}]}"#))
        let note = store.items[0]

        store.apply(try message(#"{"type":"item_patch","sessionId":"s","itemId":"b","append":{"text":" more"}}"#), from: "one")
        store.apply(try message(#"{"type":"item_patch","sessionId":"s","itemId":"b","set":{"text":"replaced","status":"done","output":"out"}}"#), from: "one")
        store.apply(try message(#"{"type":"item_patch","sessionId":"s","itemId":"c","set":{"text":"Done."}}"#), from: "one")

        XCTAssertEqual(store.items[0], note)
        XCTAssertEqual(store.items[1].text, "Done.")
    }

    func testAPageOfEarlierItemsKeepsWhatItCanRead() throws {
        let page = try JSONDecoder().decode(EarlierItems.self, from: Data(#"""
        {"earlier":3,"items":[{"id":"a","kind":"text","text":"Before"},\#(unknownKind),7]}
        """#.utf8))
        XCTAssertEqual(page.earlier, 3)
        XCTAssertEqual(page.items.map(\.kind), [.text, .note, .note])
        XCTAssertEqual(page.items[1].id, "b")
    }
}
