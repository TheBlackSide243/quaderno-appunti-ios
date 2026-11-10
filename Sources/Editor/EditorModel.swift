import Observation
import PencilKit
import SwiftUI
import UIKit

/// The tools of the editor toolbar.
enum Tool: String, CaseIterable, Codable, Identifiable {
    case pen, pencil, highlighter, eraser, lasso, hand
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: "Penna"
        case .pencil: "Matita"
        case .highlighter: "Evidenziatore"
        case .eraser: "Gomma"
        case .lasso: "Lazo"
        case .hand: "Sposta testi e foto"
        }
    }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .hand: "hand.point.up.left"
        }
    }

    /// The three thicknesses offered (for the eraser: whole stroke, small, large).
    var widths: [CGFloat] {
        switch self {
        case .pen: [1.5, 3, 6]
        case .pencil: [2.5, 4.5, 8]
        case .highlighter: [12, 20, 30]
        case .eraser: [0, 10, 30]
        case .lasso, .hand: []
        }
    }

    /// The three colours always at hand.
    var presets: [String] {
        switch self {
        case .pen: ["1C1C20", "1D4ED8", "DC2626"]
        case .pencil: ["3F3F46", "1D4ED8", "B91C1C"]
        case .highlighter: ["FDE047", "86EFAC", "F9A8D4"]
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
    /// Bumped when a page's picture changes, so the page grid reloads it.
    var pageVersion: [UUID: Int] = [:]

    @ObservationIgnored let canvas = PageCanvasView()

    init(library: Library, notebook: Notebook, page: Int?) {
        self.library = library
        self.notebook = notebook
        self.pageIndex = min(max(0, page ?? notebook.lastPage), max(0, notebook.pages.count - 1))
        if UserDefaults.standard.object(forKey: "fingerDraws") != nil {
            fingerDraws = UserDefaults.standard.bool(forKey: "fingerDraws")
        } else {
            fingerDraws = UIDevice.current.userInterfaceIdiom == .phone || !UIPencilInteraction.prefersPencilOnlyDrawing
        }
        canvas.fingerDraws = fingerDraws
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
        showPage()
        if tools.tool == .hand { tools.tool = .pen }
        applyTool()
    }

    var page: PageInfo { notebook.pages[pageIndex] }

    func showPage() {
        guard notebook.pages.indices.contains(pageIndex) else { return }
        canvas.load(notebook, page)
        selected = nil
    }

    private func pageSaved(_ pg: PageInfo) {
        library.save(notebook)
        if notebook.pages.first?.id == pg.id { library.refreshThumb(notebook.id) }
        pageVersion[pg.id, default: 0] += 1
        Indexer.shared.schedule(notebook, page: pg.id)
    }

    func close() {
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
        tools.tool = t
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
        if t == .hand {
            setDrawMode(false)
            return
        }
        if !drawMode { setDrawMode(true) }
        let w = t.widths.isEmpty ? 0 : t.widths[widthIndex(of: t)]
        let c = UIColor(hex: color(of: t))
        switch t {
        case .pen: canvas.setTool(PKInkingTool(.pen, color: c, width: w))
        case .pencil: canvas.setTool(PKInkingTool(.pencil, color: c, width: w))
        case .highlighter: canvas.setTool(PKInkingTool(.marker, color: c, width: w))
        case .eraser: canvas.setTool(w == 0 ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: w))
        case .lasso: canvas.setTool(PKLassoTool())
        case .hand: break
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
        let d = Store.loadDrawing(notebook.id, src.id)
        Store.saveDrawing(d, notebook.id, copy.id)
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
        Store.removePageFiles(notebook.id, pg.id)
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

    func appendPDF(_ url: URL) {
        canvas.saveNow()
        library.save(notebook)
        if let nb = library.appendPDF(url, to: notebook.id) {
            notebook = nb
            go(to: notebook.pages.count - 1 < pageIndex ? pageIndex : notebook.pages.count - 1)
        }
    }

    // MARK: Boxes

    func addText() {
        tools.tool = .hand
        drawMode = false
        canvas.addText()
    }

    func addImage(_ img: UIImage) {
        tools.tool = .hand
        drawMode = false
        canvas.addImage(img)
    }

    func update(_ change: (inout PageItem) -> Void) { canvas.updateSelected(change) }
    func deleteSelected() { canvas.deleteSelected() }

    // MARK: Export

    func exportPDF(currentOnly: Bool) throws -> URL {
        canvas.saveNow()
        return try PageRenderer.exportPDF(notebook, pages: currentOnly ? [page] : nil)
    }
}
