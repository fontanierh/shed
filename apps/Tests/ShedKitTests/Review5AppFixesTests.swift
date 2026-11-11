import XCTest
@testable import ShedKit

final class Review5AppFixesTests: XCTestCase {
    @MainActor func testFeedRowDoesNotCacheEmptySpawnedOnPreparingStep() {
        let preparing = Item(id: "i1", kind: .tool, text: "", toolName: "python_repl", args: "", status: .preparing)
        let blocks1 = Activity.blocks([preparing], busy: true)
        guard case .activity(let act1) = blocks1[0] else { return XCTFail("expected activity") }
        let row = FeedRow(blocks1[0], streaming: true)
        XCTAssertTrue(row.spawned(act1).isEmpty)

        let settled = Item(
            id: "i1",
            kind: .tool,
            text: "",
            toolName: "python_repl",
            args: #"await rlm.spawn("task", name="scout")"#,
            status: .done
        )
        let blocks2 = Activity.blocks([settled], busy: false)
        guard case .activity(let act2) = blocks2[0] else { return XCTFail("expected activity") }
        row.block = blocks2[0]
        XCTAssertEqual(row.spawned(act2).map(\.name), ["scout"])
    }

    func testStreamingMarkdownSplitsCRLFAndRespectsNestedAndInlineFences() {
        XCTAssertEqual(
            StreamingMarkdown.blockTexts("# Heading\r\n\r\nFirst paragraph\r\n\r\nSecond paragraph"),
            ["# Heading", "First paragraph", "Second paragraph"]
        )

        let nested = """
        ````markdown
        ```bash
        echo 1

        echo 2
        ```
        ````

        After fence
        """
        XCTAssertEqual(StreamingMarkdown.blockTexts(nested).count, 2)

        let inlineStart = """
        ```foo``` is inline code at line start.

        Second paragraph.
        """
        XCTAssertEqual(StreamingMarkdown.blockTexts(inlineStart).count, 2)
    }

    @MainActor func testDuplicateItemIdsInSnapshotDoNotCrashAndKeepLatest() {
        let store = SessionStore(defaults: scratchDefaults())
        let summary = SessionSummary(
            id: "s", agent: .pi, kind: .root, name: nil, runningSubagents: false, readOnly: false,
            cwd: "/tmp", title: "s", status: .idle, error: nil, createdAt: 0, model: nil,
            thinkingLevel: nil, thinkingLevels: [], context: nil, cost: 0,
            queue: Queue(steering: [], followUp: []), autoCompaction: true, contextLimit: nil,
            standardWindow: nil, backgroundJobs: 0, waitingOn: nil, stuck: nil, lastActiveAt: nil,
            goal: nil, question: nil, spend: nil, sites: nil
        )
        store.apply(.sessions([summary]), from: "one")
        store.select("one:s")
        store.apply(
            .snapshot(
                sessionId: "s",
                items: [
                    Item(id: "dup", kind: .text, text: "first"),
                    Item(id: "dup", kind: .text, text: "second"),
                ],
                earlier: 0
            ),
            from: "one"
        )
        XCTAssertEqual(store.items.count, 2)
        store.apply(
            .itemPatch(sessionId: "s", itemId: "dup", set: ItemSet(text: "updated"), append: nil),
            from: "one"
        )
        XCTAssertEqual(store.items.last?.text, "updated")
    }

    @MainActor func testQuestionCardCompleteAllowsMixedOptionAndOptionlessQuestions() throws {
        let raw = #"""
        {
          "id": "q-batch",
          "questions": [
            { "id": "mode", "question": "Mode?", "options": [{ "label": "Fast" }] },
            { "id": "notes", "question": "Any notes?" }
          ]
        }
        """#
        let batch = try JSONDecoder().decode(AgentQuestion.self, from: Data(raw.utf8))
        XCTAssertFalse(QuestionCard.isComplete(questions: batch.questions, picked: [:]))
        XCTAssertTrue(QuestionCard.isComplete(questions: batch.questions, picked: ["mode": ["Fast"]]))
    }
}
