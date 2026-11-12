import Observation
import PencilKit
import SwiftUI
import UIKit

/// The tools of the editor toolbar.
enum Tool: String, CaseIterable, Codable, Identifiable {
    case pen, pencil, highlighter, eraser, shape, lasso, tape, hand, laser
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: String(localized: "Penna")
        case .pencil: String(localized: "Matita")
        case .highlighter: String(localized: "Evidenziatore")
        case .eraser: String(localized: "Gomma")
        case .shape: String(localized: "Forme")
        case .lasso: String(localized: "Lazo")
        case .tape: String(localized: "Nastro adesivo")
        case .hand: String(localized: "Sposta testi e foto")
        case .laser: String(localized: "Puntatore laser")
        }
    }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .shape: "square.on.circle"
        case .lasso: "lasso"
        case .tape: "bandage"
        case .hand: "hand.point.up.left"
        case .laser: "cursorarrow.rays"
        }
    }

    /// The three thicknesses offered (for the eraser: whole stroke, small, large).
    var widths: [CGFloat] {
        switch self {
        case .pen: [1.5, 3, 6]
        case .pencil: [2.5, 4.5, 8]
        case .highlighter: [12, 20, 30]
        case .eraser: [0, 10, 30]
        case .shape: [1.5, 3, 5]
        case .lasso, .tape, .hand, .laser: []
        }
    }

    /// The three colours always at hand.
    var presets: [String] {
        switch self {
        case .pen, .shape: ["1C1C20", "1D4ED8", "DC2626"]
        case .pencil: ["3F3F46", "1D4ED8", "B91C1C"]
        case .highlighter: ["FDE047", "86EFAC", "F9A8D4"]
        case .tape: Array(TapeColors.all.prefix(3))
        default: []
        }
    }

    var inks: Bool { !presets.isEmpty }
}

/// What the toolbar remembers between notebooks.
struct ToolSettings: Codable {
    var tool: Tool = .pen
    var colors: [String: String] = [:]
    var widths: [String: Int] = [:]
    /// The shape drawn by the shape tool (optional so settings saved by older versions still load).
    var shape: ShapeKind?

    static let key = "toolSettings"

