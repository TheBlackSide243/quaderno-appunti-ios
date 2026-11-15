import SwiftUI
import UIKit

/// The layer above the page that holds the lasso selection, in page points. Touches outside the
/// selection fall through to the page.
@MainActor
final class SelectionHost: UIView {
    let box = SelectionBox()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        box.isHidden = true
        addSubview(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    /// The handles keep the same size on screen at any zoom.
    func setZoom(_ z: CGFloat) { box.unit = 1 / max(0.05, z) }
}

/// What the lasso chose: a dashed frame to drag, a corner to make it bigger or smaller and a
/// handle on top to turn it. While it moves it shows a picture of what is inside; the real strokes
/// and boxes change when the finger lifts.
@MainActor
final class SelectionBox: UIView {
    let picture = UIImageView()
    private let border = CAShapeLayer()
    private let scaleHandle = UIView()
    private let rotateHandle = UIView()
    private let stem = CAShapeLayer()

    /// One screen point, in page points.
    var unit: CGFloat = 1 { didSet { if unit != oldValue { setNeedsLayout() } } }
    /// Whether turning is offered (not when only boxes are chosen: they do not turn).
    var canRotate = true { didSet { rotateHandle.isHidden = !canRotate; stem.isHidden = !canRotate } }

    var onBegin: (() -> Void)?
    /// The change so far: move, scale and turn about the centre of the frame.
    var onChange: ((CGPoint, CGFloat, CGFloat) -> Void)?
    var onEnd: ((CGPoint, CGFloat, CGFloat) -> Void)?

    private var move = CGPoint.zero
    private var scale: CGFloat = 1
    private var turn: CGFloat = 0
    private var startPoint = CGPoint.zero
    private var center0 = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.accent).withAlphaComponent(0.06)
        picture.contentMode = .scaleToFill
        addSubview(picture)
        border.fillColor = nil
        border.strokeColor = UIColor(Theme.accent).cgColor
        border.lineDashPattern = [6, 4]
        layer.addSublayer(border)
        stem.strokeColor = UIColor(Theme.accent).cgColor
        layer.addSublayer(stem)
        for h in [scaleHandle, rotateHandle] {
            h.backgroundColor = UIColor(Theme.accent)
            h.layer.borderColor = UIColor.white.cgColor
            addSubview(h)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moved))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let sp = UIPanGestureRecognizer(target: self, action: #selector(scaled))
        scaleHandle.addGestureRecognizer(sp)
        let rp = UIPanGestureRecognizer(target: self, action: #selector(turned))
        rotateHandle.addGestureRecognizer(rp)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let u = unit
        picture.frame = bounds
        border.frame = bounds
        border.lineWidth = 1.5 * u
        border.lineDashPattern = [NSNumber(value: Double(6 * u)), NSNumber(value: Double(4 * u))]
        border.path = UIBezierPath(rect: bounds.insetBy(dx: -3 * u, dy: -3 * u)).cgPath
        let s = 22 * u
        scaleHandle.frame = CGRect(x: bounds.maxX - s / 2 + 3 * u, y: bounds.maxY - s / 2 + 3 * u, width: s, height: s)
        rotateHandle.frame = CGRect(x: bounds.midX - s / 2, y: -34 * u - s / 2, width: s, height: s)
        for h in [scaleHandle, rotateHandle] {
            h.layer.cornerRadius = s / 2
            h.layer.borderWidth = 2 * u
        }
        stem.lineWidth = 1.5 * u
        let p = UIBezierPath()
        p.move(to: CGPoint(x: bounds.midX, y: -3 * u))
        p.addLine(to: CGPoint(x: bounds.midX, y: -34 * u + s / 2))
        stem.path = p.cgPath
    }

    /// Touches on the handles count even though they stick out of the frame.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.insetBy(dx: -8 * unit, dy: -8 * unit).contains(point) { return true }
        return [scaleHandle, rotateHandle].contains { !$0.isHidden && $0.frame.insetBy(dx: -10 * unit, dy: -10 * unit).contains(point) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for h in [scaleHandle, rotateHandle] where !h.isHidden && h.frame.insetBy(dx: -10 * unit, dy: -10 * unit).contains(point) { return h }
        return super.hitTest(point, with: event)
    }

    /// Puts the frame around `r` (page points), back to no change.
    func reset(to r: CGRect) {
        transform = .identity
        frame = r
        move = .zero
        scale = 1
        turn = 0
        picture.image = nil
        setNeedsLayout()
    }

    private var host: UIView { superview ?? self }

    private func begin(_ g: UIGestureRecognizer) {
        startPoint = g.location(in: host)
        center0 = CGPoint(x: frame.midX, y: frame.midY)
        // the frame keeps its centre: `frame` is only read before any transform is set
        onBegin?()
    }

    private func update(_ g: UIGestureRecognizer) {
        transform = CGAffineTransform(translationX: move.x, y: move.y).rotated(by: turn).scaledBy(x: scale, y: scale)
        if g.state == .ended {
            onEnd?(move, scale, turn)
        } else if g.state == .cancelled || g.state == .failed {
            move = .zero; scale = 1; turn = 0
            transform = .identity
            onEnd?(.zero, 1, 0)
        } else {
            onChange?(move, scale, turn)
        }
    }

    @objc private func moved(_ g: UIPanGestureRecognizer) {
        if g.state == .began { begin(g) }
        let p = g.location(in: host)
        move = CGPoint(x: p.x - startPoint.x, y: p.y - startPoint.y)
        update(g)
    }

    @objc private func scaled(_ g: UIPanGestureRecognizer) {
        if g.state == .began { begin(g) }
        let p = g.location(in: host)
        let d0 = hypot(startPoint.x - center0.x, startPoint.y - center0.y)
        let d1 = hypot(p.x - center0.x, p.y - center0.y)
        scale = d0 > 1 ? min(8, max(0.15, d1 / d0)) : 1
        update(g)
    }

    @objc private func turned(_ g: UIPanGestureRecognizer) {
        if g.state == .began { begin(g) }
        let p = g.location(in: host)
        var a = atan2(p.y - center0.y, p.x - center0.x) - atan2(startPoint.y - center0.y, startPoint.x - center0.x)
        // snaps to straight angles when close
        for k in stride(from: -2.0, through: 2.0, by: 0.5) where abs(a - CGFloat(k) * .pi) < 0.06 { a = CGFloat(k) * .pi }
        turn = a
        update(g)
    }

    /// The change in page points: move, then turn and scale about the centre the frame had.
    static func pageTransform(center c: CGPoint, move m: CGPoint, scale s: CGFloat, turn t: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x + m.x, y: c.y + m.y).rotated(by: t).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
    }
}
