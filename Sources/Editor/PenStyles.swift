import PencilKit
import UIKit

/// The kinds of ink of the pen and of the pencil: the pen writes as a ballpoint, a fountain pen or
/// with an even line; the pencil as graphite, a crayon or watercolour.
enum PenStyle: String, Codable, CaseIterable, Identifiable {
    case ballpoint, fountain, monoline
    case graphite, crayon, watercolor
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ballpoint: String(localized: "Penna a sfera")
        case .fountain: String(localized: "Stilografica")
        case .monoline: String(localized: "Tratto uniforme")
        case .graphite: String(localized: "Grafite")
        case .crayon: String(localized: "Pastello")
        case .watercolor: String(localized: "Acquerello")
        }
    }

    var icon: String {
        switch self {
        case .ballpoint: "pencil.tip"
        case .fountain: "signature"
        case .monoline: "line.diagonal"
        case .graphite: "pencil"
        case .crayon: "pencil.and.scribble"
        case .watercolor: "paintbrush.pointed"
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .ballpoint: .pen
        case .fountain: .fountainPen
        case .monoline: .monoline
        case .graphite: .pencil
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }

    /// The crayon and the watercolour are much finer than the pencil at the same width.
    var widthFactor: CGFloat {
        switch self {
        case .ballpoint, .graphite: 1
        case .fountain: 1.25
        case .monoline: 0.9
        case .crayon: 2.2
        case .watercolor: 3
        }
    }

    /// The kinds offered for a tool (none for the tools that are not pens).
    static func options(for tool: Tool) -> [PenStyle] {
        switch tool {
        case .pen: [.ballpoint, .fountain, .monoline]
        case .pencil: [.graphite, .crayon, .watercolor]
        default: []
        }
    }

    /// The kind a tool writes with when none was chosen.
    static func standard(for tool: Tool) -> PenStyle? {
        options(for: tool).first
    }
}
