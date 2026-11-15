import PencilKit
import UIKit
import XCTest
@testable import Appunti

/// Study streaks, earlier versions of a page, the zoom window and the lasso's changes.
final class MediumFeaturesTests: XCTestCase {
    private func stroke(_ x: CGFloat, y: CGFloat = 10) -> PKStroke {
        let pts = [CGPoint(x: x, y: y), CGPoint(x: x + 40, y: y + 20)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    // MARK: streak

    func testStreakCountsDaysInARow() {
        let cal = Calendar.current
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 18))!
        func day(_ back: Int) -> String { StudyLog.key(cal.date(byAdding: .day, value: -back, to: today)!) }
        var days: [String: StudyLog.Day] = [:]
        XCTAssertEqual(StudyLog.streak(days, today: today), 0)
        days[day(0)] = .init(reviews: 3, right: 2, focus: 0)
        days[day(1)] = .init(reviews: 0, right: 0, focus: 25)
        days[day(2)] = .init(reviews: 1, right: 1, focus: 0)
        days[day(4)] = .init(reviews: 5, right: 5, focus: 0)
        XCTAssertEqual(StudyLog.streak(days, today: today), 3)
        // today not studied yet does not break the streak
        days[day(0)] = nil
        XCTAssertEqual(StudyLog.streak(days, today: today), 2)
        // a day with nothing done does
        days[day(1)] = .init()
        XCTAssertEqual(StudyLog.streak(days, today: today), 0)
    }

    func testDayKeys() {
        let d = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59))!
        XCTAssertEqual(StudyLog.key(d), "2026-03-07")
    }

    // MARK: page history

    func testSnapshotAndRestore() throws {
        let nb = Notebook(title: "Storia", paper: .white, pages: [PageInfo(template: .lined, size: CGSize(width: 595, height: 842))])
        let pg = nb.pages[0]
        defer {
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            PageHistory.removeAll(nb.id)
        }
        Store.ensureDirs(nb.id)
        // an empty page is not kept
        XCTAssertNil(PageHistory.snapshot(nb, pg))

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        Store.saveDrawing(PKDrawing(strokes: [stroke(10)]), nb.id, pg.id)
        let v1 = try XCTUnwrap(PageHistory.snapshot(nb, pg, now: t0))
        // not again within ten minutes
        Store.saveDrawing(PKDrawing(strokes: [stroke(10), stroke(100)]), nb.id, pg.id)
        PageHistory.snapshotIfDue(nb, pg, now: t0.addingTimeInterval(120))
        XCTAssertEqual(PageHistory.versions(nb.id, pg.id).count, 1)
        PageHistory.snapshotIfDue(nb, pg, now: t0.addingTimeInterval(PageHistory.gap + 1))
        let list = PageHistory.versions(nb.id, pg.id)
        XCTAssertEqual(list.count, 2)
        XCTAssertGreaterThan(list[0].date, list[1].date, "newest first")
        XCTAssertEqual(PageHistory.ink(v1, try XCTUnwrap(PageHistory.page(v1))).strokes.count, 1)

        // going back keeps the page as it is now among the versions
        var marked = pg
        marked.bookmarked = true
        let back = try XCTUnwrap(PageHistory.restore(v1, nb, marked))
        XCTAssertEqual(back.id, pg.id)
        XCTAssertTrue(back.isBookmarked, "the bookmark is not part of the writing")
        XCTAssertEqual(Store.loadDrawing(nb.id, pg.id).strokes.count, 1)
        XCTAssertEqual(PageHistory.versions(nb.id, pg.id).count, 3)
        XCTAssertNotNil(PageHistory.preview(v1, nb, width: 200))
    }

    func testHistoryKeepsTheLastOnes() throws {
        let nb = Notebook(title: "Tante", paper: .white, pages: [PageInfo(template: .blank, size: CGSize(width: 300, height: 400))])
        let pg = nb.pages[0]
        defer {
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            PageHistory.removeAll(nb.id)
        }
        Store.ensureDirs(nb.id)
        Store.saveDrawing(PKDrawing(strokes: [stroke(10)]), nb.id, pg.id)
        for i in 0..<(PageHistory.keep + 4) {
            PageHistory.snapshot(nb, pg, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 1000))
        }
        XCTAssertEqual(PageHistory.versions(nb.id, pg.id).count, PageHistory.keep)
        PageHistory.removeAll(nb.id)
        XCTAssertTrue(PageHistory.versions(nb.id, pg.id).isEmpty)
    }

    // MARK: zoom window

    func testZoomStrokesGoSmallIntoTheBox() {
        let s = stroke(100, y: 50)
        let moved = ZoomPadView.scaled(s, by: 0.4, to: CGPoint(x: 200, y: 300))
        let first = moved.path[0].location
        XCTAssertEqual(first.x, 240, accuracy: 0.01)
        XCTAssertEqual(first.y, 320, accuracy: 0.01)
        XCTAssertEqual(moved.path[0].size.width, 1.6, accuracy: 0.01)
        XCTAssertEqual(moved.path.count, s.path.count)
    }

    // MARK: lasso

    @MainActor
    func testSelectionTransform() {
        let c = CGPoint(x: 100, y: 100)
        // moving only
        let m = SelectionBox.pageTransform(center: c, move: CGPoint(x: 10, y: -5), scale: 1, turn: 0)
        XCTAssertEqual(CGPoint(x: 50, y: 50).applying(m).x, 60, accuracy: 0.001)
        XCTAssertEqual(CGPoint(x: 50, y: 50).applying(m).y, 45, accuracy: 0.001)
        // the centre stays where it is when it only grows or turns
        let g = SelectionBox.pageTransform(center: c, move: .zero, scale: 2, turn: .pi / 2)
        XCTAssertEqual(c.applying(g).x, 100, accuracy: 0.001)
        XCTAssertEqual(c.applying(g).y, 100, accuracy: 0.001)
        // a point to the right of the centre goes below it, twice as far
        let p = CGPoint(x: 110, y: 100).applying(g)
        XCTAssertEqual(p.x, 100, accuracy: 0.001)
        XCTAssertEqual(p.y, 120, accuracy: 0.001)
    }
}
