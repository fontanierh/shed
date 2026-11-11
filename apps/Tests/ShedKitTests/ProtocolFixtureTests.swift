import XCTest
@testable import ShedKit

/// protocol/server_messages.json holds one of every message the bridge sends, written by the bridge's own tests.
/// Reading it here means a field the bridge adds or renames fails the app's tests instead of going unread.
final class ProtocolFixtureTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/server_messages.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    /// JSON as Foundation reads it, without the nulls: the app writes a missing value as no key at all.
    private func withoutNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.mapValues(withoutNulls)
        }
        if let list = value as? [Any] { return list.map(withoutNulls) }
        return value
    }

    /// What the app read holds everything the bridge sent.
    private func assertRead(_ read: some Encodable, holds sent: Any?, _ what: String) throws {
        let reread = try JSONSerialization.jsonObject(with: JSONEncoder().encode(read), options: .fragmentsAllowed)
        let sent = try XCTUnwrap(sent, what)
        XCTAssertEqual(withoutNulls(reread) as? NSObject, withoutNulls(sent) as? NSObject, what)
    }

    func testTheAppReadsEveryMessageTheBridgeSends() throws {
        let messages = try XCTUnwrap(try fixture()["messages"] as? [[String: Any]])
        for sent in messages {
            let type = try XCTUnwrap(sent["type"] as? String)
            // Replies go to whoever asked, through `BridgeClient`.
            if type == "reply" { continue }
            let message = try JSONDecoder().decode(ServerMessage.self, from: JSONSerialization.data(withJSONObject: sent))
            switch message {
            case .sessions(let sessions, let bridge):
                try assertRead(sessions, holds: sent["sessions"], type)
                XCTAssertEqual(bridge, sent["bridge"] as? Int)
            case .session(let session): try assertRead(session, holds: sent["session"], type)
            case .sessionRemoved(let sessionId): XCTAssertEqual(sessionId, sent["sessionId"] as? String)
            case .snapshot(let sessionId, let items, let earlier):
                XCTAssertEqual(sessionId, sent["sessionId"] as? String)
                XCTAssertEqual(earlier, sent["earlier"] as? Int ?? 0)
                try assertRead(items, holds: sent["items"], type)
            case .itemAdd(let sessionId, let item):
                XCTAssertEqual(sessionId, sent["sessionId"] as? String)
                try assertRead(item, holds: sent["item"], type)
            case .itemPatch(let sessionId, let itemId, let set, let append):
                XCTAssertEqual(sessionId, sent["sessionId"] as? String)
                XCTAssertEqual(itemId, sent["itemId"] as? String)
                if let sentSet = sent["set"] { try assertRead(try XCTUnwrap(set), holds: sentSet, "\(type) set") }
                if let sentAppend = sent["append"] { try assertRead(try XCTUnwrap(append), holds: sentAppend, "\(type) append") }
            }
        }
    }

    /// A reply's code is read by `BridgeClient`, off the socket; the names are what the two sides share.
    func testTheAppKnowsEveryCodeTheBridgeAnswersWith() throws {
        let messages = try XCTUnwrap(try fixture()["messages"] as? [[String: Any]])
        for reply in messages where reply["type"] as? String == "reply" {
            guard let code = reply["code"] as? String else { continue }
            XCTAssertNotNil(BridgeError.Code(rawValue: code), code)
        }
    }

    func testTheAppKnowsEveryValueTheBridgeSends() throws {
        let enums = try XCTUnwrap(try fixture()["enums"] as? [String: [String]])
        let known: [String: (String) -> Bool] = [
            "agent": { AgentKind(rawValue: $0) != nil },
            "itemKind": { ItemKind(rawValue: $0) != nil },
            "toolStatus": { ToolStatus(rawValue: $0) != nil },
            "sessionStatus": { SessionStatus(rawValue: $0) != nil },
            "sessionKind": { SessionKind(rawValue: $0) != nil },
            "stuckKind": { StuckKind(rawValue: $0) != nil },
        ]
        XCTAssertEqual(Set(enums.keys), Set(known.keys))
        for (name, values) in enums {
            for value in values { XCTAssertTrue(known[name]?(value) ?? false, "\(name): \(value)") }
        }
    }

    /// A status or kind a newer bridge or agent names is kept, as unknown: the command or the notice still shows.
    func testAJobStatusOrStuckKindTheAppDoesNotKnowIsKept() throws {
        let job = #"{"id": "j1", "command": "make", "status": "paused", "persistent": false}"#
        let decoded = try JSONDecoder().decode(BackgroundJob.self, from: Data(job.utf8))
        XCTAssertEqual(decoded.status, .unknown)
        XCTAssertFalse(decoded.isRunning)
        let lost = try JSONDecoder().decode(BackgroundJob.self, from: Data(job.replacingOccurrences(of: "paused", with: "lost").utf8))
        XCTAssertEqual(lost.status, .lost)
        let stuck = #"{"kind": "network", "command": "curl", "reason": "waiting"}"#
        XCTAssertEqual(try JSONDecoder().decode(Stuck.self, from: Data(stuck.utf8)).kind, .unknown)
    }
}
