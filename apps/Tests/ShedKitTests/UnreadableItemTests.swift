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
        XCTAssertEqual(read[1...6].map(\.kind), Array(repeating: .note, count: 6))
        XCTAssertEqual(read[4].id, "m")
        XCTAssertEqual(read[5].id, "t")
        XCTAssertEqual(Set(read.map(\.id)).count, 8)

        XCTAssertEqual(open(snapshot).items, read)
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
