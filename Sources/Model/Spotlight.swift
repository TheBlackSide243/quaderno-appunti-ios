import CoreSpotlight
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Puts the notebooks and the text of their pages in the iPhone's search (Spotlight): typing a
/// word on the Home Screen finds the page where it was written, and a tap opens it.
/// Everything stays on the device.
final class Spotlight: @unchecked Sendable {
    static let shared = Spotlight()
    static let enabledKey = "spotlight.enabled"
    private let queue = DispatchQueue(label: "appunti.spotlight", qos: .utility)
    private var pending: [UUID: Notebook] = [:]
    private var scheduled = false

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Updates a notebook a few seconds from now (its title, its pages' text).
    func schedule(_ nb: Notebook) {
        guard Self.enabled, nb.deletedAt == nil else { return }
        queue.async {
            self.pending[nb.id] = nb
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 5) { self.drain() }
        }
    }

    func reindexAll(_ list: [Notebook]) {
        guard Self.enabled else { return }
        queue.async {
            CSSearchableIndex.default().deleteAllSearchableItems { _ in
                self.queue.async {
                    for nb in list { self.pending[nb.id] = nb }
                    self.drain()
                }
            }
        }
    }

    func remove(_ id: UUID) {
        queue.async { self.pending[id] = nil }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [id.uuidString])
    }

    func removeAll() {
        queue.async { self.pending = [:] }
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    private func drain() {
        scheduled = false
        let work = Array(pending.values)
        pending = [:]
        guard Self.enabled, CSSearchableIndex.isIndexingAvailable(), !work.isEmpty else { return }
        var items: [CSSearchableItem] = []
        for nb in work {
            items.append(contentsOf: autoreleasepool { Self.items(nb) })
        }
        let domains = work.map(\.id.uuidString)
        // the old pages of these notebooks go first: pages may have been deleted or moved
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domains) { _ in
            CSSearchableIndex.default().indexSearchableItems(items)
        }
    }

    private static func items(_ nb: Notebook) -> [CSSearchableItem] {
        let index = (try? Data(contentsOf: Store.index(nb.id))).flatMap { try? Store.decoder.decode([String: PageText].self, from: $0) } ?? [:]
        let domain = nb.id.uuidString
        var out: [CSSearchableItem] = []

        let book = CSSearchableItemAttributeSet(contentType: .content)
        book.title = nb.title
        let pages = nb.pages.count == 1 ? String(localized: "1 pagina") : String(localized: "\(nb.pages.count) pagine")
        book.contentDescription = ([pages] + nb.tagList).joined(separator: " · ")
        book.keywords = nb.tagList
        book.contentModificationDate = nb.modified
        if let data = try? Data(contentsOf: Store.thumb(nb.id)) { book.thumbnailData = data }
        out.append(CSSearchableItem(uniqueIdentifier: "nb:\(nb.id.uuidString)", domainIdentifier: domain, attributeSet: book))

        for (n, page) in nb.pages.enumerated() {
            guard let text = index[page.id.uuidString]?.all.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = String(localized: "\(nb.title) · pagina \(n + 1)")
            a.contentDescription = String(text.replacingOccurrences(of: "\n", with: " ").prefix(240))
            a.textContent = text
            a.keywords = nb.tagList
            a.contentModificationDate = nb.modified
            out.append(CSSearchableItem(uniqueIdentifier: "pg:\(nb.id.uuidString):\(page.id.uuidString)", domainIdentifier: domain, attributeSet: a))
        }
        return out
    }

    /// The notebook and page of a Spotlight result.
    static func target(_ identifier: String) -> (notebook: UUID, page: UUID?)? {
        let parts = identifier.split(separator: ":").map(String.init)
        guard parts.count >= 2, let nb = UUID(uuidString: parts[1]) else { return nil }
        return (nb, parts.count >= 3 ? UUID(uuidString: parts[2]) : nil)
    }
}

/// Notebooks deleted on this device, so syncing removes them on the others too instead of
/// bringing them back. Kept in Documents/eliminati.json as id → when.
enum Tombstones {
    static let file = Store.documents.appendingPathComponent("eliminati.json")
    private static let lock = NSLock()

    static func load() -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: file)).flatMap { try? Store.decoder.decode([String: Date].self, from: $0) } ?? [:]
    }

    static func save(_ t: [String: Date]) {
        lock.lock(); defer { lock.unlock() }
        // older than 60 days: every device has seen them by now
        let limit = Date().addingTimeInterval(-60 * 86_400)
        let kept = t.filter { $0.value > limit }
        if let data = try? Store.encoder.encode(kept) { try? data.write(to: file, options: .atomic) }
    }

    static func add(_ id: UUID) {
        var t = load()
        t[id.uuidString] = Date()
        save(t)
    }

    static func remove(_ id: UUID) {
        var t = load()
        t[id.uuidString] = nil
        save(t)
    }
}
