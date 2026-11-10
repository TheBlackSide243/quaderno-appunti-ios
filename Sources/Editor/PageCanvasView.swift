import PencilKit
import UIKit

/// The page being edited: a zoomable PencilKit canvas with the paper drawn behind the ink and the
/// text boxes and pictures in a layer above it.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let canvas = PKCanvasView()
    private let paper = UIImageView()
    let items = ItemsLayer()

    private(set) var notebook: Notebook?
    private(set) var page: PageInfo?
    private var paperScale: CGFloat = 0
    private var fittedWidth: CGFloat = 0
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    /// True while a page is being loaded, so putting its ink on the canvas does not count as an edit.
    private var loading = false

    /// Called after the page's ink or boxes were written to disk.
    var onSaved: ((PageInfo) -> Void)?
    /// Called when the selected box changes.
    var onSelection: ((PageItem?) -> Void)?
    /// Called when the undo state may have changed.
    var onUndoChange: (() -> Void)?
    /// Called when the page was pulled past its top (-1) or bottom (+1) and released.
    var onPull: ((Int) -> Void)?
    /// Called on a double tap on the side of the Apple Pencil.
    var onPencilTap: (() -> Void)?

    /// What pulling past the top and the bottom of the page does; nil = nothing there.
    var pullLabels: (previous: String?, next: String?) = (nil, nil)
    private let pullHint = PaddedLabel()
    private let pullThreshold: CGFloat = 84

    var drawMode = true {
        didSet { applyMode() }
    }

    /// The shape tool: when set, dragging draws this shape instead of free ink.
    struct ShapeStyle {
        var kind: ShapeKind
        var color: UIColor
        var width: CGFloat
    }

    var shape: ShapeStyle? {
        didSet { applyMode() }
    }

    private let shapePan = UIPanGestureRecognizer()
    private let shapeLayer = CAShapeLayer()
    private var shapeStart = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.desk)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .default
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.bouncesZoom = true
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        addSubview(canvas)

        paper.contentMode = .scaleToFill
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.35
        paper.layer.shadowRadius = 10
        paper.layer.shadowOffset = CGSize(width: 0, height: 3)
        paper.layer.anchorPoint = .zero
        canvas.insertSubview(paper, at: 0)

        items.layer.anchorPoint = .zero
        items.onChange = { [weak self] in self?.itemsChanged() }
        items.onSelection = { [weak self] item in self?.onSelection?(item) }
        canvas.addSubview(items)

        shapeLayer.fillColor = nil
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.zPosition = 10
        items.layer.addSublayer(shapeLayer)

        shapePan.addTarget(self, action: #selector(shapeDragged))
        shapePan.maximumNumberOfTouches = 1
        shapePan.delegate = self
        shapePan.isEnabled = false
        canvas.addGestureRecognizer(shapePan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedEmpty))
        tap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(tap)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        pullHint.font = .systemFont(ofSize: 13, weight: .semibold)
        pullHint.textColor = UIColor(Theme.bg)
        pullHint.backgroundColor = UIColor(Theme.accent)
        pullHint.layer.cornerRadius = 15
        pullHint.layer.masksToBounds = true
        pullHint.alpha = 0
        pullHint.isUserInteractionEnabled = false
        addSubview(pullHint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyMode() }
    }

    // MARK: Loading and saving

    func load(_ nb: Notebook, _ pg: PageInfo) {
        if let page, page.id == pg.id, notebook?.id == nb.id {
            notebook = nb
            self.page = pg
            if paper.image == nil || paperScale == 0 { renderPaper() }
            return
        }
        saveNow()
        if notebook != nil {
            // a short fade between pages
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            layer.add(fade, forKey: "page")
        }
        notebook = nb
        page = pg
        // stop a bounce still running from the pull that turned the page
        canvas.setContentOffset(canvas.contentOffset, animated: false)
        loading = true
        canvas.drawing = Store.loadDrawing(nb.id, pg.id)
        loading = false
        canvas.undoManager?.removeAllActions()
        paper.bounds = CGRect(origin: .zero, size: pg.size)
        items.bounds = CGRect(origin: .zero, size: pg.size)
        items.load(nb, Store.loadItems(nb.id, pg.id))
        shapeLayer.path = nil
        paperScale = 0
        fittedWidth = 0
        setNeedsLayout()
        layoutIfNeeded()
        renderPaper()
        onUndoChange?()
    }

    /// Redraws the paper (after the template changed).
    func reloadPaper(_ nb: Notebook, _ pg: PageInfo) {
        notebook = nb
        page = pg
        paperScale = 0
        renderPaper()
    }

    private func renderPaper() {
        guard let nb = notebook, let pg = page else { return }
        // Sharp enough for the current zoom, capped at ~24 Mpx.
        let screen = window?.screen.scale ?? 2
        let maxScale = sqrt(24_000_000 / (pg.size.width * pg.size.height))
        let want = min(maxScale, max(2, canvas.zoomScale * screen))
        guard want > paperScale * 1.15 || paperScale == 0 else { return }
        paperScale = want
        paper.image = PageRenderer.background(nb, pg, scale: want)
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty, let nb = notebook, let pg = page else { return }
        dirty = false
        Store.saveDrawing(canvas.drawing, nb.id, pg.id)
        Store.saveItems(items.items, nb.id, pg.id)
        onSaved?(pg)
    }

    private func itemsChanged() { scheduleSave() }

    // MARK: Layout and zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        guard let pg = page, bounds.width > 0 else { return }
        let margin: CGFloat = bounds.width > 600 ? 28 : 10
        let fit = (bounds.width - margin * 2) / pg.size.width
        let refit = fittedWidth != bounds.width
        if refit {
            fittedWidth = bounds.width
            canvas.minimumZoomScale = fit * 0.6
            canvas.maximumZoomScale = fit * 6
            canvas.zoomScale = fit
        }
        updateContent()
        if refit {
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
        canvas.bringSubviewToFront(items)
        canvas.sendSubviewToBack(paper)
        multiplyInk()
    }

    /// Ink is laid on the paper like on real paper: multiplied, so a highlighter tints the white
    /// but the black text of a PDF stays black under it instead of being covered.
    private func multiplyInk() {
        for v in canvas.subviews where v !== paper && v !== items && v.layer.compositingFilter == nil {
            v.layer.compositingFilter = "multiplyBlendMode"
        }
    }

    private func updateContent() {
        guard let pg = page else { return }
        let z = canvas.zoomScale
        let size = CGSize(width: pg.size.width * z, height: pg.size.height * z)
        canvas.contentSize = size
        let t = CGAffineTransform(scaleX: z, y: z)
        paper.transform = t
        paper.layer.position = .zero
        items.transform = t
        items.layer.position = .zero
        let dx = max(0, (bounds.width - size.width) / 2)
        let dy = max(12, (bounds.height - size.height) / 2)
        canvas.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: max(64, dy), right: dx)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderPaper()
    }

    /// Shows the end of the page (after going back to the previous page by pulling).
    func scrollToBottom() {
        layoutIfNeeded()
        let y = canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height
        canvas.contentOffset = CGPoint(x: canvas.contentOffset.x, y: max(-canvas.contentInset.top, y))
    }

    /// The point of the page at the middle of the screen.
    var visibleCenter: CGPoint {
        let z = canvas.zoomScale
        let c = CGPoint(x: canvas.contentOffset.x + canvas.bounds.width / 2, y: canvas.contentOffset.y + canvas.bounds.height / 2)
        guard let pg = page else { return CGPoint(x: c.x / z, y: c.y / z) }
        return CGPoint(x: min(max(40, c.x / z), pg.size.width - 40), y: min(max(40, c.y / z), pg.size.height - 40))
    }

    // MARK: Pull to turn the page

    /// How far the page is pulled past its end: > 0 past the bottom, < 0 past the top.
    private func overscroll(_ s: UIScrollView) -> CGFloat {
        let top = -(s.contentOffset.y + s.contentInset.top)
        if top > 0 { return -top }
        return max(0, s.contentOffset.y + s.bounds.height - s.contentSize.height - s.contentInset.bottom)
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        guard s.isDragging, !s.isZooming, !s.isZoomBouncing else {
            if pullHint.alpha > 0 { pullHint.alpha = 0 }
            return
        }
        let o = overscroll(s)
        guard abs(o) > 18, let text = o < 0 ? pullLabels.previous : pullLabels.next else {
            if pullHint.alpha > 0 { pullHint.alpha = 0 }
            return
        }
        let ready = abs(o) >= pullThreshold
        pullHint.text = ready ? "Rilascia: \(text)" : text
        pullHint.sizeToFit()
        let size = pullHint.bounds.size
        let y = o < 0 ? 14 : bounds.height - safeAreaInsets.bottom - size.height - 14
        pullHint.frame = CGRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        pullHint.alpha = ready ? 1 : min(0.85, abs(o) / pullThreshold)
    }

    func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate decelerate: Bool) {
        pullHint.alpha = 0
        guard !s.isZooming, !s.isZoomBouncing else { return }
        let o = overscroll(s)
        guard abs(o) >= pullThreshold else { return }
        if o < 0, pullLabels.previous != nil {
            onPull?(-1)
        } else if o > 0, pullLabels.next != nil {
            onPull?(1)
        }
    }

    // MARK: Modes

    private func applyMode() {
        canvas.drawingGestureRecognizer.isEnabled = drawMode && shape == nil
        shapePan.isEnabled = drawMode && shape != nil
        updateShapeTouches()
        items.isUserInteractionEnabled = !drawMode
        if !drawMode { items.select(nil) }
        guard window != nil else { return }
        if drawMode { items.endEditing(true) }
    }

    /// The pen, marker, eraser or lasso chosen in the toolbar.
    func setTool(_ tool: PKTool) { canvas.tool = tool }

    /// With false, only the Apple Pencil draws and fingers scroll the page.
    var fingerDraws: Bool {
        get { canvas.drawingPolicy == .anyInput }
        set {
            canvas.drawingPolicy = newValue ? .anyInput : .pencilOnly
            updateShapeTouches()
        }
    }

    var rulerActive: Bool {
        get { canvas.isRulerActive }
        set { canvas.isRulerActive = newValue }
    }

    @objc private func tappedEmpty(_ g: UITapGestureRecognizer) {
        guard !drawMode else { return }
        let p = g.location(in: items)
        if items.item(at: p) == nil {
            items.endEditing(true)
            items.select(nil)
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        onPencilTap?()
    }

    // MARK: Shapes

    /// Shapes follow the same rule as ink: with "write with finger" off only the Pencil draws them.
    private func updateShapeTouches() {
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if fingerDraws { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        shapePan.allowedTouchTypes = types
    }

    /// The page must not scroll while a shape is being dragged.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === shapePan && other === canvas.panGestureRecognizer
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        guard let pg = page else { return p }
        return CGPoint(x: min(max(0, p.x), pg.size.width), y: min(max(0, p.y), pg.size.height))
    }

    @objc private func shapeDragged(_ g: UIPanGestureRecognizer) {
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

    private func setDrawingUndoable(_ new: PKDrawing) {
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setDrawingUndoable(old) }
        }
        canvas.drawing = new
        onUndoChange?()
    }

    // MARK: Canvas delegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading else { return }
        scheduleSave()
        onUndoChange?()
    }

    func undo() { canvas.undoManager?.undo(); onUndoChange?() }
    func redo() { canvas.undoManager?.redo(); onUndoChange?() }
    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func clearInk() {
        setDrawingUndoable(PKDrawing())
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

    func addImage(_ img: UIImage) {
        guard let nb = notebook, let pg = page, let (name, size) = Store.saveImage(img, nb.id) else { return }
        if drawMode { drawMode = false }
        let c = visibleCenter
        let w = min(pg.size.width * 0.6, size.width)
        let h = w * size.height / max(1, size.width)
        var item = PageItem(kind: .image, x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
        item.image = name
        items.add(item, edit: false)
    }

    func updateSelected(_ change: (inout PageItem) -> Void) { items.updateSelected(change) }
    func deleteSelected() { items.deleteSelected() }
    func bringSelectedToFront() { items.bringSelectedToFront() }
}

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
