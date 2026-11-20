import Observation
import PencilKit
import SwiftUI
import UIKit

/// State of an open notebook.
@MainActor
@Observable
final class EditorModel {
    let library: Library
    var notebook: Notebook
    var pageIndex: Int
    var drawMode = true
    var tools = ToolSettings.load()
    var fingerDraws: Bool
    var ruler = false
    var selected: PageItem?
    var canUndo = false
    var canRedo = false
    /// The tool to go back to on a double tap of the Pencil while erasing.
    @ObservationIgnored private var toolBeforeEraser: Tool = .pen
    /// Bumped when a page's picture changes, so the page grid reloads it.
    var pageVersion: [UUID: Int] = [:]
    /// A short message shown over the page (link to a deleted page, nothing recorded there…).
    var notice: String?
    /// An area of the page being chosen by dragging (for a flashcard or to read handwriting).
    var picking: Picking?
    /// Handwriting read from an area, to copy or turn into typed text.
    var inkText: InkText?
    /// Presentation: only the page, fitted to the screen, with the laser at hand.
    var presenting = false
    @ObservationIgnored var toolBeforePresenting: Tool = .pen
    var snapShapes = true

    enum Picking: Equatable {
        case cardFront
        case cardBack(CGRect)
        case inkText
        case sticker

        var prompt: String {
            switch self {
            case .cardFront: String(localized: "Trascina un riquadro sulla domanda")
            case .cardBack: String(localized: "Ora trascina un riquadro sulla risposta")
            case .inkText: String(localized: "Trascina un riquadro sulla scrittura da leggere")
            case .sticker: String(localized: "Trascina un riquadro su quello che diventa un adesivo")
            }
        }
    }

    struct InkText: Identifiable {
        let id = UUID()
        let area: CGRect
        /// nil while it is being read.
        var text: String?
        /// Lines of handwriting found, to size the typed text.
        var lines = 1
    }

    /// The notebook is already open in another window: this editor only says so.
    let openElsewhere: Bool
    @ObservationIgnored private var released = false

    @ObservationIgnored let canvas = PageCanvasView()
    let audio: AudioNotes

    init(library: Library, notebook: Notebook, page: Int?) {
        self.library = library
        self.notebook = notebook
        self.pageIndex = min(max(0, page ?? notebook.lastPage), max(0, notebook.pages.count - 1))
        self.audio = AudioNotes(notebookID: notebook.id)
        let elsewhere = library.isOpen(notebook.id)
        openElsewhere = elsewhere
        if !elsewhere { library.opened(notebook.id) }
        if UserDefaults.standard.object(forKey: "fingerDraws") != nil {
            fingerDraws = UserDefaults.standard.bool(forKey: "fingerDraws")
        } else {
            fingerDraws = UIDevice.current.userInterfaceIdiom == .phone || !UIPencilInteraction.prefersPencilOnlyDrawing
        }
        canvas.fingerDraws = fingerDraws
        snapShapes = UserDefaults.standard.object(forKey: "snapShapes") as? Bool ?? true
        canvas.snapShapes = snapShapes
        canvas.onPick = { [weak self] r in self?.picked(r) }
        canvas.onSpellTap = { [weak self] i in
            guard let self, self.misses.indices.contains(i) else { return }
            self.missChosen = self.misses[i]
        }
        canvas.onSaved = { [weak self] pg in self?.pageSaved(pg) }
        canvas.onSelection = { [weak self] item in self?.selected = item }
        canvas.onUndoChange = { [weak self] in
            // PencilKit registers the undo step right after telling us about the change.
            DispatchQueue.main.async {
                guard let self else { return }
                self.canUndo = self.canvas.canUndo
                self.canRedo = self.canvas.canRedo
                if self.zoomOn { self.zoomPad.refresh() }
            }
        }
        setUpZoomPad()
        canvas.onSelectionChange = { [weak self] on in self?.hasSelection = on }
        canvas.onPull = { [weak self] direction in self?.pulled(direction) }
        canvas.onPencilTap = { [weak self] in self?.toggleEraser() }
        canvas.onSqueeze = { [weak self] s in self?.squeezed(s) }
        canvas.onLink = { [weak self] page in self?.follow(page) }
        canvas.onInkTap = { [weak self] date in self?.playFrom(date) }
        audio.onSaved = { [weak self] rec in self?.recordingSaved(rec) }
        audio.onListenChange = { [weak self] on in self?.canvas.listenMode = on }
        showPage()
        if tools.tool == .hand { tools.tool = .pen }
        applyTool()
        if !openElsewhere { startSharedSync() }
    }

    // MARK: Shared notebooks

    @ObservationIgnored private var shareTask: Task<Void, Never>?
    var isShared: Bool { SharedNotebooks.shared.isShared(notebook.id) }

