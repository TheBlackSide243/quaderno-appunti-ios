import PencilKit
import UIKit

/// The zoom window's box, the spelling marks, tape and areas, text boxes and pictures.
extension PageCanvasView {
    // MARK: Zoom window

    private func setUpZoomBox() {
        zoomBoxLayer.fillColor = UIColor(Theme.accent).withAlphaComponent(0.10).cgColor
        zoomBoxLayer.strokeColor = UIColor(Theme.accent).cgColor
        zoomBoxLayer.lineDashPattern = [5, 4]
        zoomBoxLayer.zPosition = 14
        items.layer.addSublayer(zoomBoxLayer)
        zoomTap.addTarget(self, action: #selector(zoomTapped))
        zoomTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        zoomTap.isEnabled = false
        canvas.addGestureRecognizer(zoomTap)
    }

    /// Shows where the zoom window writes (nil = hides it) and keeps that place in view.
    func showZoomBox(_ r: CGRect?) {
        if zoomBoxLayer.superlayer == nil { setUpZoomBox() }
        zoomTap.isEnabled = r != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomBoxLayer.lineWidth = 1.5 / max(0.05, canvas.zoomScale)
        zoomBoxLayer.path = r.map { UIBezierPath(rect: $0).cgPath }
        CATransaction.commit()
        guard let r else { return }
        let z = canvas.zoomScale
        let visible = CGRect(x: canvas.contentOffset.x / z, y: canvas.contentOffset.y / z,
                             width: canvas.bounds.width / z, height: (canvas.bounds.height - 260) / z)
        if !visible.contains(r) {
            canvas.scrollRectToVisible(CGRect(x: r.minX * z - 20, y: r.minY * z - 60, width: r.width * z + 40, height: r.height * z + 120), animated: true)
        }
    }

    @objc private func zoomTapped(_ g: UITapGestureRecognizer) {
        onZoomTap?(g.location(in: items))
    }

    /// Strokes made elsewhere (the zoom window) added to the page, with undo.
    func appendStrokes(_ strokes: [PKStroke]) {
        guard !strokes.isEmpty else { return }
        var d = canvas.drawing
        d.strokes.append(contentsOf: strokes)
        setDrawingUndoable(d)
    }

    /// A picture of a part of the page as it is now: paper, boxes and every visible layer.
    func snapshot(of r: CGRect, scale: CGFloat) -> UIImage? {
        guard let nb = notebook, let pg = page, r.width > 0, r.height > 0 else { return nil }
        let dark = darkPaper
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        var below: [PKStroke] = [], above: [PKStroke] = []
        if let lid = layerID, let i = pg.inkLayers.firstIndex(where: { $0.id == lid }), pg.inkLayers.count > 1 {
            below = pg.inkLayers[..<i].filter { !$0.isHidden }.flatMap { Store.loadDrawing(nb.id, $0.id).strokes }
            above = pg.inkLayers[(i + 1)...].filter { !$0.isHidden }.flatMap { Store.loadDrawing(nb.id, $0.id).strokes }
        }
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            ink = PKDrawing(strokes: below + canvas.drawing.strokes + above).image(from: r, scale: scale)
        }
        let list = items.items
        return UIGraphicsImageRenderer(size: r.size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.saveGState()
            c.translateBy(x: -r.minX, y: -r.minY)
            c.clip(to: r)
            PageRenderer.drawBackground(nb, pg, in: c)
            PageRenderer.drawItems(nb, list.filter { $0.kind != .tape }, dark: dark)
            c.restoreGState()
            ink.draw(in: CGRect(origin: .zero, size: r.size), blendMode: dark ? .normal : .multiply, alpha: 1)
        }
    }

    // MARK: Spelling