    static func load() -> ToolSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(ToolSettings.self, from: d) else { return ToolSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

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
    @ObservationIgnored private var toolBeforePresenting: Tool = .pen
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
            }
        }
        canvas.onPull = { [weak self] direction in self?.pulled(direction) }
        canvas.onPencilTap = { [weak self] in self?.toggleEraser() }
        canvas.onLink = { [weak self] page in self?.follow(page) }
        canvas.onInkTap = { [weak self] date in self?.playFrom(date) }
        audio.onSaved = { [weak self] rec in self?.recordingSaved(rec) }
        audio.onListenChange = { [weak self] on in self?.canvas.listenMode = on }
        showPage()
        if tools.tool == .hand { tools.tool = .pen }
        applyTool()
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
        if !released {
            released = true
            library.closed(notebook.id)
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
        if t == .eraser, tools.tool != .eraser, tools.tool != .hand { toolBeforeEraser = tools.tool }
        tools.tool = t
        tools.save()
        applyTool()
    }

    /// Double tap on the Pencil: eraser, and back to the tool used before.
    func toggleEraser() {
        select(tool == .eraser ? toolBeforeEraser : .eraser)
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

    private func applyTool() {
        let t = tool
        canvas.laser = t == .laser
        if audio.listening { audio.listening = false }
        if t == .hand {
            canvas.pick = nil
            setDrawMode(false)
            return
        }
        if !drawMode { setDrawMode(true) }
        let w = t.widths.isEmpty ? 0 : t.widths[widthIndex(of: t)]
        let c = UIColor(hex: color(of: t))
        canvas.shape = t == .shape ? PageCanvasView.ShapeStyle(kind: shapeKind, color: c, width: w) : nil
        syncPick()
        switch t {
        case .pen: canvas.setTool(PKInkingTool(.pen, color: c, width: w))
        case .pencil: canvas.setTool(PKInkingTool(.pencil, color: c, width: w))
        case .highlighter: canvas.setTool(PKInkingTool(.marker, color: c, width: w))
        case .eraser: canvas.setTool(w == 0 ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: w))
        case .lasso: canvas.setTool(PKLassoTool())
        case .shape, .tape, .hand, .laser: break
        }
    }

    /// What dragging a rectangle does now: choosing an area, laying tape, or nothing.
    private func syncPick() {
        if picking != nil {
            canvas.pick = .area
        } else if tool == .tape {
            canvas.pick = .tape(color(of: .tape))
        } else {
            canvas.pick = nil
        }
    }

    // MARK: Choosing an area

    func startPicking(_ p: Picking) {
        if !drawMode { setDrawMode(true) }
        picking = p
        canvas.mark(nil)
        syncPick()
    }

    func endPicking() {
        picking = nil
        canvas.mark(nil)
        syncPick()
    }

    private func picked(_ r: CGRect) {
        switch picking {
        case .cardFront:
            picking = .cardBack(r)
            canvas.mark(r)
        case .cardBack(let front):
            endPicking()
            var list = notebook.cards ?? []
            list.append(Flashcard(page: page.id, front: front, back: r))
            notebook.cards = list
            canvas.saveNow()
            library.save(notebook)
            notice = String(localized: "Flashcard creata: \(list.count) in questo quaderno.")
        case .inkText:
            endPicking()
            readInk(in: r)
        case .sticker:
            endPicking()
            if let img = canvas.cutout(r) {
                StickerStore.shared.add(img)
                notice = String(localized: "Adesivo salvato: lo trovi tra gli adesivi.")
            } else {
                notice = String(localized: "In quel riquadro non c'è niente.")
            }
        case nil:
            break
        }
    }

    // MARK: Spelling

    /// Handwritten words the dictionary does not know, marked on the page.
    var misses: [SpellCheck.Miss] = []
    var checkingSpelling = false
    /// The marked word tapped, to choose a correction.
    var missChosen: SpellCheck.Miss?

    func checkSpelling() async {
        guard !checkingSpelling else { return }
        canvas.saveNow()
        checkingSpelling = true
        let pageID = page.id
        let words = await Indexer.shared.words(canvas.canvas.drawing)
        checkingSpelling = false
        guard page.id == pageID else { return }
        misses = SpellCheck.misses(words)
        canvas.showMisspelled(misses.map(\.rect))
        if misses.isEmpty { notice = String(localized: "Nessun errore trovato nella scrittura di questa pagina.") }
    }

    /// Writes the correction as typed text in place of the handwritten word.
    func fix(_ m: SpellCheck.Miss, with word: String) {
        canvas.removeStrokes(in: m.rect.insetBy(dx: -2, dy: -2))
        canvas.addTextBox(word, in: m.rect.insetBy(dx: -4, dy: -6), fontSize: Double(min(40, max(12, m.rect.height * 0.8))).rounded())
        drop(m)
    }

    func drop(_ m: SpellCheck.Miss) {
        misses.removeAll { $0.id == m.id }
        canvas.showMisspelled(misses.map(\.rect))
    }

    func clearMisses() {
        misses = []
        canvas.showMisspelled([])
    }

    // MARK: Flashcards

    /// Questions and answers written by the assistant, as flashcards of this page.
    func addTextCards(_ list: [NoteAI.QA]) {
        guard !list.isEmpty else { return }
        var cards = notebook.cards ?? []
        for qa in list {
            var c = Flashcard(page: page.id, front: .zero, back: .zero)
            c.question = qa.question
            c.answer = qa.answer
            cards.append(c)
        }
        notebook.cards = cards
        library.save(notebook, touch: false)
    }

    var cards: [Flashcard] { notebook.cards ?? [] }
    var dueCards: Int { cards.filter { $0.isDue() }.count }

    func updateCard(_ c: Flashcard) {
        guard let i = notebook.cards?.firstIndex(where: { $0.id == c.id }) else { return }
        notebook.cards?[i] = c
        library.save(notebook, touch: false)
    }

    func deleteCard(_ c: Flashcard) {
        notebook.cards?.removeAll { $0.id == c.id }
        if notebook.cards?.isEmpty == true { notebook.cards = nil }
        library.save(notebook, touch: false)
    }

    // MARK: Handwriting to text

    private func readInk(in r: CGRect) {
        let strokes = canvas.strokes(in: r)
        guard !strokes.isEmpty else {
            notice = String(localized: "In quel riquadro non c'è scrittura a mano.")
            return
        }
        inkText = InkText(area: r)
        let d = PKDrawing(strokes: strokes)
        Task {
            let (text, lines) = await Indexer.shared.read(d)
            guard inkText?.area == r else { return }
            inkText?.text = text
            inkText?.lines = max(1, lines)
        }
    }

    /// Puts the text read in a box over the handwriting; with `replace` the handwriting goes.
    func placeInkText(_ text: String, replace: Bool) {
        guard let it = inkText else { return }
        inkText = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let size = min(40, max(12, (Double(it.area.height) / Double(max(1, it.lines))) * 0.62))
        if replace { canvas.removeStrokes(in: it.area) }
        canvas.addTextBox(t, in: replace ? it.area : it.area.offsetBy(dx: 0, dy: it.area.height + 8), fontSize: size.rounded())
    }

    // MARK: Presentation

    func setPresenting(_ on: Bool) {
        guard on != presenting else { return }
        if picking != nil { endPicking() }
        if on {
            toolBeforePresenting = tool
            presenting = true
            canvas.fitWhole = true
            select(.laser)
        } else {
            presenting = false
            canvas.fitWhole = false
            select(toolBeforePresenting == .hand ? .pen : toolBeforePresenting)
        }
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        notebook.title = t
        library.save(notebook, touch: false)
    }

    func setFingerDraws(_ on: Bool) {
        fingerDraws = on
        canvas.fingerDraws = on
        UserDefaults.standard.set(on, forKey: "fingerDraws")
    }

    func toggleRuler() {
        ruler.toggle()
        canvas.rulerActive = ruler
    }

    // MARK: Pages

    func go(to i: Int) {
        guard notebook.pages.indices.contains(i), i != pageIndex else { return }
        canvas.saveNow()
        pageIndex = i
        showPage()
    }

    func next() {
        guard !notebook.isBoard else { return }
        if pageIndex + 1 < notebook.pages.count { go(to: pageIndex + 1) } else { addPage(after: pageIndex, template: nil) }
    }

    func previous() { go(to: pageIndex - 1) }

    /// Inserts a page after `index`, with the given ruling or the one of the current page.
    func addPage(after index: Int, template: PageTemplate?) {
        canvas.saveNow()
        let ref = notebook.pages[min(index, notebook.pages.count - 1)]
        let t = template ?? (ref.pdfIndex == nil ? ref.template : .lined)
        let size = ref.pdfIndex == nil ? ref.size : PageFormat.a4Portrait.size
        notebook.pages.insert(PageInfo(template: t, size: size), at: index + 1)
        library.save(notebook)
        pageIndex = index + 1
        showPage()
    }

    func duplicatePage(_ index: Int) {
        canvas.saveNow()
        let src = notebook.pages[index]
        var copy = src
        copy.id = UUID()
        // every layer gets a new id; the first layer always has the page's id
        var newLayers: [InkLayer] = []
        for l in src.inkLayers {
            var n = l
            n.id = l.id == src.id ? copy.id : UUID()
            Store.saveDrawing(Store.loadDrawing(notebook.id, l.id), notebook.id, n.id)
            newLayers.append(n)
        }
        if src.layers != nil { copy.layers = newLayers }
        var items = Store.loadItems(notebook.id, src.id)
        for i in items.indices {
            items[i].id = UUID()
            if let name = items[i].image {
                let newName = UUID().uuidString + ".jpg"
                try? FileManager.default.copyItem(at: Store.image(notebook.id, name), to: Store.image(notebook.id, newName))
                items[i].image = newName
            }
        }
        Store.saveItems(items, notebook.id, copy.id)
        notebook.pages.insert(copy, at: index + 1)
        library.save(notebook)
        Indexer.shared.schedule(notebook, page: copy.id)
        go(to: index + 1)
    }

    func deletePage(_ index: Int) {
        guard notebook.pages.count > 1 else { return }
        canvas.saveNow()
        let pg = notebook.pages.remove(at: index)
        Store.removePageFiles(notebook.id, pg)
        notebook.cards?.removeAll { $0.page == pg.id }
        if notebook.cards?.isEmpty == true { notebook.cards = nil }
        library.save(notebook)
        Indexer.shared.prune(notebook)
        if index == 0 { library.refreshThumb(notebook.id) }
        pageIndex = min(pageIndex > index ? pageIndex - 1 : pageIndex, notebook.pages.count - 1)
        showPage()
    }

    func movePage(_ index: Int, by delta: Int) {
        let to = index + delta
        guard notebook.pages.indices.contains(index), notebook.pages.indices.contains(to) else { return }
        canvas.saveNow()
        let current = page.id
        notebook.pages.swapAt(index, to)
        library.save(notebook)
        if index == 0 || to == 0 { library.refreshThumb(notebook.id) }
        pageIndex = notebook.pages.firstIndex { $0.id == current } ?? 0
        showPage()
    }

    func setTemplate(_ t: PageTemplate, for index: Int) {
        notebook.pages[index].template = t
        library.save(notebook)
        if index == pageIndex { canvas.reloadPaper(notebook, page) }
        if index == 0 { library.refreshThumb(notebook.id) }
        pageVersion[notebook.pages[index].id, default: 0] += 1
    }

    func setTemplateForAll(_ t: PageTemplate) {
        for i in notebook.pages.indices where notebook.pages[i].pdfIndex == nil { notebook.pages[i].template = t }
        library.save(notebook)
        canvas.reloadPaper(notebook, page)
        library.refreshThumb(notebook.id)
        for p in notebook.pages { pageVersion[p.id, default: 0] += 1 }
    }

    func setPaper(_ p: Paper) {
        notebook.paper = p
        library.save(notebook)
        canvas.reloadPaper(notebook, page)
        library.refreshThumb(notebook.id)
        for p in notebook.pages { pageVersion[p.id, default: 0] += 1 }
    }

    func toggleBookmark(_ index: Int) {
        guard notebook.pages.indices.contains(index) else { return }
        notebook.pages[index].bookmarked = notebook.pages[index].isBookmarked ? nil : true
        library.save(notebook, touch: false)
    }

    var bookmarkCount: Int { notebook.pages.filter(\.isBookmarked).count }

    func appendPDF(_ url: URL) {
        canvas.saveNow()
        library.save(notebook)
        let before = notebook.pages.count
        if let nb = library.appendPDF(url, to: notebook.id) {
            notebook = nb
            // open the first of the new pages
            if notebook.pages.count > before { go(to: before) }
        }
    }

    /// Adds one page per picture (scans, photos) after the current page; each picture fills its page.
    func appendImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        canvas.saveNow()
        var at = pageIndex + 1
        let first = at
        for img in images {
            guard let (name, px) = Store.saveImage(img, notebook.id), px.width > 0 else { continue }
            let w: CGFloat = 595
            let h = (w * px.height / px.width).rounded()
            let pg = PageInfo(template: .blank, size: CGSize(width: w, height: h))
            var item = PageItem(kind: .image, x: 0, y: 0, w: Double(w), h: Double(h))
            item.image = name
            Store.saveItems([item], notebook.id, pg.id)
            notebook.pages.insert(pg, at: at)
            at += 1
        }
        guard at > first else { return }
        library.save(notebook)
        go(to: first)
    }

    // MARK: Layers

    var layers: [InkLayer] { page.inkLayers }

    func selectLayer(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        // drawing on a hidden layer shows it
        if let i = layers.firstIndex(where: { $0.id == id }), layers[i].isHidden {
            var list = layers
            list[i].hidden = nil
            setLayers(list)
        }
        canvas.load(notebook, page, layer: id)
        layerID = canvas.layerID
    }

    func addLayer() {
        canvas.saveNow()
        var list = layers
        let l = InkLayer(name: String(localized: "Livello \(list.count + 1)"))
        list.append(l)
        setLayers(list)
        selectLayer(l.id)
    }

    func toggleLayerHidden(_ id: UUID) {
        guard id != layerID, let i = layers.firstIndex(where: { $0.id == id }) else { return }
        var list = layers
        list[i].hidden = list[i].isHidden ? nil : true
        setLayers(list)
    }

    func renameLayer(_ id: UUID, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = layers.firstIndex(where: { $0.id == id }) else { return }
        var list = layers
        list[i].name = t
        setLayers(list)
    }

    /// Moves a layer up (+1, over the others) or down (-1).
    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(i + delta) else { return }
        canvas.saveNow()
        var list = layers
        list.swapAt(i, i + delta)
        setLayers(list)
    }

    func deleteLayer(_ id: UUID) {
        guard layers.count > 1 else { return }
        canvas.saveNow()
        let list = layers.filter { $0.id != id }
        let wasActive = id == layerID
        notebook.pages[pageIndex].layers = list
        library.save(notebook)
        try? FileManager.default.removeItem(at: Store.drawing(notebook.id, id))
        if wasActive {
            canvas.load(notebook, page, layer: PageCanvasView.startLayer(page))
            layerID = canvas.layerID
        }
        layerChanged()
    }

    private func setLayers(_ list: [InkLayer]) {
        notebook.pages[pageIndex].layers = list
        library.save(notebook)
        layerChanged()
    }

    private func layerChanged() {
        canvas.reloadLayers(notebook, page)
        if pageIndex == 0 { library.refreshThumb(notebook.id) }
        pageVersion[page.id, default: 0] += 1
        Indexer.shared.schedule(notebook, page: page.id)
    }

    // MARK: Boxes

    func addText() {
        tools.tool = .hand
        drawMode = false
        canvas.addText()
    }

    func addImage(_ img: UIImage, sticker: Bool = false) {
        tools.tool = .hand
        drawMode = false
        canvas.addImage(img, sticker: sticker)
    }

    /// Puts what is on the clipboard on the page: a picture, or text in a new box. False if there is nothing.
    func paste() -> Bool {
        let board = UIPasteboard.general
        if board.hasImages, let img = board.image {
            addImage(img)
            return true
        }
        if board.hasStrings, let s = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            tools.tool = .hand
            drawMode = false
            canvas.addText(s)
            return true
        }
        return false
    }

    func update(_ change: (inout PageItem) -> Void) { canvas.updateSelected(change) }
    func deleteSelected() { canvas.deleteSelected() }

    // MARK: Links

    /// Opens the page a link leads to.
    func follow(_ pageID: UUID) {
        guard let i = notebook.pages.firstIndex(where: { $0.id == pageID }) else {
            notice = String(localized: "La pagina collegata non c'è più.")
            return
        }
        go(to: i)
    }

    /// Links the selected box to a page (nil removes the link).
    func link(to pageID: UUID?) {
        update { $0.link = pageID }
    }

    /// A short name for each page, for the table of contents: its number and its first line.
    func pageNames() -> [String] {
        let texts = Indexer.storedTexts(notebook.id)
        return notebook.pages.enumerated().map { i, pg in
            let n = String(localized: "Pagina \(i + 1)")
            let first = (texts[pg.id.uuidString]?.all ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count > 1 }
            guard let first else { return n }
            return n + " · " + String(first.prefix(40))
        }
    }

    /// Adds pages after the current one with the list of the bookmarked pages (or of every page),
    /// each line a link to its page.
    func insertContents() {
        canvas.saveNow()
        let marked = notebook.pages.indices.filter { notebook.pages[$0].isBookmarked }
        let names = pageNames()
        let entries = (marked.isEmpty ? Array(notebook.pages.indices) : marked).map { (notebook.pages[$0].id, names[$0]) }
        let size = PageFormat.a4Portrait.size
        let lineH: CGFloat = 30, top: CGFloat = 112
        let perPage = max(1, Int((size.height - top - 40) / lineH))
        var at = pageIndex + 1
        let first = at
        var chunk = 0
        repeat {
            let pg = PageInfo(template: .blank, size: size)
            var items: [PageItem] = []
            var title = PageItem(kind: .text, x: 56, y: 44, w: Double(size.width - 112), h: 44)
            title.text = chunk == 0 ? String(localized: "Indice") : String(localized: "Indice (continua)")
            title.fontSize = 28
            title.bold = true
            items.append(title)
            let slice = entries.dropFirst(chunk * perPage).prefix(perPage)
            for (n, e) in slice.enumerated() {
                var line = PageItem(kind: .text, x: 56, y: Double(top + CGFloat(n) * lineH), w: Double(size.width - 150), h: 28)
                line.text = e.1
                line.fontSize = 16
                line.color = "1D4ED8"
                line.link = e.0
                items.append(line)
            }
            Store.saveItems(items, notebook.id, pg.id)
            notebook.pages.insert(pg, at: at)
            at += 1
            chunk += 1
        } while chunk * perPage < entries.count
        library.save(notebook)
        for p in notebook.pages[first..<at] { Indexer.shared.schedule(notebook, page: p.id) }
        pageIndex = first
        showPage()
    }

    // MARK: Audio

    var recordings: [Recording] { notebook.recordings ?? [] }

    private func recordingSaved(_ rec: Recording) {
        var list = recordings
        list.append(rec)
        notebook.recordings = list
        library.save(notebook)
    }

    func setTranscript(_ rec: Recording, _ text: String) {
        guard let i = recordings.firstIndex(where: { $0.id == rec.id }) else { return }
        notebook.recordings?[i].transcript = text
        library.save(notebook)
    }

    /// Puts text on the page in a new box.
    func insertText(_ text: String) {
        tools.tool = .hand
        drawMode = false
        canvas.addText(text)
    }

    func deleteRecording(_ rec: Recording) {
        audio.forget(rec)
        try? FileManager.default.removeItem(at: Store.audio(notebook.id, rec.id))
        notebook.recordings = recordings.filter { $0.id != rec.id }
        if notebook.recordings?.isEmpty == true { notebook.recordings = nil }
        library.save(notebook)
    }

    /// A tap on the writing while listening: plays what was recorded when that stroke was written.
    private func playFrom(_ date: Date?) {
        guard let date else {
            notice = String(localized: "Tocca un tratto scritto a mano.")
            return
        }
        guard let rec = recordings.last(where: { $0.start.addingTimeInterval(-1) <= date && date <= $0.end.addingTimeInterval(1) }) else {
            notice = String(localized: "Mentre scrivevi questo non stavi registrando.")
            return
        }
        audio.play(rec, at: max(0, date.timeIntervalSince(rec.start) - 2))
    }

    // MARK: Export

    func exportPDF(currentOnly: Bool) throws -> URL {
        canvas.saveNow()
        return try PageRenderer.exportPDF(notebook, pages: currentOnly ? [page] : nil)
    }

    /// The current page as a PNG picture.
    func exportImage() throws -> URL {
        canvas.saveNow()
        let img = PageRenderer.render(notebook, page, width: 2000)
        guard let data = img.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let safe = notebook.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Quaderno Appunti" : safe) - pagina \(pageIndex + 1).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Typed and PDF text of the current page, at once.
    func quickPageText() -> PageText {
        canvas.saveNow()
        return Indexer.shared.quickText(notebook, page)
    }

    /// Handwriting, typed text and PDF text of the current page, read now.
    func pageText() async -> PageText {
        canvas.saveNow()
        return await Indexer.shared.pageText(notebook, page)
    }
}
