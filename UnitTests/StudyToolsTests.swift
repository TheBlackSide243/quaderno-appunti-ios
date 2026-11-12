import CoreGraphics
import XCTest
@testable import Appunti

/// Hand-drawn shapes made clean, and the flashcard schedule.
final class StudyToolsTests: XCTestCase {
    /// A wobbly stroke through the given corners, a point every few points with a little noise.
    private func hand(_ corners: [CGPoint], noise: CGFloat = 1.5) -> [CGPoint] {
        var seed: UInt64 = 7
        func r() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max) - 0.5
        }
        var out: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 4))
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t + r() * noise * 2, y: a.y + (b.y - a.y) * t + r() * noise * 2))
            }
        }
        out.append(corners.last!)
        return out
    }

    private func circle(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, from start: CGFloat = 0, turns: CGFloat = 1.02) -> [CGPoint] {
        (0...90).map { i in
            let t = start + CGFloat(i) / 90 * 2 * .pi * turns
            return CGPoint(x: c.x + rx * cos(t) + sin(t * 7) * 1.2, y: c.y + ry * sin(t) + cos(t * 5) * 1.2)
        }
    }

    func testLine() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(hand([CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 90)])))
        XCTAssertEqual(r.kind, .line)
        XCTAssertEqual(r.points.count, 2)
    }

    func testAlmostHorizontalLineIsStraightened() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(hand([CGPoint(x: 10, y: 50), CGPoint(x: 300, y: 58)])))
        XCTAssertEqual(r.kind, .line)
        XCTAssertEqual(r.points[0].y, r.points[1].y, accuracy: 0.001)
    }

    func testRectangle() throws {
        let c = [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 52), CGPoint(x: 248, y: 160), CGPoint(x: 52, y: 158), CGPoint(x: 51, y: 54)]
        let r = try XCTUnwrap(ShapeRecognizer.recognize(hand(c)))
        XCTAssertEqual(r.kind, .rectangle)
        let box = ShapeRecognizer.bounds(r.points)
        XCTAssertEqual(box.minX, 51, accuracy: 6)
        XCTAssertEqual(box.maxX, 249, accuracy: 6)
        XCTAssertEqual(box.minY, 51, accuracy: 6)
        XCTAssertEqual(box.maxY, 159, accuracy: 6)
    }

    func testRectangleStartedInTheMiddleOfASide() throws {
        let c = [CGPoint(x: 150, y: 50), CGPoint(x: 250, y: 50), CGPoint(x: 250, y: 160), CGPoint(x: 50, y: 160),
                 CGPoint(x: 50, y: 50), CGPoint(x: 146, y: 52)]
        XCTAssertEqual(ShapeRecognizer.recognize(hand(c))?.kind, .rectangle)
    }

    func testTriangle() throws {
        let c = [CGPoint(x: 100, y: 20), CGPoint(x: 190, y: 180), CGPoint(x: 10, y: 178), CGPoint(x: 98, y: 26)]
        XCTAssertEqual(ShapeRecognizer.recognize(hand(c))?.kind, .triangle)
    }

    func testCircleAndEllipse() throws {
        let c = try XCTUnwrap(ShapeRecognizer.recognize(circle(CGPoint(x: 200, y: 200), 80, 78)))
        XCTAssertEqual(c.kind, .ellipse)
        let b = ShapeRecognizer.bounds(c.points)
        XCTAssertEqual(b.width, b.height, accuracy: 0.5, "a nearly round stroke becomes a circle")
        let e = try XCTUnwrap(ShapeRecognizer.recognize(circle(CGPoint(x: 200, y: 200), 140, 60, from: 1)))
        XCTAssertEqual(e.kind, .ellipse)
    }

    func testBrokenLine() throws {
        let c = [CGPoint(x: 10, y: 200), CGPoint(x: 100, y: 40), CGPoint(x: 190, y: 200)]
        XCTAssertEqual(ShapeRecognizer.recognize(hand(c))?.kind, .polyline)
    }

    func testScribbleAndWritingStayAsTheyAre() {
        // looped handwriting
        var pts: [CGPoint] = []
        for i in 0...200 {
            let t = CGFloat(i) / 200 * 12 * .pi
            pts.append(CGPoint(x: 20 + t * 9 - 8 * sin(t), y: 100 - 14 * (1 + cos(t)) / 2))
        }
        XCTAssertNil(ShapeRecognizer.recognize(pts))
        // a dot
        XCTAssertNil(ShapeRecognizer.recognize([CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 6), CGPoint(x: 7, y: 5)]))
    }

    // MARK: Flashcards

    func testSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var c = Flashcard(page: UUID(), front: .zero, back: .zero)
        XCTAssertTrue(c.isDue(now))
        c = c.answered(.good, now: now)
        XCTAssertEqual(c.interval, 1)
        XCTAssertEqual(c.due.timeIntervalSince(now), 86400, accuracy: 1)
        c = c.answered(.good, now: now)
        XCTAssertEqual(c.interval, 3)
        c = c.answered(.good, now: now)
        XCTAssertEqual(c.interval, 7.5, accuracy: 0.01)
        XCTAssertFalse(c.isDue(now))
        let wrong = c.answered(.again, now: now)
        XCTAssertEqual(wrong.reps, 0)
        XCTAssertEqual(wrong.lapses, 1)
        XCTAssertLessThan(wrong.ease, c.ease)
        XCTAssertEqual(wrong.due.timeIntervalSince(now), 60, accuracy: 1)
        let easy = Flashcard(page: UUID(), front: .zero, back: .zero).answered(.easy, now: now)
        XCTAssertEqual(easy.interval, 4)
        XCTAssertGreaterThan(easy.ease, 2.5)
    }

    func testCardsSurviveSaving() throws {
        var nb = Notebook(title: "Test", pages: [PageInfo(template: .lined, size: CGSize(width: 595, height: 842))])
        nb.cards = [Flashcard(page: nb.pages[0].id, front: CGRect(x: 1, y: 2, width: 3, height: 4), back: CGRect(x: 5, y: 6, width: 7, height: 8))]
        let back = try JSONDecoder().decode(Notebook.self, from: JSONEncoder().encode(nb))
        XCTAssertEqual(back.cards, nb.cards)
        // notebooks saved before flashcards existed still open
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nb)) as! [String: Any]
        old["cards"] = nil
        let older = try JSONDecoder().decode(Notebook.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(older.cards)
    }

    func testTapeItem() throws {
        var t = PageItem(kind: .tape, x: 0, y: 0, w: 50, h: 20)
        XCTAssertTrue(t.isCovered)
        t.covered = false
        let back = try JSONDecoder().decode(PageItem.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.kind, .tape)
        XCTAssertFalse(back.isCovered)
    }
}
