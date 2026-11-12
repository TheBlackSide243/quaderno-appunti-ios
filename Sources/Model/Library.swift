import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

/// Where everything is stored. Each notebook is a folder in Documents/Quaderni, visible in the Files app:
///   notebook.json, source.pdf (imported PDFs), pages/<id>.drawing, pages/<id>.items.json,
///   images/<name>.jpg, thumb.jpg and index.json (text for the search).
enum Store {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let root = documents.appendingPathComponent("Quaderni", isDirectory: true)
    static let foldersFile = documents.appendingPathComponent("cartelle.json")
    /// Deleted notebooks wait here for 30 days.
    static let trash = documents.appendingPathComponent("Cestino", isDirectory: true)
    static let trashDays = 30

    static func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func meta(_ id: UUID) -> URL { dir(id).appendingPathComponent("notebook.json") }
    static func pdf(_ id: UUID) -> URL { dir(id).appendingPathComponent("source.pdf") }
    static func thumb(_ id: UUID) -> URL { dir(id).appendingPathComponent("thumb.jpg") }
    static func index(_ id: UUID) -> URL { dir(id).appendingPathComponent("index.json") }
    static func pagesDir(_ id: UUID) -> URL { dir(id).appendingPathComponent("pages", isDirectory: true) }
    static func imagesDir(_ id: UUID) -> URL { dir(id).appendingPathComponent("images", isDirectory: true) }
    static func drawing(_ id: UUID, _ page: UUID) -> URL { pagesDir(id).appendingPathComponent("\(page.uuidString).drawing") }
    static func items(_ id: UUID, _ page: UUID) -> URL { pagesDir(id).appendingPathComponent("\(page.uuidString).items.json") }
    static func image(_ id: UUID, _ name: String) -> URL { imagesDir(id).appendingPathComponent(name) }
    static func audioDir(_ id: UUID) -> URL { dir(id).appendingPathComponent("audio", isDirectory: true) }
    static func audio(_ id: UUID, _ rec: UUID) -> URL { audioDir(id).appendingPathComponent("\(rec.uuidString).m4a") }

    static func ensureDirs(_ id: UUID) {
        for d in [dir(id), pagesDir(id), imagesDir(id)] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Page contents

    static func loadDrawing(_ nb: UUID, _ page: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawing(nb, page)), let d = try? PKDrawing(data: data) else { return PKDrawing() }
        return d
    }

    static func saveDrawing(_ d: PKDrawing, _ nb: UUID, _ page: UUID) {
        ensureDirs(nb)
        try? d.dataRepresentation().write(to: drawing(nb, page), options: .atomic)
    }

    static func loadItems(_ nb: UUID, _ page: UUID) -> [PageItem] {
        guard let data = try? Data(contentsOf: items(nb, page)) else { return [] }
        return (try? decoder.decode([PageItem].self, from: data)) ?? []
    }

    static func saveItems(_ list: [PageItem], _ nb: UUID, _ page: UUID) {
        ensureDirs(nb)
        if list.isEmpty {
            try? FileManager.default.removeItem(at: items(nb, page))
        } else if let data = try? encoder.encode(list) {
            try? data.write(to: items(nb, page), options: .atomic)
        }
    }

    static func removePageFiles(_ nb: UUID, _ page: PageInfo) {
        for item in loadItems(nb, page.id) where item.kind == .image {
            if let name = item.image { try? FileManager.default.removeItem(at: image(nb, name)) }
        }
        for l in page.inkLayers { try? FileManager.default.removeItem(at: drawing(nb, l.id)) }
        try? FileManager.default.removeItem(at: drawing(nb, page.id))
        try? FileManager.default.removeItem(at: items(nb, page.id))
    }

    /// The ink of every visible layer of a page, bottom layer first.
    static func loadInk(_ nb: UUID, _ page: PageInfo) -> PKDrawing {
        let layers = page.inkLayers.filter { !$0.isHidden }
        if layers.count == 1 { return loadDrawing(nb, layers[0].id) }
        return PKDrawing(strokes: layers.flatMap { loadDrawing(nb, $0.id).strokes })
    }

