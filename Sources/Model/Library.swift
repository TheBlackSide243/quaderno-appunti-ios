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

    static func removePageFiles(_ nb: UUID, _ page: UUID) {
        for item in loadItems(nb, page) where item.kind == .image {
            if let name = item.image { try? FileManager.default.removeItem(at: image(nb, name)) }
        }
        try? FileManager.default.removeItem(at: drawing(nb, page))
        try? FileManager.default.removeItem(at: items(nb, page))
    }

    /// Saves a picture for a page, scaled down to at most 2400 px, and returns its file name.
    static func saveImage(_ img: UIImage, _ nb: UUID) -> (String, CGSize)? {
        ensureDirs(nb)
        let maxSide: CGFloat = 2400
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height))
        let target = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
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
    }

    private func saveFolders() {
        if let data = try? Store.encoder.encode(folders) { try? data.write(to: Store.foldersFile, options: .atomic) }
    }

    // MARK: Notebooks

    @discardableResult
    func create(title: String, cover: Int, template: PageTemplate, paper: Paper, format: PageFormat, folder: UUID?) -> Notebook {
        let name = title.trimmingCharacters(in: .whitespaces)
        let nb = Notebook(title: name.isEmpty ? "Senza titolo" : name, cover: cover, paper: paper, folderID: folder,
                          pages: [PageInfo(template: template, size: format.size)])
        save(nb)
        refreshThumb(nb.id)
        return nb
    }

    /// Copies a PDF into a new notebook, one page per PDF page.
    func importPDF(_ url: URL, folder: UUID?) -> Notebook? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            error = "Il file non è un PDF leggibile."
            return nil
        }
        if doc.isLocked {
            error = "Il PDF è protetto da password: sbloccalo prima di importarlo."
            return nil
        }
        var nb = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: nil, folderID: folder, pages: [])
        nb.hasPDF = true
        Store.ensureDirs(nb.id)
        do {
            try FileManager.default.copyItem(at: url, to: Store.pdf(nb.id))
        } catch {
            self.error = "Non riesco a copiare il PDF: \(error.localizedDescription)"
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

    /// Adds the pages of a PDF at the end of an existing notebook.
    func appendPDF(_ url: URL, to id: UUID) -> Notebook? {
        guard var nb = notebook(id) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let incoming = PDFDocument(url: url), incoming.pageCount > 0, !incoming.isLocked else {
            error = "Il file non è un PDF leggibile (o è protetto da password)."
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
            error = "Non riesco a salvare il PDF unito."
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: Store.pdf(id).path) {
                _ = try FileManager.default.replaceItemAt(Store.pdf(id), withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: Store.pdf(id))
            }
        } catch {
            self.error = "Non riesco a salvare il PDF unito: \(error.localizedDescription)"
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
        nb.title += " (copia)"
        nb.created = Date()
        do {
            try FileManager.default.copyItem(at: Store.dir(old), to: Store.dir(nb.id))
        } catch {
            self.error = "Copia non riuscita: \(error.localizedDescription)"
            return
        }
        save(nb)
        Indexer.shared.forget(nb.id)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.dir(id))
        PDFCache.shared.forget(id)
        Indexer.shared.forget(id)
        notebooks.removeAll { $0.id == id }
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