    func showMisspelled(_ rects: [CGRect]) {
        spellRects = rects
        spellTap.isEnabled = !rects.isEmpty
        let path = UIBezierPath()
        for r in rects {
            // a wavy line under the word
            let y = r.maxY + 1.5
            var x = r.minX
            path.move(to: CGPoint(x: x, y: y))
            var up = true
            while x < r.maxX {
                let nx = min(r.maxX, x + 2.5)
                path.addQuadCurve(to: CGPoint(x: nx, y: y), controlPoint: CGPoint(x: (x + nx) / 2, y: y + (up ? -2 : 2)))
                up.toggle()
                x = nx
            }
        }
        spellLayer.path = rects.isEmpty ? nil : path.cgPath
    }

    func spellIndex(at p: CGPoint) -> Int? {
        spellRects.firstIndex { $0.insetBy(dx: -6, dy: -8).contains(p) }
    }

    @objc func spellTapped(_ g: UITapGestureRecognizer) {
        if let i = spellIndex(at: g.location(in: items)) { onSpellTap?(i) }
    }

    // MARK: Tape and areas

    @objc func pickDragged(_ g: UIPanGestureRecognizer) {
        guard let mode = pick else { return }
        let p = clamped(g.location(in: items))
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                let t = g.translation(in: items)
                pickStart = clamped(CGPoint(x: p.x - t.x, y: p.y - t.y))
            }
            let r = pickRect(mode, from: pickStart, to: p)
            let z = max(0.05, canvas.zoomScale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch mode {
            case .tape(let hex):
                pickLayer.fillColor = UIColor(hex: hex).withAlphaComponent(0.85).cgColor
                pickLayer.strokeColor = nil
                pickLayer.lineDashPattern = nil
            case .area:
                pickLayer.fillColor = UIColor(Theme.accent).withAlphaComponent(0.12).cgColor
                pickLayer.strokeColor = UIColor(Theme.accent).cgColor
                pickLayer.lineWidth = 2 / z
                pickLayer.lineDashPattern = [NSNumber(value: Double(6 / z)), NSNumber(value: Double(4 / z))]
            }
            pickLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 2).cgPath
            CATransaction.commit()
        case .ended:
            pickLayer.path = nil
            let r = pickRect(mode, from: pickStart, to: p)
            guard r.width > 8, r.height > 8 else { return }
            switch mode {
            case .tape(let hex): addTape(r, color: hex)
            case .area: onPick?(r)
            }
        default:
            pickLayer.path = nil
        }
    }

    /// The rectangle dragged; tape dragged along a line becomes a strip one line high.
    private func pickRect(_ mode: Pick, from a: CGPoint, to b: CGPoint) -> CGRect {
        var r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        if case .tape = mode, r.height < 20 {
            let mid = (a.y + b.y) / 2
            r = CGRect(x: r.minX, y: mid - 11, width: max(r.width, 1), height: 22)
        }
        return r
    }

    func addTape(_ r: CGRect, color: String) {
        var item = PageItem(kind: .tape, x: r.minX, y: r.minY, w: r.width, h: r.height)
        item.color = color
        items.add(item, edit: false, select: false)
    }

    @objc func tapeTapped(_ g: UITapGestureRecognizer) {
        guard let t = items.tape(at: g.location(in: items)) else { return }
        items.setCovered(t.id, !t.isCovered)
    }

    /// Covers all the tape on the page again; false if none was uncovered.
    @discardableResult
    func coverAllTapes() -> Bool { items.coverAllTapes() }

    var hasTape: Bool { items.hasTape }

    /// Outlines an area already chosen; nil removes it.
    func mark(_ r: CGRect?) {
        guard let r else { markLayer.path = nil; return }
        let z = max(0.05, canvas.zoomScale)
        markLayer.fillColor = UIColor(Theme.accent).withAlphaComponent(0.18).cgColor
        markLayer.strokeColor = UIColor(Theme.accent).cgColor
        markLayer.lineWidth = 2 / z
        markLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 2).cgPath
    }

    /// The strokes mostly inside an area.
    func strokes(in r: CGRect) -> [PKStroke] {
        canvas.drawing.strokes.filter { Self.mostlyInside($0, r) }
    }

    private static func mostlyInside(_ s: PKStroke, _ r: CGRect) -> Bool {
        let b = s.renderBounds
        let i = b.intersection(r)
        guard !i.isNull else { return false }
        return i.width * i.height >= 0.5 * max(1, b.width * b.height) || r.contains(CGPoint(x: b.midX, y: b.midY))
    }

    /// Removes the strokes mostly inside an area (undoable).
    func removeStrokes(in r: CGRect) {
        var d = canvas.drawing
        let before = d.strokes.count
        d.strokes.removeAll { Self.mostlyInside($0, r) }
        guard d.strokes.count != before else { return }
        setDrawingUndoable(d)
    }

    /// What is inside an area (ink, text and pictures, without the paper and the tape) as a picture
    /// with a transparent background; nil when the area is empty.
    func cutout(_ r: CGRect) -> UIImage? {
        guard let nb = notebook else { return nil }
        let list = items.items.filter { $0.kind != .tape && $0.frame.intersects(r) }
        let ink = canvas.drawing.strokes.filter { $0.renderBounds.intersects(r) }
        guard !list.isEmpty || !ink.isEmpty else { return nil }
        let scale: CGFloat = 3
        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = PKDrawing(strokes: ink).image(from: r, scale: scale)
        }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: r.size, format: fmt).image { ctx in
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: -r.minX, y: -r.minY)
            PageRenderer.drawItems(nb, list)
            ctx.cgContext.restoreGState()
            inkImage.draw(in: CGRect(origin: .zero, size: r.size))
        }
    }

    /// A text box over an area, for typed text that replaces handwriting.
    func addTextBox(_ text: String, in r: CGRect, fontSize: Double) {
        var item = PageItem(kind: .text, x: r.minX, y: r.minY, w: max(60, r.width), h: max(30, r.height))
        item.text = text
        item.fontSize = fontSize
        items.add(item, edit: false, select: false)
    }

    // MARK: Boxes

    /// A new text box in the middle of the screen; with `text` it is filled in, otherwise it opens for typing.
    func addText(_ text: String? = nil) {
        if drawMode { drawMode = false }
        let c = visibleCenter
        let w = min(320, (page?.size.width ?? 595) * 0.6)
        var item = PageItem(kind: .text, x: c.x - w / 2, y: c.y - 30, w: w, h: 60)
        if let text {
            item.text = text
            // tall enough for the whole text, so nothing is cut when the page is exported
            let inset = PageRenderer.textInset
            let box = (text as NSString).boundingRect(with: CGSize(width: w - inset.left - inset.right, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: PageRenderer.textAttributes(item), context: nil)
            item.h = Double(box.height.rounded(.up) + inset.top + inset.bottom + 2)
            if let pg = page {
                item.y = Double(min(max(8, c.y - box.height / 2), max(8, pg.size.height - CGFloat(item.h) - 8)))
            }
        }
        items.add(item, edit: text == nil)
    }

    /// A picture in the middle of the screen; stickers keep their transparency and come in small.
    func addImage(_ img: UIImage, sticker: Bool = false) {
        guard let nb = notebook, let pg = page, let (name, size) = Store.saveImage(img, nb.id, keepAlpha: sticker) else { return }
        if drawMode { drawMode = false }
        let c = visibleCenter
        let w = sticker ? min(140, size.width / 2) : min(pg.size.width * 0.6, size.width)
        let h = w * size.height / max(1, size.width)
        var item = PageItem(kind: .image, x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
        item.image = name
        items.add(item, edit: false)
    }

    func updateSelected(_ change: (inout PageItem) -> Void) { items.updateSelected(change) }
    func deleteSelected() { items.deleteSelected() }
    func bringSelectedToFront() { items.bringSelectedToFront() }
}
