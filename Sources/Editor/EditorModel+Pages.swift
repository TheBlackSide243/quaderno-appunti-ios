import PencilKit
import SwiftUI
import UIKit

/// Pages, several pages at once, lesson replay, paper and bookmarks, layers, links and export.
extension EditorModel {
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
        var fresh = PageInfo(template: t, size: size)
        // a new page keeps the custom paper of the page it follows, unless a ruling was chosen
        if template == nil { fresh.backdrop = ref.backdrop }
        notebook.pages.insert(fresh, at: index + 1)
        library.save(notebook)
        pageIndex = index + 1
        showPage()
    }

    func duplicatePage(_ index: Int) {
        canvas.saveNow()
        let copy = copyOf(notebook.pages[index])
        notebook.pages.insert(copy, at: index + 1)
        library.save(notebook)
        Indexer.shared.schedule(notebook, page: copy.id)
        go(to: index + 1)
    }

    /// A copy of a page with its own files: ink of every layer, boxes and pictures.
    private func copyOf(_ src: PageInfo) -> PageInfo {
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
        return copy
    }

    func deletePage(_ index: Int) {
        guard notebook.pages.count > 1 else { return }
        canvas.saveNow()
        let pg = notebook.pages.remove(at: index)
        Store.removePageFiles(notebook.id, pg)
        if SharedNotebooks.shared.isShared(notebook.id) { notebook.deletedPages = (notebook.deletedPages ?? []) + [pg.id] }
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

    // MARK: Several pages at once (page grid)

    /// The chosen pages, in the order of the notebook.
    func pages(_ ids: Set<UUID>) -> [PageInfo] { notebook.pages.filter { ids.contains($0.id) } }

    /// Bookmarks all the chosen pages, or takes the bookmark off all of them.
    func setBookmarks(_ ids: Set<UUID>, on: Bool) {
        for i in notebook.pages.indices where ids.contains(notebook.pages[i].id) {
            notebook.pages[i].bookmarked = on ? true : nil
        }
        library.save(notebook, touch: false)
    }

    /// Copies of the chosen pages, in their order, after the last of them. Returns the copies' ids.
    @discardableResult
    func duplicatePages(_ ids: Set<UUID>) -> [UUID] {
        let chosen = pages(ids)
        guard let last = notebook.pages.lastIndex(where: { ids.contains($0.id) }) else { return [] }
        canvas.saveNow()
        let copies = chosen.map { copyOf($0) }
        notebook.pages.insert(contentsOf: copies, at: last + 1)
        library.save(notebook)
        for c in copies { Indexer.shared.schedule(notebook, page: c.id) }
        return copies.map(\.id)
    }

    /// Deletes the chosen pages; at least one page always stays.
    func deletePages(_ ids: Set<UUID>) {
        let gone = pages(ids)
        guard !gone.isEmpty, gone.count < notebook.pages.count else { return }
        canvas.saveNow()
        let current = page.id
        let firstBefore = notebook.pages.first?.id
        let oldIndex = pageIndex
        for pg in gone { Store.removePageFiles(notebook.id, pg) }
        notebook.pages.removeAll { ids.contains($0.id) }
        if SharedNotebooks.shared.isShared(notebook.id) { notebook.deletedPages = (notebook.deletedPages ?? []) + gone.map(\.id) }
        notebook.cards?.removeAll { ids.contains($0.page) }
        if notebook.cards?.isEmpty == true { notebook.cards = nil }
        library.save(notebook)
        Indexer.shared.prune(notebook)
        if notebook.pages.first?.id != firstBefore { library.refreshThumb(notebook.id) }
        // the same page stays open; if it was deleted, the one that took its place
        pageIndex = notebook.pages.firstIndex { $0.id == current } ?? min(oldIndex, notebook.pages.count - 1)
        showPage()
    }

    /// Moves the chosen pages, in their order, to the start or the end of the notebook.
    func movePages(_ ids: Set<UUID>, toStart: Bool) {
        let chosen = pages(ids)
        guard !chosen.isEmpty else { return }
        canvas.saveNow()
        let current = page.id
        let firstBefore = notebook.pages.first?.id
        let rest = notebook.pages.filter { !ids.contains($0.id) }
        notebook.pages = toStart ? chosen + rest : rest + chosen
        library.save(notebook)
        if notebook.pages.first?.id != firstBefore { library.refreshThumb(notebook.id) }
        pageIndex = notebook.pages.firstIndex { $0.id == current } ?? 0
        showPage()
    }

    /// The chosen pages as one PDF.
    func exportPDF(pages ids: Set<UUID>) throws -> URL {
        canvas.saveNow()
        return try PageRenderer.exportPDF(notebook, pages: pages(ids))
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

    // MARK: Lesson replay

    func toggleReplay() { replaying ? stopReplay() : startReplay() }

    func startReplay() {
        guard let rec = audio.current, !audio.recording else { return }
        if picking != nil { endPicking() }
        replaying = true
        canvas.beginReplay()
        if !audio.playing { audio.play(rec, at: audio.position >= audio.duration - 0.2 ? 0 : audio.position) }
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.replaying else { return }
                self.canvas.showReplay(until: rec.start.addingTimeInterval(self.audio.position))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        replaying = false
        canvas.endReplay()
    }

    /// Puts back an earlier version of the page in view.
    func restoreVersion(_ v: PageHistory.Version) {
        canvas.saveNow()
        guard let restored = PageHistory.restore(v, notebook, page) else {
            notice = String(localized: "Non riesco a ripristinare questa versione.")
            return
        }
        notebook.pages[pageIndex] = restored
        library.save(notebook)
        canvas.reload(notebook, page)
        layerID = canvas.layerID
        pageVersion[page.id, default: 0] += 1
        if pageIndex == 0 { library.refreshThumb(notebook.id) }
        Indexer.shared.schedule(notebook, page: page.id)
        notice = String(localized: "Versione ripristinata.")
    }

    /// A picture as the paper of this page or of every page (nil = back to the ordinary paper).
    /// The picture is copied into the notebook, so it goes with it when synced or shared.
    func setBackdrop(_ img: UIImage?, allPages: Bool) {
        canvas.saveNow()
        var name: String?
        if let img {
            guard let (saved, _) = Store.saveImage(img, notebook.id) else {
                notice = String(localized: "Non riesco a salvare la carta.")
                return
            }
            name = saved
        }
        let targets = allPages ? Array(notebook.pages.indices) : [pageIndex]
        for i in targets where notebook.pages[i].pdfIndex == nil {
            notebook.pages[i].backdrop = name
            // the ruling would go over the picture
            if name != nil { notebook.pages[i].template = .blank }
        }
        library.save(notebook)
        canvas.reloadPaper(notebook, page)
        library.refreshThumb(notebook.id)
        for i in targets { pageVersion[notebook.pages[i].id, default: 0] += 1 }
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
