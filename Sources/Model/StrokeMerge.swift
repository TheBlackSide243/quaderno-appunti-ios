import Foundation
import PencilKit

/// Two people writing on the same page of a shared notebook: instead of keeping only the copy
/// saved last, the strokes and the boxes of both are put together. What each one added stays, what
/// each one erased goes. To tell "erased by them" from "added by me" it compares both copies with
/// the one both had at the last sync (`base`); without it nothing is taken away.
enum StrokeMerge {
    /// What makes a stroke that stroke: its ink, where its points are, when it was begun, how it
    /// was moved and what of it was erased. A stroke moved with the lasso is a new stroke (and the
    /// old one is gone), so moving and writing on both sides also come together.
    nonisolated static func key(_ s: PKStroke) -> String {
        func r(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        var c: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        s.ink.color.getRed(&c.0, green: &c.1, blue: &c.2, alpha: &c.3)
        let path = s.path
        let first = path.first?.location ?? .zero, last = path.last?.location ?? .zero
        let t = s.transform
        let mask = s.mask?.bounds ?? .null
        return [
            s.ink.inkType.rawValue, r(c.0), r(c.1), r(c.2), r(c.3),
            String(path.count), String(format: "%.3f", path.creationDate.timeIntervalSince1970),
            r(first.x), r(first.y), r(last.x), r(last.y),
            r(t.a), r(t.b), r(t.c), r(t.d), r(t.tx), r(t.ty),
            mask.isNull ? "-" : "\(r(mask.minX)),\(r(mask.minY)),\(r(mask.width)),\(r(mask.height))",
        ].joined(separator: "|")
    }

    /// My strokes, without the ones they erased, then the ones they added.
    nonisolated static func merge(base: [PKStroke]?, mine: [PKStroke], theirs: [PKStroke]) -> [PKStroke] {
        let b = Set((base ?? []).map(key)), t = Set(theirs.map(key)), m = Set(mine.map(key))
        var out = mine.filter { s in
            let k = key(s)
            return !(b.contains(k) && !t.contains(k))
        }
        var added = Set<String>()
        for s in theirs {
            let k = key(s)
            guard !m.contains(k), !b.contains(k), !added.contains(k) else { continue }
            added.insert(k)
            out.append(s)
        }
        return out
    }

    /// The boxes by their id: a box changed by only one of the two takes that change, one changed
    /// by both keeps mine.
    nonisolated static func mergeItems(base: [PageItem]?, mine: [PageItem], theirs: [PageItem]) -> [PageItem] {
        let b = Dictionary((base ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let t = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mineIDs = Set(mine.map(\.id))
        var out: [PageItem] = []
        for item in mine {
            let old = b[item.id]
            guard let other = t[item.id] else {
                // gone on their side: erased by them if it was there before, else mine is new
                if old == nil { out.append(item) }
                continue
            }
            out.append(old == item && other != item ? other : item)
        }
        for item in theirs where !mineIDs.contains(item.id) && b[item.id] == nil {
            out.append(item)
        }
        return out
    }

    /// Whether a file of a notebook can be put together this way.
    nonisolated static func canMerge(_ rel: String) -> Bool {
        rel.hasPrefix("pages/") && (rel.hasSuffix(".drawing") || rel.hasSuffix(".items.json"))
    }

    /// The two copies of a page file put together, or nil when one of them cannot be read (then
    /// the newest copy wins as before).
    nonisolated static func mergeFile(_ rel: String, base: Data?, mine: Data, theirs: Data) -> Data? {
        if mine == theirs { return mine }
        if rel.hasSuffix(".drawing") {
            guard let m = try? PKDrawing(data: mine), let t = try? PKDrawing(data: theirs) else { return nil }
            let b = base.flatMap { try? PKDrawing(data: $0) }
            let out = merge(base: b?.strokes, mine: m.strokes, theirs: t.strokes)
            if out.map(key) == m.strokes.map(key) { return mine }
            if out.map(key) == t.strokes.map(key) { return theirs }
            return PKDrawing(strokes: out).dataRepresentation()
        }
        guard let m = try? Store.decoder.decode([PageItem].self, from: mine),
              let t = try? Store.decoder.decode([PageItem].self, from: theirs) else { return nil }
        let b = base.flatMap { try? Store.decoder.decode([PageItem].self, from: $0) }
        let out = mergeItems(base: b, mine: m, theirs: t)
        if out == m { return mine }
        if out == t { return theirs }
        return try? Store.encoder.encode(out)
    }

    // MARK: The copy both had at the last sync

    /// Kept on this device only, outside the notebook's folder.
    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Condivisi", isDirectory: true)
    }()

    nonisolated static func baseURL(_ nb: UUID, _ rel: String) -> URL {
        root.appendingPathComponent(nb.uuidString, isDirectory: true).appendingPathComponent(rel)
    }

    nonisolated static func base(_ nb: UUID, _ rel: String) -> Data? {
        try? Data(contentsOf: baseURL(nb, rel))
    }

    nonisolated static func setBase(_ nb: UUID, _ rel: String, _ data: Data?) {
        let u = baseURL(nb, rel)
        guard let data else {
            try? FileManager.default.removeItem(at: u)
            return
        }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
    }

    nonisolated static func removeAll(_ nb: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(nb.uuidString, isDirectory: true))
    }
}
