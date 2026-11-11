import XCTest
@testable import ShedKit

/// What the bridge sends, as the store's readers then see it. The messages come from computers that were never added,
/// so nothing connects.
final class SessionStoreTests: XCTestCase {
    @MainActor private func summary(_ id: String, parent: String? = nil, createdAt: Double = 0, status: SessionStatus = .idle,
                                    sites: [Site]? = nil, agent: AgentKind = .prime, cost: Double = 0) -> SessionSummary {
        var summary = SessionSummary(id: id, agent: agent, kind: parent == nil ? .root : .subagent, name: nil,
                                     runningSubagents: false, readOnly: false, cwd: "/tmp", title: id, status: status, error: nil,
                                     createdAt: createdAt, model: nil, thinkingLevel: nil, thinkingLevels: [], context: nil,
                                     cost: cost, queue: Queue(steering: [], followUp: []), autoCompaction: true,
                                     contextLimit: nil, standardWindow: nil, backgroundJobs: 0, waitingOn: nil,
                                     stuck: nil, lastActiveAt: nil, goal: nil, question: nil, spend: nil, sites: sites)
        summary.parentId = parent
        return summary
    }

    private func site(_ port: Int, published: Bool) -> Site {
        Site(port: port, title: nil, command: "node", url: "http://127.0.0.1:\(port)/", published: published, exposed: false, reason: nil)
    }

    @MainActor func testSessionIdsCarryTheirComputer() throws {
        XCTAssertEqual(SessionStore.tag("one", "s1"), "one:s1")
        let split = try XCTUnwrap(SessionStore.split("one:s1"))
        XCTAssertEqual(split.env, "one")
        XCTAssertEqual(split.raw, "s1")
        // Only the first colon divides: the bridge's own id may hold more.
        XCTAssertEqual(SessionStore.split("one:a:b")?.raw, "a:b")
        XCTAssertNil(SessionStore.split("s1"))
    }

