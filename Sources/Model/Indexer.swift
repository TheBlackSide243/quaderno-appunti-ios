import Foundation
import PDFKit
import PencilKit
import UIKit
import Vision

/// The text found on one page.
struct PageText: Codable {
    var ink = ""
    var typed = ""
    var pdf = ""
    /// When the ink was last read, to skip pages that did not change.
    var inkStamp: Date?

    var all: String { [ink, typed, pdf].filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let notebookID: UUID
    let pageIndex: Int?
    let snippet: String
}

/// Reads handwriting with Vision (on the device, nothing leaves the phone), plus typed text and
/// PDF text, and keeps it in each notebook's index.json for the search.
final class Indexer: @unchecked Sendable {
    static let shared = Indexer()
    private let queue = DispatchQueue(label: "appunti.indexer", qos: .utility)
    private var indexes: [UUID: [String: PageText]] = [:]
    private var pending: [UUID: (Notebook, Set<UUID>)] = [:]
    private var scheduled = false

    // MARK: Index storage (on `queue`)

    private func index(_ id: UUID) -> [String: PageText] {
        if let i = indexes[id] { return i }
        let i = (try? Data(contentsOf: Store.index(id))).flatMap { try? Store.decoder.decode([String: PageText].self, from: $0) } ?? [:]
        indexes[id] = i
        return i
    }

    private func store(_ id: UUID, _ i: [String: PageText]) {
        indexes[id] = i
        guard FileManager.default.fileExists(atPath: Store.dir(id).path) else { return }
        if let data = try? Store.encoder.encode(i) { try? data.write(to: Store.index(id), options: .atomic) }
    }

    func forget(_ id: UUID) {
        queue.async { self.indexes[id] = nil; self.pending[id] = nil }
    }

    // MARK: Updating

    /// Reads the text of every PDF page of a notebook.
    func indexPDF(_ nb: Notebook) {
        queue.async {
            guard let doc = PDFDocument(url: Store.pdf(nb.id)) else { return }
            var i = self.index(nb.id)
            for page in nb.pages {
                guard let n = page.pdfIndex, let p = doc.page(at: n) else { continue }
                var t = i[page.id.uuidString] ?? PageText()
                t.pdf = p.string ?? ""
                i[page.id.uuidString] = t
            }
            self.store(nb.id, i)
            Spotlight.shared.schedule(nb)
        }
    }

    /// Queues a page for reading; pages are read a few seconds later, in the background.
    func schedule(_ nb: Notebook, page: UUID) {
        queue.async {
            var entry = self.pending[nb.id] ?? (nb, [])
            entry.0 = nb
            entry.1.insert(page)
            self.pending[nb.id] = entry
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 3) { self.drain() }
        }
    }

    /// Removes pages that no longer exist.
    func prune(_ nb: Notebook) {
        queue.async {
            var i = self.index(nb.id)
            let keep = Set(nb.pages.map(\.id.uuidString))
            i = i.filter { keep.contains($0.key) }
            self.store(nb.id, i)
        }
    }

    /// Reads pages that were never read (for example after an update of the app).
    func catchUp(_ notebooks: [Notebook]) {
        queue.async {
            for nb in notebooks {
                let i = self.index(nb.id)
                for page in nb.pages where i[page.id.uuidString] == nil {
                    if Store.inkStamp(nb.id, page) != nil
                        || (nb.isText && FileManager.default.fileExists(atPath: TextDoc.url(nb.id).path))
                        || FileManager.default.fileExists(atPath: Store.items(nb.id, page.id).path) {
                        var e = self.pending[nb.id] ?? (nb, [])
                        e.1.insert(page.id)
                        self.pending[nb.id] = e
                    }
                }
                if nb.hasPDF, nb.pages.contains(where: { $0.pdfIndex != nil && i[$0.id.uuidString] == nil }) { self.indexPDF(nb) }
            }
            if !self.pending.isEmpty, !self.scheduled {
                self.scheduled = true
                self.queue.asyncAfter(deadline: .now() + 2) { self.drain() }
            }
        }
    }

    private func drain() {
        scheduled = false
        let work = pending
        pending = [:]
        for (id, (nb, pages)) in work {
            var i = index(id)
            for pid in pages {
                guard let page = nb.pages.first(where: { $0.id == pid }) else { continue }
                var t = i[pid.uuidString] ?? PageText()
                if nb.isText {
                    t.typed = TextDoc.plain(id)
                    t.ink = ""
                    i[pid.uuidString] = t
                    continue
                }
                t.typed = Store.loadItems(id, pid).filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                let stamp = Store.inkStamp(id, page)
                if stamp == nil {
                    t.ink = ""
                } else if stamp != t.inkStamp {
                    t.ink = autoreleasepool { recognize(Store.loadInk(id, page), size: page.size) }
                }
                t.inkStamp = stamp
                i[pid.uuidString] = t
            }
            store(id, i)
            Spotlight.shared.schedule(nb)
        }
    }