    /// While a shared notebook is open: what was written is sent, and the others' changes come in,
    /// every few seconds.
    private func startSharedSync() {
        guard isShared else { return }
        shareTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncShared()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func syncShared() async {
        canvas.saveNow()
        let changed = await SharedNotebooks.shared.sync(notebook.id, library: library)
        guard changed, !released, let fresh = library.notebook(notebook.id) else { return }
        let current = page.id
        let keep = notebook.lastPage
        notebook = fresh
        notebook.lastPage = keep
        pageIndex = notebook.pages.firstIndex { $0.id == current } ?? min(pageIndex, max(0, notebook.pages.count - 1))
        canvas.refreshFromDisk(notebook, page)
        layerID = canvas.layerID
        for p in notebook.pages { pageVersion[p.id, default: 0] += 1 }
        notice = String(localized: "Sono arrivate modifiche da chi condivide il quaderno.")
    }

    func setSnapShapes(_ on: Bool) {
        snapShapes = on
        canvas.snapShapes = on
        UserDefaults.standard.set(on, forKey: "snapShapes")
    }

    var page: PageInfo { notebook.pages[pageIndex] }

    /// The layer being drawn on.
    var layerID: UUID?

    func showPage() {
        guard notebook.pages.indices.contains(pageIndex) else { return }
        if replaying { stopReplay() }
        if zoomOn { toggleZoom() }
        if picking != nil { endPicking() }
        misses = []
        canvas.load(notebook, page)
        layerID = canvas.layerID
        canvas.pullLabels = notebook.isBoard ? (nil, nil) :
            (pageIndex > 0 ? String(localized: "Pagina precedente") : nil,
             pageIndex + 1 < notebook.pages.count ? String(localized: "Pagina successiva") : String(localized: "Nuova pagina"))
        selected = nil
    }

    /// The page was pulled past its top (-1) or bottom (+1) and released.
    private func pulled(_ direction: Int) {
        if direction < 0 {
            guard pageIndex > 0 else { return }
            go(to: pageIndex - 1)
            canvas.scrollToBottom()
        } else {
            next()
        }
    }

    private func pageSaved(_ pg: PageInfo) {
        growBoardIfNeeded()
        library.save(notebook)
        if notebook.pages.first?.id == pg.id { library.refreshThumb(notebook.id) }
        pageVersion[pg.id, default: 0] += 1
        Indexer.shared.schedule(notebook, page: pg.id)
    }

    /// A whiteboard gets bigger when the writing comes near its right or bottom edge.
    private func growBoardIfNeeded() {
        guard notebook.isBoard, notebook.pages.indices.contains(pageIndex) else { return }
        let pg = notebook.pages[pageIndex]
        var content = canvas.canvas.drawing.bounds
        for it in canvas.items.items { content = content.union(it.frame) }
        guard !content.isNull, !content.isEmpty else { return }
        var w = pg.width, h = pg.height
        let edge: Double = 320, step: Double = 1000
        if Double(content.maxX) > w - edge { w = min(Notebook.boardMax, w + step) }
        if Double(content.maxY) > h - edge { h = min(Notebook.boardMax, h + step) }
        guard w != pg.width || h != pg.height else { return }
        notebook.pages[pageIndex].width = w
        notebook.pages[pageIndex].height = h
        canvas.resize(notebook.pages[pageIndex])
    }

    func close() {
        guard !openElsewhere else { return }
        if replaying { stopReplay() }
        shareTask?.cancel()
        if !released {
            released = true
            library.closed(notebook.id)
            if isShared {
                let lib = library, id = notebook.id
                Task { @MainActor in
                    // after the last save of the editor
                    try? await Task.sleep(for: .milliseconds(300))
                    _ = await SharedNotebooks.shared.sync(id, library: lib)
                }
            }
        }
        audio.stopAll()
        canvas.saveNow()
        notebook.lastPage = pageIndex
        library.save(notebook, touch: false)
    }

    func setDrawMode(_ on: Bool) {
        drawMode = on
        canvas.drawMode = on
        if on { selected = nil }
    }

    // MARK: Tools

    var tool: Tool { tools.tool }

    func color(of t: Tool) -> String { tools.colors[t.rawValue] ?? t.presets.first ?? "1C1C20" }
    func widthIndex(of t: Tool) -> Int { min(tools.widths[t.rawValue] ?? 1, max(0, t.widths.count - 1)) }

    func select(_ t: Tool) {
        if t != tools.tool { previousTool = tools.tool }
        if t == .eraser, tools.tool != .eraser, tools.tool != .hand { toolBeforeEraser = tools.tool }
        tools.tool = t
        tools.save()
        applyTool()
    }

    /// Double tap on the Pencil: eraser, and back to the tool used before.
    func toggleEraser() {
        select(tool == .eraser ? toolBeforeEraser : .eraser)
    }

    /// Where the quick palette of the Apple Pencil Pro is open (nil = closed), in the page view.
    var palette: CGPoint?
    /// The size being changed (tool and place), shown in a small panel under its button.
    var widthPanel: WidthSlot?
    @ObservationIgnored private var previousTool: Tool = .pen

    private func squeezed(_ s: PageCanvasView.Squeeze) {
        switch s {
        case .eraser: toggleEraser()
        case .previous: select(previousTool)
        case .palette(let p): palette = palette == nil ? p : nil
        }
    }

    var shapeKind: ShapeKind { tools.shape ?? .line }

    func setShape(_ k: ShapeKind) {
        tools.shape = k
        tools.save()
        applyTool()
    }

    func setColor(_ hex: String) {
        guard tool.inks else { return }
        tools.colors[tool.rawValue] = hex
        tools.save()
        applyTool()
    }

    func setWidth(_ i: Int) {
        tools.widths[tool.rawValue] = i
        tools.save()
        applyTool()
    }

    /// The three sizes of a tool, with the ones changed by the person.
    func widths(of t: Tool) -> [CGFloat] { t.widths(custom: tools.customWidths?[t.rawValue]) }

    /// Puts another size in place `i` of a tool's three, and uses it.
    func setWidth(_ i: Int, of t: Tool, to w: CGFloat) {
        guard t.canChangeWidth(i), i < t.widths.count else { return }
        var list = widths(of: t).map(Double.init)
        list[i] = Double(min(max(w, t.widthRange.lowerBound), t.widthRange.upperBound))
        var all = tools.customWidths ?? [:]
        all[t.rawValue] = list
        tools.customWidths = all
        tools.widths[t.rawValue] = i
        tools.save()
        if t == tool { applyTool() }
    }

    /// Back to the standard three sizes of a tool.
    func resetWidths(_ t: Tool) {
        tools.customWidths?[t.rawValue] = nil
        tools.save()
        if t == tool { applyTool() }
    }

    /// The kind of ink of the pen or the pencil (nil for the other tools).
    func style(of t: Tool) -> PenStyle? {
        let options = PenStyle.options(for: t)
        guard !options.isEmpty else { return nil }
        if let raw = tools.styles?[t.rawValue], let s = PenStyle(rawValue: raw), options.contains(s) { return s }
        return PenStyle.standard(for: t)
    }

    func setStyle(_ s: PenStyle) {
        guard PenStyle.options(for: tool).contains(s) else { return }
        var all = tools.styles ?? [:]
        all[tool.rawValue] = s.rawValue
        tools.styles = all
        tools.save()
        applyTool()
    }

    private func applyTool() {
        defer { if zoomOn { zoomPad.syncTool() } }
        let t = tool
        canvas.laser = t == .laser
        canvas.lassoMode = t == .lasso
        if audio.listening { audio.listening = false }
        if t == .hand {
            canvas.pick = nil
            setDrawMode(false)
            return
        }
        if !drawMode { setDrawMode(true) }
        let sizes = widths(of: t)
        let w = sizes.isEmpty ? 0 : sizes[widthIndex(of: t)]
        let c = UIColor(hex: color(of: t))
        canvas.shape = t == .shape ? PageCanvasView.ShapeStyle(kind: shapeKind, color: c, width: w) : nil
        syncPick()
        switch t {
        case .pen, .pencil:
            let s = style(of: t) ?? .ballpoint
            canvas.setTool(PKInkingTool(s.inkType, color: c, width: w * s.widthFactor))
        case .highlighter: canvas.setTool(PKInkingTool(.marker, color: c, width: w))
        case .eraser: canvas.setTool(w == 0 ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: w))
        case .lasso: break
        case .shape, .tape, .hand, .laser: break
        }
    }

