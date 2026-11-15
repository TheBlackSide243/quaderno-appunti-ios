import PencilKit
import UIKit

/// Earlier versions of each page: before a page is saved, a copy of how it was is kept, at most
/// one every ten minutes of writing and the last 30 per page. They stay on this device only (in
/// Application Support), outside the notebook's folder, so they are never synced or shared.
enum PageHistory {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cronologia", isDirectory: true)
    }()
    static let gap: TimeInterval = 600
    static let keep = 30

    struct Version: Identifiable, Hashable {
        let id: String
        let date: Date
        let url: URL
    }

    static func dir(_ nb: UUID, _ page: UUID) -> URL {
        root.appendingPathComponent(nb.uuidString, isDirectory: true).appendingPathComponent(page.uuidString, isDirectory: true)
    }

    /// The versions of a page, newest first.
    static func versions(_ nb: UUID, _ page: UUID) -> [Version] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir(nb, page).path)) ?? []
        return names.compactMap { n -> Version? in
            guard let t = Double(n) else { return nil }
            return Version(id: n, date: Date(timeIntervalSince1970: t), url: dir(nb, page).appendingPathComponent(n, isDirectory: true))
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps a copy of the page as it is on disk now, if the last copy is older than `gap`.
    static func snapshotIfDue(_ nb: Notebook, _ page: PageInfo, now: Date = Date()) {
        if let last = versions(nb.id, page.id).first, now.timeIntervalSince(last.date) < gap { return }
        snapshot(nb, page, now: now)
    }

    /// Copies the files of the page (every layer, the boxes, their pictures and the page's
    /// description) into a new version. A page with nothing on it is not kept.
    @discardableResult
    static func snapshot(_ nb: Notebook, _ page: PageInfo, now: Date = Date()) -> Version? {
        let fm = FileManager.default
        let layers = page.inkLayers.map { Store.drawing(nb.id, $0.id) }.filter { fm.fileExists(atPath: $0.path) }
        let itemsURL = Store.items(nb.id, page.id)
        let hasItems = fm.fileExists(atPath: itemsURL.path)
        guard !layers.isEmpty || hasItems else { return nil }
        let id = String(format: "%.3f", now.timeIntervalSince1970)
        let to = dir(nb.id, page.id).appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for l in layers { try fm.copyItem(at: l, to: to.appendingPathComponent(l.lastPathComponent)) }
            if hasItems {
                try fm.copyItem(at: itemsURL, to: to.appendingPathComponent(itemsURL.lastPathComponent))
                for item in Store.loadItems(nb.id, page.id) {
                    guard let name = item.image else { continue }
                    let src = Store.image(nb.id, name)
                    if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: to.appendingPathComponent("img-" + name)) }
                }
            }
            try Store.encoder.encode(page).write(to: to.appendingPathComponent("page.json"))
        } catch {
            try? fm.removeItem(at: to)
            return nil
        }
        prune(nb.id, page.id)
        return Version(id: id, date: now, url: to)
    }

    static func prune(_ nb: UUID, _ page: UUID) {
        for v in versions(nb, page).dropFirst(keep) { try? FileManager.default.removeItem(at: v.url) }
    }

    /// The description of the page in a version (its layers as they were).
    static func page(_ v: Version) -> PageInfo? {
        (try? Data(contentsOf: v.url.appendingPathComponent("page.json"))).flatMap { try? Store.decoder.decode(PageInfo.self, from: $0) }
    }

    static func ink(_ v: Version, _ page: PageInfo) -> PKDrawing {
        let strokes = page.inkLayers.filter { !$0.isHidden }.flatMap { l -> [PKStroke] in
            let u = v.url.appendingPathComponent("\(l.id.uuidString).drawing")
            return ((try? Data(contentsOf: u)).flatMap { try? PKDrawing(data: $0) })?.strokes ?? []
        }
        return PKDrawing(strokes: strokes)
    }

    static func items(_ v: Version, _ page: UUID) -> [PageItem] {
        (try? Data(contentsOf: v.url.appendingPathComponent("\(page.uuidString).items.json"))).flatMap { try? Store.decoder.decode([PageItem].self, from: $0) } ?? []
    }

    /// A picture of the page as it was in the version.
    static func preview(_ v: Version, _ nb: Notebook, width: CGFloat) -> UIImage? {
        guard let pg = page(v) else { return nil }
        return PageRenderer.render(nb, pg, width: width, ink: ink(v, pg), items: items(v, pg.id), imageDir: v.url)
    }

    /// Puts the version back: the page as it is now is kept as a version first, so going back
    /// can be undone. Returns the page's description to save in the notebook.
    static func restore(_ v: Version, _ nb: Notebook, _ current: PageInfo) -> PageInfo? {
        guard var old = page(v) else { return nil }
        let fm = FileManager.default
        snapshot(nb, current)
        Store.ensureDirs(nb.id)
        // the ink of the layers as they are now goes away, then the old files come back
        for l in current.inkLayers { try? fm.removeItem(at: Store.drawing(nb.id, l.id)) }
        try? fm.removeItem(at: Store.items(nb.id, current.id))
        for l in old.inkLayers {
            let src = v.url.appendingPathComponent("\(l.id.uuidString).drawing")
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: Store.drawing(nb.id, l.id)) }
        }
        let items = v.url.appendingPathComponent("\(current.id.uuidString).items.json")
        if fm.fileExists(atPath: items.path) { try? fm.copyItem(at: items, to: Store.items(nb.id, current.id)) }
        for item in Store.loadItems(nb.id, current.id) {
            guard let name = item.image else { continue }
            let dst = Store.image(nb.id, name)
            let src = v.url.appendingPathComponent("img-" + name)
            if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dst) }
        }
        // the page keeps what is not part of its writing as it is now
        old.id = current.id
        old.bookmarked = current.bookmarked
        old.width = max(old.width, current.width)
        old.height = max(old.height, current.height)
        return old
    }

    /// A notebook deleted for good takes its history with it.
    static func removeAll(_ nb: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(nb.uuidString, isDirectory: true))
    }
}
