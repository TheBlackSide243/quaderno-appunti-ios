import PencilKit
import UIKit

/// The page being edited: a zoomable PencilKit canvas with the paper drawn behind the ink and the
/// text boxes and pictures in a layer above it.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate {
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

    var drawMode = true {
        didSet { applyMode() }
    }

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedEmpty))
        tap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(tap)

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
        notebook = nb
        page = pg
        loading = true
        canvas.drawing = Store.loadDrawing(nb.id, pg.id)
        loading = false
        canvas.undoManager?.removeAllActions()
        paper.bounds = CGRect(origin: .zero, size: pg.size)
        items.bounds = CGRect(origin: .zero, size: pg.size)
        items.load(nb, Store.loadItems(nb.id, pg.id))
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
        if fittedWidth != bounds.width {
            fittedWidth = bounds.width
            canvas.minimumZoomScale = fit * 0.6
            canvas.maximumZoomScale = fit * 6
            canvas.zoomScale = fit
            canvas.contentOffset = .zero
        }
        updateContent()
        canvas.bringSubviewToFront(items)
        canvas.sendSubviewToBack(paper)
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
        canvas.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: max(24, dy), right: dx)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderPaper()
    }

    /// The point of the page at the middle of the screen.
    var visibleCenter: CGPoint {
        let z = canvas.zoomScale
        let c = CGPoint(x: canvas.contentOffset.x + canvas.bounds.width / 2, y: canvas.contentOffset.y + canvas.bounds.height / 2)
        return CGPoint(x: c.x / z, y: c.y / z)
    }

    // MARK: Modes

    private func applyMode() {
        canvas.drawingGestureRecognizer.isEnabled = drawMode
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
        set { canvas.drawingPolicy = newValue ? .anyInput : .pencilOnly }
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
        canvas.drawing = PKDrawing()
        scheduleSave()
    }

    // MARK: Boxes

    func addText() {
        if drawMode { drawMode = false }
        let c = visibleCenter
        let w = min(320, (page?.size.width ?? 595) * 0.6)
        let item = PageItem(kind: .text, x: c.x - w / 2, y: c.y - 30, w: w, h: 60)
        items.add(item, edit: true)
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
