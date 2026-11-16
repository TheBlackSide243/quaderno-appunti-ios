import XCTest
@testable import Appunti

/// The three sizes of each tool, as the person changes them.
@MainActor
final class WidthsTests: XCTestCase {
    func testStandardSizesWithoutChanges() {
        for t in Tool.allCases {
            XCTAssertEqual(t.widths(custom: nil), t.widths)
            for w in t.widths where !(t == .eraser && w == 0) {
                XCTAssertTrue(t.widthRange.contains(w), "\(t) \(w)")
            }
            for s in t.widthSteps {
                XCTAssertTrue(t.widthRange.contains(s), "\(t) step \(s)")
            }
            if !t.widths.isEmpty { XCTAssertGreaterThanOrEqual(t.widthSteps.count, 8, "\(t)") }
        }
    }

    func testChangedSizesAreKeptAndPutRight() {
        XCTAssertEqual(Tool.pen.widths(custom: [0.5, 10, 16]), [0.5, 10, 16])
        // out of range: brought to the nearest end
        XCTAssertEqual(Tool.pen.widths(custom: [0.1, 3, 99]), [0.5, 3, 16])
        // another number of sizes: the standard ones
        XCTAssertEqual(Tool.pen.widths(custom: [2, 3]), Tool.pen.widths)
        // the eraser's "whole stroke" stays
        XCTAssertEqual(Tool.eraser.widths(custom: [25, 6, 80]), [0, 6, 80])
        XCTAssertFalse(Tool.eraser.canChangeWidth(0))
        XCTAssertTrue(Tool.eraser.canChangeWidth(1))
        XCTAssertFalse(Tool.lasso.canChangeWidth(0))
    }

    func testFractionForTheBar() {
        XCTAssertEqual(Tool.highlighter.widthFraction(6), 0)
        XCTAssertEqual(Tool.highlighter.widthFraction(60), 1)
        XCTAssertEqual(Tool.highlighter.widthFraction(33), 0.5, accuracy: 0.001)
        XCTAssertLessThan(WidthSlot.barHeight(.pen, 0.5), WidthSlot.barHeight(.pen, 16))
    }

    func testSettingsFromOlderVersionsStillLoad() throws {
        let old = #"{"tool":"pen","colors":{},"widths":{"pen":2}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ToolSettings.self, from: old)
        XCTAssertNil(s.customWidths)
        var t = s
        t.customWidths = ["pencil": [2, 5, 12]]
        let back = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.customWidths?["pencil"], [2, 5, 12])
    }
}
