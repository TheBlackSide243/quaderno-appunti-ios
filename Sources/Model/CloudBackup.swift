import Foundation
import Observation
import UIKit

/// Keeps the notebooks in sync between devices through a folder the user picks in iCloud Drive
/// (or any other provider in Files).
///
/// Real iCloud sync needs an iCloud container, which only apps signed by a paid Apple developer
/// account get; a sideloaded app cannot have one. A folder picked in Files works for every app:
/// the app keeps a bookmark to it and iCloud Drive carries what is written there to the other
/// devices, which pick the same folder.
///
/// Each file goes the way of its newest copy, so two devices can write different pages of the
/// same notebook. The notebook's description (its list of pages) comes from the device that
/// changed it last. Notebooks deleted on one device are deleted on the others (eliminati.json).
@MainActor
@Observable
final class CloudBackup {
    private(set) var folderName: String?
    var auto: Bool {
        didSet { UserDefaults.standard.set(auto, forKey: "backup.auto") }
    }
    private(set) var lastBackup: Date?
    private(set) var running = false
    var message: String?
    var error: String?

    private static let bookmarkKey = "backup.bookmark"
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var bgTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var again = false

    init() {
        auto = UserDefaults.standard.object(forKey: "backup.auto") as? Bool ?? true
        lastBackup = UserDefaults.standard.object(forKey: "backup.last") as? Date
        folderName = resolve()?.lastPathComponent
    }

    var configured: Bool { folderName != nil }

    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    /// Remembers the folder picked in Files.
    func choose(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            folderName = url.lastPathComponent
            error = nil
            message = nil
        } catch {
            self.error = String(localized: "Non riesco a ricordare la cartella: \(error.localizedDescription)")
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
        message = nil
    }

    // MARK: Syncing

    /// Syncs now when automatic sync is on (the app opens or goes to the background).
    func backupIfAuto(_ library: Library, open: UUID? = nil) {
        guard auto, configured else { return }
        autoTask?.cancel()
        syncNow(library, open: open)
    }