    /// When the ink of a page last changed (any layer); nil = no ink saved.
    static func inkStamp(_ nb: UUID, _ page: PageInfo) -> Date? {
        page.inkLayers.compactMap { (try? drawing(nb, $0.id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
    }

    /// Saves a picture for a page, scaled down to at most 2400 px, and returns its file name.
    /// With `keepAlpha` (stickers) the picture is kept as PNG, with its transparent parts.
    static func saveImage(_ img: UIImage, _ nb: UUID, keepAlpha: Bool = false) -> (String, CGSize)? {
        ensureDirs(nb)
        let maxSide: CGFloat = 2400
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height))
        let target = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = !keepAlpha
        let scaled = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = keepAlpha ? scaled.pngData() : scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + (keepAlpha ? ".png" : ".jpg")
        do { try data.write(to: image(nb, name), options: .atomic) } catch { return nil }
        return (name, target)
    }
}

/// Keeps the open PDFs in memory so turning pages is quick.
final class PDFCache {
    static let shared = PDFCache()
    private let cache = NSCache<NSString, PDFDocument>()
    private let lock = NSLock()

    func document(_ id: UUID) -> PDFDocument? {
        lock.lock(); defer { lock.unlock() }
        if let d = cache.object(forKey: id.uuidString as NSString) { return d }
        guard let d = PDFDocument(url: Store.pdf(id)) else { return nil }
        cache.setObject(d, forKey: id.uuidString as NSString)
        return d
    }

    func forget(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache.removeObject(forKey: id.uuidString as NSString)
    }
}

/// All notebooks and folders.
@MainActor
@Observable
final class Library {
    var notebooks: [Notebook] = []
    var folders: [Folder] = []
    /// Notebooks in the trash, newest first.
    var trashed: [Notebook] = []
    var error: String?
    /// Bumped whenever a cover image changes, so the grid reloads it.
    var thumbVersion: [UUID: Int] = [:]

    init() { load() }

