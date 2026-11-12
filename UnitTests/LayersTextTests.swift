import PencilKit
import UIKit
import XCTest
@testable import Appunti

/// Layers of ink and text documents.
final class LayersTextTests: XCTestCase {
    private func stroke(_ x: CGFloat) -> PKStroke {
        let pts = [CGPoint(x: x, y: 10), CGPoint(x: x + 40, y: 30)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i), size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    func testPagesWithoutLayersHaveOne() {
        let pg = PageInfo(template: .lined, size: CGSize(width: 595, height: 842))
        XCTAssertEqual(pg.inkLayers.count, 1)
        XCTAssertEqual(pg.inkLayers[0].id, pg.id, "the first layer keeps the page's own drawing file")
    }

    func testInkOfVisibleLayers() throws {
        let nb = UUID()
        defer { try? FileManager.default.removeItem(at: Store.dir(nb)) }
        var pg = PageInfo(template: .lined, size: CGSize(width: 595, height: 842))
        let top = InkLayer(name: "Sopra")
        pg.layers = [InkLayer(id: pg.id, name: "Sotto"), top]
        Store.saveDrawing(PKDrawing(strokes: [stroke(10)]), nb, pg.id)
        Store.saveDrawing(PKDrawing(strokes: [stroke(100), stroke(200)]), nb, top.id)
        XCTAssertEqual(Store.loadInk(nb, pg).strokes.count, 3)
        XCTAssertEqual(Store.loadInk(nb, pg).strokes.first?.renderBounds.minX ?? 0, 10, accuracy: 4, "the bottom layer is drawn first")
        pg.layers?[1].hidden = true
        XCTAssertEqual(Store.loadInk(nb, pg).strokes.count, 1, "hidden layers are not drawn")
        XCTAssertNotNil(Store.inkStamp(nb, pg))
        Store.removePageFiles(nb, pg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.drawing(nb, top.id).path))
    }

    func testTextDocumentKeepsItsFormatting() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.dir(id)) }
        let s = NSMutableAttributedString(string: "Titolo\n", attributes: [.font: TextDoc.Style.title.font])
        s.append(NSAttributedString(string: "• punto\n", attributes: TextDoc.bodyAttributes))
        TextDoc.save(s, id)
        let back = TextDoc.load(id)
        XCTAssertEqual(back.string, s.string)
        let f = try XCTUnwrap(back.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(f.pointSize, 28, accuracy: 0.5)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(TextDoc.plain(id), "Titolo\n• punto\n")
    }

    func testListsGoOn() {
        XCTAssertEqual(TextDocController.listPrefix("• latte"), "• ")
        XCTAssertEqual(TextDocController.listPrefix("12. uova"), "12. ")
        XCTAssertEqual(TextDocController.listPrefix("☑ fatto"), "☐ ")
        XCTAssertNil(TextDocController.listPrefix("testo"))
        XCTAssertNil(TextDocController.listPrefix("2024 fu un anno"))
    }

    @MainActor
    func testTextDocumentPDF() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.dir(id)) }
        let long = String(repeating: "Una riga di testo abbastanza lunga da riempire le pagine. ", count: 300)
        TextDoc.save(NSAttributedString(string: long, attributes: TextDoc.bodyAttributes), id)
        var nb = Notebook(id: id, title: "Prova", pages: [PageInfo(template: .blank, size: TextDoc.pageSize)])
        nb.textDocument = true
        let url = try TextDoc.exportPDF(nb)
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertGreaterThan(doc.numberOfPages, 1)
    }
}
