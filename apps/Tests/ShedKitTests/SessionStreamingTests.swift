import XCTest
@testable import ShedKit

final class SessionStreamingTests: XCTestCase {
    @MainActor private func summary(_ id: String, status: SessionStatus = .running) -> SessionSummary {
        SessionSummary(id: id, agent: .deepseek, kind: .root, name: nil, runningSubagents: false,
                       readOnly: false, cwd: "/tmp", title: id, status: status, error: nil, createdAt: 0,
                       model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                       cost: 0, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                       contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                       stuck: nil, lastActiveAt: nil, goal: nil, question: nil, spend: nil, sites: nil)
    }

    @MainActor func testSelectedSessionTransitionsAndItemsCommitText() {
        let store = SessionStore(defaults: scratchDefaults())
        store.select("test:reply")
        store.apply(.session(summary("reply")), from: "test")
        store.apply(.snapshot(sessionId: "reply", items: [Item(id: "text", kind: .text, text: "Start ")], earlier: 0), from: "test")
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "one ")), from: "test")
        store.apply(.session(summary("reply")), from: "test")
        store.apply(.itemAdd(sessionId: "other", item: Item(id: "ignored", kind: .tool, text: "")), from: "test")
        XCTAssertEqual(store.items[0].text, "Start ")
        store.apply(.itemAdd(sessionId: "reply", item: Item(id: "tool", kind: .tool, text: "")), from: "test")
        XCTAssertEqual(store.items[0].text, "Start one ")
        store.apply(.itemPatch(sessionId: "reply", itemId: "tool", set: ItemSet(status: .done), append: nil), from: "test")
        XCTAssertEqual(store.items[1].status, .done)
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "two ")), from: "test")
        store.apply(.sessions([summary("reply", status: .idle)]), from: "test")
        XCTAssertEqual(store.items[0].text, "Start one two ")
    }

    /// The store's waits, each held until the test lets it go: no clock is read.
    @MainActor final class HeldPauses {
        private(set) var asked: [Duration] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var held: Int { waiting.count }

        func pause(_ time: Duration) async {
            asked.append(time)
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Lets go of the oldest wait only.
        func releaseFirst() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }

        func release() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    @MainActor private func store(_ pauses: HeldPauses) -> SessionStore {
        let store = SessionStore(defaults: scratchDefaults(), connection: { ScriptedBridge() }, pause: { await pauses.pause($0) })
        store.select("test:reply")
        store.apply(.session(summary("reply")), from: "test")
        store.apply(.snapshot(sessionId: "reply", items: [Item(id: "text", kind: .text, text: "Start ")], earlier: 0), from: "test")
        return store
    }

    /// A burst keeps one deadline: a thousand deltas wait on one pause of 80 ms, and show together when it ends.
    @MainActor func testThousandDeltaBurstStaysBatched() async {
        let pauses = HeldPauses()
        let store = store(pauses)
        for i in 0..<1000 {
            store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "word ")), from: "test")
            store.apply(.session(summary("other-\(i % 10)")), from: "test")
        }
        let held = await eventually { pauses.held == 1 }
        XCTAssertTrue(held)
        XCTAssertEqual(pauses.asked, [.milliseconds(80)])
        XCTAssertEqual(store.items[0].text, "Start ")
        XCTAssertTrue(store.live.texts.isEmpty)
        pauses.release()
        let expected = "Start " + String(repeating: "word ", count: 1000)
        let shown = await eventually { store.live.texts["text"] == expected }
        XCTAssertTrue(shown)
        XCTAssertEqual(store.items[0].text, "Start ")
        store.apply(.session(summary("reply", status: .idle)), from: "test")
        XCTAssertEqual(store.items[0].text, expected)
        XCTAssertTrue(store.live.texts.isEmpty)
    }

    /// A change of state flushes at once and calls the waiting deadline off: text after it waits on a deadline of its
    /// own, not on the rest of the old one.
    @MainActor func testForcedFlushCancelsReadyTimer() async {
        let pauses = HeldPauses()
        let store = store(pauses)
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "old ")), from: "test")
        let first = await eventually { pauses.held == 1 }
        XCTAssertTrue(first)
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: ItemSet(text: "Replaced "), append: nil), from: "test")
        XCTAssertEqual(store.items[0].text, "Replaced ")
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "new ")), from: "test")
        let second = await eventually { pauses.held == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(pauses.asked, [.milliseconds(80), .milliseconds(80)])
        XCTAssertNil(store.live.texts["text"])
        // The old deadline ending shows nothing: it was called off.
        pauses.releaseFirst()
        let early = await eventually { store.live.texts["text"] != nil }
        XCTAssertFalse(early)
        pauses.release()
        let shown = await eventually { store.live.texts["text"] == "Replaced new " }
        XCTAssertTrue(shown)
        store.apply(.session(summary("reply", status: .idle)), from: "test")
        XCTAssertEqual(store.items[0].text, "Replaced new ")
        XCTAssertTrue(store.live.texts.isEmpty)
    }
}
