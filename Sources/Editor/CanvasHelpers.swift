import PencilKit
import UIKit

/// A label with room around its text.
final class PaddedLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 14)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + 28, height: s.height + 14)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 14, dy: 7))
    }
}

/// The PencilKit canvas, which does not start a stroke on a link button so the button gets the tap.
final class LinkAwareCanvas: PKCanvasView {
    var blocksDrawing: ((CGPoint) -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === drawingGestureRecognizer, blocksDrawing?(g.location(in: self)) == true { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// Round buttons on the corner of the boxes that link to a page. They keep the same size on
/// screen at any zoom and only they take touches.
@MainActor
final class LinkLayer: UIView {
    var onTap: ((UUID) -> Void)?
    private var buttons: [UUID: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        button(at: point)
    }

    func button(at p: CGPoint) -> UIButton? {
        buttons.values.first { !$0.isHidden && $0.frame.insetBy(dx: -6, dy: -6).contains(p) }
    }

    func update(_ items: [PageItem], zoom: CGFloat) {
        let z = zoom.isFinite && zoom > 0 ? zoom : 1
        let linked = items.filter { $0.link != nil }
        let keep = Set(linked.map(\.id))
        for (id, b) in buttons where !keep.contains(id) {
            b.removeFromSuperview()
            buttons[id] = nil
        }
        for item in linked {
            let b = buttons[item.id] ?? makeButton(item.id)
            b.accessibilityValue = item.text
            b.tag = 0
            b.transform = CGAffineTransform(scaleX: 1 / z, y: 1 / z)
            // on the right end of the box, vertically centred on its first line
            let side: CGFloat = 30
            b.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            b.center = CGPoint(x: item.frame.maxX + side / (2 * z), y: item.frame.minY + min(item.frame.height, 34) / 2)
            linkTargets[item.id] = item.link
        }
    }

    private var linkTargets: [UUID: UUID] = [:]

    private func makeButton(_ id: UUID) -> UIButton {
        var conf = UIButton.Configuration.filled()
        conf.image = UIImage(systemName: "arrow.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        conf.baseBackgroundColor = UIColor(Theme.accent)
        conf.baseForegroundColor = UIColor(Theme.bg)
        conf.cornerStyle = .capsule
        let b = UIButton(configuration: conf)
        b.accessibilityLabel = String(localized: "Vai alla pagina collegata")
        b.addAction(UIAction { [weak self] _ in
            guard let self, let target = self.linkTargets[id] else { return }
            self.onTap?(target)
        }, for: .touchUpInside)
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.3
        b.layer.shadowRadius = 2
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(b)
        buttons[id] = b
        return b
    }
}
