import XCTest
@testable import ShedKit

/// A request waits for its reply no longer than its limit: a bridge that still answers pings but never this request
/// must not leave whoever asked waiting for good. The waiting is `PendingReplies`, which `BridgeClient` keeps its
/// requests in, with a stand-in for the passing of time: a `BridgeClient` itself asks nothing without a socket.
final class ReplyLimitTests: XCTestCase {
    /// Notes the limits asked for. A limit either is over at once, or lasts until the request is settled.
    @MainActor private final class Time {
        var asked: [Duration] = []
        var cancelled = 0
        let passes: Bool

        init(passes: Bool) { self.passes = passes }

        func pause(_ limit: Duration) async throws {
            asked.append(limit)
            guard !passes else { return }
            // Nothing ever comes down this stream: it ends when the limit is called off.
            for await _ in AsyncStream<Never>(Never.self, { _ in }) {}
            cancelled += 1
            throw CancellationError()
        }
    }

    private let reply = Data(#"{"type":"reply","ok":true,"data":null}"#.utf8)

    @MainActor func testARequestLeftUnansweredPastItsLimitFails() async {
        let time = Time(passes: true)
        let replies = PendingReplies(pause: time.pause)
        do {
            _ = try await replies.reply(to: "c1", within: .seconds(120)) {
                // The bridge's answer, long after the limit.
                Task { @MainActor in
                    for _ in 0..<100 { await Task.yield() }
                    replies.settle("c1", .success(self.reply))
                }
            }
            XCTFail("answered")
        } catch {
            XCTAssertTrue(error is Unanswered)
            XCTAssertFalse(error is ConnectionLost)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertEqual(time.asked, [.seconds(120)])
        // The answer that comes after all is dropped.
        replies.settle("c1", .success(reply))
    }

    @MainActor func testARequestAnsweredWithinItsLimitGetsItsReplyAndStopsCounting() async throws {
        let time = Time(passes: false)
        let replies = PendingReplies(pause: time.pause)
        let data = try await replies.reply(to: "c1", within: .seconds(120)) {
            Task { @MainActor in
                for _ in 0..<100 { await Task.yield() }
                replies.settle("c1", .success(self.reply))
            }
        }
        XCTAssertEqual(data, reply)
        let stopped = await eventually { time.cancelled == 1 }
        XCTAssertTrue(stopped)
    }

    @MainActor func testEveryWaitingRequestFailsWithTheConnection() async {
        let replies = PendingReplies(pause: Time(passes: false).pause)
        do {
            _ = try await replies.reply(to: "c1", within: .seconds(120)) {
                Task { @MainActor in replies.failAll(ConnectionLost(maybeDelivered: true)) }
            }
            XCTFail("answered")
        } catch {
            XCTAssertEqual((error as? ConnectionLost)?.maybeDelivered, true)
        }
    }

    /// The bridge gives its agents two minutes to answer, and half an hour for a compaction.
    func testACompactionMayTakeHalfAnHourAndAnythingElseTwoMinutes() {
        XCTAssertEqual(ClientOp.compact(sessionId: "s").replyLimit, .seconds(31 * 60))
        for op in [ClientOp.ping, .send(sessionId: "s", text: "Hello"), .abort(sessionId: "s"), .listDir(path: nil, hidden: false),
                   .createSession(agent: .pi, cwd: "/tmp", model: nil, thinking: nil)] {
            XCTAssertEqual(op.replyLimit, .seconds(150), op.name.rawValue)
        }
    }
}
