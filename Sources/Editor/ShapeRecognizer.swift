import CoreGraphics
import Foundation

/// Turns a hand-drawn stroke into a clean shape when the pen stays still at the end of it: a line,
/// a triangle, a rectangle (or any four-sided shape), an ellipse or circle, or a short broken line.
enum ShapeRecognizer {
    enum Kind: Equatable { case line, polyline, triangle, rectangle, quadrilateral, ellipse }

    struct Result: Equatable {
        var kind: Kind
        /// The outline, as one polyline in the same coordinates as the input.
        var points: [CGPoint]
    }

    static func recognize(_ raw: [CGPoint]) -> Result? {
        let pts = dedupe(raw)
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let box = bounds(pts)
        let diag = hypot(box.width, box.height)
        guard diag >= 14 else { return nil }
        // the length of the stroke without the tremble of the hand
        let length = pathLength(smoothed(pts, radius: 3))
        let chord = dist(first, last)

        // A line: the ends are almost as far apart as the stroke is long, and no point strays.
        if chord / length > 0.9, maxDeviation(pts, first, last) < max(4, chord * 0.07) {
            return Result(kind: .line, points: straighten(first, last))
        }

        let closed = chord < max(18, diag * 0.22) && length > diag * 1.6
        if closed {
            if let e = ellipse(pts) { return e }
            var ring = simplify(pts, epsilon: diag * 0.07)
            if ring.count > 2, dist(ring[0], ring[ring.count - 1]) < max(18, diag * 0.22) { ring.removeLast() }
            ring = dropStraight(mergeClose(ring, minDistance: diag * 0.12))
            switch ring.count {
            case 3:
                return Result(kind: .triangle, points: ring + [ring[0]])
            case 4:
                if axisAligned(ring) {
                    let r = averagedRect(ring)
                    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                    return Result(kind: .rectangle, points: corners + [corners[0]])
                }
                return Result(kind: .quadrilateral, points: ring + [ring[0]])
            default:
                return nil
            }
        }

        // An open broken line of two to four straight pieces.
        let simple = mergeClose(simplify(pts, epsilon: diag * 0.06), minDistance: diag * 0.1)
        if (3...5).contains(simple.count), fits(pts, simple, tolerance: max(5, diag * 0.06)) {
            return Result(kind: .polyline, points: simple)
        }
        return nil
    }

    // MARK: Pieces

