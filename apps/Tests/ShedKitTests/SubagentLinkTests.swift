import XCTest
@testable import ShedKit

final class SubagentLinkTests: XCTestCase {
    @MainActor private func summary(_ id: String, parent: String? = nil, name: String? = nil, createdAt: Double = 0,
                                    status: SessionStatus = .idle, lastActiveAt: Double? = nil) -> SessionSummary {
        var summary = SessionSummary(id: id, agent: .prime, kind: parent == nil ? .root : .subagent, name: name,
                                     runningSubagents: false, readOnly: false, cwd: "/tmp", title: id, status: status, error: nil,
                                     createdAt: createdAt, model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                                     cost: 0, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                                     contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                                     stuck: nil, lastActiveAt: lastActiveAt, goal: nil, question: nil, spend: nil, sites: nil)
        summary.parentId = parent
        return summary
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// A session may name one subagent after another the same: the time of the mention tells which one it means.
    @MainActor func testMentionLeadsToTheSubagentOfItsTime() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([
            summary("p"),
            summary("first", parent: "p", name: "scout", createdAt: 10_000),
            summary("second", parent: "p", name: "scout", createdAt: 100_000),
        ]), from: "test")
        func link(_ seconds: Double, spawning: Bool = false) -> SubagentLink {
            store.link(of: "test:p", to: SubagentMention(name: "scout", date: date(seconds), spawning: spawning))
        }
        // The call that starts a subagent comes just before it; what it sends comes after.
        XCTAssertEqual(link(9, spawning: true), .open("test:first"))
        XCTAssertEqual(link(98, spawning: true), .open("test:second"))
        XCTAssertEqual(link(60), .open("test:first"))
        XCTAssertEqual(link(160), .open("test:second"))
        XCTAssertEqual(store.link(of: "test:p", to: SubagentMention(name: "scout", date: nil)), .open("test:second"))
    }

    /// A subagent nobody lists is on its way while its call runs, and gone once that is long past.
    @MainActor func testUnlistedSubagentIsPendingThenEnded() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("p")]), from: "test")
        let old = date(1000)
        XCTAssertEqual(store.link(of: "test:p", to: SubagentMention(name: "scout", date: old, spawning: true, running: true)), .pending)
        XCTAssertEqual(store.link(of: "test:p", to: SubagentMention(name: "scout", date: .now, spawning: true)), .pending)
        XCTAssertEqual(store.link(of: "test:p", to: SubagentMention(name: "scout", date: old, spawning: true)), .ended)
    }

    /// Opening a subagent the bridge can't attach to marks it ended without an alert; it leaves the lists, its
    /// mentions lead nowhere, and it comes back if it works again.
    @MainActor func testSubagentThatCannotBeOpenedEnds() async {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("p"), summary("c", parent: "p", name: "scout", createdAt: 10_000, lastActiveAt: 10_000)]), from: "test")
        let mention = SubagentMention(name: "scout", date: date(60))
        XCTAssertEqual(store.link(of: "test:p", to: mention), .open("test:c"))
        // A bridge out of reach says nothing about the subagent: that is an error like any other.
        await store.attachFailed("test:c", BridgeError("timed out"))
        XCTAssertFalse(store.ended.contains("test:c"))
        XCTAssertEqual(store.errorMessage, "timed out")
        store.errorMessage = nil
        // What the bridge answers for a subagent the agent has let go of.
        await store.attachFailed("test:c", BridgeError("session ended"))
        XCTAssertTrue(store.ended.contains("test:c"))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.link(of: "test:p", to: mention), .ended)
        store.select(nil)
        XCTAssertTrue(store.children(of: "test:p").isEmpty)
        XCTAssertEqual(store.endedChildren(of: "test:p").map(\.id), ["test:c"])
        XCTAssertTrue(store.activeSubagents.isEmpty)

        store.apply(.session(summary("c", parent: "p", name: "scout", createdAt: 10_000, status: .running, lastActiveAt: 20_000)), from: "test")
        XCTAssertFalse(store.ended.contains("test:c"))
        XCTAssertEqual(store.link(of: "test:p", to: mention), .open("test:c"))
    }
}
