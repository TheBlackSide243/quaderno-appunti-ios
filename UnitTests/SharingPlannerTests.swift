import XCTest
@testable import Appunti

/// Shared notebooks merged from two people, and planners.
final class SharingPlannerTests: XCTestCase {
    private func page() -> PageInfo { PageInfo(template: .lined, size: CGSize(width: 595, height: 842)) }

    func testPagesAddedOnBothSidesStay() {
        let a = page(), b = page(), c = page()
        let x = page(), y = page()
        // mine: a b c + x after a; theirs: a b c + y after c
        let mine = [a, x, b, c], theirs = [a, b, c, y]
        let merged = SharedNotebooks.mergePages(mine, theirs, deleted: [])
        XCTAssertEqual(merged.map(\.id), [a, x, b, c, y].map(\.id))
    }

    func testPagesDeletedOnOneSideGo() {
        let a = page(), b = page(), c = page()
        var mine = Notebook(title: "Insieme", pages: [a, c])
        mine.deletedPages = [b.id]
        mine.modified = Date(timeIntervalSince1970: 100)
        var theirs = Notebook(id: mine.id, title: "Insieme (nuovo titolo)", pages: [a, b, c])
        theirs.modified = Date(timeIntervalSince1970: 200)
        theirs.favorite = true
        let m = SharedNotebooks.merge(mine, theirs)
        XCTAssertEqual(m.pages.map(\.id), [a.id, c.id])
        XCTAssertEqual(m.title, "Insieme (nuovo titolo)", "the newer description wins")
        XCTAssertFalse(m.favorite, "favourites stay personal")
        XCTAssertEqual(m.deletedPages, [b.id])
    }

    func testFlashcardsOfBothSides() {
        let a = page()
        var mine = Notebook(title: "T", pages: [a])
        var theirs = Notebook(id: mine.id, title: "T", pages: [a])
        mine.cards = [Flashcard(page: a.id, front: .zero, back: .zero)]
        theirs.cards = [Flashcard(page: a.id, front: .zero, back: .zero)]
        XCTAssertEqual(SharedNotebooks.merge(mine, theirs).cards?.count, 2)
    }

    @MainActor
    func testPlannerWeeks() {
        let weeks = Planner.weeks(2027)
        XCTAssertTrue((52...53).contains(weeks.count))
        let cal = Calendar(identifier: .gregorian)
        for w in weeks { XCTAssertEqual(cal.component(.weekday, from: w), 2, "every week starts on Monday") }
        // 1 January 2027 is a Friday: the first week starts on Monday 28 December 2026
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: weeks[0]), DateComponents(year: 2026, month: 12, day: 28))
    }
}
