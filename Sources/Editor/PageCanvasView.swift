import PencilKit
import UIKit

/// The page being edited: a zoomable PencilKit canvas with the paper drawn behind the ink and the
/// text boxes and pictures in a layer above it.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let canvas = LinkAwareCanvas()
    private let paper = UIImageView()
    let items = ItemsLayer()
    /// The link buttons of the boxes, above everything and usable with any tool.
    private let links = LinkLayer()

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
    /// Called when a link button is tapped, with the page it leads to.
    var onLink: ((UUID) -> Void)?
    /// Called on a tap while listening, with when the touched stroke was written (nil = no stroke there).
    var onInkTap: ((Date?) -> Void)?

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

    /// The laser pointer: a glowing trail that fades by itself and is never saved.
    var laser = false {
        didSet { applyMode() }
    }
    private let laserPan = UIPanGestureRecognizer()
    private let laserGlow = CAShapeLayer()
    private let laserCore = CAShapeLayer()
    private var laserPoints: [(p: CGPoint, t: CFTimeInterval, start: Bool)] = []
    private var laserLink: CADisplayLink?

    /// Listening to a recording: a tap on the writing plays what was said while it was written.
    var listenMode = false {
        didSet { applyMode() }
    }
    private let listenTap = UITapGestureRecognizer()

    /// Dragging a rectangle: a strip of study tape of that colour, or an area of the page for the
    /// caller (flashcards, reading the handwriting).
    enum Pick: Equatable {
        case tape(String)
        case area
    }

    var pick: Pick? {
        didSet {
            if pick != oldValue { pickLayer.path = nil }
            applyMode()
        }
    }
    /// Called with the area dragged in `.area` mode, in page points.
    var onPick: ((CGRect) -> Void)?
    private let pickPan = UIPanGestureRecognizer()
    private let pickLayer = CAShapeLayer()
    /// An area already chosen (the question of a flashcard), shown while choosing the next one.
    private let markLayer = CAShapeLayer()
    private var pickStart = CGPoint.zero
    private let tapeTap = UITapGestureRecognizer()

    /// Draw a shape by hand and keep the pen still at the end: it becomes a clean shape.
    var snapShapes = true
    private var inkPoints: [CGPoint] = []
    private var holdAnchor = CGPoint.zero
    private var holdWork: DispatchWorkItem?
    private var snapOutline: [CGPoint]?
    private var pendingSnap: [CGPoint]?

    /// While presenting: the whole page fits the screen.
    var fitWhole = false {
        didSet {
            guard fitWhole != oldValue else { return }
            fittedWidth = 0
            setNeedsLayout()
        }
    }
    private var fittedHeight: CGFloat = 0

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

        links.layer.anchorPoint = .zero
        links.onTap = { [weak self] page in self?.onLink?(page) }
        canvas.addSubview(links)
        canvas.blocksDrawing = { [weak self] p in
            guard let self else { return false }
            if self.links.button(at: self.canvas.convert(p, to: self.links)) != nil { return true }
            // a covered tape takes the touch, to be uncovered
            return self.items.tape(at: self.canvas.convert(p, to: self.items))?.isCovered == true
        }

        for l in [laserGlow, laserCore] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.zPosition = 11
            items.layer.addSublayer(l)
        }
        laserGlow.strokeColor = UIColor(red: 1, green: 0.18, blue: 0.12, alpha: 0.45).cgColor
        laserGlow.shadowColor = UIColor(red: 1, green: 0.1, blue: 0.05, alpha: 1).cgColor
        laserGlow.shadowOpacity = 0.9
        laserGlow.shadowRadius = 6
        laserGlow.shadowOffset = .zero
        laserCore.strokeColor = UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1).cgColor

        laserPan.addTarget(self, action: #selector(laserDragged))
        laserPan.maximumNumberOfTouches = 1
        laserPan.delegate = self
        laserPan.isEnabled = false
        canvas.addGestureRecognizer(laserPan)

        listenTap.addTarget(self, action: #selector(listenTapped))
        listenTap.isEnabled = false
        canvas.addGestureRecognizer(listenTap)

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

        for l in [pickLayer, markLayer] {
            l.lineJoin = .round
            l.zPosition = 12
            items.layer.addSublayer(l)
        }
        pickPan.addTarget(self, action: #selector(pickDragged))
        pickPan.maximumNumberOfTouches = 1
        pickPan.delegate = self
        pickPan.isEnabled = false
        canvas.addGestureRecognizer(pickPan)

        tapeTap.addTarget(self, action: #selector(tapeTapped))
        tapeTap.delegate = self
        canvas.addGestureRecognizer(tapeTap)

        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(inkGesture))

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
        links.bounds = CGRect(origin: .zero, size: pg.size)
        links.update(items.items, zoom: canvas.zoomScale)
        shapeLayer.path = nil
        pickLayer.path = nil
        markLayer.path = nil
        snapOutline = nil
        pendingSnap = nil
        laserPoints = []
        laserCore.path = nil
        laserGlow.path = nil
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
        let zoom = canvas.zoomScale.isFinite && canvas.zoomScale > 0 ? canvas.zoomScale : 1
        let want = min(maxScale, max(2, zoom * screen))
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

    private func itemsChanged() {
        links.update(items.items, zoom: canvas.zoomScale)
        scheduleSave()
    }

    // MARK: Layout and zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        // While the iPhone Duo folds or a window resizes the view can be momentarily very narrow:
        // a zoom of zero or less would put NaN in the layer positions and end the app.
        guard let pg = page, bounds.width > 40, bounds.height > 40, pg.size.width > 0, pg.size.height > 0 else { return }
        let margin: CGFloat = fitWhole ? 8 : (bounds.width > 600 ? 28 : 10)
        var fit = (bounds.width - margin * 2) / pg.size.width
        if fitWhole { fit = min(fit, (bounds.height - margin * 2) / pg.size.height) }
        guard fit.isFinite, fit > 0 else { return }
        let refit = fittedWidth != bounds.width || (fitWhole && fittedHeight != bounds.height)
        if refit {
            fittedWidth = bounds.width
            fittedHeight = bounds.height
            canvas.minimumZoomScale = fit * 0.6
            canvas.maximumZoomScale = fit * 6
            canvas.zoomScale = fit
        }
        updateContent()
        if refit {
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
        canvas.bringSubviewToFront(items)
        canvas.bringSubviewToFront(links)
        canvas.sendSubviewToBack(paper)
        multiplyInk()
    }

    /// Ink is laid on the paper like on real paper: multiplied, so a highlighter tints the white
    /// but the black text of a PDF stays black under it instead of being covered.
    private func multiplyInk() {
        for v in canvas.subviews where v !== paper && v !== items && v !== links && v.layer.compositingFilter == nil {
            v.layer.compositingFilter = "multiplyBlendMode"
        }
    }

    private func updateContent() {
        guard let pg = page else { return }
        let z = canvas.zoomScale
        guard z.isFinite, z > 0 else { return }
        let size = CGSize(width: pg.size.width * z, height: pg.size.height * z)
        canvas.contentSize = size
        let t = CGAffineTransform(scaleX: z, y: z)
        paper.transform = t
        paper.layer.position = .zero
        items.transform = t
        items.layer.position = .zero
        links.transform = t
        links.layer.position = .zero
        links.update(items.items, zoom: z)
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
        let z = canvas.zoomScale > 0 && canvas.zoomScale.isFinite ? canvas.zoomScale : 1
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
        pullHint.text = ready ? String(localized: "Rilascia: \(text)") : text
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
        let free = drawMode && !listenMode && pick == nil
        canvas.drawingGestureRecognizer.isEnabled = free && shape == nil && !laser
        shapePan.isEnabled = free && shape != nil && !laser
        laserPan.isEnabled = free && laser
        pickPan.isEnabled = drawMode && !listenMode && pick != nil
        tapeTap.isEnabled = drawMode && !listenMode
        listenTap.isEnabled = listenMode
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
        // choosing an area works with any finger; tape is drawn like ink
        if case .tape = pick {
            pickPan.allowedTouchTypes = types
        } else {
            pickPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }

    /// The page must not scroll while a shape is being drawn or the laser is moving.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        (g === shapePan || g === laserPan || g === pickPan) && other === canvas.panGestureRecognizer
    }

    /// A tap on tape works together with the other gestures of the page.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === tapeTap
    }

    /// Shapes and the laser do not start on a link button.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === shapePan || g === laserPan || g === pickPan {
            return links.button(at: g.location(in: links)) == nil
        }
        if g === tapeTap {
            guard let t = items.tape(at: g.location(in: items)) else { return false }
            // with the tape tool any tape opens and closes; otherwise only covered tape opens
            if case .tape = pick { return true }
            return t.isCovered
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    // MARK: Laser

    @objc private func laserDragged(_ g: UIPanGestureRecognizer) {
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

    @objc private func listenTapped(_ g: UITapGestureRecognizer) {
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
        if let outline = pendingSnap {
            pendingSnap = nil
            // not inside PencilKit's own change: replace the stroke right after
            DispatchQueue.main.async { [weak self] in self?.snapLastStroke(to: outline) }
        }
    }

    func undo() { canvas.undoManager?.undo(); onUndoChange?() }
    func redo() { canvas.undoManager?.redo(); onUndoChange?() }
    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func clearInk() {
        setDrawingUndoable(PKDrawing())
    }

    // MARK: Tape and areas

    @objc private func pickDragged(_ g: UIPanGestureRecognizer) {
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

    @objc private func tapeTapped(_ g: UITapGestureRecognizer) {
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

    /// A text box over an area, for typed text that replaces handwriting.
    func addTextBox(_ text: String, in r: CGRect, fontSize: Double) {
        var item = PageItem(kind: .text, x: r.minX, y: r.minY, w: max(60, r.width), h: max(30, r.height))
        item.text = text
        item.fontSize = fontSize
        items.add(item, edit: false, select: false)
    }

    // MARK: Shapes drawn by hand

    @objc private func inkGesture(_ g: UIGestureRecognizer) {
        guard snapShapes, let tool = canvas.tool as? PKInkingTool else { return }
        let p = g.location(in: items)
        let screen = g.location(in: self)
        switch g.state {
        case .began:
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
    private func snapLastStroke(to outline: [CGPoint]) {
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
