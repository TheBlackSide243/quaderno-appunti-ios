import PencilKit
import XCTest
@testable import Appunti

/// Imports UnitTests/Fixtures/sample.goodnotes (made by scripts/make_goodnotes_fixture.py).
final class GoodNotesImportTests: XCTestCase {
    private var notebook: Notebook?

    override func tearDown() {
        if let nb = notebook { try? FileManager.default.removeItem(at: Store.dir(nb.id)) }
        super.tearDown()
    }

    private func importSample() throws -> Notebook {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "goodnotes"))
        let nb = try GoodNotesImport.read(url, folder: nil)
        notebook = nb
        return nb
    }

    func testPages() throws {
        let nb = try importSample()
        XCTAssertEqual(nb.title, "sample")
        // the third page was deleted in GoodNotes
        XCTAssertEqual(nb.pages.count, 2)
        XCTAssertTrue(nb.hasPDF)

        // page 1 keeps its grid paper as a PDF page
        let p1 = nb.pages[0]
        XCTAssertEqual(p1.pdfIndex, 0)
        XCTAssertEqual(p1.width, 455.04, accuracy: 0.5)
        XCTAssertEqual(p1.height, 588.45, accuracy: 0.5)
        XCTAssertEqual(PDFCacheFree.pageCount(Store.pdf(nb.id)), 1)

        // page 2 has no paper: blank, the size of its canvas at 6/11
        let p2 = nb.pages[1]
        XCTAssertNil(p2.pdfIndex)
        XCTAssertEqual(p2.width, 455, accuracy: 1)
        XCTAssertEqual(p2.height, 588, accuracy: 1)
    }

    func testInk() throws {
        let nb = try importSample()
        let d1 = Store.loadDrawing(nb.id, nb.pages[0].id)
        // black pen, yellow highlighter, pressure pen, rectangle; the deleted red stroke is not there
        XCTAssertEqual(d1.strokes.count, 4)
        let types = d1.strokes.map(\.ink.inkType)
        XCTAssertEqual(types.filter { $0 == .marker }.count, 1)
        XCTAssertEqual(types.filter { $0 == .monoline }.count, 3)
        for s in d1.strokes {
            let c = s.ink.color.cgColor.components ?? []
            XCTAssertFalse(c.count >= 3 && c[0] > 0.9 && c[1] < 0.1 && c[2] < 0.1, "the deleted red stroke came back")
        }
        // the black line goes from (100, 100) to (300, 100) canvas units, i.e. 54.5 to 163.6 points
        let scale: CGFloat = 455.04 / 834.24
        let black = try XCTUnwrap(d1.strokes.first { s in
            let c = s.ink.color.cgColor.components ?? [1]
            return s.ink.inkType == .monoline && c.prefix(3).allSatisfy { $0 < 0.05 } && s.path.count > 6
        })
        let xs = black.path.map(\.location.x), ys = black.path.map(\.location.y)
        XCTAssertEqual(xs.min()!, 100 * scale, accuracy: 0.5)
        XCTAssertEqual(xs.max()!, 300 * scale, accuracy: 0.5)
        XCTAssertEqual(ys.min()!, 100 * scale, accuracy: 0.5)
        XCTAssertEqual(ys.max()!, 100 * scale, accuracy: 0.5)
        // the rectangle: centre (500, 500), 100 x 60 canvas units
        let rect = try XCTUnwrap(d1.strokes.first { s in
            let c = s.ink.color.cgColor.components ?? [0, 0, 0]
            return c.count >= 3 && c[2] > 0.9 && c[0] < 0.1
        })
        let rx = rect.path.map(\.location.x), ry = rect.path.map(\.location.y)
        XCTAssertEqual(rx.min()!, 450 * scale, accuracy: 0.5)
        XCTAssertEqual(rx.max()!, 550 * scale, accuracy: 0.5)
        XCTAssertEqual(ry.min()!, 470 * scale, accuracy: 0.5)
        XCTAssertEqual(ry.max()!, 530 * scale, accuracy: 0.5)

        let d2 = Store.loadDrawing(nb.id, nb.pages[1].id)
        XCTAssertEqual(d2.strokes.count, 1)
        print("GoodNotes import: page 1 strokes \(d1.strokes.count), page 2 strokes \(d2.strokes.count)")
    }

    func testPictureAndText() throws {
        let nb = try importSample()
        let items = Store.loadItems(nb.id, nb.pages[0].id)
        XCTAssertEqual(items.count, 2)
        let scale = 455.04 / 834.24
        let picture = try XCTUnwrap(items.first { $0.kind == .image })
        XCTAssertEqual(picture.x, 400 * scale, accuracy: 0.5)
        XCTAssertEqual(picture.y, 600 * scale, accuracy: 0.5)
        XCTAssertEqual(picture.w, 200 * scale, accuracy: 0.5)
        XCTAssertEqual(picture.h, 150 * scale, accuracy: 0.5)
        let name = try XCTUnwrap(picture.image)
        XCTAssertNotNil(UIImage(contentsOfFile: Store.image(nb.id, name).path))
        let text = try XCTUnwrap(items.first { $0.kind == .text })
        XCTAssertEqual(text.text, "Ciao GoodNotes")
        XCTAssertEqual(text.x, 100 * scale, accuracy: 0.5)
    }

    func testNotAGoodNotesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope.goodnotes")
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try GoodNotesImport.read(url, folder: nil))
    }
}

/// Page count of a PDF without going through the app's cache.
private enum PDFCacheFree {
    static func pageCount(_ url: URL) -> Int {
        guard let doc = CGPDFDocument(url as CFURL) else { return -1 }
        return doc.numberOfPages
    }
}
