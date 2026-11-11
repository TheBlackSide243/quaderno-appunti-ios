import Compression
import Foundation
import PDFKit
import PencilKit
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// A GoodNotes 5/6 notebook (a zip archive).
    static let goodNotes = UTType(importedAs: "com.local.appunti.goodnotes", conformingTo: .data)
}

/// Reads a `.goodnotes` notebook into a new notebook of this app: the pages with their paper (kept
/// as PDF pages), the handwriting and highlighter as ink, photos and text boxes.
///
/// The format is not documented. What is read here follows the public notes of the projects that
/// studied it (goodparse, parser-for-goodnotes, oblyx), checked on a real notebook:
/// - the file is a zip; `index.events.pb` describes the pages (order, paper, canvas size),
///   `notes/<page>` is the log of a page's objects, `attachments/` holds papers (PDF) and images;
/// - every part is a stream of length-prefixed protobuf records;
/// - a stroke's path is an Apple LZ4 block holding a "tpl" binary record of quadratic segments.
enum GoodNotesImport {
    enum Failure: LocalizedError {
        case unreadable, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Il file non è un quaderno GoodNotes leggibile.")
            case .empty: String(localized: "In questo quaderno GoodNotes non ho trovato pagine.")
            }
        }
    }

    /// Stroke widths of GoodNotes' even pens are 11/12 canvas units per stored unit.
    private static let uniformWidth: Float = 11 / 12
    /// Canvas units to page points when a page has no paper to measure (the scale of every sample).
    private static let defaultScale: CGFloat = 6 / 11

    /// Builds the notebook's folder and returns the notebook, not yet saved to the library.
    static func read(_ url: URL, folder: UUID?) throws -> Notebook {
        let zip = try Zip(data: Data(contentsOf: url))
        let pages = document(zip)
        guard !pages.isEmpty else { throw Failure.empty }

        var nb = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: nil, folderID: folder, pages: [])
        Store.ensureDirs(nb.id)
        do {
            try build(&nb, pages, zip)
        } catch {
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            throw error
        }
        guard !nb.pages.isEmpty else {
            try? FileManager.default.removeItem(at: Store.dir(nb.id))
            throw Failure.empty
        }
        return nb
    }

    // MARK: Building the notebook

    private static func build(_ nb: inout Notebook, _ pages: [PageMeta], _ zip: Zip) throws {
        let merged = PDFDocument()
        var papers: [String: PDFDocument] = [:]
        for meta in pages {
            var info: PageInfo
            var scale = defaultScale
            var background: PageItem?
            let paperData = meta.paper.flatMap { zip.file("attachments/\($0)") }
            if let paper = meta.paper, let data = paperData, data.starts(with: Array("%PDF".utf8)) {
                if papers[paper] == nil { papers[paper] = PDFDocument(data: data) }
                if let doc = papers[paper], doc.pageCount > 0,
                   let page = doc.page(at: min(meta.paperPage, doc.pageCount - 1))?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                    let size = PageRenderer.pdfPageSize(page)
                    info = PageInfo(template: .blank, size: size, pdfIndex: merged.pageCount - 1)
                    if let c = meta.canvas, c.width > 0 { scale = size.width / c.width }
                } else {
                    info = PageInfo(template: .blank, size: plainSize(meta))
                }
            } else {
                info = PageInfo(template: .blank, size: plainSize(meta))
                // a paper that is a picture fills the page under everything else
                if let data = paperData, let img = UIImage(data: data), let (name, _) = Store.saveImage(img, nb.id) {
                    var item = PageItem(kind: .image, x: 0, y: 0, w: info.width, h: info.height)
                    item.image = name
                    background = item
                }
            }
            if let c = meta.canvas, info.pdfIndex == nil, c.width > 0 { scale = info.size.width / c.width }

            var strokes: [PKStroke] = []
            var items: [PageItem] = background.map { [$0] } ?? []
            if let member = meta.member, let data = zip.file(member) {
                for obj in objects(data) {
                    switch obj.kind {
                    case 7: strokes += stroke(obj.body, scale: scale)
                    case 1: if let it = image(obj, zip, nb.id, scale: scale) { items.append(it) }
                    case 8: if let it = textBox(obj.body, scale: scale) { items.append(it) }
                    default: break
                    }
                }
            }
            // the file lists objects topmost first
            strokes.reverse()
            if !strokes.isEmpty { Store.saveDrawing(PKDrawing(strokes: strokes), nb.id, info.id) }
            if !items.isEmpty { Store.saveItems(items, nb.id, info.id) }
            nb.pages.append(info)
        }
        if merged.pageCount > 0 {
            guard merged.write(to: Store.pdf(nb.id)) else { throw Failure.unreadable }
            nb.hasPDF = true
        }
    }

    private static func plainSize(_ meta: PageMeta) -> CGSize {
        guard let c = meta.canvas else { return PageFormat.a4Portrait.size }
        return CGSize(width: (c.width * defaultScale).rounded(), height: (c.height * defaultScale).rounded())
    }

    // MARK: Pages

    struct PageMeta {
        var member: String?
        var canvas: CGSize?
        var paper: String?
        var paperPage = 0
    }

    /// The pages in display order, from the event log (or the page index when there is none).
    static func document(_ zip: Zip) -> [PageMeta] {
        let members = Dictionary(zip.names.filter { $0.hasPrefix("notes/") }.map { (String($0.dropFirst(6).prefix(32)), $0) },
                                 uniquingKeysWith: { a, _ in a })
        var out: [PageMeta] = []
        if let events = zip.file("index.events.pb") {
            var layers: [String: (paper: String?, canvas: CGSize?, page: Int)] = [:]
            var paperFile: [String: String] = [:]
            var created: [String] = []
            var layerOf: [String: (Int, [UInt8])] = [:]
            var position: [String: (Int, [UInt8])] = [:]
            var deleted = Set<String>()
            for rec in PB.records(events) {
                guard let t = PB(rec) else { continue }
                let top = t.uuid(1)
                if let top, let info = t.message(2) {
                    var old = layers[top] ?? (nil, nil, 0)
                    if let p = info.uuid(4) { old.paper = p }
                    if case let .int(n)? = info.first(5), n >= 1 { old.page = Int(n) - 1 }
                    if let c = info.message(8), let w = c.float(1), let h = c.float(2), w > 100, h > 100, w < 5000, h < 5000 {
                        old.canvas = CGSize(width: CGFloat(w), height: CGFloat(h))
                    }
                    layers[top] = old
                }
                if let top, let six = t.message(6), let att = six.uuid(2) { paperFile[top] = att }
                if let top, t.has(56) { deleted.insert(String(top.prefix(32))) }
                for op in [54, 3, 55] {
                    guard let body = t.message(op), let page = body.uuid(2) else { continue }
                    func assign(_ reg: inout [String: (Int, [UInt8])], _ v: (Int, [UInt8])?) {
                        if let v, v.0 >= (reg[page]?.0 ?? -1) { reg[page] = v }
                    }
                    switch op {
                    case 54:
                        created.append(page)
                        assign(&layerOf, versioned(body.message(3)))
                        assign(&position, versioned(body.message(4)))
                    case 3: assign(&layerOf, versioned(body.message(3)))
                    default: assign(&position, versioned(body.message(3)))
                    }
                }
            }
            // pages sort by their latest position key, bytewise; the sort keeps creation order for ties
            let order = created.enumerated().sorted { a, b in
                let ka = position[a.element]?.1 ?? [], kb = position[b.element]?.1 ?? []
                return ka.lexicographicallyPrecedes(kb) || (ka == kb && a.offset < b.offset)
            }
            var seen = Set<String>()
            for (_, page) in order {
                let key = String(page.prefix(32))
                guard !deleted.contains(key), seen.insert(key).inserted else { continue }
                var meta = PageMeta(member: members[key])
                if let raw = layerOf[page]?.1, let layer = PB.uuid(in: raw), let l = layers[layer] {
                    meta.paper = l.paper.map { paperFile[$0] ?? $0 }
                    meta.canvas = l.canvas
                    meta.paperPage = l.page
                }
                if meta.member != nil { out.append(meta) }
            }
        }
        if out.isEmpty, let index = zip.file("index.notes.pb") {
            for rec in PB.records(index) {
                if let id = PB(rec)?.uuid(1), let m = members[String(id.prefix(32))] { out.append(PageMeta(member: m)) }
            }
        }
        return out
    }

    /// A versioned register `{1: value, 2: {1: version}}`.
    private static func versioned(_ m: PB?) -> (Int, [UInt8])? {
        guard let m, case let .bytes(v)? = m.first(1), !v.isEmpty else { return nil }
        var version = 0
        if let ver = m.message(2), case let .int(n)? = ver.first(1) { version = Int(n) }
        return (version, v)
    }

    // MARK: Page objects

    struct Object {
        var kind: Int
        var body: PB
        var header: PB?
    }

    /// The live objects of a page: records come in pairs (header, then body); deleted ones are skipped.
    static func objects(_ data: [UInt8]) -> [Object] {
        var out: [Object] = []
        var header: PB?
        for rec in PB.records(data) {
            guard let t = PB(rec) else { header = nil; continue }
            if t.fields.count == 1, let (kind, values) = t.fields.first, values.count == 1,
               case let .bytes(b) = values[0], let body = PB(b) {
                let id = body.uuid(1)
                let hdr = (header?.uuid(1) == id) ? header : nil
                header = nil
                if hdr?.int(3) == 1 || body.int(14) == 1 { continue }
                out.append(Object(kind: kind, body: body, header: hdr))
                continue
            }
            header = t
        }
        return out
    }

    private static func color(_ m: PB?) -> (UIColor, CGFloat) {
        var c: [CGFloat] = [0, 0, 0, 1]
        if let m { for k in 1...4 { if let v = m.float(k) { c[k - 1] = CGFloat(v) } } }
        return (UIColor(red: c[0], green: c[1], blue: c[2], alpha: 1), c[3])
    }

    /// One GoodNotes stroke as PencilKit strokes (one per piece left by the eraser).
    private static func stroke(_ body: PB, scale: CGFloat) -> [PKStroke] {
        let (rgb, alpha) = color(body.message(4))
        var dx: Float = 0, dy: Float = 0
        if let move = body.message(6) { dx = move.float(1) ?? 0; dy = move.float(2) ?? 0 }

        var paths: [[SIMD3<Float>]] = []
        var kind = "pen"
        if let shape = body.message(9), let outline = shapeOutline(shape) {
            let w = shape.float(15) ?? 10.3937
            paths = [outline.map { SIMD3($0.x, $0.y, w) }]
        } else if let blob = body.all(2).first(where: { $0.starts(with: Array("bv41".utf8)) }),
                  let raw = appleLZ4(blob), let ink = Ink(raw) {
            paths = ink.paths
            kind = ink.kind
        }
        let highlighter = alpha < 0.95 && kind != "pencil"
        let type: PKInk.InkType = highlighter ? .marker : (kind == "pencil" ? .pencil : .monoline)
        let inkColor = kind == "pencil" ? rgb.withAlphaComponent(max(0.35, alpha)) : rgb
        let now = Date()
        return paths.compactMap { path in
            guard !path.isEmpty else { return nil }
            let pts = path.enumerated().map { i, p -> PKStrokePoint in
                let width = CGFloat(p.z) * scale
                // the same correction as the shape tool: PencilKit draws a size s about 1.77 (s - 1.85) wide
                let s = max(1.9, width * 0.565 + 1.85)
                return PKStrokePoint(location: CGPoint(x: CGFloat(p.x + dx) * scale, y: CGFloat(p.y + dy) * scale),
                                     timeOffset: TimeInterval(i) * 0.008, size: CGSize(width: s, height: s),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(type, color: inkColor), path: PKStrokePath(controlPoints: pts, creationDate: now))
        }
    }

    /// A recognised shape: polygon, quadratic curve, rectangle or ellipse (canvas units).
    private static func shapeOutline(_ m: PB) -> [SIMD2<Float>]? {
        func point(_ p: PB?) -> SIMD2<Float>? {
            guard let p, let x = p.float(1), let y = p.float(2), x.isFinite, y.isFinite else { return nil }
            return SIMD2(x, y)
        }
        if case .bytes = m.first(1) {
            let pts = m.all(1).compactMap { PB($0) }.compactMap(point)
            return pts.count >= 2 ? pts : nil
        }
        if let q = m.message(2), let a = point(q.message(1)), let c = point(q.message(2)), let b = point(q.message(3)) {
            return (0...32).map { i in
                let t = Float(i) / 32
                return (1 - t) * (1 - t) * a + 2 * (1 - t) * t * c + t * t * b
            }
        }
        for (field, ellipse) in [(3, false), (4, true)] {
            guard let r = m.message(field), let c = point(r.message(1)), let s = point(r.message(2)) else { continue }
            let rot = r.float(3) ?? 0
            let local: [SIMD2<Float>]
            if ellipse {
                local = (0...72).map { i in let t = Float(i) / 72 * 2 * .pi; return SIMD2(s.x * cos(t), s.y * sin(t)) }
            } else {
                let hx = s.x / 2, hy = s.y / 2
                local = [SIMD2(-hx, -hy), SIMD2(hx, -hy), SIMD2(hx, hy), SIMD2(-hx, hy), SIMD2(-hx, -hy)]
            }
            let ca = cos(rot), sa = sin(rot)
            return local.map { SIMD2(c.x + $0.x * ca - $0.y * sa, c.y + $0.x * sa + $0.y * ca) }
        }
        return nil
    }

    /// The placement `{2: {1: top-left, 2: size}}` of a picture or a text box, in page points.
    private static func frame(_ body: PB, scale: CGFloat) -> CGRect? {
        guard let m = body.message(2), let a = m.message(1), let b = m.message(2),
              let x = a.float(1), let y = a.float(2), let w = b.float(1), let h = b.float(2), w > 0, h > 0 else { return nil }
        return CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    }

    private static func image(_ obj: Object, _ zip: Zip, _ nb: UUID, scale: CGFloat) -> PageItem? {
        guard let r = frame(obj.body, scale: scale) else { return nil }
        let names = [obj.header?.uuid(7), obj.header?.uuid(4)].compactMap { $0 }
        guard let data = names.lazy.compactMap({ zip.file("attachments/\($0)") }).first,
              let img = UIImage(data: Data(data)), let (name, _) = Store.saveImage(img, nb) else { return nil }
        var item = PageItem(kind: .image, x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
        item.image = name
        return item
    }

    private static func textBox(_ body: PB, scale: CGFloat) -> PageItem? {
        guard let r = frame(body, scale: scale) else { return nil }
        let rtf = body.fields.values.joined().compactMap { v -> [UInt8]? in
            if case let .bytes(b) = v, b.starts(with: Array("{\\rtf".utf8)) { return b }
            return nil
        }.first
        guard let rtf, let text = try? NSAttributedString(data: Data(rtf), options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                          documentAttributes: nil) else { return nil }
        let plain = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        var item = PageItem(kind: .text, x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
        item.text = plain
        if let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            item.fontSize = Double(max(8, font.pointSize * scale * 1.6))
        } else {
            item.fontSize = 14
        }
        return item
    }

    // MARK: Stroke paths

    /// A stroke's "tpl" record: `tpl\0`, total length, a type signature, `\0`, then packed values.
    /// The signature uses v (uint16), u and f (32-bit float), A(...) (count + items) and S(...) (struct).
    struct Ink {
        var kind: String
        var paths: [[SIMD3<Float>]]

        indirect enum Value {
            case num(Float)
            case list([Value])
        }

        init?(_ raw: [UInt8]) {
            guard raw.count > 9, raw.starts(with: Array("tpl\0".utf8)), let end = raw[8...].firstIndex(of: 0),
                  let sig = String(bytes: raw[8..<end], encoding: .ascii) else { return nil }
            var i = 0
            let chars = Array(sig)
            // parse the signature into a tree
            indirect enum T { case v, u, a([T]), s([T]) }
            func parse() -> [T] {
                var out: [T] = []
                while i < chars.count {
                    let c = chars[i]
                    if c == "A" || c == "S" {
                        i += 2
                        let sub = parse()
                        out.append(c == "A" ? .a(sub) : .s(sub))
                    } else if c == ")" {
                        i += 1
                        return out
                    } else {
                        out.append(c == "v" ? .v : .u)
                        i += 1
                    }
                }
                return out
            }
            let tree = parse()
            var off = end + 1
            var ok = true
            func read(_ ts: [T]) -> [Value] {
                var vals: [Value] = []
                for t in ts {
                    guard ok else { return vals }
                    switch t {
                    case .v:
                        guard off + 2 <= raw.count else { ok = false; return vals }
                        vals.append(.num(Float(UInt16(raw[off]) | UInt16(raw[off + 1]) << 8))); off += 2
                    case .u:
                        guard off + 4 <= raw.count else { ok = false; return vals }
                        vals.append(.num(Float(bitPattern: le32(raw, off)))); off += 4
                    case let .s(sub):
                        vals.append(.list(read(sub)))
                    case let .a(sub):
                        guard off + 4 <= raw.count else { ok = false; return vals }
                        let n = Int(le32(raw, off)); off += 4
                        guard n <= raw.count else { ok = false; return vals }
                        var arr: [Value] = []
                        arr.reserveCapacity(n)
                        for _ in 0..<n {
                            let v = read(sub)
                            arr.append(sub.count == 1 ? (v.first ?? .num(0)) : .list(v))
                        }
                        vals.append(.list(arr))
                    }
                }
                return vals
            }
            let v = read(tree)
            guard ok else { return nil }

            func nums(_ x: Value) -> [Float] {
                switch x {
                case let .num(n): return [n]
                case let .list(l): return l.flatMap(nums)
                }
            }
            func list(_ x: Value) -> [Value] { if case let .list(l) = x { return l }; return [] }
            func num(_ x: Value) -> Float { if case let .num(n) = x { return n }; return 0 }

            if sig.hasPrefix("vA(v)A(u)A(u)") || sig.hasPrefix("vuA(v)A(u)A(u)") {
                let newer = sig.hasPrefix("vu")
                let b = newer ? 1 : 0
                guard v.count > 3 + b else { return nil }
                let flags = list(v[1 + b]).map { Int(num($0)) }
                let start = nums(v[2 + b]), seg = nums(v[3 + b])
                let dr = newer ? num(v[1]) : 0
                var moves: [SIMD3<Float>] = [], quads: [(SIMD3<Float>, SIMD3<Float>)] = []
                var si = 0, gi = 0
                for fl in flags {
                    let extra = fl & 4 != 0
                    let own = !newer || fl & 2 != 0
                    if fl & 1 == 0 {
                        guard si + (own ? 3 : 2) <= start.count else { return nil }
                        let r = own ? start[si + 2] : dr
                        moves.append(SIMD3(start[si], start[si + 1], 2 * r))
                        si += (own ? 3 : 2) + (extra ? 1 : 0)
                    } else {
                        guard gi + (own ? 6 : 4) <= seg.count else { return nil }
                        if !newer {
                            quads.append((SIMD3(seg[gi], seg[gi + 1], 2 * seg[gi + 2]), SIMD3(seg[gi + 3], seg[gi + 4], 2 * seg[gi + 5])))
                        } else if own {
                            quads.append((SIMD3(seg[gi], seg[gi + 1], 2 * seg[gi + 4]), SIMD3(seg[gi + 2], seg[gi + 3], 2 * seg[gi + 5])))
                        } else {
                            quads.append((SIMD3(seg[gi], seg[gi + 1], 2 * dr), SIMD3(seg[gi + 2], seg[gi + 3], 2 * dr)))
                        }
                        gi += (own ? 6 : 4) + (extra ? 3 : 0)
                    }
                }
                kind = "pen"
                paths = Self.assemble(flags, moves, quads)
            } else if sig.hasPrefix("vuA(v)A(S(uu))A(S(uuuu))") {
                guard v.count >= 5 else { return nil }
                let w = num(v[1]) * GoodNotesImport.uniformWidth
                let flags = list(v[2]).map { Int(num($0)) }
                let moves = list(v[3]).map { let p = nums($0); return SIMD3(p[0], p[1], w) }
                let quads = list(v[4]).map { let p = nums($0); return (SIMD3(p[0], p[1], w), SIMD3(p[2], p[3], w)) }
                kind = "pen"
                paths = Self.assemble(flags, moves, quads)
            } else if sig.hasPrefix("vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))") {
                guard v.count >= 5 else { return nil }
                let w = num(v[1]) * GoodNotesImport.uniformWidth
                let flags = list(v[2]).map { Int(num($0)) }
                let moves = list(v[3]).map { let p = nums($0); return SIMD3(p[0], p[1], w) }
                let quads = list(v[4]).map { let p = nums($0); return (SIMD3(p[1], p[2], w), SIMD3(p[6], p[7], w)) }
                kind = "pencil"
                paths = Self.assemble(flags, moves, quads)
            } else {
                return nil
            }
            if paths.isEmpty { return nil }
        }

        /// Node flags: bit 0 clear = move to (a new piece), set = quadratic curve to.
        private static func assemble(_ flags: [Int], _ moves: [SIMD3<Float>], _ quads: [(SIMD3<Float>, SIMD3<Float>)]) -> [[SIMD3<Float>]] {
            var paths: [[SIMD3<Float>]] = []
            var mi = 0, qi = 0
            for fl in flags {
                if fl & 1 == 0 {
                    guard mi < moves.count else { break }
                    paths.append([moves[mi]]); mi += 1
                } else {
                    guard qi < quads.count, var path = paths.popLast(), let p0 = path.last else { break }
                    let (c, e) = quads[qi]; qi += 1
                    for k in 1...4 {
                        let t = Float(k) / 4
                        path.append((1 - t) * (1 - t) * p0 + 2 * (1 - t) * t * c + t * t * e)
                    }
                    paths.append(path)
                }
            }
            return paths.filter { !$0.isEmpty }
        }
    }

    // MARK: Apple LZ4

    /// Blocks `bv41` (raw size, packed size, LZ4 data) and `bv4-` (raw size, data), ending with `bv4$`.
    static func appleLZ4(_ b: [UInt8]) -> [UInt8]? {
        var total = 0
        var i = 0
        while i + 8 <= b.count {
            let magic = String(bytes: b[i..<i + 4], encoding: .ascii)
            if magic == "bv4$" { break }
            let raw = Int(le32(b, i + 4))
            if magic == "bv41", i + 12 <= b.count {
                total += raw
                i += 12 + Int(le32(b, i + 8))
            } else if magic == "bv4-" {
                total += raw
                i += 8 + raw
            } else {
                return nil
            }
        }
        guard total > 0, total < 64 << 20 else { return nil }
        var out = [UInt8](repeating: 0, count: total)
        let n = out.withUnsafeMutableBufferPointer { dst in
            b.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.baseAddress!, total, src.baseAddress!, b.count, nil, COMPRESSION_LZ4)
            }
        }
        return n == total ? out : nil
    }
}