    /// Lines close to horizontal or vertical become exactly so.
    private static func straighten(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let ang = abs(atan2(b.y - a.y, b.x - a.x))
        let tol = 6 * CGFloat.pi / 180
        if ang < tol || abs(ang - .pi) < tol {
            let y = (a.y + b.y) / 2
            return [CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y)]
        }
        if abs(ang - .pi / 2) < tol {
            let x = (a.x + b.x) / 2
            return [CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y)]
        }
        return [a, b]
    }

    /// An ellipse with axes along the page, when every point is close to it.
    private static func ellipse(_ pts: [CGPoint]) -> Result? {
        let box = bounds(pts)
        guard box.width > 8, box.height > 8 else { return nil }
        let c = CGPoint(x: box.midX, y: box.midY)
        var rx = box.width / 2, ry = box.height / 2
        // nearly round: a circle
        if abs(rx - ry) / max(rx, ry) < 0.12 {
            let r = (rx + ry) / 2
            rx = r; ry = r
        }
        var err: CGFloat = 0
        for p in pts {
            let dx = (p.x - c.x) / rx, dy = (p.y - c.y) / ry
            err += abs(sqrt(dx * dx + dy * dy) - 1)
        }
        err /= CGFloat(pts.count)
        guard err < 0.1 else { return nil }
        // the stroke must go round, not just fill the box with a zigzag
        var turned: CGFloat = 0
        var prev = atan2(pts[0].y - c.y, pts[0].x - c.x)
        for p in pts.dropFirst() {
            let a = atan2(p.y - c.y, p.x - c.x)
            var d = a - prev
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            turned += d
            prev = a
        }
        guard abs(turned) > 1.6 * .pi else { return nil }
        let outline = (0...72).map { i -> CGPoint in
            let t = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
        }
        return Result(kind: .ellipse, points: outline)
    }

    private static func axisAligned(_ q: [CGPoint]) -> Bool {
        let tol = 14 * CGFloat.pi / 180
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            var ang = abs(atan2(b.y - a.y, b.x - a.x)).truncatingRemainder(dividingBy: .pi / 2)
            ang = min(ang, .pi / 2 - ang)
            if ang > tol { return false }
        }
        return true
    }

    /// The rectangle whose sides are the averages of the drawn sides.
    private static func averagedRect(_ q: [CGPoint]) -> CGRect {
        let xs = q.map(\.x).sorted(), ys = q.map(\.y).sorted()
        let minX = (xs[0] + xs[1]) / 2, maxX = (xs[2] + xs[3]) / 2
        let minY = (ys[0] + ys[1]) / 2, maxY = (ys[2] + ys[3]) / 2
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Geometry

    private static func dedupe(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts where out.last.map({ dist($0, p) > 0.5 }) ?? true { out.append(p) }
        return out
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Each point moved to the average of its neighbours.
    private static func smoothed(_ pts: [CGPoint], radius: Int) -> [CGPoint] {
        guard pts.count > radius * 2 else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - radius), hi = min(pts.count - 1, i + radius)
            var x: CGFloat = 0, y: CGFloat = 0
            for k in lo...hi { x += pts[k].x; y += pts[k].y }
            let n = CGFloat(hi - lo + 1)
            return CGPoint(x: x / n, y: y / n)
        }
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
    }

    /// Distance of `p` from the segment a–b.
    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func maxDeviation(_ pts: [CGPoint], _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        pts.map { segmentDistance($0, a, b) }.max() ?? 0
    }

    /// Ramer–Douglas–Peucker: the corners of the stroke.
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var best = s, bestD: CGFloat = 0
            for i in (s + 1)..<e {
                let d = segmentDistance(pts[i], pts[s], pts[e])
                if d > bestD { bestD = d; best = i }
            }
            if bestD > epsilon {
                keep[best] = true
                stack.append((s, best))
                stack.append((best, e))
            }
        }
        // a closed stroke starts and ends at the same place: split it at its farthest point too
        if dist(pts[0], pts[pts.count - 1]) < epsilon {
            let far = pts.indices.max { dist(pts[$0], pts[0]) < dist(pts[$1], pts[0]) } ?? 0
            if !keep[far] {
                keep[far] = true
                let left = simplify(Array(pts[0...far]), epsilon: epsilon)
                let right = simplify(Array(pts[far...]), epsilon: epsilon)
                return left + right.dropFirst()
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Drops corners closer than `minDistance` to the previous one.
    private static func mergeClose(_ pts: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = pts.first else { return pts }
        var out = [first]
        for p in pts.dropFirst() {
            if dist(p, out[out.count - 1]) >= minDistance { out.append(p) } else if p == pts.last { out[out.count - 1] = p }
        }
        return out
    }

    /// Removes the corners of a closed outline where it hardly turns (where the stroke started in
    /// the middle of a side, for example).
    private static func dropStraight(_ ring: [CGPoint]) -> [CGPoint] {
        var r = ring
        var changed = true
        while changed, r.count > 3 {
            changed = false
            for i in 0..<r.count {
                let a = r[(i + r.count - 1) % r.count], b = r[i], c = r[(i + 1) % r.count]
                let a1 = atan2(b.y - a.y, b.x - a.x), a2 = atan2(c.y - b.y, c.x - b.x)
                var turn = abs(a2 - a1)
                if turn > .pi { turn = 2 * .pi - turn }
                if turn < 0.45 {
                    r.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return r
    }

    /// True when every point of the stroke is close to the broken line.
    private static func fits(_ pts: [CGPoint], _ poly: [CGPoint], tolerance: CGFloat) -> Bool {
        for p in pts {
            var best = CGFloat.infinity
            for (a, b) in zip(poly, poly.dropFirst()) { best = min(best, segmentDistance(p, a, b)) }
            if best > tolerance { return false }
        }
        return true
    }
}
