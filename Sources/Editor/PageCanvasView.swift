import PencilKit
import UIKit

/// The page being edited: a zoomable PencilKit canvas with the paper drawn behind the ink and the
/// text boxes and pictures in a layer above it.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let canvas = LinkAwareCanvas()
    let paper = UIImageView()
    /// The ink of the other layers, drawn as pictures under and over the layer being edited.
    let belowInk = UIImageView()
    let aboveInk = UIImageView()
    var layerScale: CGFloat = 0
    /// The layer whose ink is on the canvas.
    var layerID: UUID?
    /// When the files of the page were last read or written, to notice changes made by others.
    var stamps: [Date?] = []
    /// The ink and the boxes as they were last read or saved: what came from disk since then is
    /// put together with what was written here and not saved yet.
    var inkBase: [PKStroke] = []
    var itemsBase: [PageItem] = []
    let items = ItemsLayer()
    /// The link buttons of the boxes, above everything and usable with any tool.
    let links = LinkLayer()

    var notebook: Notebook?
    var page: PageInfo?
    var paperScale: CGFloat = 0
    var fittedWidth: CGFloat = 0
    var saveTask: Task<Void, Never>?
    var dirty = false
    /// True while a page is being loaded, so putting its ink on the canvas does not count as an edit.
    var loading = false

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
    let shapeLayer = CAShapeLayer()
    var shapeStart = CGPoint.zero

    /// The laser pointer: a glowing trail that fades by itself and is never saved.
    var laser = false {
        didSet { applyMode() }
    }
    let laserPan = UIPanGestureRecognizer()
    let laserGlow = CAShapeLayer()
    let laserCore = CAShapeLayer()
    var laserPoints: [(p: CGPoint, t: CFTimeInterval, start: Bool)] = []
    var laserLink: CADisplayLink?

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
    let pickLayer = CAShapeLayer()
    /// An area already chosen (the question of a flashcard), shown while choosing the next one.
    let markLayer = CAShapeLayer()
    var pickStart = CGPoint.zero
    private let tapeTap = UITapGestureRecognizer()

    /// Words marked by the spelling check, with a red wavy line; a tap on one asks what to do.
    let spellLayer = CAShapeLayer()
    var spellRects: [CGRect] = []
    let spellTap = UITapGestureRecognizer()
    var onSpellTap: ((Int) -> Void)?

    /// Draw a shape by hand and keep the pen still at the end: it becomes a clean shape.
    var snapShapes = true
    var inkPoints: [CGPoint] = []
    var holdAnchor = CGPoint.zero
    var holdWork: DispatchWorkItem?
    var snapOutline: [CGPoint]?
    var pendingSnap: [CGPoint]?

    /// Under a hovering Apple Pencil: what the tip is about to leave.
    let hoverMark = HoverPreview()
    private let hoverGesture = UIHoverGestureRecognizer()

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

        for v in [belowInk, aboveInk] {
            v.layer.anchorPoint = .zero
            v.isUserInteractionEnabled = false
            v.contentMode = .scaleToFill
            canvas.addSubview(v)
        }

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
            if self.spellIndex(at: self.canvas.convert(p, to: self.items)) != nil { return true }
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

        spellLayer.fillColor = nil
        spellLayer.strokeColor = UIColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 0.9).cgColor
        spellLayer.lineWidth = 1.4
        spellLayer.lineCap = .round
        spellLayer.zPosition = 13
        items.layer.addSublayer(spellLayer)
        spellTap.addTarget(self, action: #selector(spellTapped))
        spellTap.delegate = self
        spellTap.isEnabled = false
        canvas.addGestureRecognizer(spellTap)

        tapeTap.addTarget(self, action: #selector(tapeTapped))
        tapeTap.delegate = self
        canvas.addGestureRecognizer(tapeTap)

        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(inkGesture))
        setUpLasso()

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

        addSubview(hoverMark)
        hoverGesture.addTarget(self, action: #selector(hovered))
        addGestureRecognizer(hoverGesture)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyMode() }
    }

    // MARK: Layout and zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        hoverMark.frame = bounds
        // While the iPhone Duo folds or a window resizes the view can be momentarily very narrow:
        // a zoom of zero or less would put NaN in the layer positions and end the app.
        guard let pg = page, bounds.width > 40, bounds.height > 40, pg.size.width > 0, pg.size.height > 0 else { return }
        let margin: CGFloat = fitWhole ? 8 : (bounds.width > 600 ? 28 : 10)
        var fit = (bounds.width - margin * 2) / pg.size.width
        let whole = min(fit, (bounds.height - margin * 2) / pg.size.height)
        if fitWhole { fit = whole }
        guard fit.isFinite, fit > 0, whole.isFinite, whole > 0 else { return }
        let board = notebook?.isBoard == true
        let refit = fittedWidth != bounds.width || (fitWhole && fittedHeight != bounds.height)
        if refit {
            fittedWidth = bounds.width
            fittedHeight = bounds.height
            // a whiteboard opens at about 900 points across, and zooms out until it is all in view
            let start = board && !fitWhole ? max(whole, bounds.width / 900) : fit
            canvas.minimumZoomScale = board ? min(start, whole) * 0.9 : fit * 0.6
            canvas.maximumZoomScale = start * 6
            canvas.zoomScale = start
        }
        updateContent()
        if refit {
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
        canvas.bringSubviewToFront(aboveInk)
        canvas.bringSubviewToFront(items)
        canvas.bringSubviewToFront(links)
        canvas.bringSubviewToFront(selectionHost)
        canvas.sendSubviewToBack(paper)
        canvas.insertSubview(belowInk, aboveSubview: paper)
        multiplyInk()
    }

    /// Ink is laid on the paper like on real paper: multiplied, so a highlighter tints the white
    /// but the black text of a PDF stays black under it instead of being covered. On dark paper
    /// multiplying would hide the ink, so it is laid on as it is.
    private func multiplyInk() {
        let filter: String? = darkPaper ? nil : "multiplyBlendMode"
        for v in canvas.subviews where v !== paper && v !== items && v !== links && v !== selectionHost {
            if (v.layer.compositingFilter as? String) != filter { v.layer.compositingFilter = filter }
        }
    }

    /// The page is on dark paper: PencilKit shows the ink in its dark-mode colours.
    var darkPaper: Bool {
        guard let nb = notebook, let pg = page else { return false }
        return PageRenderer.isDark(nb, pg)
    }

    func applyPaperStyle() {
        let dark = darkPaper
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        if canvas.overrideUserInterfaceStyle != style { canvas.overrideUserInterfaceStyle = style }
        items.dark = dark
        multiplyInk()
    }

    func updateContent() {
        guard let pg = page else { return }
        let z = canvas.zoomScale
        guard z.isFinite, z > 0 else { return }
        let size = CGSize(width: pg.size.width * z, height: pg.size.height * z)
        canvas.contentSize = size
        let t = CGAffineTransform(scaleX: z, y: z)
        paper.transform = t
        paper.layer.position = .zero
        for v in [belowInk, aboveInk] {
            v.transform = t
            v.layer.position = .zero
        }
        items.transform = t
        items.layer.position = .zero
        links.transform = t
        links.layer.position = .zero
        selectionHost.transform = t
        selectionHost.layer.position = .zero
        selectionHost.setZoom(z)
        links.update(items.items, zoom: z)
        let dx = max(0, (bounds.width - size.width) / 2)
        let dy = max(12, (bounds.height - size.height) / 2)
        canvas.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: max(64, dy), right: dx)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderPaper()
        renderLayers(force: false)
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

    func applyMode() {
        let free = drawMode && !listenMode && pick == nil && replayFull == nil
        canvas.drawingGestureRecognizer.isEnabled = free && shape == nil && !laser && !lassoMode
        lassoPan.isEnabled = free && lassoMode
        lassoTap.isEnabled = free && lassoMode
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

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            // a trackpad pointer hovers at height zero: only the Pencil gets the mark
            guard g.zOffset > 0, HoverPreview.wanted, let look = hoverLook else { hoverMark.hide(); return }
            hoverMark.show(look, at: g.location(in: self))
        default:
            hoverMark.hide()
        }
    }

    /// What the tip would leave with the tool in use; nil when it would leave nothing.
    private var hoverLook: HoverPreview.Look? {
        let free = drawMode && !listenMode && pick == nil && replayFull == nil
        guard free, !laser, !lassoMode else { return nil }
        if let s = shape { return HoverPreview.look(shapeWidth: s.width, color: s.color, zoom: canvas.zoomScale) }
        return HoverPreview.look(for: canvas.tool, zoom: canvas.zoomScale, darkPaper: darkPaper)
    }

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

    /// What a squeeze of the Apple Pencil Pro asks for, as set in the iPad's settings.
    enum Squeeze {
        case palette(CGPoint)
        case eraser
        case previous
    }

    /// Called when the Apple Pencil Pro is squeezed.
    var onSqueeze: ((Squeeze) -> Void)?

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore: return
        case .switchEraser: onSqueeze?(.eraser)
        case .switchPrevious: onSqueeze?(.previous)
        default:
            // the palette opens next to the tip of the Pencil, or in the middle when it is too far
            let p = squeeze.hoverPose?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
            onSqueeze?(.palette(p))
        }
    }

    // MARK: Shapes

    /// Shapes follow the same rule as ink: with "write with finger" off only the Pencil draws them.
    private func updateShapeTouches() {
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if fingerDraws { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        shapePan.allowedTouchTypes = types
        lassoPan.allowedTouchTypes = types
        // choosing an area works with any finger; tape is drawn like ink
        if case .tape = pick {
            pickPan.allowedTouchTypes = types
        } else {
            pickPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }

    /// The page must not scroll while a shape is being drawn or the laser is moving.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        (g === shapePan || g === laserPan || g === pickPan || g === lassoPan) && other === canvas.panGestureRecognizer
    }

    /// A tap on tape works together with the other gestures of the page.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === tapeTap || g === spellTap
    }

    /// Shapes and the laser do not start on a link button.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === lassoPan {
            // a drag on the chosen things moves them instead of drawing a new lasso
            if hasSelection, selectionHost.box.frame.insetBy(dx: -12, dy: -12).contains(g.location(in: selectionHost)) { return false }
            return links.button(at: g.location(in: links)) == nil
        }
        if g === shapePan || g === laserPan || g === pickPan {
            return links.button(at: g.location(in: links)) == nil
        }
        if g === spellTap {
            return spellIndex(at: g.location(in: items)) != nil
        }
        if g === tapeTap {
            guard let t = items.tape(at: g.location(in: items)) else { return false }
            // with the tape tool any tape opens and closes; otherwise only covered tape opens
            if case .tape = pick { return true }
            return t.isCovered
        }
        return super.gestureRecognizerShouldBegin(g)
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

    func undo() { clearSelection(); canvas.undoManager?.undo(); onUndoChange?() }
    func redo() { clearSelection(); canvas.undoManager?.redo(); onUndoChange?() }
    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func clearInk() {
        setDrawingUndoable(PKDrawing())
    }

    // MARK: Lasso selection (state; the code is in PageCanvasView+Selection.swift)
    /// The lasso: drawing round strokes and boxes chooses them; then they can be moved, made
    /// bigger or smaller, turned, recoloured, copied, duplicated or deleted.
    var lassoMode = false {
        didSet {
            guard lassoMode != oldValue else { return }
            if !lassoMode { clearSelection() }
            applyMode()
        }
    }
    let selectionHost = SelectionHost()
    let lassoPan = UIPanGestureRecognizer()
    let lassoTap = UITapGestureRecognizer()
    let lassoLayer = CAShapeLayer()
    var lassoPoints: [CGPoint] = []
    /// Indices of the chosen strokes in the canvas's drawing, and the chosen boxes.
    var selStrokes: [Int] = []
    var selItems: Set<UUID> = []
    var selOriginal: PKDrawing?
    var selFrame = CGRect.zero
    /// Called when something gets chosen or nothing is chosen any more.
    var onSelectionChange: ((Bool) -> Void)?

    // MARK: Zoom window (state; the code is in PageCanvasView+Areas.swift)
    let zoomBoxLayer = CAShapeLayer()
    let zoomTap = UITapGestureRecognizer()
    /// A tap with the finger on the page while the zoom window is open, in page points.
    var onZoomTap: ((CGPoint) -> Void)?

    // MARK: Lesson replay (state; the code is in PageCanvasView+Loading.swift)
    var replayFull: PKDrawing?
    var replayShown = -1
}