    /// Syncs a few seconds after a notebook is closed.
    func scheduleAuto(_ library: Library) {
        guard auto, configured else { return }
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.syncNow(library)
        }
    }

    /// Sends what changed here and brings what changed on the other devices. The notebook open
    /// in the editor (`open`) is only sent, never replaced while it is being written.
    func syncNow(_ library: Library, open: UUID? = nil) {
        guard let url = resolve() else { return }
        guard !running else { again = true; return }
        running = true
        error = nil
        let local = library.notebooks
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Sincronizzazione iCloud Drive") { [weak self] in
            self?.endBackgroundTask()
        }
        Task.detached(priority: .utility) {
            let result = Self.sync(root: url, local: local, open: open)
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let r):
                    self.lastBackup = Date()
                    UserDefaults.standard.set(self.lastBackup, forKey: "backup.last")
                    self.apply(r, to: library)
                    if r.sent == 0 && r.received == 0 && r.removed.isEmpty {
                        self.message = String(localized: "Tutto sincronizzato.")
                    } else {
                        self.message = String(localized: "Sincronizzato: \(r.sent) file inviati, \(r.received) ricevuti.")
                    }
                case .failure(let e):
                    self.error = String(localized: "Sincronizzazione non riuscita: \(e.localizedDescription)")
                }
                self.endBackgroundTask()
                if self.again {
                    self.again = false
                    self.syncNow(library)
                }
            }
        }
    }

    /// Kept for the button of older screens: a sync does both ways.
    func backupNow(_ library: Library) { syncNow(library) }

    private func apply(_ r: SyncReport, to library: Library) {
        if r.received > 0 || !r.changed.isEmpty {
            library.load()
            for id in r.changed {
                PDFCache.shared.forget(id)
                library.refreshThumb(id)
            }
            Indexer.shared.catchUp(library.notebooks.filter { r.changed.contains($0.id) })
        }
        for id in r.removed where library.notebook(id) != nil {
            library.delete(id)
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: File work (off the main thread)

    struct SyncReport: Sendable {
        var sent = 0
        var received = 0
        /// Notebooks whose files changed here.
        var changed: Set<UUID> = []
        /// Notebooks deleted on another device.
        var removed: [UUID] = []
    }

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Relative paths of the regular files under `dir`; files only in the cloud (".name.icloud")
    /// are listed by their real name.
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
            } else if name.hasPrefix(".") || name == "source-new.pdf" {
                continue
            }
            out.insert((parts + [name]).joined(separator: "/"))
        }
        return out
    }

    /// Copies a file keeping its modification date, so the next sync sees both copies as equal.
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

    /// Reads a file of the provider (downloading it if it is only in the cloud) and copies it here.
    private nonisolated static func pull(_ remote: URL, _ local: URL) throws {
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: remote, options: [], error: &coordError) { real in
            do { try copy(real, local) } catch { failure = error }
        }
        if let e = coordError ?? failure { throw e }
    }

    /// Decodes a JSON file of the provider, downloading it first if needed.
    private nonisolated static func readRemote<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        var value: T?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { real in
            value = (try? Data(contentsOf: real)).flatMap { try? Store.decoder.decode(T.self, from: $0) }
        }
        return value
    }

    private nonisolated static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    private nonisolated static func sync(root: URL, local: [Notebook], open: UUID?) -> Result<SyncReport, Error> {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var report = SyncReport()
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordError) { base in
            do {
                let shelf = base.appendingPathComponent("Quaderni", isDirectory: true)
                try fm.createDirectory(at: shelf, withIntermediateDirectories: true)
                try fm.createDirectory(at: Store.root, withIntermediateDirectories: true)

                // deletions known on either side
                var tombs = Tombstones.load()
                let remoteTombsURL = base.appendingPathComponent("eliminati.json")
                if exists(remoteTombsURL), let remote = readRemote([String: Date].self, remoteTombsURL) {
                    for (k, v) in remote where (tombs[k] ?? .distantPast) < v { tombs[k] = v }
                }
                Tombstones.save(tombs)
                try Store.encoder.encode(tombs).write(to: remoteTombsURL, options: .atomic)

                var ids = Set(local.map(\.id))
                for d in (try? fm.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil)) ?? [] {
                    if let id = UUID(uuidString: d.lastPathComponent) { ids.insert(id) }
                }
                let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

                for id in ids {
                    let here = Store.dir(id), there = shelf.appendingPathComponent(id.uuidString, isDirectory: true)
                    let metaThere = there.appendingPathComponent("notebook.json")
                    let mine = localByID[id]
                    let theirs = exists(metaThere) ? readRemote(Notebook.self, metaThere) : nil
                    if mine == nil && theirs == nil { continue }

                    // deleted somewhere after its last change: it goes everywhere
                    if let when = tombs[id.uuidString],
                       (mine?.modified ?? .distantPast) <= when, (theirs?.modified ?? .distantPast) <= when {
                        try? fm.removeItem(at: there)
                        if mine != nil { report.removed.append(id) }
                        continue
                    }

                    let pushOnly = id == open || theirs == nil
                    let pullOnly = mine == nil
                    // the description of the notebook comes from the side changed last
                    let theirsWins = !pushOnly && (pullOnly || (theirs!.modified > mine!.modified.addingTimeInterval(1)))

                    let hereFiles = mine == nil ? [] : files(in: here)
                    let thereFiles = files(in: there)
                    for rel in hereFiles.union(thereFiles) {
                        let h = here.appendingPathComponent(rel), t = there.appendingPathComponent(rel)
                        let inHere = hereFiles.contains(rel), inThere = thereFiles.contains(rel)
                        var send = false, receive = false
                        if rel == "notebook.json" {
                            send = !theirsWins && inHere && (!inThere || mine!.modified > (theirs?.modified ?? .distantPast).addingTimeInterval(1))
                            receive = theirsWins
                        } else if inHere && !inThere {
                            send = true
                        } else if inThere && !inHere {
                            receive = !pushOnly
                        } else {
                            let dh = modified(h), dt = fm.fileExists(atPath: t.path) ? modified(t) : .distantPast
                            if dh > dt.addingTimeInterval(1) { send = true } else if dt > dh.addingTimeInterval(1) { receive = !pushOnly }
                        }
                        if send {
                            try copy(h, t)
                            report.sent += 1
                        } else if receive {
                            try pull(t, h)
                            report.received += 1
                            report.changed.insert(id)
                        }
                    }
                    if !pushOnly { cleanUp(id, here: here, there: there) }
                }

                // folders: every folder known on either side
                let remoteFoldersURL = base.appendingPathComponent("cartelle.json")
                let decode = { (u: URL) in (try? Data(contentsOf: u)).flatMap { try? Store.decoder.decode([Folder].self, from: $0) } ?? [] }
                var merged = decode(Store.foldersFile)
                let before = merged.count
                if exists(remoteFoldersURL) {
                    for f in readRemote([Folder].self, remoteFoldersURL) ?? [] where !merged.contains(where: { $0.id == f.id }) { merged.append(f) }
                }
                let data = try Store.encoder.encode(merged)
                if merged.count != before { try data.write(to: Store.foldersFile, options: .atomic); report.received += 1 }
                if (try? Data(contentsOf: remoteFoldersURL)) != data { try data.write(to: remoteFoldersURL, options: .atomic) }
            } catch {
                failure = error
            }
        }
        if let e = coordError ?? failure { return .failure(e) }
        return .success(report)
    }

    /// After a sync both copies of a notebook have the same pages: files of pages, pictures and
    /// recordings it no longer uses are removed on both sides.
    private nonisolated static func cleanUp(_ id: UUID, here: URL, there: URL) {
        guard let nb = (try? Data(contentsOf: Store.meta(id))).flatMap({ try? Store.decoder.decode(Notebook.self, from: $0) }) else { return }
        let fm = FileManager.default
        // the ink of a page is in one file per layer, named after the layer
        let pages = Set(nb.pages.flatMap { [$0.id.uuidString] + $0.inkLayers.map(\.id.uuidString) })
        var images: Set<String> = []
        for p in nb.pages {
            for item in Store.loadItems(id, p.id) { if let name = item.image { images.insert(name) } }
        }
        let audio = Set((nb.recordings ?? []).map { "\($0.id.uuidString).m4a" })
        for dir in [here, there] {
            for rel in files(in: dir) {
                let parts = rel.components(separatedBy: "/")
                guard parts.count == 2 else { continue }
                let name = parts[1]
                var unused = false
                switch parts[0] {
                case "pages": unused = !pages.contains(String(name.prefix(36)))
                case "images": unused = !images.contains(name)
                case "audio": unused = !audio.contains(name)
                default: break
                }
                if unused { try? fm.removeItem(at: dir.appendingPathComponent(rel)) }
            }
        }
    }
}
