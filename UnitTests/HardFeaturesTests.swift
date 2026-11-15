import PencilKit
import XCTest
@testable import Appunti

/// Shared pages put together stroke by stroke, and the links the widgets open.
final class HardFeaturesTests: XCTestCase {
    private func stroke(_ x: CGFloat, made: TimeInterval = 1_800_000_000) -> PKStroke {
        let pts = [CGPoint(x: x, y: 10), CGPoint(x: x + 40, y: 30)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i), size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: made + Double(x))))
    }

    private func xs(_ list: [PKStroke]) -> [CGFloat] { list.map { ($0.path.first?.location.x ?? 0).rounded() } }

    func testBothAddStrokes() {
        let base = [stroke(10)]
        let mine = base + [stroke(100)]
        let theirs = base + [stroke(200)]
        XCTAssertEqual(xs(StrokeMerge.merge(base: base, mine: mine, theirs: theirs)), [10, 100, 200])
    }

    func testErasedOnEitherSideGoes() {
        let base = [stroke(10), stroke(50), stroke(90)]
        // they erased 50, I erased 90 and wrote 300
        let mine = [stroke(10), stroke(50), stroke(300)]
        let theirs = [stroke(10), stroke(90)]
        XCTAssertEqual(xs(StrokeMerge.merge(base: base, mine: mine, theirs: theirs)), [10, 300])
    }

    func testWithoutBaseNothingIsTakenAway() {
        let mine = [stroke(10)], theirs = [stroke(10), stroke(70)]
        XCTAssertEqual(xs(StrokeMerge.merge(base: nil, mine: mine, theirs: theirs)), [10, 70])
    }

    func testMovedStrokeIsANewOne() {
        let a = stroke(10)
        var moved = a
        moved.transform = CGAffineTransform(translationX: 30, y: 0)
        XCTAssertNotEqual(StrokeMerge.key(a), StrokeMerge.key(moved))
        // I moved it, they wrote something: the moved one and theirs, not the old one
        let out = StrokeMerge.merge(base: [a], mine: [moved], theirs: [a, stroke(200)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(StrokeMerge.key(out[0]), StrokeMerge.key(moved))
    }

    func testDrawingFilesMerge() throws {
        let base = PKDrawing(strokes: [stroke(10)]).dataRepresentation()
        let mine = PKDrawing(strokes: [stroke(10), stroke(100)]).dataRepresentation()
        let theirs = PKDrawing(strokes: [stroke(10), stroke(200)]).dataRepresentation()
        let out = try XCTUnwrap(StrokeMerge.mergeFile("pages/x.drawing", base: base, mine: mine, theirs: theirs))
        XCTAssertEqual(try PKDrawing(data: out).strokes.count, 3)
        XCTAssertNil(StrokeMerge.mergeFile("pages/x.drawing", base: nil, mine: Data("no".utf8), theirs: theirs))
        XCTAssertTrue(StrokeMerge.canMerge("pages/ABC.drawing"))
        XCTAssertTrue(StrokeMerge.canMerge("pages/ABC.items.json"))
        XCTAssertFalse(StrokeMerge.canMerge("notebook.json"))
        XCTAssertFalse(StrokeMerge.canMerge("images/a.jpg"))
    }

    func testBoxesMergeByID() {
        var a = PageItem(kind: .text, x: 0, y: 0, w: 100, h: 40)
        a.text = "Prima"
        var b = PageItem(kind: .text, x: 0, y: 100, w: 100, h: 40)
        b.text = "Seconda"
        let c = PageItem(kind: .text, x: 0, y: 200, w: 100, h: 40)
        var aTheirs = a
        aTheirs.text = "Prima, cambiata da loro"
        // they changed a and erased b; I added c
        let out = StrokeMerge.mergeItems(base: [a, b], mine: [a, b, c], theirs: [aTheirs])
        XCTAssertEqual(out.map(\.id), [a.id, c.id])
        XCTAssertEqual(out[0].text, "Prima, cambiata da loro")
        // changed on both sides: mine stays
        var aMine = a
        aMine.text = "Prima, cambiata da me"
        XCTAssertEqual(StrokeMerge.mergeItems(base: [a], mine: [aMine], theirs: [aTheirs]).first?.text, "Prima, cambiata da me")
    }
}
