import PencilKit
import SwiftUI
import UIKit

/// The tools of the editor toolbar.
enum Tool: String, CaseIterable, Codable, Identifiable {
    case pen, pencil, highlighter, eraser, shape, lasso, tape, hand, laser
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: String(localized: "Penna")
        case .pencil: String(localized: "Matita")
        case .highlighter: String(localized: "Evidenziatore")
        case .eraser: String(localized: "Gomma")
        case .shape: String(localized: "Forme")
        case .lasso: String(localized: "Lazo")
        case .tape: String(localized: "Nastro adesivo")
        case .hand: String(localized: "Sposta testi e foto")
        case .laser: String(localized: "Puntatore laser")
        }
    }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .shape: "square.on.circle"
        case .lasso: "lasso"
        case .tape: "bandage"
        case .hand: "hand.point.up.left"
        case .laser: "cursorarrow.rays"
        }
    }

    /// The three thicknesses offered (for the eraser: whole stroke, small, large).
    var widths: [CGFloat] {
        switch self {
        case .pen: [1.5, 3, 6]
        case .pencil: [2.5, 4.5, 8]
        case .highlighter: [12, 20, 30]
        case .eraser: [0, 10, 30]
        case .shape: [1.5, 3, 5]
        case .lasso, .tape, .hand, .laser: []
        }
    }

    /// How thin and how thick each of the three can be made.
    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen, .shape: 0.5...16
        case .pencil: 1...20
        case .highlighter: 6...60
        case .eraser: 4...80
        case .lasso, .tape, .hand, .laser: 1...1
        }
    }

    /// The sizes offered ready to tap when one of the three is changed.
    var widthSteps: [CGFloat] {
        switch self {
        case .pen, .shape: [0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16]
        case .pencil: [1, 1.5, 2.5, 3.5, 4.5, 6, 8, 10, 12, 14, 16, 20]
        case .highlighter: [6, 9, 12, 16, 20, 25, 30, 35, 40, 45, 50, 60]
        case .eraser: [4, 6, 8, 10, 15, 20, 30, 40, 50, 60, 70, 80]
        case .lasso, .tape, .hand, .laser: []
        }
    }

    /// Whether the size in that place can be changed (not the eraser's "whole stroke").
    func canChangeWidth(_ i: Int) -> Bool { !widths.isEmpty && !(self == .eraser && i == 0) }

    /// The three sizes with the ones the person chose in place of the standard ones; saved sizes
    /// that do not fit (another number of them, out of range) are put right.
    func widths(custom: [Double]?) -> [CGFloat] {
        let base = widths
        guard let custom, custom.count == base.count else { return base }
        return custom.enumerated().map { i, v in
            canChangeWidth(i) ? min(max(CGFloat(v), widthRange.lowerBound), widthRange.upperBound) : base[i]
        }
    }

    /// Where a size sits between the thinnest and the thickest (0…1), to draw it in the bar.
    func widthFraction(_ w: CGFloat) -> CGFloat {
        let r = widthRange
        guard r.upperBound > r.lowerBound else { return 0 }
        return min(max((w - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
    }

    /// The three colours always at hand.
    var presets: [String] {
        switch self {
        case .pen, .shape: ["1C1C20", "1D4ED8", "DC2626"]
        case .pencil: ["3F3F46", "1D4ED8", "B91C1C"]
        case .highlighter: ["FDE047", "86EFAC", "F9A8D4"]
        case .tape: Array(TapeColors.all.prefix(3))
        default: []
        }
    }

    var inks: Bool { !presets.isEmpty }
}

/// What the toolbar remembers between notebooks.
struct ToolSettings: Codable {
    var tool: Tool = .pen
    var colors: [String: String] = [:]
    var widths: [String: Int] = [:]
    /// The shape drawn by the shape tool (optional so settings saved by older versions still load).
    var shape: ShapeKind?
    /// The kind of ink of the pen and of the pencil, by tool.
    var styles: [String: String]?
    /// The three sizes of a tool when the person changed them, by tool.
    var customWidths: [String: [Double]]?

    static let key = "toolSettings"

    static func load() -> ToolSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(ToolSettings.self, from: d) else { return ToolSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
