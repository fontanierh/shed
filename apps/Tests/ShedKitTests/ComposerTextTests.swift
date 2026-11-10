import XCTest
@testable import ShedKit

/// The words and levels the composer and what sits above it work out from a session.
final class ComposerTextTests: XCTestCase {
    /// Prime's own notices wait in the queue too; the reader is shown only the messages they sent.
    func testTheQueueShownLeavesOutTheAgentsOwnNotices() {
        let queue = Queue(
            steering: ["Use the staging database", "[agent-message from child:scout] Done", "Agent message received: hello"],
            followUp: ["[goal continue] Keep going", "[child-exited: no-reply child:scout] gone", "[bash-done pid:1 exit:0] make", "Then open a pull request",
                       "[draft] a message that only starts with a bracket"]
        )
        XCTAssertEqual(queue.forReader, Queue(steering: ["Use the staging database"],
                                              followUp: ["Then open a pull request", "[draft] a message that only starts with a bracket"]))
    }

    @MainActor func testAStuckReasonNamesTheComputerAndEndsAsASentence() {
        XCTAssertEqual(StuckBanner.phrase("macOS is asking for permission on this Mac", on: "studio"),
                       "MacOS is asking for permission on studio.")
        XCTAssertEqual(StuckBanner.phrase("the command waits for input on this Mac", on: nil), "The command waits for input on this Mac.")
        XCTAssertEqual(StuckBanner.phrase("Is it waiting?", on: "studio"), "Is it waiting?")
    }

    @MainActor func testAnEffortLevelIsItsPlaceAmongTheModels() {
        let levels = ["low", "medium", "high"]
        XCTAssertEqual(EffortBars.level(of: "low", in: levels), 0)
        XCTAssertEqual(EffortBars.level(of: "medium", in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: "high", in: levels), 1)
        // Unknown, unset, or nothing to place it among: the middle.
        XCTAssertEqual(EffortBars.level(of: "max", in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: nil, in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: "high", in: ["high"]), 0.5)
    }
}