    /// The text last read on every page of a notebook, from the saved index (no reading now).
    static func storedTexts(_ nb: UUID) -> [String: PageText] {
        (try? Data(contentsOf: Store.index(nb))).flatMap { try? Store.decoder.decode([String: PageText].self, from: $0) } ?? [:]
    }

    /// Reads some handwriting now: the text and how many lines it has.
    func read(_ d: PKDrawing) async -> (String, Int) {
        await withCheckedContinuation { cont in
            queue.async {
                let text = autoreleasepool { self.recognize(d, size: CGSize(width: 1e5, height: 1e5)) }
                cont.resume(returning: (text, text.split(whereSeparator: \.isNewline).count))
            }
        }
    }

    /// Handwriting recognition of the ink alone, drawn black on white.
    private func recognize(_ d: PKDrawing, size: CGSize) -> String {
        guard !d.strokes.isEmpty else { return "" }
        let bounds = d.bounds.intersection(CGRect(origin: .zero, size: size)).insetBy(dx: -12, dy: -12)
        guard bounds.width > 4, bounds.height > 4 else { return "" }
        let scale = min(2.5, 3000 / max(bounds.width, bounds.height))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = d.image(from: bounds, scale: scale) }
        let img = UIGraphicsImageRenderer(size: bounds.size, format: fmt).image { r in
            UIColor.white.setFill()
            r.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        guard let cg = img.cgImage else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let wanted = ["it-IT", "en-US"]
        if let supported = try? req.supportedRecognitionLanguages() {
            let langs = wanted.filter { supported.contains($0) }
            if !langs.isEmpty { req.recognitionLanguages = langs }
        }
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        } catch {
            return ""
        }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Typed and PDF text of a page: quick, without the handwriting.
    func quickText(_ nb: Notebook, _ page: PageInfo) -> PageText {
        var t = PageText()
        t.typed = Store.loadItems(nb.id, page.id).filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        if let n = page.pdfIndex, let p = PDFCache.shared.document(nb.id)?.page(at: n) { t.pdf = p.string ?? "" }
        return t
    }

    /// Reads one page now (for "recognised text"), without waiting for the background pass.
    func pageText(_ nb: Notebook, _ page: PageInfo) async -> PageText {
        await withCheckedContinuation { cont in
            queue.async {
                var t = PageText()
                t.typed = Store.loadItems(nb.id, page.id).filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                t.ink = autoreleasepool { self.recognize(Store.loadInk(nb.id, page), size: page.size) }
                if let n = page.pdfIndex, let doc = PDFDocument(url: Store.pdf(nb.id)), let p = doc.page(at: n) {
                    t.pdf = p.string ?? ""
                }
                cont.resume(returning: t)
            }
        }
    }

    // MARK: Search

    /// Looks for `query` in titles, handwriting, typed text and PDF text. Accents and case are ignored.
    func search(_ query: String, in notebooks: [Notebook]) async -> [SearchHit] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        return await withCheckedContinuation { cont in
            queue.async {
                var hits: [SearchHit] = []
                for nb in notebooks {
                    if Self.fold(nb.title).contains(q) {
                        hits.append(SearchHit(notebookID: nb.id, pageIndex: nil, snippet: nb.title))
                    }
                    let i = self.index(nb.id)
                    for (n, page) in nb.pages.enumerated() {
                        guard let text = i[page.id.uuidString]?.all, !text.isEmpty else { continue }
                        if let s = Self.snippet(text, q) {
                            hits.append(SearchHit(notebookID: nb.id, pageIndex: n, snippet: s))
                        }
                    }
                }
                cont.resume(returning: hits)
            }
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "it_IT"))
    }

    /// The line containing the match, shortened around it.
    private static func snippet(_ text: String, _ q: String) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let folded = fold(flat)
        guard let r = folded.range(of: q) else { return nil }
        let pos = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let chars = Array(flat)
        guard pos < chars.count else { return String(flat.prefix(120)) }
        let a = max(0, pos - 40), b = min(chars.count, pos + q.count + 60)
        return (a > 0 ? "…" : "") + String(chars[a..<b]) + (b < chars.count ? "…" : "")
    }
}