private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

private func le16(_ b: [UInt8], _ i: Int) -> Int {
    Int(b[i]) | Int(b[i + 1]) << 8
}

// MARK: Protobuf

/// A protobuf message read without a schema: field number -> values.
struct PB {
    enum Value {
        case int(UInt64)
        case f32(Float)
        case f64(Double)
        case bytes([UInt8])
    }

    var fields: [Int: [Value]] = [:]

    /// nil when the bytes are not a well-formed message.
    init?(_ b: [UInt8]) {
        var i = 0
        while i < b.count {
            guard let key = PB.varint(b, &i) else { return nil }
            let f = Int(key >> 3)
            guard f > 0 else { return nil }
            let v: Value
            switch key & 7 {
            case 0:
                guard let n = PB.varint(b, &i) else { return nil }
                v = .int(n)
            case 1:
                guard i + 8 <= b.count else { return nil }
                let lo = UInt64(le32(b, i)), hi = UInt64(le32(b, i + 4))
                v = .f64(Double(bitPattern: lo | hi << 32)); i += 8
            case 5:
                guard i + 4 <= b.count else { return nil }
                v = .f32(Float(bitPattern: le32(b, i))); i += 4
            case 2:
                guard let n = PB.varint(b, &i), n <= UInt64(b.count - i) else { return nil }
                v = .bytes(Array(b[i..<i + Int(n)])); i += Int(n)
            default:
                return nil
            }
            fields[f, default: []].append(v)
        }
    }

