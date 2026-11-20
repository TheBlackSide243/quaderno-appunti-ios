import PencilKit
import UIKit

/// The lasso: choosing strokes and boxes, moving, recolouring, copying them.
extension PageCanvasView {
    // MARK: Lasso selection
    static let inkPasteType = "com.local.appunti.ink"

    var hasSelection: Bool { !selStrokes.isEmpty || !selItems.isEmpty }
    /// Where the chosen things are, in page points.
    var selectionRect: CGRect? { hasSelection ? selFrame : nil }

    func setUpLasso() {
        selectionHost.layer.anchorPoint = .zero
        canvas.addSubview(selectionHost)
        let box = selectionHost.box
        box.onBegin = { [weak self] in self?.selectionMoveBegan() }
        box.onEnd = { [weak self] m, s, t in self?.selectionMoveEnded(m, s, t) }
        lassoLayer.fillColor = UIColor(Theme.accent).withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = UIColor(Theme.accent).cgColor
        lassoLayer.lineJoin = .round
        lassoLayer.zPosition = 15
        items.layer.addSublayer(lassoLayer)
        lassoPan.addTarget(self, action: #selector(lassoDragged))
        lassoPan.maximumNumberOfTouches = 1
        lassoPan.delegate = self
        lassoPan.isEnabled = false
        canvas.addGestureRecognizer(lassoPan)
        lassoTap.addTarget(self, action: #selector(lassoTapped))
        lassoTap.delegate = self
        lassoTap.isEnabled = false
        canvas.addGestureRecognizer(lassoTap)
    }

    @objc private func lassoDragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: items)
        switch g.state {
        case .began:
            clearSelection()
            let t = g.translation(in: items)
            lassoPoints = [CGPoint(x: p.x - t.x, y: p.y - t.y), p]
            drawLasso()
        case .changed:
            lassoPoints.append(p)
            drawLasso()
        case .ended:
            lassoLayer.path = nil
            selectInside(lassoPoints)
            lassoPoints = []
        default:
            lassoLayer.path = nil
            lassoPoints = []
        }
    }

    private func drawLasso() {
        let path = CGMutablePath()
        path.addLines(between: lassoPoints)
        let z = max(0.05, canvas.zoomScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoLayer.lineWidth = 1.5 / z
        lassoLayer.lineDashPattern = [NSNumber(value: Double(6 / z)), NSNumber(value: Double(4 / z))]
        lassoLayer.path = path
        CATransaction.commit()
    }

    @objc private func lassoTapped(_ g: UITapGestureRecognizer) {
        guard hasSelection else { return }
        let p = g.location(in: selectionHost)
        if !selectionHost.box.frame.insetBy(dx: -12, dy: -12).contains(p) { clearSelection() }
    }

    /// Strokes with at least half of their points inside the lasso, and boxes with their centre inside.
    func selectInside(_ poly: [CGPoint]) {
        guard poly.count > 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: poly)
        path.closeSubpath()
        var chosen: [Int] = []
        for (i, s) in canvas.drawing.strokes.enumerated() {
            let pts = s.path.map { $0.location.applying(s.transform) }
            guard !pts.isEmpty else { continue }
            let step = max(1, pts.count / 24)
            var inside = 0, total = 0
            for j in stride(from: 0, to: pts.count, by: step) {
                total += 1
                if path.contains(pts[j]) { inside += 1 }
            }
            if inside * 2 >= total { chosen.append(i) }
        }
        let boxes = items.items.filter { $0.kind != .tape && path.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.map(\.id)
        select(strokes: chosen, items: Set(boxes))
    }

    func select(strokes: [Int], items ids: Set<UUID>) {
        selStrokes = strokes
        selItems = ids
        guard hasSelection else {
            clearSelection()
            return
        }
        selFrame = currentSelectionBounds()
        let box = selectionHost.box
        box.isHidden = false
        box.canRotate = !selStrokes.isEmpty && selItems.isEmpty
        box.reset(to: selFrame.insetBy(dx: -6, dy: -6))
        canvas.bringSubviewToFront(selectionHost)
        onSelectionChange?(true)
    }

    private func currentSelectionBounds() -> CGRect {
        var r = CGRect.null
        let all = canvas.drawing.strokes
        for i in selStrokes where all.indices.contains(i) { r = r.union(all[i].renderBounds) }
        for it in items.items where selItems.contains(it.id) { r = r.union(it.frame) }
        return r.isNull ? .zero : r
    }

    func clearSelection() {
        if selOriginal != nil { selectionMoveEnded(.zero, 1, 0) }
        let had = hasSelection
        selStrokes = []
        selItems = []
        selectionHost.box.isHidden = true
        selectionHost.box.picture.image = nil
        lassoLayer.path = nil
        if had { onSelectionChange?(false) }
    }

    /// A picture of the chosen strokes and boxes, to move around while the finger is down.
    private func selectionPicture(in r: CGRect) -> UIImage? {
        guard r.width > 0, r.height > 0, let nb = notebook else { return nil }
        let strokes = selStrokes.compactMap { canvas.drawing.strokes.indices.contains($0) ? canvas.drawing.strokes[$0] : nil }
        let scale = min(6, (window?.screen.scale ?? 2) * max(1, canvas.zoomScale))
        var ink: UIImage?
        if !strokes.isEmpty {
            UITraitCollection(userInterfaceStyle: darkPaper ? .dark : .light).performAsCurrent {
                ink = PKDrawing(strokes: strokes).image(from: r, scale: scale)
            }
        }
        let boxes = items.items.filter { selItems.contains($0.id) }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let dark = darkPaper
        return UIGraphicsImageRenderer(size: r.size, format: fmt).image { ctx in
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: -r.minX, y: -r.minY)
            PageRenderer.drawItems(nb, boxes, dark: dark)
            ctx.cgContext.restoreGState()
            ink?.draw(in: CGRect(origin: .zero, size: r.size))
        }
    }

