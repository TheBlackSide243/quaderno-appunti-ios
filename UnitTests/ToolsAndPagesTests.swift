import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Appunti

/// Several pages at once in the page grid, the mark under a hovering Pencil and the listening speeds.
@MainActor
final class ToolsAndPagesTests: XCTestCase {
    private var made: [UUID] = []

    override func tearDown() {
        for id in made {
            try? FileManager.default.removeItem(at: Store.dir(id))
            try? FileManager.default.removeItem(at: Store.trash.appendingPathComponent(id.uuidString))
            PageHistory.removeAll(id)
        }
        super.tearDown()
    }

    private func stroke() -> PKStroke {
        let pts = [CGPoint(x: 20, y: 20), CGPoint(x: 90, y: 60)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    func testSeveralPagesAtOnce() throws {
        let library = Library()
        let nb = library.create(title: "Pagine", cover: 0, style: .plain, template: .lined, paper: .white, format: .a4Portrait, folder: nil)
        made.append(nb.id)
        let model = EditorModel(library: library, notebook: nb, page: 0)
        defer { model.close() }
        for _ in 0..<4 { model.addPage(after: model.notebook.pages.count - 1, template: nil) }
        let p = model.notebook.pages.map(\.id)
        XCTAssertEqual(p.count, 5)
        Store.saveDrawing(PKDrawing(strokes: [stroke()]), nb.id, p[1])
        func order() -> [UUID] { model.notebook.pages.map(\.id) }

        model.setBookmarks([p[3], p[1]], on: true)
        XCTAssertEqual(model.notebook.pages.filter(\.isBookmarked).map(\.id), [p[1], p[3]])
        model.setBookmarks([p[1], p[3]], on: false)
        XCTAssertEqual(model.bookmarkCount, 0)

        // copies in the order of the notebook, after the last chosen page, with their own ink
        let copies = model.duplicatePages([p[3], p[1]])
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(order(), [p[0], p[1], p[2], p[3], copies[0], copies[1], p[4]])
        XCTAssertEqual(Store.loadDrawing(nb.id, copies[0]).strokes.count, 1)
        XCTAssertEqual(Store.loadDrawing(nb.id, copies[1]).strokes.count, 0)

        // the page open stays open wherever it goes
        model.go(to: 2)
        model.movePages([p[4], p[0]], toStart: false)
        XCTAssertEqual(order(), [p[1], p[2], p[3], copies[0], copies[1], p[0], p[4]])
        XCTAssertEqual(model.page.id, p[2])
        model.movePages([p[4]], toStart: true)
        XCTAssertEqual(order().first, p[4])
        XCTAssertEqual(model.page.id, p[2])

        // one page always stays
        model.deletePages(Set(order()))
        XCTAssertEqual(order().count, 7)
        model.deletePages([p[2], copies[0]])
        XCTAssertEqual(order(), [p[4], p[1], p[3], copies[1], p[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.drawing(nb.id, copies[0]).path))
        XCTAssertTrue(model.notebook.pages.indices.contains(model.pageIndex))
        XCTAssertEqual(library.notebook(nb.id)?.pages.map(\.id), order(), "saved")

        let pdf = try model.exportPDF(pages: [p[1], p[3]])
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
    }

    func testHoverMark() throws {
        let pen = PKInkingTool(.pen, color: .black, width: 4)
        let look = try XCTUnwrap(HoverPreview.look(for: pen, zoom: 2, darkPaper: false))
        XCTAssertEqual(look.diameter, pen.width * 2, accuracy: 0.01)
        XCTAssertFalse(look.ring)
        // never too small to see
        XCTAssertEqual(HoverPreview.look(for: PKInkingTool(.pen, color: .black, width: 0.5), zoom: 1, darkPaper: false)?.diameter, 4)

        let eraser = PKEraserTool(.bitmap, width: 20)
        let ring = try XCTUnwrap(HoverPreview.look(for: eraser, zoom: 1.5, darkPaper: false))
        XCTAssertTrue(ring.ring)
        XCTAssertEqual(ring.diameter, min(240, eraser.width * 1.5), accuracy: 0.01)
        XCTAssertEqual(HoverPreview.look(for: PKEraserTool(.vector), zoom: 3, darkPaper: false)?.diameter, 12)

        XCTAssertNil(HoverPreview.look(for: PKLassoTool(), zoom: 1, darkPaper: false))
        XCTAssertNil(HoverPreview.look(for: pen, zoom: 0, darkPaper: false))

        // on dark paper black ink shows light, and so does its mark
        let dark = try XCTUnwrap(HoverPreview.look(for: pen, zoom: 1, darkPaper: true))
        var white: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(dark.color.getWhite(&white, alpha: &alpha))
        XCTAssertGreaterThan(white, 0.6)

        let shape = try XCTUnwrap(HoverPreview.look(shapeWidth: 3, color: .red, zoom: 2))
        XCTAssertEqual(shape.diameter, 6, accuracy: 0.01)
    }

    func testListeningSpeeds() {
        XCTAssertEqual(AudioNotes.speeds.first, 0.75)
        XCTAssertEqual(AudioNotes.speeds.last, 2)
        XCTAssertTrue(AudioNotes.speeds.contains(1))
        XCTAssertEqual(AudioNotes.speedLabel(1), "1×")
        XCTAssertTrue(["1,5×", "1.5×"].contains(AudioNotes.speedLabel(1.5)), AudioNotes.speedLabel(1.5))
        let before = UserDefaults.standard.object(forKey: "audio.speed")
        defer { UserDefaults.standard.set(before, forKey: "audio.speed") }
        UserDefaults.standard.set(Float(3), forKey: "audio.speed")
        XCTAssertEqual(AudioNotes.savedSpeed, 1, "a speed not offered falls back to 1×")
        UserDefaults.standard.set(Float(1.25), forKey: "audio.speed")
        XCTAssertEqual(AudioNotes.savedSpeed, 1.25)
        UserDefaults.standard.removeObject(forKey: "audio.speed")
        XCTAssertEqual(AudioNotes.savedSpeed, 1)
    }
}