    /// What dragging a rectangle does now: choosing an area, laying tape, or nothing.
    func syncPick() {
        if picking != nil {
            canvas.pick = .area
        } else if tool == .tape {
            canvas.pick = .tape(color(of: .tape))
        } else {
            canvas.pick = nil
        }
    }

    // MARK: Spelling (state; the code is in EditorModel+Study.swift)
    /// Handwritten words the dictionary does not know, marked on the page.
    var misses: [SpellCheck.Miss] = []
    var checkingSpelling = false
    /// The marked word tapped, to choose a correction.
    var missChosen: SpellCheck.Miss?

    // MARK: Lasso selection (state; the code is in EditorModel+Writing.swift)
    /// Something is chosen with the lasso.
    var hasSelection = false

    // MARK: Zoom window (state; the code is in EditorModel+Writing.swift)
    /// The zoom window is open.
    var zoomOn = false
    /// Where the zoom window writes on the page, in page points.
    var zoomBox = CGRect(x: 70, y: 100, width: 200, height: 70)
    var zoomLevel = CGFloat(UserDefaults.standard.object(forKey: "zoomLevel") as? Double ?? 2.5)
    @ObservationIgnored let zoomPad = ZoomPadView()

    // MARK: Lesson replay (state; the code is in EditorModel+Pages.swift)
    /// The writing of the page comes back stroke by stroke while the recording plays, as it was
    /// written during the lesson.
    var replaying = false
    @ObservationIgnored var replayTask: Task<Void, Never>?
}
