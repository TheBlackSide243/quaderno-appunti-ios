import Foundation
import Observation
import UIKit

/// Copies the notebooks into a folder the user picks in iCloud Drive (or any other provider in
/// Files), and brings them back from there on another device.
///
/// Real iCloud sync needs an iCloud container, which only apps signed by a paid Apple developer
/// account get; a sideloaded app cannot have one. A folder picked in Files works for every app:
/// the app keeps a bookmark to it and iCloud Drive uploads what is written there.
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
            self.error = "Non riesco a ricordare la cartella: \(error.localizedDescription)"
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
        message = nil
    }

    // MARK: Saving

    /// Saves now when automatic saving is on (the app is going to the background).
    func backupIfAuto(_ library: Library) {
        guard auto, configured else { return }
        autoTask?.cancel()
        backupNow(library)
    }

    /// Saves a few seconds after a notebook is closed.
    func scheduleAuto(_ library: Library) {
        guard auto, configured else { return }
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.backupNow(library)
        }
    }

    func backupNow(_ library: Library) {
        guard !running, let url = resolve() else { return }
        running = true
        error = nil
        let ids = library.notebooks.map(\.id)
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Salvataggio su iCloud Drive") { [weak self] in
            self?.endBackgroundTask()
        }
        Task.detached(priority: .utility) {
            let result = Self.mirror(to: url, notebooks: ids)
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let n):
                    self.lastBackup = Date()
                    UserDefaults.standard.set(self.lastBackup, forKey: "backup.last")
                    self.message = n == 0 ? "Già tutto salvato." : "Salvati \(n) file."
                case .failure(let e):
                    self.error = "Salvataggio non riuscito: \(e.localizedDescription)"
                }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// Brings back every notebook of the folder that is missing here or newer there.
    func restore(_ library: Library) {
        guard !running, let url = resolve() else { return }
        running = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Self.restore(from: url)
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let n):
                    library.load()
                    for nb in library.notebooks { PDFCache.shared.forget(nb.id); library.refreshThumb(nb.id) }
                    Indexer.shared.catchUp(library.notebooks)
                    self.message = n == 0 ? "Niente di nuovo da ripristinare." : "Ripristinati \(n) file."
                case .failure(let e):
                    self.error = "Ripristino non riuscito: \(e.localizedDescription)"
                }
            }
        }
    }

    // MARK: File copies (off the main thread)

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Relative paths of the regular files under `dir`.
    private nonisolated static func files(in dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = dir.standardizedFileURL.path
        var out: [String] = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            out.append(String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return out
    }

    /// Copies `src` over `dst` when `dst` is missing or older. Returns true if it copied.
    private nonisolated static func copyIfNewer(_ src: URL, _ dst: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path), modified(src) <= modified(dst).addingTimeInterval(1) { return false }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return true
    }

    private nonisolated static func mirror(to root: URL, notebooks: [UUID]) -> Result<Int, Error> {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var copied = 0
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordError) { base in
            do {
                let shelf = base.appendingPathComponent("Quaderni", isDirectory: true)
                try fm.createDirectory(at: shelf, withIntermediateDirectories: true)
                for id in notebooks {
                    let src = Store.dir(id), dst = shelf.appendingPathComponent(id.uuidString, isDirectory: true)
                    let list = files(in: src)
                    for rel in list {
                        if try copyIfNewer(src.appendingPathComponent(rel), dst.appendingPathComponent(rel)) { copied += 1 }
                    }
                    // pages deleted here are deleted there too
                    let keep = Set(list)
                    for rel in files(in: dst) where !keep.contains(rel) && !(rel as NSString).lastPathComponent.hasPrefix(".") {
                        try? fm.removeItem(at: dst.appendingPathComponent(rel))
                    }
                }
                // notebooks deleted here go too (never when this device has none, e.g. a fresh install)
                if !notebooks.isEmpty {
                    let known = Set(notebooks.map(\.uuidString))
                    for d in (try? fm.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil)) ?? []
                    where UUID(uuidString: d.lastPathComponent) != nil && !known.contains(d.lastPathComponent) {
                        try? fm.removeItem(at: d)
                    }
                }
                if fm.fileExists(atPath: Store.foldersFile.path),
                   try copyIfNewer(Store.foldersFile, base.appendingPathComponent("cartelle.json")) {
                    copied += 1
                }
            } catch {
                failure = error
            }
        }
        if let e = coordError ?? failure { return .failure(e) }
        return .success(copied)
    }

    /// Reads a file of the provider, downloading it first if it is only in the cloud.
    private nonisolated static func fetch(_ url: URL, into dst: URL) throws -> Bool {
        var result: Result<Bool, Error> = .success(false)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { real in
            result = Result { try copyIfNewer(real, dst) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    private nonisolated static func restore(from root: URL) -> Result<Int, Error> {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let shelf = root.appendingPathComponent("Quaderni", isDirectory: true)
        guard fm.fileExists(atPath: shelf.path) else {
            return .failure(NSError(domain: "Appunti", code: 1, userInfo: [NSLocalizedDescriptionKey: "nella cartella non c'è nessun salvataggio di Appunti."]))
        }
        var copied = 0
        do {
            try fm.createDirectory(at: Store.root, withIntermediateDirectories: true)
            for d in (try? fm.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil)) ?? [] {
                guard UUID(uuidString: d.lastPathComponent) != nil else { continue }
                let dst = Store.dir(UUID(uuidString: d.lastPathComponent)!)
                for rel in files(in: d) {
                    // Files only in the cloud show up as ".name.icloud" until downloaded.
                    var parts = rel.components(separatedBy: "/")
                    var name = parts.removeLast()
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        name = String(name.dropFirst().dropLast(".icloud".count))
                    } else if name.hasPrefix(".") {
                        continue
                    }
                    let clean = (parts + [name]).joined(separator: "/")
                    if try fetch(d.appendingPathComponent(clean), into: dst.appendingPathComponent(clean)) { copied += 1 }
                }
            }
            let remoteFolders = root.appendingPathComponent("cartelle.json")
            if fm.fileExists(atPath: remoteFolders.path) || fm.fileExists(atPath: root.appendingPathComponent(".cartelle.json.icloud").path) {
                let tmp = fm.temporaryDirectory.appendingPathComponent("cartelle-remote.json")
                try? fm.removeItem(at: tmp)
                _ = try fetch(remoteFolders, into: tmp)
                let decode = { (u: URL) in (try? Data(contentsOf: u)).flatMap { try? Store.decoder.decode([Folder].self, from: $0) } ?? [] }
                var merged = decode(Store.foldersFile)
                for f in decode(tmp) where !merged.contains(where: { $0.id == f.id }) { merged.append(f) }
                try Store.encoder.encode(merged).write(to: Store.foldersFile, options: .atomic)
            }
        } catch {
            return .failure(error)
        }
        return .success(copied)
    }
}
