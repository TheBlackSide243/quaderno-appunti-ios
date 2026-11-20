import PencilKit
import UIKit

/// Reading and writing the page, and the lesson replay.
extension PageCanvasView {
    // MARK: Loading and saving

    /// The layer drawn on when a page opens: the top one that is not hidden.
    static func startLayer(_ pg: PageInfo) -> UUID {
        (pg.inkLayers.last { !$0.isHidden } ?? pg.inkLayers[pg.inkLayers.count - 1]).id
    }

    func load(_ nb: Notebook, _ pg: PageInfo, layer: UUID? = nil) {
        let lid = layer.flatMap { l in pg.inkLayers.contains { $0.id == l } ? l : nil } ?? Self.startLayer(pg)
        if let page, page.id == pg.id, notebook?.id == nb.id {
            if lid != layerID {
                // another layer of the same page: save this one, put the other on the canvas
                saveNow()
                notebook = nb
                self.page = pg
                layerID = lid
                loading = true
                canvas.drawing = Store.loadDrawing(nb.id, lid)
                loading = false
                inkBase = canvas.drawing.strokes
                canvas.undoManager?.removeAllActions()
                renderLayers(force: true)
                onUndoChange?()
                return
            }
            notebook = nb
            self.page = pg
            if paper.image == nil || paperScale == 0 { renderPaper() }
            renderLayers(force: true)
            return
        }
        saveNow()
        if notebook != nil {
            // a short fade between pages
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            self.layer.add(fade, forKey: "page")
        }
        notebook = nb
        page = pg
        // stop a bounce still running from the pull that turned the page
        canvas.setContentOffset(canvas.contentOffset, animated: false)
        layerID = lid
        loading = true
        canvas.drawing = Store.loadDrawing(nb.id, lid)
        loading = false
        canvas.undoManager?.removeAllActions()
        paper.bounds = CGRect(origin: .zero, size: pg.size)
        belowInk.bounds = CGRect(origin: .zero, size: pg.size)
        aboveInk.bounds = CGRect(origin: .zero, size: pg.size)
        layerScale = 0
        items.bounds = CGRect(origin: .zero, size: pg.size)
        items.load(nb, Store.loadItems(nb.id, pg.id))
        inkBase = canvas.drawing.strokes
        itemsBase = items.items
        links.bounds = CGRect(origin: .zero, size: pg.size)
        links.update(items.items, zoom: canvas.zoomScale)
        clearSelection()
        selectionHost.bounds = CGRect(origin: .zero, size: pg.size)
        shapeLayer.path = nil
        spellLayer.path = nil
        spellRects = []
        spellTap.isEnabled = false
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
        applyPaperStyle()
        renderPaper()
        renderLayers(force: true)
        stamps = currentStamps()
        onUndoChange?()
    }

