import Foundation
import Observation
import UIKit

/// Notebooks shared with other people through a folder shared in iCloud Drive (Files → Share →
/// Collaborate). Each person picks the same folder in the app; the notebook is kept in sync with
/// it every few seconds while it is open, and when the shelf comes back on screen.
///
/// Unlike the backup sync, both sides may change the same notebook at once: the list of pages is
/// merged (pages added on either side stay, pages deleted on either side go), and each page file
/// follows its newest copy. Two people writing on the same page at the same moment: the last save
/// wins for that page.
@MainActor
@Observable
final class SharedNotebooks {
    static let shared = SharedNotebooks()

    /// Notebook id → bookmark of its shared folder.
    private var links: [String: Data]
    private(set) var syncing: Set<UUID> = []
    private(set) var lastSync: [UUID: Date] = [:]
    var error: String?

    private static let key = "shared.links"

    private init() {
        links = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data]) ?? [:]
    }

    func isShared(_ id: UUID) -> Bool { links[id.uuidString] != nil }
    var sharedIDs: [UUID] { links.keys.compactMap(UUID.init(uuidString:)) }

    func folderName(_ id: UUID) -> String? { folder(id)?.lastPathComponent }

    private func persist() { UserDefaults.standard.set(links, forKey: Self.key) }

    private func folder(_ id: UUID) -> URL? {
        guard let data = links[id.uuidString] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData() { links[id.uuidString] = fresh; persist() }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    private func bookmark(_ url: URL) -> Data? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: Sharing and joining

    /// Shares a notebook through a folder: its files are copied there.
    func share(_ nb: Notebook, in url: URL, library: Library) async {
        guard let data = bookmark(url) else {
            error = String(localized: "Non riesco a usare quella cartella.")
            return
        }
        links[nb.id.uuidString] = data
        persist()
        _ = await sync(nb.id, library: library)
    }

    func stopSharing(_ id: UUID) {
        links[id.uuidString] = nil
        lastSync[id] = nil
        persist()
    }

    /// Opens the notebooks found in a shared folder: they are copied here and kept in sync.
    @discardableResult
    func join(_ url: URL, library: Library) async -> Int {
        guard let data = bookmark(url) else {
            error = String(localized: "Non riesco a usare quella cartella.")
            return 0
        }
        let ids = await Task.detached(priority: .userInitiated) { Self.notebooks(in: url) }.value
        guard !ids.isEmpty else {
            error = String(localized: "In questa cartella non c'è ancora nessun quaderno condiviso. Chi lo condivide deve sceglierla per primo.")
            return 0
        }
        for id in ids {
            links[id.uuidString] = data
        }
        persist()
        for id in ids { _ = await sync(id, library: library) }
        return ids.count
    }

    private nonisolated static func notebooks(in root: URL) -> [UUID] {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        var out: [UUID] = []
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordError) { base in
            for d in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                guard let id = UUID(uuidString: d.lastPathComponent) else { continue }
                let meta = d.appendingPathComponent("notebook.json")
                let placeholder = d.appendingPathComponent(".notebook.json.icloud")
                if FileManager.default.fileExists(atPath: meta.path) || FileManager.default.fileExists(atPath: placeholder.path) { out.append(id) }
            }
        }
        return out
    }

    // MARK: Syncing

    /// Syncs every shared notebook that is not open in an editor.
    func syncAll(_ library: Library) async {
        for id in sharedIDs where !library.isOpen(id) {
            _ = await sync(id, library: library)
        }
    }

    /// Brings the other people's changes and sends ours. True when something arrived.
    func sync(_ id: UUID, library: Library) async -> Bool {
        guard let url = folder(id), !syncing.contains(id) else { return false }
        syncing.insert(id)
        defer { syncing.remove(id) }
        let result = await Task.detached(priority: .utility) { Self.syncOne(root: url, id: id) }.value
        switch result {
        case .success(let changed):
            lastSync[id] = Date()
            error = nil
            if changed {
                library.reload(id)
                PDFCache.shared.forget(id)
                Indexer.shared.catchUp(library.notebooks.filter { $0.id == id })
            }
            return changed
        case .failure(let e):
            error = String(localized: "Sincronizzazione del quaderno condiviso non riuscita: \(e.localizedDescription)")
            return false
        }
    }

    // MARK: File work (off the main thread)

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private nonisolated static func files(in dir: URL) -> Set<String> {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = dir.standardizedFileURL.path
        var out: Set<String> = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            var parts = String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")
            var name = parts.removeLast()
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            } else if name.hasPrefix(".") || name == "source-new.pdf" || name == "thumb.jpg" || name == "index.json" {
                continue
            }
            out.insert((parts + [name]).joined(separator: "/"))
        }
        return out
    }

    private nonisolated static func copy(_ src: URL, _ dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".sync-\(UUID().uuidString)")
        try fm.copyItem(at: src, to: tmp)
        try? fm.setAttributes([.modificationDate: modified(src)], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dst.path) {
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dst)
        }
    }

    private nonisolated static func pull(_ remote: URL, _ local: URL) throws {
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: remote, options: [], error: &coordError) { real in
            do { try copy(real, local) } catch { failure = error }
        }
        if let e = coordError ?? failure { throw e }
    }

    private nonisolated static func read(_ url: URL) -> Notebook? {
        var value: Notebook?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { real in
            value = (try? Data(contentsOf: real)).flatMap { try? Store.decoder.decode(Notebook.self, from: $0) }
        }
        return value
    }

    /// The two descriptions of a notebook made one: the newer one for the title and the rest,
    /// the pages of both minus the ones deleted on either side.
    nonisolated static func merge(_ mine: Notebook, _ theirs: Notebook) -> Notebook {
        let mineNewer = mine.modified >= theirs.modified
        var out = mineNewer ? mine : theirs
        let other = mineNewer ? theirs : mine
        let deleted = Set((mine.deletedPages ?? []) + (theirs.deletedPages ?? []))
        out.deletedPages = deleted.isEmpty ? nil : Array(deleted).sorted { $0.uuidString < $1.uuidString }
        out.pages = mergePages(out.pages, other.pages, deleted: deleted)
        if out.pages.isEmpty { out.pages = mineNewer ? mine.pages : theirs.pages }
        // flashcards and recordings of both
        func union<T: Identifiable>(_ a: [T]?, _ b: [T]?) -> [T]? where T.ID == UUID {
            var list = a ?? []
            for x in b ?? [] where !list.contains(where: { $0.id == x.id }) { list.append(x) }
            return list.isEmpty ? nil : list
        }
        out.cards = union(out.cards, other.cards)?.filter { c in out.pages.contains { $0.id == c.page } }
        if out.cards?.isEmpty == true { out.cards = nil }
        out.recordings = union(out.recordings, other.recordings)
        out.modified = max(mine.modified, theirs.modified)
        // where each person was is their own business
        out.lastPage = mine.lastPage
        out.folderID = mine.folderID
        out.favorite = mine.favorite
        out.deletedAt = nil
        return out
    }

    /// The pages of `a`, then the ones only in `b`, each after the page it follows in `b`.
    nonisolated static func mergePages(_ a: [PageInfo], _ b: [PageInfo], deleted: Set<UUID>) -> [PageInfo] {
        var out = a.filter { !deleted.contains($0.id) }
        for (i, p) in b.enumerated() where !deleted.contains(p.id) && !out.contains(where: { $0.id == p.id }) {
            var at = 0
            var j = i - 1
            while j >= 0 {
                if let k = out.firstIndex(where: { $0.id == b[j].id }) { at = k + 1; break }
                j -= 1
            }
            out.insert(p, at: at)
        }
        return out
    }

    private nonisolated static func syncOne(root: URL, id: UUID) -> Result<Bool, Error> {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var changed = false
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordError) { base in
            do {
                let here = Store.dir(id), there = base.appendingPathComponent(id.uuidString, isDirectory: true)
                try fm.createDirectory(at: there, withIntermediateDirectories: true)
                let mine = (try? Data(contentsOf: Store.meta(id))).flatMap { try? Store.decoder.decode(Notebook.self, from: $0) }
                let theirs = read(there.appendingPathComponent("notebook.json"))
                guard mine != nil || theirs != nil else { return }

                // every file but the description: the newest copy wins, both ways
                let hereFiles = mine == nil ? [] : files(in: here)
                let thereFiles = files(in: there)
                for rel in hereFiles.union(thereFiles) where rel != "notebook.json" {
                    let h = here.appendingPathComponent(rel), t = there.appendingPathComponent(rel)
                    let inHere = hereFiles.contains(rel), inThere = thereFiles.contains(rel)
                    if inHere && !inThere {
                        try copy(h, t)
                    } else if inThere && !inHere {
                        try pull(t, h)
                        changed = true
                    } else {
                        let dh = modified(h), dt = fm.fileExists(atPath: t.path) ? modified(t) : .distantPast
                        if dh > dt.addingTimeInterval(1) {
                            try copy(h, t)
                        } else if dt > dh.addingTimeInterval(1) {
                            try pull(t, h)
                            changed = true
                        }
                    }
                }

                // the description, merged
                var merged: Notebook
                if let mine, let theirs {
                    merged = merge(mine, theirs)
                } else {
                    merged = (mine ?? theirs)!
                    if mine == nil {
                        merged.folderID = nil
                        merged.favorite = false
                    }
                }
                let data = try Store.encoder.encode(merged)
                if mine.map({ (try? Store.encoder.encode($0)) != data }) ?? true {
                    Store.ensureDirs(id)
                    try data.write(to: Store.meta(id), options: .atomic)
                    changed = true
                }
                if theirs.map({ (try? Store.encoder.encode($0)) != data }) ?? true {
                    try data.write(to: there.appendingPathComponent("notebook.json"), options: .atomic)
                }

                // pages deleted by someone go on both sides
                for pid in merged.deletedPages ?? [] {
                    for dir in [here, there] {
                        let pages = dir.appendingPathComponent("pages")
                        for name in (try? fm.contentsOfDirectory(atPath: pages.path)) ?? [] where name.hasPrefix(pid.uuidString) {
                            try? fm.removeItem(at: pages.appendingPathComponent(name))
                        }
                    }
                }
            } catch {
                failure = error
            }
        }
        if let e = coordError ?? failure { return .failure(e) }
        return .success(changed)
    }
}