    func load() {
        try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
        var list: [Notebook] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Store.root, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("notebook.json")),
                  let nb = try? Store.decoder.decode(Notebook.self, from: data) else { continue }
            list.append(nb)
        }
        notebooks = list.sorted { $0.modified > $1.modified }
        if let data = try? Data(contentsOf: Store.foldersFile), let f = try? Store.decoder.decode([Folder].self, from: data) {
            folders = f
        }
        loadTrash()
    }

    /// Reads the trash and removes for good what has been there longer than 30 days.
    func loadTrash() {
        var list: [Notebook] = []
        let limit = Date().addingTimeInterval(-Double(Store.trashDays) * 86_400)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Store.trash, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("notebook.json")),
                  let nb = try? Store.decoder.decode(Notebook.self, from: data) else { continue }
            if let when = nb.deletedAt, when < limit {
                try? FileManager.default.removeItem(at: d)
            } else {
                list.append(nb)
            }
        }
        trashed = list.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func notebook(_ id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    /// Writes the notebook's description and puts it first in the list.
    func save(_ nb: Notebook, touch: Bool = true) {
        var nb = nb
        if touch { nb.modified = Date() }
        Store.ensureDirs(nb.id)
        if let data = try? Store.encoder.encode(nb) { try? data.write(to: Store.meta(nb.id), options: .atomic) }
        if let i = notebooks.firstIndex(where: { $0.id == nb.id }) { notebooks[i] = nb } else { notebooks.append(nb) }
        notebooks.sort { $0.modified > $1.modified }
        Spotlight.shared.schedule(nb)
    }

    private func saveFolders() {
        if let data = try? Store.encoder.encode(folders) { try? data.write(to: Store.foldersFile, options: .atomic) }
    }

    // MARK: Notebooks

    @discardableResult
    func create(title: String, cover: Int?, style: CoverStyle, template: PageTemplate, paper: Paper, format: PageFormat, folder: UUID?,
                board: Bool = false, text: Bool = false) -> Notebook {
        let name = title.trimmingCharacters(in: .whitespaces)
        let size = board ? Notebook.boardStart : (text ? TextDoc.pageSize : format.size)
        var nb = Notebook(title: name.isEmpty ? String(localized: "Senza titolo") : name, cover: cover, paper: paper, folderID: folder,
                          pages: [PageInfo(template: template, size: size)])
        nb.coverStyle = style
        if board { nb.board = true }
        if text {
            nb.textDocument = true
            nb.pages[0].template = .blank
            TextDoc.save(NSAttributedString(string: "", attributes: TextDoc.bodyAttributes), nb.id)
        }
        save(nb)
        refreshThumb(nb.id)
        return nb
    }

    /// Copies a PDF into a new notebook, one page per PDF page.
    func importPDF(_ url: URL, folder: UUID?) -> Notebook? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            error = String(localized: "Il file non è un PDF leggibile.")
            return nil
        }
        if doc.isLocked {
            error = String(localized: "Il PDF è protetto da password: sbloccalo prima di importarlo.")
            return nil
        }
        var nb = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: nil, folderID: folder, pages: [])
        nb.hasPDF = true
        Store.ensureDirs(nb.id)
        do {
            try FileManager.default.copyItem(at: url, to: Store.pdf(nb.id))
        } catch {
            self.error = String(localized: "Non riesco a copiare il PDF: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            return nil
        }
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            nb.pages.append(PageInfo(template: .blank, size: PageRenderer.pdfPageSize(p), pdfIndex: i))
        }
        save(nb)
        refreshThumb(nb.id)
        Indexer.shared.indexPDF(nb)
        return nb
    }

    /// Turns a GoodNotes notebook into a new notebook: paper, handwriting, highlighter, photos, text.
    func importGoodNotes(_ url: URL, folder: UUID?) async -> Notebook? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let nb = try await Task.detached(priority: .userInitiated) { try GoodNotesImport.read(url, folder: folder) }.value
            save(nb)
            refreshThumb(nb.id)
            if nb.hasPDF { Indexer.shared.indexPDF(nb) }
            for page in nb.pages { Indexer.shared.schedule(nb, page: page.id) }
            return nb
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Il file non è un quaderno GoodNotes leggibile.")
            return nil
        }
    }

    /// Adds the pages of a PDF at the end of an existing notebook.
    func appendPDF(_ url: URL, to id: UUID) -> Notebook? {
        guard var nb = notebook(id) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let incoming = PDFDocument(url: url), incoming.pageCount > 0, !incoming.isLocked else {
            error = String(localized: "Il file non è un PDF leggibile (o è protetto da password).")
            return nil
        }
        var merged = PDFDocument()
        if nb.hasPDF, let existing = PDFDocument(url: Store.pdf(id)) { merged = existing }
        let start = merged.pageCount
        for i in 0..<incoming.pageCount {
            if let p = incoming.page(at: i)?.copy() as? PDFPage { merged.insert(p, at: merged.pageCount) }
        }
        // Written next to the old file first: the old one is still being read lazily.
        let tmp = Store.dir(id).appendingPathComponent("source-new.pdf")
        guard merged.write(to: tmp) else {
            error = String(localized: "Non riesco a salvare il PDF unito.")
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: Store.pdf(id).path) {
                _ = try FileManager.default.replaceItemAt(Store.pdf(id), withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: Store.pdf(id))
            }
        } catch {
            self.error = String(localized: "Non riesco a salvare il PDF unito: \(error.localizedDescription)")
            return nil
        }
        PDFCache.shared.forget(id)
        for i in start..<merged.pageCount {
            guard let p = merged.page(at: i) else { continue }
            nb.pages.append(PageInfo(template: .blank, size: PageRenderer.pdfPageSize(p), pdfIndex: i))
        }
        nb.hasPDF = true
        save(nb)
        Indexer.shared.indexPDF(nb)
        return nb
    }

    /// A new notebook with one page per picture, each picture filling its page.
    func importImages(_ images: [UIImage], title: String, folder: UUID?) -> Notebook? {
        guard !images.isEmpty else { return nil }
        var nb = Notebook(title: title, cover: nil, folderID: folder, pages: [])
        Store.ensureDirs(nb.id)
        for img in images {
            guard let (name, px) = Store.saveImage(img, nb.id), px.width > 0 else { continue }
            let w: CGFloat = 595
            let h = (w * px.height / px.width).rounded()
            let page = PageInfo(template: .blank, size: CGSize(width: w, height: h))
            var item = PageItem(kind: .image, x: 0, y: 0, w: Double(w), h: Double(h))
            item.image = name
            Store.saveItems([item], nb.id, page.id)
            nb.pages.append(page)
        }
        guard !nb.pages.isEmpty else {
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            error = String(localized: "Non riesco a leggere le immagini.")
            return nil
        }
        save(nb)
        refreshThumb(nb.id)
        return nb
    }

    func setCoverStyle(_ id: UUID, _ style: CoverStyle) {
        guard var nb = notebook(id) else { return }
        nb.coverStyle = style
        if nb.cover == nil { nb.cover = 0 }
        save(nb, touch: false)
    }

    /// Notebooks of a folder (nil = not in any folder), in the chosen order.
    func notebooks(in folder: UUID?, order: SortOrder, favoritesOnly: Bool = false) -> [Notebook] {
        let known = Set(folders.map(\.id))
        var list = notebooks.filter { nb in
            if favoritesOnly { return nb.favorite }
            if let f = folder { return nb.folderID == f }
            return nb.folderID == nil || !known.contains(nb.folderID!)
        }
        switch order {
        case .date: list.sort { $0.modified > $1.modified }
        case .name: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .kind: list.sort { ($0.hasPDF ? 1 : 0, $0.title.lowercased()) < ($1.hasPDF ? 1 : 0, $1.title.lowercased()) }
        }
        return list
    }

    func count(in folder: UUID) -> Int { notebooks.filter { $0.folderID == folder }.count }

    // MARK: Tags

    /// Every label used by some notebook, in alphabetical order.
    var allTags: [String] {
        Array(Set(notebooks.flatMap(\.tagList))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Notebooks with a label, from every folder, in the chosen order.
    func notebooks(tagged tag: String, order: SortOrder, favoritesOnly: Bool) -> [Notebook] {
        var list = notebooks.filter { $0.tagList.contains(tag) && (!favoritesOnly || $0.favorite) }
        switch order {
        case .date: list.sort { $0.modified > $1.modified }
        case .name, .kind: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    func toggleTag(_ id: UUID, _ tag: String) {
        guard var nb = notebook(id) else { return }
        var t = nb.tagList
        if let i = t.firstIndex(of: tag) { t.remove(at: i) } else { t.append(tag) }
        nb.tags = t.isEmpty ? nil : t
        save(nb, touch: false)
    }

    /// Adds a new label to a notebook; returns the label as stored (trimmed), or nil if empty.
    @discardableResult
    func addTag(_ id: UUID, _ raw: String) -> String? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, var nb = notebook(id) else { return nil }
        // reuse the spelling of a label that already exists
        let existing = allTags.first { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? tag
        if !nb.tagList.contains(existing) { nb.tags = nb.tagList + [existing] }
        save(nb, touch: false)
        return existing
    }

    func renameTag(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        for var nb in notebooks where nb.tagList.contains(old) {
            var t = nb.tagList.filter { $0 != old }
            if !t.contains(new) { t.append(new) }
            nb.tags = t
            save(nb, touch: false)
        }
    }

    func deleteTag(_ tag: String) {
        for var nb in notebooks where nb.tagList.contains(tag) {
            let t = nb.tagList.filter { $0 != tag }
            nb.tags = t.isEmpty ? nil : t
            save(nb, touch: false)
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard var nb = notebook(id) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        nb.title = t.isEmpty ? nb.title : t
        save(nb, touch: false)
    }

    func setCover(_ id: UUID, _ cover: Int?) {
        guard var nb = notebook(id) else { return }
        nb.cover = cover
        save(nb, touch: false)
    }

    /// Reads a notebook again from its folder (after a shared notebook got changes).
    func reload(_ id: UUID) {
        guard let data = try? Data(contentsOf: Store.meta(id)), let nb = try? Store.decoder.decode(Notebook.self, from: data) else { return }
        if let i = notebooks.firstIndex(where: { $0.id == id }) { notebooks[i] = nb } else { notebooks.append(nb) }
        refreshThumb(id)
    }

    func updateCard(_ id: UUID, _ c: Flashcard) {
        guard var nb = notebook(id), let i = nb.cards?.firstIndex(where: { $0.id == c.id }) else { return }
        nb.cards?[i] = c
        save(nb, touch: false)
    }

    func deleteCard(_ id: UUID, _ c: Flashcard) {
        guard var nb = notebook(id) else { return }
        nb.cards?.removeAll { $0.id == c.id }
        if nb.cards?.isEmpty == true { nb.cards = nil }
        save(nb, touch: false)
    }

    // MARK: Windows

    /// Notebooks open in an editor, in any window: the same one is never open twice.
    private(set) var openNotebooks: Set<UUID> = []

    func isOpen(_ id: UUID) -> Bool { openNotebooks.contains(id) }
    func opened(_ id: UUID) { openNotebooks.insert(id) }
    func closed(_ id: UUID) { openNotebooks.remove(id) }

    func toggleFavorite(_ id: UUID) {
        guard var nb = notebook(id) else { return }
        nb.favorite.toggle()
        save(nb, touch: false)
    }

    func move(_ id: UUID, to folder: UUID?) {
        guard var nb = notebook(id) else { return }
        nb.folderID = folder
        save(nb, touch: false)
    }

    func duplicate(_ id: UUID) {
        guard var nb = notebook(id) else { return }
        let old = nb.id
        nb.id = UUID()
        nb.title += String(localized: " (copia)")
        nb.created = Date()
        do {
            try FileManager.default.copyItem(at: Store.dir(old), to: Store.dir(nb.id))
        } catch {
            self.error = String(localized: "Copia non riuscita: \(error.localizedDescription)")
            return
        }
        save(nb)
        Indexer.shared.forget(nb.id)
    }

    /// Moves a notebook to the trash, where it stays for 30 days.
    func delete(_ id: UUID) {
        guard var nb = notebook(id) else { return }
        nb.deletedAt = Date()
        let fm = FileManager.default
        let dst = Store.trash.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: Store.trash, withIntermediateDirectories: true)
            if let data = try? Store.encoder.encode(nb) { try? data.write(to: Store.meta(id), options: .atomic) }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: Store.dir(id), to: dst)
        } catch {
            self.error = String(localized: "Non riesco a spostare il quaderno nel cestino: \(error.localizedDescription)")
            return
        }
        PDFCache.shared.forget(id)
        Indexer.shared.forget(id)
        Spotlight.shared.remove(id)
        Tombstones.add(id)
        notebooks.removeAll { $0.id == id }
        trashed.insert(nb, at: 0)
    }

    /// Puts a notebook from the trash back on the shelf.
    func restore(_ id: UUID) {
        guard var nb = trashed.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        let src = Store.trash.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: Store.root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: Store.dir(id).path) { try fm.removeItem(at: Store.dir(id)) }
            try fm.moveItem(at: src, to: Store.dir(id))
        } catch {
            self.error = String(localized: "Non riesco a ripristinare il quaderno: \(error.localizedDescription)")
            return
        }
        nb.deletedAt = nil
        if let f = nb.folderID, !folders.contains(where: { $0.id == f }) { nb.folderID = nil }
        trashed.removeAll { $0.id == id }
        Tombstones.remove(id)
        // newer than its deletion, so syncing does not delete it again on the other devices
        save(nb, touch: true)
        refreshThumb(id)
        Indexer.shared.catchUp([nb])
    }

    /// Removes a notebook from the trash for good.
    func deleteForever(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.trash.appendingPathComponent(id.uuidString, isDirectory: true))
        trashed.removeAll { $0.id == id }
    }

    func emptyTrash() {
        for nb in trashed {
            try? FileManager.default.removeItem(at: Store.trash.appendingPathComponent(nb.id.uuidString, isDirectory: true))
        }
        trashed = []
    }

    /// Days left before a trashed notebook is removed for good.
    func daysLeft(_ nb: Notebook) -> Int {
        guard let when = nb.deletedAt else { return Store.trashDays }
        let passed = Int(Date().timeIntervalSince(when) / 86_400)
        return max(0, Store.trashDays - passed)
    }

    // MARK: Folders

    func addFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        folders.append(Folder(name: n))
        saveFolders()
    }

    func renameFolder(_ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = n
        saveFolders()
    }

    /// Removes the folder; its notebooks go back to the main list.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        saveFolders()
        for nb in notebooks where nb.folderID == id { move(nb.id, to: nil) }
    }

    // MARK: Covers

    /// Redraws the small picture of the first page used as cover and in the grid.
    func refreshThumb(_ id: UUID) {
        guard let nb = notebook(id), let first = nb.pages.first else { return }
        Task.detached(priority: .utility) {
            let img = PageRenderer.render(nb, first, width: 360)
            if let data = img.jpegData(compressionQuality: 0.8) { try? data.write(to: Store.thumb(id), options: .atomic) }
            await MainActor.run { self.thumbVersion[id, default: 0] += 1 }
        }
    }
}