    private func currentStamps() -> [Date?] {
        guard let nb = notebook, let pg = page else { return [] }
        func mod(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return pg.inkLayers.map { mod(Store.drawing(nb.id, $0.id)) } + [mod(Store.items(nb.id, pg.id))]
    }

    /// A shared notebook got changes: the page is read again if its files changed and nothing
    /// written here is waiting to be saved.
    func refreshFromDisk(_ nb: Notebook, _ pg: PageInfo) {
        guard page?.id == pg.id, let lid = layerID, pg.inkLayers.contains(where: { $0.id == lid }) else {
            load(nb, pg)
            return
        }
        let paperChanged = page?.template != pg.template || page?.size != pg.size || notebook?.paper != nb.paper || page?.backdrop != pg.backdrop
        notebook = nb
        page = pg
        if paperChanged {
            paperScale = 0
            applyPaperStyle()
            renderPaper()
        }
        let now = currentStamps()
        guard now != stamps else {
            if !dirty { renderLayers(force: true) }
            return
        }
        let disk = Store.loadDrawing(nb.id, lid)
        let diskItems = Store.loadItems(nb.id, pg.id)
        if dirty {
            // written here and not saved yet: both together, and saved soon
            let ink = StrokeMerge.merge(base: inkBase, mine: canvas.drawing.strokes, theirs: disk.strokes)
            let list = StrokeMerge.mergeItems(base: itemsBase, mine: items.items, theirs: diskItems)
            inkBase = disk.strokes
            itemsBase = diskItems
            stamps = now
            if ink.map(StrokeMerge.key) != canvas.drawing.strokes.map(StrokeMerge.key) {
                loading = true
                canvas.drawing = PKDrawing(strokes: ink)
                loading = false
                canvas.undoManager?.removeAllActions()
                onUndoChange?()
            }
            if list != items.items {
                items.load(nb, list)
                links.update(items.items, zoom: canvas.zoomScale)
            }
            renderLayers(force: true)
            scheduleSave()
            return
        }
        loading = true
        canvas.drawing = disk
        loading = false
        inkBase = disk.strokes
        itemsBase = diskItems
        items.load(nb, diskItems)
        links.update(items.items, zoom: canvas.zoomScale)
        renderLayers(force: true)
        stamps = now
        canvas.undoManager?.removeAllActions()
        onUndoChange?()
    }

    /// Draws the other visible layers of the page under and over the one being edited.
    func renderLayers(force: Bool) {
        guard let nb = notebook, let pg = page, let lid = layerID else { return }
        let list = pg.inkLayers
        guard list.count > 1, let i = list.firstIndex(where: { $0.id == lid }) else {
            belowInk.image = nil
            aboveInk.image = nil
            return
        }
        let screen = window?.screen.scale ?? 2
        let maxScale = sqrt(16_000_000 / max(1, pg.size.width * pg.size.height))
        let zoom = canvas.zoomScale.isFinite && canvas.zoomScale > 0 ? canvas.zoomScale : 1
        let want = min(maxScale, max(1.5, zoom * screen))
        guard force || want > layerScale * 1.15 else { return }
        layerScale = want
        func picture(_ ls: ArraySlice<InkLayer>) -> UIImage? {
            let strokes = ls.filter { !$0.isHidden }.flatMap { Store.loadDrawing(nb.id, $0.id).strokes }
            return strokes.isEmpty ? nil : PageRenderer.inkImage(PKDrawing(strokes: strokes), size: pg.size, scale: want, dark: darkPaper)
        }
        belowInk.image = picture(list[..<i])
        aboveInk.image = picture(list[(i + 1)...])
    }

    // MARK: Lesson replay

    /// From now on the canvas shows only part of the ink, without saving it or letting anyone write.
    func beginReplay() {
        guard replayFull == nil else { return }
        saveNow()
        replayFull = canvas.drawing
        replayShown = -1
        canvas.drawingGestureRecognizer.isEnabled = false
    }

    /// Shows the strokes written up to `t`.
    func showReplay(until t: Date) {
        guard let full = replayFull else { return }
        let visible = full.strokes.filter { $0.path.creationDate <= t }
        guard visible.count != replayShown else { return }
        replayShown = visible.count
        loading = true
        canvas.drawing = PKDrawing(strokes: visible)
        loading = false
    }

    func endReplay() {
        guard let full = replayFull else { return }
        replayFull = nil
        loading = true
        canvas.drawing = full
        loading = false
        applyMode()
    }

    /// Reads the page again from its files (an earlier version was put back).
    func reload(_ nb: Notebook, _ pg: PageInfo) {
        saveNow()
        page = nil
        notebook = nil
        load(nb, pg)
    }

    /// After a layer was hidden, shown or moved.
    func reloadLayers(_ nb: Notebook, _ pg: PageInfo) {
        notebook = nb
        page = pg
        renderLayers(force: true)
    }

    /// The page got bigger (a whiteboard growing): the content stays where it is.
    func resize(_ pg: PageInfo) {
        page = pg
        paper.bounds = CGRect(origin: .zero, size: pg.size)
        belowInk.bounds = CGRect(origin: .zero, size: pg.size)
        aboveInk.bounds = CGRect(origin: .zero, size: pg.size)
        items.bounds = CGRect(origin: .zero, size: pg.size)
        links.bounds = CGRect(origin: .zero, size: pg.size)
        selectionHost.bounds = CGRect(origin: .zero, size: pg.size)
        if bounds.width > 40, bounds.height > 40 {
            let whole = min((bounds.width - 20) / pg.size.width, (bounds.height - 20) / pg.size.height)
            if whole.isFinite, whole > 0 { canvas.minimumZoomScale = min(canvas.minimumZoomScale, whole * 0.9) }
        }
        updateContent()
    }

    /// Redraws the paper (after the template changed).
    func reloadPaper(_ nb: Notebook, _ pg: PageInfo) {
        notebook = nb
        page = pg
        paperScale = 0
        applyPaperStyle()
        renderPaper()
        renderLayers(force: true)
    }

    func renderPaper() {
        guard let nb = notebook, let pg = page else { return }
        if nb.isBoard {
            // a whiteboard can be huge: its paper is a pattern repeated, sharp at any size
            if paperScale == 0 {
                paperScale = 1
                paper.image = nil
                paper.backgroundColor = UIColor(patternImage: PageRenderer.tile(pg.template, paper: nb.paper))
            }
            return
        }
        paper.backgroundColor = nil
        // Sharp enough for the current zoom, capped at ~24 Mpx.
        let screen = window?.screen.scale ?? 2
        let maxScale = sqrt(24_000_000 / (pg.size.width * pg.size.height))
        let zoom = canvas.zoomScale.isFinite && canvas.zoomScale > 0 ? canvas.zoomScale : 1
        let want = min(maxScale, max(2, zoom * screen))
        guard want > paperScale * 1.15 || paperScale == 0 else { return }
        paperScale = want
        paper.image = PageRenderer.background(nb, pg, scale: want)
    }

    func scheduleSave() {
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
        // how the page was before this writing, for … → Page → Earlier versions
        PageHistory.snapshotIfDue(nb, pg)
        Store.saveDrawing(canvas.drawing, nb.id, layerID ?? pg.id)
        Store.saveItems(items.items, nb.id, pg.id)
        inkBase = canvas.drawing.strokes
        itemsBase = items.items
        stamps = currentStamps()
        onSaved?(pg)
    }

    func itemsChanged() {
        links.update(items.items, zoom: canvas.zoomScale)
        scheduleSave()
    }
}
