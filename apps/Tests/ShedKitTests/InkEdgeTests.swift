import XCTest
@testable import ShedKit

final class InkEdgeTests: XCTestCase {
    private func line(_ line: Int, x: CGFloat = 0, y: CGFloat, width: CGFloat) -> InkLine {
        InkLine(text: 0, line: line, rect: CGRect(x: x, y: y, width: width, height: 20))
    }

    /// A line that grew prints the stretch it grew by; a new line prints whole.
    func testGrowthPrintsWhereTheTextIsNew() {
        let old = [line(0, y: 0, width: 300), line(1, y: 20, width: 80)]
        let new = [line(0, y: 0, width: 300), line(1, y: 20, width: 140), line(2, y: 40, width: 60)]
        XCTAssertEqual(InkEdge.fresh(from: old, to: new), [
            CGRect(x: 80, y: 20, width: 60, height: 20),
            CGRect(x: 0, y: 40, width: 60, height: 20),
        ])
    }

    func testNothingNewPrintsNothing() {
        let lines = [line(0, y: 0, width: 300)]
        XCTAssertEqual(InkEdge.fresh(from: lines, to: lines), [])
    }

    /// Text that moved, shrank or went away is a reflow: nothing prints.
    func testReflowPrintsNothing() {
        let old = [line(0, y: 0, width: 300), line(1, y: 20, width: 80)]
        XCTAssertNil(InkEdge.fresh(from: old, to: [line(0, y: 0, width: 300), line(1, y: 28, width: 80)]))
        XCTAssertNil(InkEdge.fresh(from: old, to: [line(0, y: 0, width: 300), line(1, y: 20, width: 40)]))
        XCTAssertNil(InkEdge.fresh(from: old, to: [line(0, y: 0, width: 300)]))
    }

    /// Only a block's last lines are read. One leaving that window at the top as a new one starts is not a reflow.
    func testTheWindowMovingOnIsNotAReflow() {
        let old = (0..<40).map { line($0, y: CGFloat($0) * 20, width: 300) }
        let new = (1..<41).map { line($0, y: CGFloat($0) * 20, width: $0 == 40 ? 60 : 300) }
        XCTAssertEqual(InkEdge.fresh(from: old, to: new), [CGRect(x: 0, y: 800, width: 60, height: 20)])
        // A line gone from inside the window still is.
        XCTAssertNil(InkEdge.fresh(from: old, to: new.filter { $0.line != 20 }))
    }

    /// A block arriving whole prints as one piece.
    func testManyLinesPrintAsOne() {
        let new = (0..<14).map { line($0, y: CGFloat($0) * 20, width: 200) }
        XCTAssertEqual(InkEdge.fresh(from: [], to: new), [CGRect(x: 0, y: 0, width: 200, height: 280)])
    }

    /// A word still being written waits for its end.
    func testLastWordWaits() {
        XCTAssertEqual(InkEdge.settled("the quick bro"), "the quick ")
        XCTAssertEqual(InkEdge.settled("the quick brown "), "the quick brown ")
        XCTAssertEqual(InkEdge.settled("done."), "done.")
        XCTAssertEqual(InkEdge.settled("see `co"), "see `co")
        XCTAssertEqual(InkEdge.settled("don’t"), "")
        let long = String(repeating: "a", count: 30)
        XCTAssertEqual(InkEdge.settled("x " + long), "x " + long)
    }
}
