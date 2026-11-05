import XCTest
@testable import ShedKit

final class SiteDecodingTests: XCTestCase {
    private func summary(_ extra: String) -> String {
        """
        {"id":"s","agent":"pi","kind":"root","depth":0,"runningSubagents":false,"readOnly":false,"cwd":"/tmp",
         "title":"t","status":"idle","createdAt":0,"thinkingLevels":[],"cost":0,
         "queue":{"steering":[],"followUp":[]},"autoCompaction":true,"backgroundJobs":0\(extra)}
        """
    }

    func testABridgeWithoutSitesStillDecodes() throws {
        let session = try JSONDecoder().decode(SessionSummary.self, from: Data(summary("").utf8))
        XCTAssertFalse(session.hasSites)
        XCTAssertEqual(session.servedSites, [])
    }

    func testSitesDecode() throws {
        let sites = #","sites":[{"port":5173,"title":"Atelier","command":"node","url":"https://h.ts.net:5173/","published":true,"exposed":false}]"#
        let session = try JSONDecoder().decode(SessionSummary.self, from: Data(summary(sites).utf8))
        XCTAssertEqual(session.servedSites.first?.name, "Atelier")
        XCTAssertEqual(session.servedSites.first?.host, "h.ts.net:5173")
    }
}
