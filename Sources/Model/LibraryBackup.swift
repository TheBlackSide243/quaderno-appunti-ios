import Foundation

/// One file with the whole library: every notebook with its pages, pictures, PDFs and
/// recordings, the folders, the stickers and custom papers made here and the study log. It is
/// a plain zip, kept wherever the user wants (Files, iCloud Drive, a computer).
///
/// Putting a copy back never replaces anything: notebooks already on the shelf (or in the trash)
/// stay as they are, and only what is missing comes back.
enum LibraryBackup {
    /// What the archive says about itself (copia.json at its top).
    struct Manifest: Codable {
        var app = "Quaderno Appunti"
        var format = 1
        var created: Date
        var notebooks: Int
        var version: String?
    }

    /// What a restore did.
    struct Summary: Equatable, Sendable {
        var restored: [UUID] = []
        var skipped = 0
        var folders = 0
        var stickers = 0
        var papers = 0
    }

    enum Failure: LocalizedError {
        case notABackup
        case empty
        var errorDescription: String? {
            switch self {
            case .notABackup: return String(localized: "Il file non è una copia di Quaderno Appunti.")
            case .empty: return String(localized: "Non ci sono quaderni da copiare.")
            }
        }
    }

    static let manifestName = "copia.json"
    /// What goes into the copy, relative to Documents. The trash, the page history and the
    /// list of deleted notebooks stay on the device.
    static let parts = ["Quaderni", "cartelle.json", "Adesivi", "Carte", "studio.json"]

    // MARK: Making a copy

