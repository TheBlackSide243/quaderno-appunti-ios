import PencilKit
import UIKit

/// Geometry of the shape tool: the same outline is used for the live preview and for the ink that
/// ends up on the page, so what you see while dragging is what you get.
enum Shapes {
    /// The outline of a shape dragged from `a` to `b`, as one polyline.
    static func outline(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, width: CGFloat) -> [CGPoint] {
        switch kind {
        case .line:
            return [a, b]
        case .arrow:
            let ang = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, width * 4.5)
            let l = CGPoint(x: b.x - head * cos(ang - 0.45), y: b.y - head * sin(ang - 0.45))
            let r = CGPoint(x: b.x - head * cos(ang + 0.45), y: b.y - head * sin(ang + 0.45))
            return [a, b, l, b, r]
        case .rectangle:
            return [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
        case .ellipse:
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return (0...72).map { i in
                let t = CGFloat(i) / 72 * 2 * .pi
                return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
            }
        }
    }

    static func path(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
        let pts = outline(kind, from: a, to: b, width: width)
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        return p
    }

    /// Points every few points of length along the polyline, so the ink follows it closely and
    /// corners stay corners.
    private static func densify(_ pts: [CGPoint], step: CGFloat = 4) -> [CGPoint] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for q in pts.dropFirst() {
            let d = hypot(q.x - last.x, q.y - last.y)
            let n = max(1, Int((d / step).rounded(.up)))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                out.append(CGPoint(x: last.x + (q.x - last.x) * t, y: last.y + (q.y - last.y) * t))
            }
            last = q
        }
        return out
    }

    /// The shape as ink: an even line of the given colour and width.
    static func stroke(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) -> PKStroke {
        let pts = densify(outline(kind, from: a, to: b, width: width))
        let size = CGSize(width: width, height: width)
        let control = pts.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.01, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: control, creationDate: Date()))
    }
}