    @MainActor func testAListReplacesOnlyItsOwnComputersSessions() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("a"), summary("b", parent: "a")]), from: "one")
        store.apply(.sessions([summary("a")]), from: "two")
        XCTAssertEqual(Set(store.sessions.keys), ["one:a", "one:b", "two:a"])
        XCTAssertEqual(store.sessions["one:b"]?.id, "one:b")
        XCTAssertEqual(store.sessions["one:b"]?.parentId, "one:a")
        XCTAssertEqual(store.snapshots, 2)

        store.apply(.sessions([summary("c")]), from: "one")
        XCTAssertEqual(Set(store.sessions.keys), ["one:c", "two:a"])
        XCTAssertEqual(store.snapshots, 3)

        store.apply(.session(summary("d", parent: "c")), from: "one")
        XCTAssertEqual(store.sessions["one:d"]?.parentId, "one:c")
        XCTAssertEqual(store.snapshots, 3)
    }

    @MainActor func testTheTreeHasNewestRootsFirstAndSubagentsInTheOrderTheyStarted() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([
            summary("old", createdAt: 1),
            summary("new", createdAt: 2),
            summary("late", parent: "old", createdAt: 5, status: .running),
            summary("early", parent: "old", createdAt: 3, status: .running),
            summary("deep", parent: "early", createdAt: 4, status: .running),
        ]), from: "one")
        // Its parent is not listed: it stands as a root.
        store.apply(.sessions([summary("orphan", parent: "gone", status: .running)]), from: "two")

        let tree = store.tree(in: "one")
        XCTAssertEqual(tree.map(\.id), ["one:new", "one:old"])
        XCTAssertNil(tree[0].children)
        XCTAssertEqual(tree[1].children?.map(\.id), ["one:early", "one:late"])
        XCTAssertEqual(tree[1].children?[0].children?.map(\.id), ["one:deep"])
        XCTAssertEqual(store.tree(in: "two").map(\.id), ["two:orphan"])
        XCTAssertEqual(Set(store.tree(in: nil).map(\.id)), ["one:new", "one:old", "two:orphan"])

        XCTAssertEqual(store.activeDescendants(of: "one:old"), 3)
        XCTAssertEqual(store.activeDescendants(of: "one:new"), 0)
        XCTAssertEqual(store.parent(of: store.sessions["one:deep"]!)?.id, "one:early")
        XCTAssertEqual(store.activeSubagents.map(\.id), ["two:orphan", "one:early", "one:deep", "one:late"])
    }

    /// A subagent idle for long is taken to be gone, unless it is the one open.
    @MainActor func testASubagentLongIdleLeavesTheListUnlessOpen() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([
            summary("p"),
            summary("idle", parent: "p", createdAt: 1),
            summary("busy", parent: "p", createdAt: 2, status: .running),
        ]), from: "one")
        XCTAssertEqual(store.children(of: "one:p").map(\.id), ["one:busy"])
        store.select("one:idle")
        XCTAssertEqual(store.children(of: "one:p").map(\.id), ["one:idle", "one:busy"])
    }

    @MainActor func testAnOpenSubagentThatIsRemovedGivesWayToItsParent() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("p"), summary("c", parent: "p", status: .running)]), from: "one")
        store.select("one:c")
        store.apply(.sessionRemoved("c"), from: "one")
        XCTAssertNil(store.sessions["one:c"])
        XCTAssertEqual(store.selectedId, "one:p")
        store.apply(.sessionRemoved("p"), from: "one")
        XCTAssertNil(store.selectedId)
    }

    @MainActor func testAListWithoutTheOpenSessionClosesIt() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("a")]), from: "one")
        store.select("one:a")
        // Another computer's list says nothing about this one's sessions.
        store.apply(.sessions([summary("b")]), from: "two")
        XCTAssertEqual(store.selectedId, "one:a")
        store.apply(.sessions([summary("b")]), from: "one")
        XCTAssertNil(store.selectedId)
    }

    @MainActor func testTheTranscriptIsTheOpenSessionsAlone() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([summary("s"), summary("other")]), from: "one")
        store.select("one:s")
        XCTAssertFalse(store.transcriptLoaded)

        store.apply(.snapshot(sessionId: "other", items: [Item(id: "x", kind: .text, text: "Elsewhere")], earlier: 9), from: "one")
        XCTAssertFalse(store.transcriptLoaded)
        XCTAssertTrue(store.items.isEmpty)

        let items = [Item(id: "u", kind: .user, text: "Hello"), Item(id: "t", kind: .text, text: "Hi")]
        store.apply(.snapshot(sessionId: "s", items: items, earlier: 4), from: "one")
        XCTAssertTrue(store.transcriptLoaded)
        XCTAssertEqual(store.items, items)
        XCTAssertEqual(store.transcript, items)
        XCTAssertEqual(store.earlier, 4)

        // The same session's id on another computer is another session.
        store.apply(.itemAdd(sessionId: "s", item: Item(id: "far", kind: .text, text: "Far")), from: "two")
        // An item already there is not added again.
        store.apply(.itemAdd(sessionId: "s", item: Item(id: "t", kind: .text, text: "Again")), from: "one")
        XCTAssertEqual(store.items, items)

        store.apply(.itemAdd(sessionId: "s", item: Item(id: "tool", kind: .tool, text: "", status: .running)), from: "one")
        store.apply(.itemPatch(sessionId: "s", itemId: "tool", set: ItemSet(output: "ok", status: .done), append: ItemAppend(args: "ls")), from: "one")
        XCTAssertEqual(store.items.map(\.id), ["u", "t", "tool"])
        XCTAssertEqual(store.items[2].status, .done)
        XCTAssertEqual(store.items[2].output, "ok")
        XCTAssertEqual(store.items[2].args, "ls")
        // A patch for an item that isn't there changes nothing.
        store.apply(.itemPatch(sessionId: "s", itemId: "missing", set: ItemSet(status: .done), append: nil), from: "one")
        XCTAssertEqual(store.items.count, 3)

        // A fresh snapshot replaces what was there.
        store.apply(.snapshot(sessionId: "s", items: [items[0]], earlier: 0), from: "one")
        XCTAssertEqual(store.items, [items[0]])
        XCTAssertEqual(store.earlier, 0)

        store.select(nil)
        XCTAssertFalse(store.transcriptLoaded)
        XCTAssertTrue(store.items.isEmpty)
    }

    /// Open Codex counts a Prime subagent's requests into its parent. Pi's and DeepSeek's each carry their own.
    @MainActor func testASessionsSpendHoldsItsSubagentsOnce() {
        for agent in AgentKind.allCases {
            let store = SessionStore(defaults: scratchDefaults())
            store.apply(.sessions([
                summary("p", agent: agent, cost: 4),
                summary("c", parent: "p", agent: agent, cost: 2),
                summary("g", parent: "c", agent: agent, cost: 1),
                summary("other", agent: agent, cost: 8),
            ]), from: "one")
            let parent = store.sessions["one:p"]!
            XCTAssertEqual(SessionStore.cost(of: parent, in: store.sessions), parent.can.spendIncludesSubagents ? 4 : 7, agent.rawValue)
            XCTAssertEqual(parent.can.spendIncludesSubagents, agent == .prime, agent.rawValue)
        }
    }

    @MainActor func testEverySiteNewestSessionFirstThenByPort() {
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(.sessions([
            summary("old", createdAt: 1, sites: [site(9000, published: true)]),
            summary("new", createdAt: 2, sites: [site(8001, published: false), site(8000, published: true)]),
            summary("none", createdAt: 3),
        ]), from: "one")
        XCTAssertEqual(store.allSites.map(\.id), ["one:new#8000", "one:new#8001", "one:old#9000"])
        // Unpublished, a site opens only on the computer that serves it, and this one is not known to be local.
        XCTAssertEqual(store.allSites.map(\.opens), [true, false, true])
        XCTAssertEqual(store.sites(of: store.sessions["one:old"]!).map(\.site.port), [9000])
    }

    @MainActor func testCapabilitiesFromBridgeOverrideByNameFallbacks() throws {
        let payload = #"""
        {
          "type": "sessions",
          "bridge": 2,
          "sessions": [
            {
              "id": "p",
              "agent": "pi",
              "kind": "root",
              "runningSubagents": false,
              "readOnly": false,
              "cwd": "/tmp",
              "title": "parent",
              "status": "idle",
              "createdAt": 0,
              "thinkingLevels": [],
              "cost": 4,
              "queue": { "steering": [], "followUp": [] },
              "autoCompaction": true,
              "backgroundJobs": 0,
              "capabilities": {
                "restartKernel": true,
                "clearGoal": true,
                "newSession": false,
                "autoCompactionSwitch": false,
                "followUp": false,
                "answer": true,
                "backgroundCommands": false,
                "spendIncludesSubagents": true
              }
            },
            {
              "id": "c",
              "agent": "pi",
              "kind": "subagent",
              "parentId": "p",
              "runningSubagents": false,
              "readOnly": true,
              "cwd": "/tmp",
              "title": "child",
              "status": "done",
              "createdAt": 0,
              "thinkingLevels": [],
              "cost": 2,
              "queue": { "steering": [], "followUp": [] },
              "autoCompaction": true,
              "backgroundJobs": 0
            }
          ]
        }
        """#
        let message = try JSONDecoder().decode(ServerMessage.self, from: Data(payload.utf8))
        let store = SessionStore(defaults: scratchDefaults())
        store.apply(message, from: "one")
        let parent = try XCTUnwrap(store.sessions["one:p"])
        let child = try XCTUnwrap(store.sessions["one:c"])
        XCTAssertEqual(SessionStore.cost(of: parent, in: store.sessions), 4)
        XCTAssertEqual(
            parent.can,
            SessionCapabilities(
                resume: true,
                restartKernel: true,
                clearGoal: true,
                newSession: false,
                autoCompactionSwitch: false,
                followUp: false,
                answer: true,
                backgroundCommands: false,
                spendIncludesSubagents: true
            )
        )
        XCTAssertNil(child.capabilities)
        XCTAssertEqual(
            child.can,
            SessionCapabilities(
                restartKernel: false,
                clearGoal: false,
                newSession: false,
                autoCompactionSwitch: false,
                followUp: false,
                answer: false,
                backgroundCommands: false,
                spendIncludesSubagents: false
            )
        )
    }

    @MainActor func testSwitchingSessionsReplacesAllOpenSessionStateIncludingLoadingEarlier() async {
        let gate = AsyncStream<Void>.makeStream()
        let bridge = ScriptedBridge([.loadEarlier: [.reply(["items": [], "earlier": 0])]])
        bridge.gates[.loadEarlier] = gate.stream
        let store = SessionStore(on: bridge)
        store.apply(.sessions([summary("a"), summary("b")]), from: "one")

        store.select("one:a")
        store.apply(.snapshot(sessionId: "a", items: [Item(id: "i1", kind: .user, text: "hi")], earlier: 5), from: "one")
        let loadingA = Task { await store.loadEarlier() }
        _ = await eventually { store.loadingEarlier }
        XCTAssertTrue(store.loadingEarlier)

        store.select("one:b")
        XCTAssertFalse(store.loadingEarlier)

        gate.continuation.finish()
        await loadingA.value
    }

    @MainActor func testStartedSessionWhoseAgentCrashedNeedsResumeWhileKeptSessionDoesNot() {
        let crashedPi = summary("pi1", status: .error, agent: .pi)
        let stoppedDsh = summary("dsh1", status: .stopped, agent: .deepseek)
        let runningPi = summary("pi2", status: .idle, agent: .pi)
        let disconnectedPrime = summary("p1", status: .error, agent: .prime)
        XCTAssertTrue(crashedPi.needsResume)
        XCTAssertTrue(stoppedDsh.needsResume)
        XCTAssertFalse(runningPi.needsResume)
        XCTAssertFalse(disconnectedPrime.needsResume)
    }
}
