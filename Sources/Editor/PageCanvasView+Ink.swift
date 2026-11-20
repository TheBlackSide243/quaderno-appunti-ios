import PencilKit
import UIKit

/// The laser pointer, listening to the writing, shapes and shapes drawn by hand.
extension PageCanvasView {
    // MARK: Laser

    @objc func laserDragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: items)
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            let t = g.translation(in: items)
            laserPoints.append((CGPoint(x: p.x - t.x, y: p.y - t.y), now, true))
            laserPoints.append((p, now, false))
            startLaser()
        case .changed:
            laserPoints.append((p, now, false))
        default:
            break
        }
    }

    private func startLaser() {
        guard laserLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(laserTick))
        link.add(to: .main, forMode: .common)
        laserLink = link
    }

    @objc private func laserTick() {
        let now = CACurrentMediaTime()
        let life: CFTimeInterval = 0.7
        // drop the old end of the trail, keeping a start marker on what remains
        while let first = laserPoints.first, now - first.t > life {
            laserPoints.removeFirst()
            if !first.start, let next = laserPoints.first, !next.start { laserPoints[0].start = true }
        }
        let z = max(0.05, canvas.zoomScale)
        let path = UIBezierPath()
        for pt in laserPoints {
            if pt.start || path.isEmpty { path.move(to: pt.p) } else { path.addLine(to: pt.p) }
        }
        if let last = laserPoints.last {
            // the dot at the tip
            let r = 4.5 / z
            path.move(to: CGPoint(x: last.p.x + r, y: last.p.y))
            path.addArc(withCenter: last.p, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        laserGlow.lineWidth = 9 / z
        laserCore.lineWidth = 3.5 / z
        laserGlow.path = path.cgPath
        laserCore.path = path.cgPath
        CATransaction.commit()
        let active = laserPan.state == .began || laserPan.state == .changed
        if laserPoints.isEmpty && !active {
            laserLink?.invalidate()
            laserLink = nil
            laserGlow.path = nil
            laserCore.path = nil
        }
    }

    // MARK: Listening

    @objc func listenTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: items)
        onInkTap?(strokeDate(at: p))
    }

    /// When the stroke under a point was written: the closest stroke within a finger's reach.
    func strokeDate(at p: CGPoint) -> Date? {
        let reach: CGFloat = 16 / max(0.3, min(2, canvas.zoomScale))
        var best: (d: CGFloat, date: Date)?
        for s in canvas.drawing.strokes.reversed() {
            guard s.renderBounds.insetBy(dx: -reach, dy: -reach).contains(p) else { continue }
            for pt in s.path.interpolatedPoints(by: .distance(3)) {
                let q = pt.location.applying(s.transform)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < reach, d < (best?.d ?? .infinity) { best = (d, s.path.creationDate) }
            }
        }
        return best?.date
    }

    func clamped(_ p: CGPoint) -> CGPoint {
        guard let pg = page else { return p }
        return CGPoint(x: min(max(0, p.x), pg.size.width), y: min(max(0, p.y), pg.size.height))
    }

    @objc func shapeDragged(_ g: UIPanGestureRecognizer) {
        guard let style = shape else { return }
        let p = clamped(g.location(in: items))
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                // the drag is recognised after a few points of movement: start where the touch began
                let t = g.translation(in: items)
                shapeStart = clamped(CGPoint(x: p.x - t.x, y: p.y - t.y))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeLayer.strokeColor = style.color.cgColor
            shapeLayer.lineWidth = style.width
            shapeLayer.path = Shapes.path(style.kind, from: shapeStart, to: p, width: style.width)
            CATransaction.commit()
        case .ended:
            shapeLayer.path = nil
            guard hypot(p.x - shapeStart.x, p.y - shapeStart.y) > 6 else { return }
            addShape(style, from: shapeStart, to: p)
        default:
            shapeLayer.path = nil
        }
    }

    /// Puts a shape on the page as ink (it can be erased, moved with the lasso and undone).
    func addShape(_ style: ShapeStyle, from a: CGPoint, to b: CGPoint) {
        var drawing = canvas.drawing
        drawing.strokes.append(Shapes.stroke(style.kind, from: a, to: b, color: style.color, width: style.width))
        setDrawingUndoable(drawing)
    }

    func setDrawingUndoable(_ new: PKDrawing) {
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setDrawingUndoable(old) }
        }
        canvas.drawing = new
        onUndoChange?()
    }

    // MARK: Shapes drawn by hand

    @objc func inkGesture(_ g: UIGestureRecognizer) {
        guard snapShapes, let tool = canvas.tool as? PKInkingTool else { return }
        let p = g.location(in: items)
        let screen = g.location(in: self)
        switch g.state {
        case .began:
            hoverMark.hide()
            inkPoints = [p]
            snapOutline = nil
            pendingSnap = nil
            holdAnchor = screen
            armHold(tool)
        case .changed:
            inkPoints.append(p)
            if hypot(screen.x - holdAnchor.x, screen.y - holdAnchor.y) > 5 {
                holdAnchor = screen
                if snapOutline != nil {
                    snapOutline = nil
                    shapeLayer.path = nil
                }
                armHold(tool)
            }
        case .ended:
            holdWork?.cancel()
            if let o = snapOutline {
                pendingSnap = o
                // if PencilKit does not hand the stroke over, do not leave the preview behind
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.pendingSnap == o else { return }
                    self.pendingSnap = nil
                    self.shapeLayer.path = nil
                }
            }
            snapOutline = nil
        default:
            holdWork?.cancel()
            snapOutline = nil
            shapeLayer.path = nil
        }
    }

    private func armHold(_ tool: PKInkingTool) {
        holdWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.holdFired(tool) }
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func holdFired(_ tool: PKInkingTool) {
        let g = canvas.drawingGestureRecognizer
        guard g.state == .began || g.state == .changed, let r = ShapeRecognizer.recognize(inkPoints) else { return }
        // the highlighter only straightens lines
        if tool.inkType == .marker, r.kind != .line { return }
        snapOutline = r.points
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let light = tool.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        shapeLayer.strokeColor = light.withAlphaComponent(tool.inkType == .marker ? 0.5 : 0.85).cgColor
        shapeLayer.lineWidth = max(1.5, tool.width * (tool.inkType == .marker ? 1 : 0.8))
        let path = CGMutablePath()
        path.addLines(between: r.points)
        shapeLayer.path = path
        CATransaction.commit()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Replaces the stroke just drawn with the clean shape, in the same ink.
    func snapLastStroke(to outline: [CGPoint]) {
        shapeLayer.path = nil
        var d = canvas.drawing
        guard let last = d.strokes.last, abs(last.path.creationDate.timeIntervalSinceNow) < 10 else { return }
        let pts = Array(last.path)
        guard !pts.isEmpty else { return }
        let median = pts.map { $0.size.width }.sorted()[pts.count / 2]
        let opacity = pts.map(\.opacity).sorted()[pts.count / 2]
        let type = last.ink.inkType
        // the pen thins strokes made in code, so the shape uses the even ink at the same width
        let ink = type == .pen ? PKInk(.monoline, color: last.ink.color) : last.ink
        let s = type == .pen ? median * 0.565 + 1.85 : median
        d.strokes[d.strokes.count - 1] = Shapes.stroke(points: outline, ink: ink, size: s, opacity: opacity)
        setDrawingUndoable(d)
    }
}
