import XCTest
@testable import MarmotIM

/// "," and "." turn the candidate page only when there is a page on that side.
/// With no page to turn to they are not page turn keys at all, so they join the
/// input buffer instead of slipping past the composition into the app.
final class PagingRulesTests: XCTestCase {

    /// `totalPages` as the controller computes it: never below 1, so an empty
    /// candidate list looks like a single page.
    private func totalPages(candidates: Int, pageSize: Int) -> Int {
        max(1, (candidates + pageSize - 1) / pageSize)
    }

    func testSinglePageTurnsNowhere() {
        let pages = totalPages(candidates: 5, pageSize: 9)
        XCTAssertEqual(pages, 1)
        XCTAssertFalse(PagingRules.canTurnPage(forward: false, currentPage: 0, totalPages: pages), ",")
        XCTAssertFalse(PagingRules.canTurnPage(forward: true, currentPage: 0, totalPages: pages), ".")
    }

    func testNoCandidatesTurnsNowhere() {
        let pages = totalPages(candidates: 0, pageSize: 9)
        XCTAssertFalse(PagingRules.canTurnPage(forward: false, currentPage: 0, totalPages: pages), ",")
        XCTAssertFalse(PagingRules.canTurnPage(forward: true, currentPage: 0, totalPages: pages), ".")
    }

    func testFirstPageOfSeveralOnlyTurnsForward() {
        let pages = totalPages(candidates: 20, pageSize: 9)
        XCTAssertEqual(pages, 3)
        XCTAssertFalse(PagingRules.canTurnPage(forward: false, currentPage: 0, totalPages: pages),
                       "no page before the first one")
        XCTAssertTrue(PagingRules.canTurnPage(forward: true, currentPage: 0, totalPages: pages))
    }

    func testMiddlePageTurnsBothWays() {
        let pages = totalPages(candidates: 20, pageSize: 9)
        XCTAssertTrue(PagingRules.canTurnPage(forward: false, currentPage: 1, totalPages: pages))
        XCTAssertTrue(PagingRules.canTurnPage(forward: true, currentPage: 1, totalPages: pages))
    }

    func testLastPageOnlyTurnsBack() {
        let pages = totalPages(candidates: 20, pageSize: 9)
        XCTAssertTrue(PagingRules.canTurnPage(forward: false, currentPage: 2, totalPages: pages))
        XCTAssertFalse(PagingRules.canTurnPage(forward: true, currentPage: 2, totalPages: pages),
                       "no page after the last one")
    }

    func testExactlyFullPageHasNoSecondPage() {
        let pages = totalPages(candidates: 9, pageSize: 9)
        XCTAssertEqual(pages, 1)
        XCTAssertFalse(PagingRules.canTurnPage(forward: true, currentPage: 0, totalPages: pages))
    }
}
