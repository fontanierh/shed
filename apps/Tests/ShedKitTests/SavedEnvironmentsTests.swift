import XCTest
@testable import ShedKit

/// The saved list of computers holds their tokens: a list the app cannot read must never be replaced by a fresh one.
final class SavedEnvironmentsTests: XCTestCase {
    private let key = "environments"
    private let keptKey = "environmentsUnread"

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private let one = #"{"id":"aaaa1111","name":"Desk","url":"wss://desk.example:7878/ws","token":"t-one"}"#
    private let two = #"{"id":"bbbb2222","name":"Laptop","url":"wss://laptop.example:7878/ws","token":"t-two"}"#

    @MainActor func testNothingSavedReadsAsNothing() {
        XCTAssertNil(SessionStore.readEnvironments(nil))
    }

    @MainActor func testAListIsReadWhole() throws {
        let saved = try XCTUnwrap(SessionStore.readEnvironments(json("[\(one),\(two)]")))
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.environments.map(\.id), ["aaaa1111", "bbbb2222"])
        XCTAssertEqual(saved.environments[1].token, "t-two")
    }

    /// As an older version's list looks to a version that has added a field.
    @MainActor func testAComputerWithoutANameOrTokenIsStillRead() throws {
        let saved = try XCTUnwrap(SessionStore.readEnvironments(json(#"[{"id":"cccc3333","url":"wss://desk.example:7878/ws"}]"#)))
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.environments, [BridgeEnvironment(id: "cccc3333", name: "desk", url: "wss://desk.example:7878/ws", token: "")])
    }

    @MainActor func testOneUnreadableComputerDoesNotHideTheOthers() throws {
        let saved = try XCTUnwrap(SessionStore.readEnvironments(json(#"[\#(one),{"id":"dddd4444","name":"No address"},7,\#(two)]"#)))
        XCTAssertFalse(saved.complete)
        XCTAssertEqual(saved.environments.map(\.id), ["aaaa1111", "bbbb2222"])
    }

    @MainActor func testDataThatIsNoListReadsAsEmptyAndIncomplete() {
        for text in ["not json", #"{"id":"aaaa1111"}"#, ""] {
            XCTAssertEqual(SessionStore.readEnvironments(json(text)), SavedEnvironments(environments: [], complete: false), text)
        }
    }

    @MainActor func testAListThatCannotBeReadIsLeftAsItWasAndSaidSo() {
        let defaults = scratchDefaults()
        let raw = json(#"{"version":2,"computers":[\#(one)]}"#)
        defaults.set(raw, forKey: key)
        // What a first launch would turn into a computer.
        defaults.set("wss://old.example:7878/ws", forKey: "bridgeURL")
        defaults.set("t-old", forKey: "bridgeToken")

        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: key), raw)
        XCTAssertEqual(store.environments, [])
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testAListPartlyReadIsKeptWholeWhenTheReadPartIsSaved() throws {
        let defaults = scratchDefaults()
        let raw = json(#"[\#(one),{"id":"dddd4444","name":"No address","token":"t-lost"}]"#)
        defaults.set(raw, forKey: key)

        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(store.environments.map(\.id), ["aaaa1111"])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(defaults.data(forKey: key), raw)
        XCTAssertNil(defaults.data(forKey: keptKey))

        store.moveEnvironments(from: IndexSet(integer: 0), to: 0)
        XCTAssertEqual(defaults.data(forKey: keptKey), raw)
        let saved = try XCTUnwrap(SessionStore.readEnvironments(defaults.data(forKey: key)))
        XCTAssertEqual(saved, SavedEnvironments(environments: store.environments, complete: true))
    }

    @MainActor func testAListReadWholeIsSavedWithoutACopy() {
        let defaults = scratchDefaults()
        defaults.set(json("[\(one),\(two)]"), forKey: key)

        let store = SessionStore(defaults: defaults)
        XCTAssertNil(store.errorMessage)
        store.moveEnvironments(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.environments.map(\.id), ["bbbb2222", "aaaa1111"])
        XCTAssertNil(defaults.data(forKey: keptKey))
    }

    @MainActor func testWithNothingSavedTheOldSingleBridgeBecomesAComputer() {
        let defaults = scratchDefaults()
        defaults.set("wss://old.example:7878/ws", forKey: "bridgeURL")
        defaults.set("t-old", forKey: "bridgeToken")

        let store = SessionStore(defaults: defaults)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.environments.last?.url, "wss://old.example:7878/ws")
        XCTAssertEqual(store.environments.last?.token, "t-old")
        XCTAssertNotNil(defaults.data(forKey: key))
    }

    /// The settings the tests hand to a store answer every kind of read the store makes themselves.
    func testScratchSettingsAnswerEveryKindOfRead() {
        let defaults = scratchDefaults()
        XCTAssertFalse(defaults.bool(forKey: "replay"))
        XCTAssertEqual(defaults.integer(forKey: "replayCount"), 0)
        XCTAssertNil(defaults.string(forKey: "select"))
        defaults.set(true, forKey: "replay")
        defaults.set(7, forKey: "replayCount")
        defaults.set("one:s", forKey: "select")
        XCTAssertTrue(defaults.bool(forKey: "replay"))
        XCTAssertEqual(defaults.integer(forKey: "replayCount"), 7)
        XCTAssertEqual(defaults.string(forKey: "select"), "one:s")
    }

    @MainActor func testDraftsAreKeptInTheSettingsTheStoreWasGiven() {
        let defaults = scratchDefaults()
        SessionStore(defaults: defaults).setDraft("Half a thought", for: "one:s")
        XCTAssertEqual(SessionStore(defaults: defaults).drafts["one:s"], "Half a thought")
    }
}