    private func selectionMoveBegan() {
        guard hasSelection, selOriginal == nil else { return }
        let original = canvas.drawing
        selectionHost.box.picture.image = selectionPicture(in: selectionHost.box.frame)
        selOriginal = original
        // the chosen strokes leave the page while their picture moves
        let gone = Set(selStrokes)
        loading = true
        canvas.drawing = PKDrawing(strokes: original.strokes.enumerated().filter { !gone.contains($0.offset) }.map(\.element))
        loading = false
        items.setHidden(selItems, true)
    }

    private func selectionMoveEnded(_ move: CGPoint, _ scale: CGFloat, _ turn: CGFloat) {
        guard let original = selOriginal else { return }
        selOriginal = nil
        // the centre the frame had before moving (a view's centre does not follow its transform)
        let center = selectionHost.box.center
        let t = SelectionBox.pageTransform(center: center, move: move, scale: scale, turn: turn)
        loading = true
        canvas.drawing = original
        loading = false
        items.setHidden(selItems, false)
        if !t.isIdentity {
            var d = original
            for i in selStrokes where d.strokes.indices.contains(i) {
                d.strokes[i].transform = d.strokes[i].transform.concatenating(t)
            }
            setDrawingUndoable(d)
            if !selItems.isEmpty { items.transformItems(selItems, by: t, scale: scale) }
        }
        selFrame = currentSelectionBounds()
        selectionHost.box.reset(to: selFrame.insetBy(dx: -6, dy: -6))
    }

    func recolorSelection(_ color: UIColor) {
        guard !selStrokes.isEmpty else { return }
        var d = canvas.drawing
        for i in selStrokes where d.strokes.indices.contains(i) {
            d.strokes[i].ink = PKInk(d.strokes[i].ink.inkType, color: color)
        }
        setDrawingUndoable(d)
    }

    /// A copy of the chosen strokes and text boxes a little lower and to the right, chosen in their place.
    func duplicateSelection() {
        guard hasSelection else { return }
        let shift = CGAffineTransform(translationX: 24, y: 24)
        var d = canvas.drawing
        let first = d.strokes.count
        let copies = selStrokes.compactMap { d.strokes.indices.contains($0) ? d.strokes[$0] : nil }.map { s -> PKStroke in
            var c = s
            c.transform = s.transform.concatenating(shift)
            return c
        }
        d.strokes.append(contentsOf: copies)
        if !copies.isEmpty { setDrawingUndoable(d) }
        var newItems: Set<UUID> = []
        for it in items.items where selItems.contains(it.id) && it.kind == .text {
            var c = it
            c.id = UUID()
            c.x += 24
            c.y += 24
            items.add(c, edit: false, select: false)
            newItems.insert(c.id)
        }
        select(strokes: Array(first..<(first + copies.count)), items: newItems)
    }

    func deleteSelection() {
        guard hasSelection else { return }
        if !selStrokes.isEmpty {
            let gone = Set(selStrokes)
            let d = PKDrawing(strokes: canvas.drawing.strokes.enumerated().filter { !gone.contains($0.offset) }.map(\.element))
            setDrawingUndoable(d)
        }
        let boxes = selItems
        selStrokes = []
        selItems = []
        items.removeItems(boxes)
        clearSelection()
        onSelectionChange?(false)
    }

    /// Copies the chosen strokes (as ink for this app, and as a picture for the others).
    func copySelection() {
        guard hasSelection else { return }
        let strokes = selStrokes.compactMap { canvas.drawing.strokes.indices.contains($0) ? canvas.drawing.strokes[$0] : nil }
        var entry: [String: Any] = [:]
        if !strokes.isEmpty { entry[Self.inkPasteType] = PKDrawing(strokes: strokes).dataRepresentation() }
        if let png = selectionPicture(in: selFrame)?.pngData() { entry["public.png"] = png }
        UIPasteboard.general.setItems([entry])
    }

    /// Puts copied ink on the page, in the middle of what is in view. False if there is none.
    func pasteInk() -> Bool {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.inkPasteType),
              let pasted = try? PKDrawing(data: data), !pasted.strokes.isEmpty else { return false }
        let b = pasted.bounds
        let c = visibleCenter
        let shift = CGAffineTransform(translationX: c.x - b.midX, y: c.y - b.midY)
        var d = canvas.drawing
        let first = d.strokes.count
        d.strokes.append(contentsOf: pasted.strokes.map { s -> PKStroke in
            var n = s
            n.transform = s.transform.concatenating(shift)
            return n
        })
        setDrawingUndoable(d)
        if lassoMode { select(strokes: Array(first..<d.strokes.count), items: []) }
        return true
    }
}
