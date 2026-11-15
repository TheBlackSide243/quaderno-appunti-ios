import PencilKit
import XCTest
@testable import Appunti

/// Dark paper, kinds of ink, locked notebooks, custom papers and the shortcuts' notebooks.
final class SimpleFeaturesTests: XCTestCase {
    func testDarkPapers() throws {
        XCTAssertTrue(Paper.night.isDark)
        XCTAssertTrue(Paper.navy.isDark)
        XCTAssertFalse(Paper.ivory.isDark)
        XCTAssertEqual(Set(Paper.light + Paper.dark), Set(Paper.allCases))
        // a paper written by a newer version opens as white paper
        let data = try JSONSerialization.data(withJSONObject: ["p": "rainbow"])
        struct Box: Decodable { let p: Paper }
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data).p, .white)
    }

    func testOnlyOwnPagesOfDarkPaperAreDark() {
        var nb = Notebook(title: "Sera", paper: .night, pages: [PageInfo(template: .lined, size: CGSize(width: 595, height: 842))])
        XCTAssertTrue(PageRenderer.isDark(nb, nb.pages[0]))
        // a PDF page and a custom paper are pictures of their own: the ink stays as it is
        nb.pages[0].pdfIndex = 0
        XCTAssertFalse(PageRenderer.isDark(nb, nb.pages[0]))
        nb.pages[0].pdfIndex = nil
        nb.pages[0].backdrop = "carta.jpg"
        XCTAssertFalse(PageRenderer.isDark(nb, nb.pages[0]))
        nb.paper = .white
        nb.pages[0].backdrop = nil
        XCTAssertFalse(PageRenderer.isDark(nb, nb.pages[0]))
    }

    func testTextTurnsLightOnDarkPaper() {
        func brightness(_ c: UIColor) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return b
        }
        XCTAssertGreaterThan(brightness(PageRenderer.textColor("1C1C20", dark: true)), 0.85)
        XCTAssertGreaterThan(brightness(PageRenderer.textColor("1D4ED8", dark: true)), 0.85)
        XCTAssertEqual(PageRenderer.textColor("1C1C20", dark: false).hexString, "1C1C20")
    }

    func testPenStyles() {
        XCTAssertEqual(PenStyle.options(for: .pen), [.ballpoint, .fountain, .monoline])
        XCTAssertEqual(PenStyle.options(for: .pencil), [.graphite, .crayon, .watercolor])
        XCTAssertTrue(PenStyle.options(for: .highlighter).isEmpty)
        XCTAssertEqual(PenStyle.fountain.inkType, .fountainPen)
        XCTAssertEqual(PenStyle.watercolor.inkType, .watercolor)
        XCTAssertEqual(PenStyle.standard(for: .pen), .ballpoint)
        // settings saved before the kinds of ink existed still load
        let old = #"{"tool":"pen","colors":{},"widths":{}}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ToolSettings.self, from: old).styles)
    }

    func testLockAndBackdropSurviveSaving() throws {
        var nb = Notebook(title: "Diario", pages: [PageInfo(template: .blank, size: CGSize(width: 595, height: 842))])
        nb.locked = true
        nb.pages[0].backdrop = "x.jpg"
        let back = try JSONDecoder().decode(Notebook.self, from: JSONEncoder().encode(nb))
        XCTAssertTrue(back.isLocked)
        XCTAssertEqual(back.pages[0].backdrop, "x.jpg")
        // notebooks saved before stay unlocked
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nb)) as! [String: Any]
        old["locked"] = nil
        XCTAssertFalse(try JSONDecoder().decode(Notebook.self, from: JSONSerialization.data(withJSONObject: old)).isLocked)
    }

    func testCustomPaperIsDrawnUnderThePage() throws {
        let nb = Notebook(title: "Carta", pages: [PageInfo(template: .blank, size: CGSize(width: 100, height: 100))])
        Store.ensureDirs(nb.id)
        defer { try? FileManager.default.removeItem(at: Store.dir(nb.id)) }
        let red = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { r in
            UIColor.red.setFill()
            r.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        let (name, _) = try XCTUnwrap(Store.saveImage(red, nb.id))
        var pg = nb.pages[0]
        pg.backdrop = name
        let img = PageRenderer.background(nb, pg, scale: 1)
        let cg = try XCTUnwrap(img.cgImage)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -50, y: -50, width: 100, height: 100))
        let px = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(px[0], 200)
        XCTAssertLessThan(px[1], 60)
    }

    func testShortcutsFindNotebooks() async throws {
        let title = "Scorciatoia \(UUID().uuidString.prefix(6))"
        let nb = Notebook(title: title, pages: [PageInfo(template: .lined, size: CGSize(width: 595, height: 842))])
        Store.ensureDirs(nb.id)
        try Store.encoder.encode(nb).write(to: Store.meta(nb.id))
        defer { try? FileManager.default.removeItem(at: Store.dir(nb.id)) }
        let found = try await NotebookQuery().entities(matching: String(title.lowercased().dropFirst(2)))
        XCTAssertEqual(found.map(\.id), [nb.id])
        let byID = try await NotebookQuery().entities(for: [nb.id])
        XCTAssertEqual(byID.first?.title, title)
    }
}