    /// Writes the copy into `folder` (the temporary folder by default) and returns it.
    static func export(from documents: URL = Store.documents, to folder: URL = FileManager.default.temporaryDirectory,
                       now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let shelf = documents.appendingPathComponent("Quaderni", isDirectory: true)
        let notebooks = ((try? fm.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && fm.fileExists(atPath: $0.appendingPathComponent("notebook.json").path) }
        guard !notebooks.isEmpty else { throw Failure.empty }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = folder.appendingPathComponent("Quaderno Appunti \(f.string(from: now)).zip")
        try? fm.removeItem(at: url)
        let zip = try ZipWriter(url: url)
        do {
            let manifest = Manifest(created: now, notebooks: notebooks.count,
                                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            try zip.add(manifestName, data: try Store.encoder.encode(manifest), modified: now)
            for part in parts {
                let src = documents.appendingPathComponent(part)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    for rel in files(in: src).sorted() {
                        try zip.add("\(part)/\(rel)", file: src.appendingPathComponent(rel))
                    }
                } else {
                    try zip.add(part, file: src)
                }
            }
            try zip.finish()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Relative paths of the files under `dir`, without hidden files, files still only in
    /// iCloud and the half-written PDF of an import.
    static func files(in dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = dir.standardizedFileURL.path
        var out: [String] = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rel.components(separatedBy: "/")
            if parts.contains(where: { $0.hasPrefix(".") }) || parts.last == "source-new.pdf" { continue }
            out.append(rel)
        }
        return out
    }

    // MARK: Putting a copy back

    /// Reads the manifest of a copy, or nil when the file is not one.
    static func manifest(_ url: URL) -> Manifest? {
        guard let zip = try? ZipReader(url: url), let found = layout(zip),
              let e = zip.entries.first(where: { $0.name == found.0 + manifestName }),
              let data = try? zip.data(e) else { return nil }
        return try? Store.decoder.decode(Manifest.self, from: data)
    }

    /// Where the library sits in the archive (a copy zipped again by hand may be inside a
    /// folder) and its entries by path below that.
    private static func layout(_ zip: ZipReader) -> (String, [String: ZipReader.Entry])? {
        var prefix: String?
        if let m = zip.entries.first(where: { $0.name == manifestName || $0.name.hasSuffix("/" + manifestName) }) {
            prefix = String(m.name.dropLast(manifestName.count))
        } else if let q = zip.entries.first(where: { $0.name.hasPrefix("Quaderni/") || $0.name.contains("/Quaderni/") }) {
            prefix = String(q.name[..<q.name.range(of: "Quaderni/")!.lowerBound])
        }
        guard let prefix else { return nil }
        var map: [String: ZipReader.Entry] = [:]
        for e in zip.entries where e.name.hasPrefix(prefix) && !e.name.hasSuffix("/") {
            let rel = String(e.name.dropFirst(prefix.count))
            // nothing may land outside the app's folders
            let parts = rel.components(separatedBy: "/")
            guard !rel.hasPrefix("/"), !parts.contains(".."), !parts.contains(""), !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            map[rel] = e
        }
        return (prefix, map)
    }

    /// Puts back what is missing here: notebooks, folders, stickers, papers and study days.
    /// Works on the files only; the caller reloads the library afterwards.
    static func restore(_ url: URL, into documents: URL = Store.documents, trash: URL = Store.trash,
                        tombstones: [String: Date] = [:], now: Date = Date()) throws -> Summary {
        let zip = try ZipReader(url: url)
        guard let map = layout(zip)?.1, map.keys.contains(where: { $0.hasPrefix("Quaderni/") }) else { throw Failure.notABackup }
        let fm = FileManager.default
        var summary = Summary()

        // notebooks
        var byNotebook: [UUID: [(String, ZipReader.Entry)]] = [:]
        for (rel, e) in map where rel.hasPrefix("Quaderni/") {
            let parts = rel.components(separatedBy: "/")
            guard parts.count >= 3, let id = UUID(uuidString: parts[1]) else { continue }
            byNotebook[id, default: []].append((parts.dropFirst(2).joined(separator: "/"), e))
        }
        let shelf = documents.appendingPathComponent("Quaderni", isDirectory: true)
        try fm.createDirectory(at: shelf, withIntermediateDirectories: true)
        for (id, list) in byNotebook.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let dst = shelf.appendingPathComponent(id.uuidString, isDirectory: true)
            let inTrash = trash.appendingPathComponent(id.uuidString, isDirectory: true)
            if fm.fileExists(atPath: dst.path) || fm.fileExists(atPath: inTrash.path) {
                summary.skipped += 1
                continue
            }
            guard let metaEntry = list.first(where: { $0.0 == "notebook.json" })?.1,
                  var nb = try? Store.decoder.decode(Notebook.self, from: zip.data(metaEntry)) else { continue }
            // written next to the shelf first, then moved in one step: a half restored notebook never shows
            let staging = shelf.appendingPathComponent(".ripristino-\(id.uuidString)", isDirectory: true)
            try? fm.removeItem(at: staging)
            do {
                for (rel, e) in list {
                    let file = staging.appendingPathComponent(rel)
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try zip.data(e).write(to: file)
                }
                nb.id = id
                nb.deletedAt = nil
                // deleted on some device after its last change: newer than that, or syncing deletes it again
                if let when = tombstones[id.uuidString], nb.modified <= when { nb.modified = now }
                try Store.encoder.encode(nb).write(to: staging.appendingPathComponent("notebook.json"), options: .atomic)
                try fm.moveItem(at: staging, to: dst)
                summary.restored.append(id)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }

        // folders the notebooks may be in
        if let e = map["cartelle.json"], let theirs = try? Store.decoder.decode([Folder].self, from: zip.data(e)) {
            let file = documents.appendingPathComponent("cartelle.json")
            var mine = (try? Data(contentsOf: file)).flatMap { try? Store.decoder.decode([Folder].self, from: $0) } ?? []
            for f in theirs where !mine.contains(where: { $0.id == f.id }) {
                mine.append(f)
                summary.folders += 1
            }
            if summary.folders > 0 { try Store.encoder.encode(mine).write(to: file, options: .atomic) }
        }

        summary.stickers = try mergeList(zip, map, folder: "Adesivi", list: "adesivi.json", documents: documents)
        summary.papers = try mergeList(zip, map, folder: "Carte", list: "carte.json", documents: documents)

        // study days: per day the larger count, so restoring twice counts nothing twice
        if let e = map["studio.json"], let theirs = try? JSONDecoder().decode([String: StudyLog.Day].self, from: zip.data(e)) {
            let file = documents.appendingPathComponent("studio.json")
            var mine = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: StudyLog.Day].self, from: $0) } ?? [:]
            let before = mine
            for (k, d) in theirs {
                var m = mine[k] ?? StudyLog.Day()
                m.reviews = max(m.reviews, d.reviews)
                m.right = max(m.right, d.right)
                m.focus = max(m.focus, d.focus)
                mine[k] = m
            }
            if mine != before { try JSONEncoder().encode(mine).write(to: file, options: .atomic) }
        }
        return summary
    }

    /// An entry of the list of stickers or papers (both are kept the same way).
    private struct ListEntry: Codable {
        var id: UUID
        var file: String
        var created: Date
    }

    /// Adds the stickers or papers of the copy that are not here, files and list.
    private static func mergeList(_ zip: ZipReader, _ map: [String: ZipReader.Entry], folder: String, list: String,
                                  documents: URL) throws -> Int {
        guard let e = map["\(folder)/\(list)"], let theirs = try? Store.decoder.decode([ListEntry].self, from: zip.data(e)) else { return 0 }
        let fm = FileManager.default
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        let listFile = dir.appendingPathComponent(list)
        var mine = (try? Data(contentsOf: listFile)).flatMap { try? Store.decoder.decode([ListEntry].self, from: $0) } ?? []
        var added = 0
        for s in theirs where !mine.contains(where: { $0.id == s.id }) {
            guard !s.file.contains("/"), let f = map["\(folder)/\(s.file)"] else { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(s.file)
            if !fm.fileExists(atPath: dst.path) { try zip.data(f).write(to: dst, options: .atomic) }
            mine.append(s)
            added += 1
        }
        if added > 0 {
            mine.sort { $0.created > $1.created }
            try Store.encoder.encode(mine).write(to: listFile, options: .atomic)
        }
        return added
    }
}
