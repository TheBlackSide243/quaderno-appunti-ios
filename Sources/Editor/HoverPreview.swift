import PencilKit
import UIKit

/// With an Apple Pencil that can hover over the screen (iPad Pro M2 and later, iPad Air M2 and
/// later, iPad mini A17 Pro), a mark under the tip shows what it is about to leave on the page:
/// a dot as big as the line, in its colour, or the circle the eraser takes away. It follows the
/// iPad's choice in Settings → Apple Pencil (hover preview), and does not change with height.
final class HoverPreview: UIView {
    /// What the mark looks like, in screen points.
    struct Look: Equatable {
        var diameter: CGFloat
        var color: UIColor
        /// Only the outline (the eraser).
        var ring: Bool
    }

    private let mark = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        mark.lineWidth = 1.5
        layer.addSublayer(mark)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ look: Look, at p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = look.diameter / 2
        mark.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: look.diameter, height: look.diameter)).cgPath
        if look.ring {
            mark.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
            mark.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
            mark.shadowOpacity = 0
        } else {
            mark.fillColor = look.color.cgColor
            // a light outline keeps a dark dot visible on dark paper and a light one on white
            mark.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
            mark.shadowColor = UIColor.black.cgColor
            mark.shadowOpacity = 0.25
            mark.shadowRadius = 1.5
            mark.shadowOffset = .zero
        }
        CATransaction.commit()
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        mark.path = nil
    }

    /// The user's choice in Settings → Apple Pencil (before iPadOS 17.5 there was none: shown).
    static var wanted: Bool {
        if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview }
        return true
    }

    /// The mark for a PencilKit tool at this zoom; nil for the tools that leave nothing (the lasso).
    static func look(for tool: PKTool, zoom: CGFloat, darkPaper: Bool) -> Look? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        if let ink = tool as? PKInkingTool {
            var color = ink.color
            if darkPaper { color = PKInkingTool.convertColor(color, from: .light, to: .dark) }
            let marker = ink.inkType == .marker
            return Look(diameter: size(ink.width * zoom), color: color.withAlphaComponent(marker ? 0.4 : 0.75), ring: false)
        }
        if let eraser = tool as? PKEraserTool {
            // the whole-stroke eraser takes away what it touches: a small ring is enough
            let d: CGFloat = eraser.eraserType == .vector ? 12 : eraser.width * zoom
            return Look(diameter: size(d), color: .clear, ring: true)
        }
        return nil
    }

    /// The mark of a shape being drawn with the shape tool.
    static func look(shapeWidth: CGFloat, color: UIColor, zoom: CGFloat) -> Look? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        return Look(diameter: size(shapeWidth * zoom), color: color.withAlphaComponent(0.75), ring: false)
    }

    /// Never so small it cannot be seen, never larger than a big eraser.
    private static func size(_ d: CGFloat) -> CGFloat { min(240, max(4, d)) }
}
