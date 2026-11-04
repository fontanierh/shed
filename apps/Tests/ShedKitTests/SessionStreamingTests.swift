import XCTest
import Observation
@testable import ShedKit

final class SessionStreamingTests: XCTestCase {
    @MainActor private func summary(_ id: String, status: SessionStatus = .running) -> SessionSummary {
        SessionSummary(id: id, agent: .deepseek, kind: .root, name: nil, depth: 0, runningSubagents: false,
                       readOnly: false, cwd: "/tmp", title: id, status: status, error: nil, createdAt: 0,
                       model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                       cost: 0, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                       contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                       stuck: nil, lastActiveAt: nil, goal: nil, question: nil, spend: nil)
    }

    @MainActor func testSelectedSessionTransitionsAndItemsCommitText() {
        let store = SessionStore()
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

    @MainActor private func waitForLive(_ store: SessionStore, _ key: String, upTo ms: Int) async -> Int {
        var waited = 0
        while waited < ms {
            if store.live.texts[key] != nil { return waited }
            try? await Task.sleep(for: .milliseconds(10), tolerance: .zero)
            waited += 10
        }
        return -1
    }

    @MainActor func testThousandDeltaBurstStaysBatched() async {
        let store = SessionStore()
        store.select("test:reply")
        store.apply(.session(summary("reply")), from: "test")
        store.apply(.snapshot(sessionId: "reply", items: [Item(id: "text", kind: .text, text: "Start ")], earlier: 0), from: "test")
        for i in 0..<1000 {
            store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "word ")), from: "test")
            store.apply(.session(summary("other-\(i % 10)")), from: "test")
        }
        XCTAssertEqual(store.items[0].text, "Start ")
        XCTAssertTrue(store.live.texts.isEmpty)
        // The deadline bounds batching, not how soon a loaded main actor must service it.
        let appeared = await waitForLive(store, "text", upTo: 2000)
        XCTAssertGreaterThanOrEqual(appeared, 0)
        let expected = "Start " + String(repeating: "word ", count: 1000)
        XCTAssertEqual(store.live.texts["text"], expected)
        XCTAssertEqual(store.items[0].text, "Start ")
        store.apply(.session(summary("reply", status: .idle)), from: "test")
        XCTAssertEqual(store.items[0].text, expected)
        XCTAssertTrue(store.live.texts.isEmpty)
    }

    @MainActor func testForcedFlushCancelsReadyTimer() {
        let store = SessionStore()
        store.select("test:reply")
        store.apply(.session(summary("reply")), from: "test")
        store.apply(.snapshot(sessionId: "reply", items: [Item(id: "text", kind: .text, text: "Start ")], earlier: 0), from: "test")
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "old ")), from: "test")
        // Start the sleeper, then keep its ready continuation waiting on the main actor.
        RunLoop.current.run(until: .now + 0.01)
        Thread.sleep(forTimeInterval: 0.3)
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: ItemSet(text: "Replaced "), append: nil), from: "test")
        let resumed = ContinuousClock.now
        @MainActor final class Publication {
            var at: ContinuousClock.Instant?
        }
        let publication = Publication()
        withObservationTracking {
            _ = store.live.texts
        } onChange: {
            MainActor.assumeIsolated { publication.at = .now }
        }
        store.apply(.itemPatch(sessionId: "reply", itemId: "text", set: nil, append: ItemAppend(text: "new ")), from: "test")
        RunLoop.current.run(until: .now + 0.3)
        XCTAssertNotNil(publication.at)
        if let at = publication.at { XCTAssertGreaterThanOrEqual(at - resumed, .milliseconds(80)) }
        XCTAssertEqual(store.live.texts["text"], "Replaced new ")
        store.apply(.session(summary("reply", status: .idle)), from: "test")
        XCTAssertEqual(store.items[0].text, "Replaced new ")
        XCTAssertTrue(store.live.texts.isEmpty)
    }
}
