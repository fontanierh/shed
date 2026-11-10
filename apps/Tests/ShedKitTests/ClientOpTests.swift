import XCTest
@testable import ShedKit

/// protocol/client_ops.json holds every operation as the bridge accepts it, and the bridge's own tests parse the file.
/// Writing one of each here and comparing means an operation the app adds, renames or sends differently fails until
/// the file, and so the bridge, agrees.
final class ClientOpTests: XCTestCase {
    /// Every operation, in each shape the app sends it.
    private let examples: [ClientOp] = [
        .ping,
        .createSession(agent: .pi, cwd: "/work/project", model: nil, thinking: nil),
        .createSession(agent: .prime, cwd: "/work/project", model: "example/model-1", thinking: "high"),
        .attach(sessionId: "s1"),
        .detach(sessionId: "s1"),
        .send(sessionId: "s1", text: "Run the tests"),
        .followUp(sessionId: "s1", text: "Then open a pull request"),
        .abort(sessionId: "s1"),
        .stopTool(sessionId: "s1"),
        .compact(sessionId: "s1"),
        .newSession(sessionId: "s1"),
        .listModels(sessionId: "s1"),
        .setModel(sessionId: "s1", provider: "example", modelId: "model-1"),
        .setThinking(sessionId: "s1", level: "high"),
        .setAutoCompaction(sessionId: "s1", enabled: false),
        .resumeSession(sessionId: "s1"),
        .renameSession(sessionId: "s1", name: "Tests"),
        .setContextLimit(sessionId: "s1", limit: 200_000),
        .setContextLimit(sessionId: "s1", limit: nil),
        .clearGoal(sessionId: "s1"),
        .restartKernel(sessionId: "s1"),
        .closeSession(sessionId: "s1"),
        .deleteSession(sessionId: "s1"),
        .listJobs(sessionId: "s1"),
        .jobOutput(sessionId: "s1", jobId: "job-1", lines: 200),
        .killJob(sessionId: "s1", jobId: "job-1"),
        .answerQuestion(sessionId: "s1", questionId: "q1", picked: ["mode": ["Fast"]]),
        .answerQuestion(sessionId: "s1", questionId: "q1", picked: [:]),
        .loadEarlier(sessionId: "s1", before: "i1"),
        .listAgentModels(agent: .deepseek),
        .listDir(path: nil, hidden: false),
        .listDir(path: "/work", hidden: true),
        .gitBranch(path: "/work/project"),
        .githubOverview,
    ]

    /// The bridge accepts these, the app does not send them.
    private let bridgeOnly: [[String: Any]] = [
        ["op": "list_sessions"],
        ["op": "compact", "sessionId": "s1", "instructions": "Keep the test names"],
    ]

    private func fixture() throws -> [[String: Any]] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/client_ops.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    /// An operation without the id of its reply, as text: `false` is not `0` there, and a `null` is not a missing key.
    private func text(_ op: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: op.filter { $0.key != "id" }, options: [.sortedKeys]), as: UTF8.self)
    }

    private func sent(_ op: ClientOp) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(op.message(id: "c1").utf8)) as? [String: Any])
    }

    func testEveryOperationHasAnExample() {
        let missing = Set(ClientOp.Name.allCases).subtracting(examples.map(\.name))
        XCTAssertEqual(missing, [], "an operation without an example in this test")
    }

    func testTheAppSendsEachOperationAsTheFileHasIt() throws {
        let listed = Set(try fixture().map(text))
        for op in examples {
            let sent = try sent(op)
            XCTAssertEqual(sent["id"] as? String, "c1")
            XCTAssertEqual(sent["op"] as? String, op.name.rawValue)
            let text = try text(sent)
            XCTAssertTrue(listed.contains(text), "protocol/client_ops.json has no \(text)")
        }
    }

    func testTheFileHasNothingTheAppDoesNotSendButWhatIsNamedHere() throws {
        let sent = Set(try examples.map { try text(sent($0)) })
        let bridgeOnly = Set(try bridgeOnly.map(text))
        let listed = Set(try fixture().map(text))
        XCTAssertEqual(listed.subtracting(sent), bridgeOnly)
        XCTAssertEqual(sent.intersection(bridgeOnly), [])
        // An operation the app never sends has no case at all.
        XCTAssertNil(ClientOp.Name(rawValue: "list_sessions"))
    }

    /// Sent again after a dropped connection even when the first may have arrived. Anything else done twice could do
    /// harm: a message sent twice, two sessions made.
    func testOnlyTheseAreSentAgainWhenTheFirstMayHaveArrived() {
        let repeatable = Set(examples.filter(\.repeatable).map(\.name.rawValue))
        XCTAssertEqual(repeatable, ["attach", "abort", "stop_tool", "set_thinking", "set_auto_compaction", "set_context_limit", "set_model",
                                    "resume_session", "close_session", "clear_goal"])
    }
}