    static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var r: UInt64 = 0, s: UInt64 = 0
        while i < b.count, s < 64 {
            let c = b[i]; i += 1
            r |= UInt64(c & 0x7f) << s
            if c < 0x80 { return r }
            s += 7
        }
        return nil
    }

    /// A file made of length-prefixed records.
    static func records(_ b: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < b.count {
            guard let n = varint(b, &i), n <= UInt64(b.count - i) else { break }
            out.append(Array(b[i..<i + Int(n)]))
            i += Int(n)
        }
        return out
    }

    func first(_ f: Int) -> Value? { fields[f]?.first }
    func has(_ f: Int) -> Bool { fields[f] != nil }

    func all(_ f: Int) -> [[UInt8]] {
        (fields[f] ?? []).compactMap { if case let .bytes(b) = $0 { return b }; return nil }
    }

    func message(_ f: Int) -> PB? {
        if case let .bytes(b)? = first(f) { return PB(b) }
        return nil
    }

    func int(_ f: Int) -> UInt64? {
        if case let .int(n)? = first(f) { return n }
        return nil
    }

    func float(_ f: Int) -> Float? {
        switch first(f) {
        case let .f32(x)?: return x
        case let .f64(x)?: return Float(x)
        default: return nil
        }
    }

    func uuid(_ f: Int) -> String? {
        if case let .bytes(b)? = first(f) { return PB.uuid(in: b) }
        return nil
    }

    /// The first UUID written as text in the bytes, upper case.
    static func uuid(in b: [UInt8]) -> String? {
        guard b.count >= 36 else { return nil }
        let hex = { (c: UInt8) in (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
        let dashes = [8, 13, 18, 23]
        outer: for start in 0...(b.count - 36) {
            for k in 0..<36 {
                let c = b[start + k]
                if dashes.contains(k) { if c != 45 { continue outer } } else if !hex(c) { continue outer }
            }
            return String(bytes: b[start..<start + 36], encoding: .ascii)?.uppercased()
        }
        return nil
    }
}

// MARK: Zip

/// Reads the files of a zip archive (stored or deflated), enough for a .goodnotes file.
struct Zip {
    private let data: [UInt8]
    private var entries: [String: (offset: Int, method: Int, packed: Int, size: Int)] = [:]
    var names: [String] { Array(entries.keys) }

    init(data: Data) throws {
        self.data = [UInt8](data)
        let b = self.data
        // the end-of-central-directory record is in the last 64 KB
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 65_557) {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw GoodNotesImport.Failure.unreadable }
        let count = le16(b, eocd + 10)
        var p = Int(le32(b, eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= b.count, le32(b, p) == 0x0201_4b50 else { throw GoodNotesImport.Failure.unreadable }
            let method = le16(b, p + 10)
            let packed = Int(le32(b, p + 20)), size = Int(le32(b, p + 24))
            let nameLen = le16(b, p + 28), extraLen = le16(b, p + 30), commentLen = le16(b, p + 32)
            let local = Int(le32(b, p + 42))
            guard p + 46 + nameLen <= b.count, let name = String(bytes: b[p + 46..<p + 46 + nameLen], encoding: .utf8) else {
                throw GoodNotesImport.Failure.unreadable
            }
            // GoodNotes exports may wrap everything in one folder: keep the path below it
            entries[name] = (local, method, packed, size)
            p += 46 + nameLen + extraLen + commentLen
        }
        // a notebook inside a folder of the archive
        if !entries.keys.contains(where: { $0.hasPrefix("notes/") }),
           let inner = entries.keys.first(where: { $0.contains("/notes/") }) {
            let prefix = String(inner[..<inner.range(of: "notes/")!.lowerBound])
            entries = Dictionary(entries.compactMap { k, v in k.hasPrefix(prefix) ? (String(k.dropFirst(prefix.count)), v) : nil },
                                 uniquingKeysWith: { a, _ in a })
        }
    }

    func file(_ name: String) -> [UInt8]? {
        guard let e = entries[name], e.offset + 30 <= data.count, le32(data, e.offset) == 0x0403_4b50 else { return nil }
        let start = e.offset + 30 + le16(data, e.offset + 26) + le16(data, e.offset + 28)
        guard start + e.packed <= data.count else { return nil }
        if e.method == 0 { return Array(data[start..<start + e.packed]) }
        guard e.method == 8 else { return nil }
        if e.size == 0 { return [] }
        var out = [UInt8](repeating: 0, count: e.size)
        let n = out.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress! + start, e.packed, nil, COMPRESSION_ZLIB)
            }
        }
        return n == e.size ? out : nil
    }
}
