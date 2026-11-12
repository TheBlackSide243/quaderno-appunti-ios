import UIKit
import XCTest
@testable import Appunti

/// Whiteboards and stickers.
final class BoardStickerTests: XCTestCase {
    func testStickerKeepsTransparency() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.dir(id)) }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: fmt).image { _ in
            UIColor.red.setFill()
            UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 20, height: 20)).fill()
        }
        let (name, size) = try XCTUnwrap(Store.saveImage(img, id, keepAlpha: true))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual(size, CGSize(width: 40, height: 40))
        let back = try XCTUnwrap(UIImage(contentsOfFile: Store.image(id, name).path)?.cgImage)
        let alpha = back.alphaInfo
        XCTAssertTrue([.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha), "the PNG has an alpha channel")
        // photos stay JPEG
        let (photo, _) = try XCTUnwrap(Store.saveImage(img, id))
        XCTAssertTrue(photo.hasSuffix(".jpg"))
    }

    func testBoardNotebook() throws {
        var nb = Notebook(title: "Lavagna", pages: [PageInfo(template: .dotted, size: Notebook.boardStart)])
        XCTAssertFalse(nb.isBoard)
        nb.board = true
        let back = try JSONDecoder().decode(Notebook.self, from: JSONEncoder().encode(nb))
        XCTAssertTrue(back.isBoard)
        XCTAssertEqual(back.pages[0].size, Notebook.boardStart)
    }

    func testTilesForEveryRuling() {
        for t in PageTemplate.allCases {
            let tile = PageRenderer.tile(t, paper: .ivory)
            XCTAssertGreaterThan(tile.size.width, 10, "\(t)")
        }
    }
}
