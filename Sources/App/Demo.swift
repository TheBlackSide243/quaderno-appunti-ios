import PDFKit
import PencilKit
import UIKit

/// Sample notebooks for the screenshots of the README. Only active when the app is launched with
/// `-demo` (the simulator script does that); `-screen <name>` then opens one screen.
@MainActor
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var enabled: Bool { args.contains("-demo") }

    static var screen: String? {
        guard enabled, let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var searchQuery: String { screen == "search" ? "Newton" : "" }

    static func route(library: Library, router: Router) async {
        guard let s = screen else { return }
        try? await Task.sleep(for: .seconds(1.2))
        func open(_ title: String, page: Int = 0) {
            if let nb = library.notebooks.first(where: { $0.title == title }) { router.open = OpenRequest(notebookID: nb.id, page: page) }
        }
        switch s {
        case "editor", "pages", "present": open("Fisica 1")
        case "tape", "study": open("Storia moderna")
        case "pdf", "ocr": open("Dispensa termodinamica")
        case "shapes": open("Fisica 1", page: 1)
        case "trash":
            // one notebook in the trash to show (not one of those on the first shelf)
            if library.trashed.isEmpty, let nb = library.notebooks.first(where: { $0.title == "Chimica" }) { library.delete(nb.id) }
            router.showTrash = true
        case "math": open("Analisi 2")
        case "ideas": open("Idee progetto")
        case "search": router.showSearch = true
        case "settings": router.showSettings = true
        case "new", "covers": router.showNew = true
        case "intro": router.showIntro = true
        default: break
        }
    }

    // MARK: Seeding

    static func seedIfNeeded(_ library: Library) {
        guard enabled, library.notebooks.isEmpty else { return }
        var rng = Rng(seed: 20261110)
        library.addFolder("Università")
        library.addFolder("Lavoro")
        let uni = library.folders.first { $0.name == "Università" }?.id
        let work = library.folders.first { $0.name == "Lavoro" }?.id
        let hour: TimeInterval = 3600

        // Physics: lined, title, handwriting, a boxed formula, highlighter and a force diagram.
        var fisica = library.create(title: "Fisica 1", cover: 1, style: .elastic, template: .lined, paper: .white, format: .a4Portrait, folder: nil)
        fisica.pages += [PageInfo(template: .lined, size: PageFormat.a4Portrait.size), PageInfo(template: .lined, size: PageFormat.a4Portrait.size)]
        fisica.favorite = true
        fisica.pages[0].bookmarked = true
        do {
            let p = fisica.pages[0]
            var d: [PKStroke] = []
            let blue = UIColor(hex: "1D4ED8"), black = UIColor(hex: "1C1C20"), red = UIColor(hex: "DC2626")
            d += marker(from: CGPoint(x: 78, y: 175), to: CGPoint(x: 330, y: 175), color: UIColor(hex: "FDE047"))
            for k in 0..<4 { d += writeLine(x0: 78, x1: 540, baseline: 180 + CGFloat(k) * 24, size: 7, color: black, rng: &rng) }
            d.append(wobblyRect(CGRect(x: 196, y: 286, width: 210, height: 58), color: red, width: 2, rng: &rng))
            for k in 0..<5 { d += writeLine(x0: 78, x1: k == 4 ? 330 : 540, baseline: 396 + CGFloat(k) * 24, size: 7, color: black, rng: &rng) }
            // force diagram
            d.append(wobblyRect(CGRect(x: 250, y: 600, width: 96, height: 66), color: black, width: 2, rng: &rng))
            d += arrow(from: CGPoint(x: 346, y: 633), to: CGPoint(x: 470, y: 633), color: blue)
            d += arrow(from: CGPoint(x: 298, y: 666), to: CGPoint(x: 298, y: 770), color: red)
            d += arrow(from: CGPoint(x: 250, y: 633), to: CGPoint(x: 150, y: 633), color: UIColor(hex: "15803D"))
            Store.saveDrawing(PKDrawing(strokes: d), fisica.id, p.id)
            Store.saveItems([
                text("Dinamica — le leggi di Newton", x: 74, y: 82, w: 470, size: 24, color: "1D4ED8", bold: true),
                text("F = m · a", x: 206, y: 292, w: 200, size: 30, color: "DC2626", bold: true),
                text("F", x: 478, y: 616, w: 30, size: 18, color: "1D4ED8", bold: true),
                text("P", x: 306, y: 752, w: 30, size: 18, color: "DC2626", bold: true),
                text("attrito", x: 92, y: 604, w: 70, size: 15, color: "15803D"),
            ], fisica.id, p.id)
        }
        fisica.modified = Date().addingTimeInterval(-0.5 * hour)
        library.save(fisica, touch: false)

        // Calculus: grid paper, axes, a curve and the area under it.
        var analisi = library.create(title: "Analisi 2", cover: 10, style: .label, template: .grid, paper: .ivory, format: .a4Portrait, folder: uni)
        do {
            let p = analisi.pages[0]
            var d: [PKStroke] = []
            let ink = UIColor(hex: "1C1C20"), blue = UIColor(hex: "1D4ED8")
            d += arrow(from: CGPoint(x: 70, y: 470), to: CGPoint(x: 540, y: 470), color: ink)
            d += arrow(from: CGPoint(x: 100, y: 640), to: CGPoint(x: 100, y: 230), color: ink)
            var curve: [CGPoint] = []
            for i in 0...120 {
                let x = 100 + CGFloat(i) * 3.6
                curve.append(CGPoint(x: x, y: 470 - 120 * sin((x - 100) / 70) * exp(-(x - 100) / 600)))
            }
            d.append(stroke(curve, color: blue, width: 2.6))
            for x in stride(from: CGFloat(160), through: 300, by: 9) {
                let y = 470 - 120 * sin((x - 100) / 70) * exp(-(x - 100) / 600)
                d.append(stroke([CGPoint(x: x, y: 470), CGPoint(x: x, y: y)], color: UIColor(hex: "86EFAC"), width: 6, ink: .marker))
            }
            for k in 0..<3 { d += writeLine(x0: 80, x1: 520, baseline: 690 + CGFloat(k) * 26, size: 7, color: ink, rng: &rng) }
            Store.saveDrawing(PKDrawing(strokes: d), analisi.id, p.id)
            Store.saveItems([
                text("Integrali definiti", x: 76, y: 70, w: 400, size: 26, color: "1C1C20", bold: true),
                text("∫ₐᵇ f(x) dx = F(b) − F(a)", x: 76, y: 120, w: 440, size: 22, color: "7C3AED"),
                text("a", x: 152, y: 476, w: 24, size: 16, color: "1C1C20"),
                text("b", x: 292, y: 476, w: 24, size: 16, color: "1C1C20"),
                text("teorema fondamentale (Newton–Leibniz)", x: 300, y: 300, w: 230, size: 14, color: "15803D"),
            ], analisi.id, p.id)
        }
        analisi.modified = Date().addingTimeInterval(-26 * hour)
        library.save(analisi, touch: false)

        // History: dates under study tape, and flashcards made from the page.
        var storia = library.create(title: "Storia moderna", cover: 6, style: .waves, template: .lined, paper: .ivory, format: .a4Portrait, folder: uni)
        do {
            let p = storia.pages[0]
            var d: [PKStroke] = []
            let ink = UIColor(hex: "1C1C20")
            var items = [text("La Rivoluzione francese", x: 74, y: 40, w: 460, size: 26, color: "1D4ED8", bold: true)]
            let events = [("1789", "presa della Bastiglia (14 luglio)"), ("1791", "prima Costituzione, monarchia costituzionale"),
                          ("1792", "nasce la Repubblica"), ("1793", "il Terrore di Robespierre"), ("1799", "colpo di Stato di Napoleone")]
            var tapes: [PageItem] = []
            var cards: [Flashcard] = []
            for (i, e) in events.enumerated() {
                let y = 106 + CGFloat(i) * 72
                items.append(text(e.0, x: 74, y: y, w: 70, size: 20, color: "DC2626", bold: true))
                items.append(text(e.1, x: 150, y: y + 2, w: 390, size: 17, color: "1C1C20"))
                d += writeLine(x0: 150, x1: 470 - CGFloat(i % 3) * 50, baseline: y + 58, size: 6.5, color: ink, rng: &rng)
                var tape = PageItem(kind: .tape, x: 70, y: Double(y) + 2, w: 72, h: 30)
                tape.color = TapeColors.all[i % 3]
                if i == 1 { tape.covered = false }
                tapes.append(tape)
                cards.append(Flashcard(page: p.id, front: CGRect(x: 146, y: y - 2, width: 400, height: 34), back: CGRect(x: 68, y: y - 2, width: 80, height: 34),
                                       created: Date().addingTimeInterval(TimeInterval(i))))
            }
            d += writeLine(x0: 78, x1: 520, baseline: 520, size: 7, color: ink, rng: &rng)
            d += writeLine(x0: 78, x1: 380, baseline: 544, size: 7, color: ink, rng: &rng)
            Store.saveDrawing(PKDrawing(strokes: d), storia.id, p.id)
            Store.saveItems(items + tapes, storia.id, p.id)
            cards[4].due = Date().addingTimeInterval(3 * 86400)
            cards[4].reps = 2
            cards[4].interval = 3
            storia.cards = cards
        }
        storia.modified = Date().addingTimeInterval(-2 * hour)
        library.save(storia, touch: false)

        var chimica = library.create(title: "Chimica", cover: 2, style: .leaves, template: .grid, paper: .white, format: .a4Portrait, folder: uni)
        chimica.modified = Date().addingTimeInterval(-80 * hour)
        library.save(chimica, touch: false)

        // Ideas: dotted page with a small mind map.
        var idee = library.create(title: "Idee progetto", cover: 4, style: .aurora, template: .dotted, paper: .white, format: .a4Portrait, folder: nil)
        do {
            let p = idee.pages[0]
            var d: [PKStroke] = []
            let purple = UIColor(hex: "7C3AED"), green = UIColor(hex: "15803D")
            let center = CGPoint(x: 297, y: 400)
            d.append(ellipse(center: center, rx: 95, ry: 46, color: purple, width: 2.4, rng: &rng))
            let spots: [(CGPoint, String)] = [(CGPoint(x: 140, y: 220), "Penna e gomma"), (CGPoint(x: 460, y: 220), "PDF"),
                                              (CGPoint(x: 140, y: 600), "Ricerca"), (CGPoint(x: 460, y: 600), "iCloud Drive")]
            var items = [text("Appunti", x: center.x - 60, y: center.y - 18, w: 120, size: 22, color: "7C3AED", bold: true)]
            for (pt, label) in spots {
                d.append(ellipse(center: pt, rx: 82, ry: 36, color: green, width: 2, rng: &rng))
                let dx = pt.x - center.x, dy = pt.y - center.y
                let len = sqrt(dx * dx + dy * dy)
                d.append(stroke([CGPoint(x: center.x + dx / len * 100, y: center.y + dy / len * 50),
                                 CGPoint(x: pt.x - dx / len * 82, y: pt.y - dy / len * 38)], color: UIColor(hex: "1C1C20"), width: 1.8))
                items.append(text(label, x: pt.x - 70, y: pt.y - 14, w: 140, size: 16, color: "15803D", bold: true))
            }
            for k in 0..<3 { d += writeLine(x0: 70, x1: 520, baseline: 730 + CGFloat(k) * 24, size: 7, color: UIColor(hex: "1C1C20"), rng: &rng) }
            Store.saveDrawing(PKDrawing(strokes: d), idee.id, p.id)
            Store.saveItems(items, idee.id, p.id)
        }
        idee.modified = Date().addingTimeInterval(-3 * hour)
        library.save(idee, touch: false)

        // Trip: lined, a "photo" and some handwriting.
        var viaggio = library.create(title: "Viaggio Giappone", cover: 1, style: .mountains, template: .lined, paper: .ivory, format: .a4Portrait, folder: nil)
        do {
            let p = viaggio.pages[0]
            var d: [PKStroke] = []
            for k in 0..<6 { d += writeLine(x0: 78, x1: 540, baseline: 132 + CGFloat(k) * 24, size: 7, color: UIColor(hex: "1C1C20"), rng: &rng) }
            Store.saveDrawing(PKDrawing(strokes: d), viaggio.id, p.id)
            var items = [text("Kyoto — giorno 3", x: 74, y: 40, w: 400, size: 24, color: "EA580C", bold: true)]
            if let (name, _) = Store.saveImage(landscape(), viaggio.id) {
                var img = PageItem(kind: .image, x: 110, y: 300, w: 375, h: 250)
                img.image = name
                items.append(img)
            }
            Store.saveItems(items, viaggio.id, p.id)
        }
        viaggio.modified = Date().addingTimeInterval(-50 * hour)
        library.save(viaggio, touch: false)

        // Shopping list on the checklist ruling.
        var spesa = library.create(title: "Lista della spesa", cover: 3, style: .dots, template: .checklist, paper: .white, format: .a4Portrait, folder: nil)
        do {
            let p = spesa.pages[0]
            var d: [PKStroke] = []
            for k in 0..<7 {
                let base: CGFloat = 96 + CGFloat(k) * 32
                let end = 160 + rng.next() * 160
                d += writeLine(x0: 70, x1: end, baseline: base - 4, size: 7, color: UIColor(hex: "1C1C20"), rng: &rng)
                if k < 4 {
                    d.append(stroke([CGPoint(x: 41, y: base - 12), CGPoint(x: 46, y: base - 6), CGPoint(x: 56, y: base - 22)], color: UIColor(hex: "15803D"), width: 2.4))
                }
            }
            Store.saveDrawing(PKDrawing(strokes: d), spesa.id, p.id)
        }
        spesa.modified = Date().addingTimeInterval(-6 * hour)
        library.save(spesa, touch: false)

        var riunioni = library.create(title: "Riunioni", cover: 8, style: .marble, template: .cornell, paper: .white, format: .a4Portrait, folder: work)
        riunioni.modified = Date().addingTimeInterval(-30 * hour)
        library.save(riunioni, touch: false)

        var diario = library.create(title: "Diario", cover: nil, style: .plain, template: .narrow, paper: .ivory, format: .a4Portrait, folder: nil)
        do {
            let p = diario.pages[0]
            var d: [PKStroke] = []
            for k in 0..<14 { d += writeLine(x0: 40, x1: k == 13 ? 300 : 555, baseline: 96 + CGFloat(k) * 36, size: 9, color: UIColor(hex: "1D4ED8"), rng: &rng) }
            Store.saveDrawing(PKDrawing(strokes: d), diario.id, p.id)
            Store.saveItems([text("5 novembre", x: 36, y: 20, w: 300, size: 22, color: "1D4ED8", bold: true)], diario.id, p.id)
        }
        diario.modified = Date().addingTimeInterval(-120 * hour)
        library.save(diario, touch: false)

        // A PDF handout, highlighted and annotated.
        if let url = handoutPDF(), var pdf = library.importPDF(url, folder: nil) {
            let p = pdf.pages[0]
            var d: [PKStroke] = []
            for (line, len) in [(4, 330.0), (9, 260.0), (14, 300.0)] {
                let y = 150 + CGFloat(line) * 20 - 4
                d += marker(from: CGPoint(x: 62, y: y), to: CGPoint(x: 62 + len, y: y), color: UIColor(hex: "FDE047"))
            }
            d.append(ellipse(center: CGPoint(x: 180, y: 487), rx: 128, ry: 18, color: UIColor(hex: "DC2626"), width: 2, rng: &rng))
            d += arrow(from: CGPoint(x: 470, y: 562), to: CGPoint(x: 316, y: 497), color: UIColor(hex: "DC2626"))
            Store.saveDrawing(PKDrawing(strokes: d), pdf.id, p.id)
            Store.saveItems([text("da sapere per l'esame!", x: 380, y: 568, w: 180, size: 15, color: "DC2626", bold: true)], pdf.id, p.id)
            pdf.modified = Date().addingTimeInterval(-1.5 * hour)
            library.save(pdf, touch: false)
            try? FileManager.default.removeItem(at: url)
        }

        for nb in library.notebooks { library.refreshThumb(nb.id) }
    }

    /// Draws one of each shape with the shape tool's own code, for the screenshot.
    static func drawShapes(_ model: EditorModel) {
        model.select(.shape)
        model.setShape(.arrow)
        let c = model.canvas
        func style(_ k: ShapeKind, _ hex: String, _ w: CGFloat) -> PageCanvasView.ShapeStyle {
            PageCanvasView.ShapeStyle(kind: k, color: UIColor(hex: hex), width: w)
        }
        c.addShape(style(.rectangle, "1C1C20", 3), from: CGPoint(x: 90, y: 110), to: CGPoint(x: 270, y: 230))
        c.addShape(style(.ellipse, "1D4ED8", 3), from: CGPoint(x: 330, y: 110), to: CGPoint(x: 510, y: 230))
        c.addShape(style(.arrow, "DC2626", 3), from: CGPoint(x: 180, y: 240), to: CGPoint(x: 180, y: 360))
        c.addShape(style(.arrow, "DC2626", 3), from: CGPoint(x: 420, y: 240), to: CGPoint(x: 420, y: 360))
        c.addShape(style(.rectangle, "15803D", 5), from: CGPoint(x: 130, y: 370), to: CGPoint(x: 470, y: 470))
        c.addShape(style(.line, "1C1C20", 1.5), from: CGPoint(x: 90, y: 540), to: CGPoint(x: 510, y: 540))
        c.addShape(style(.line, "7C3AED", 5), from: CGPoint(x: 90, y: 600), to: CGPoint(x: 510, y: 690))
        c.addShape(style(.ellipse, "EA580C", 1.5), from: CGPoint(x: 220, y: 610), to: CGPoint(x: 380, y: 770))
    }

    // MARK: Ink helpers

    struct Rng {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z % 10_000) / 10_000
        }
    }

    /// Strokes built in code: the pen ink thins them with its pressure and speed model (thin ones
    /// vanish), so pen lines use the uniform monoline ink; the marker gets a wider tip.
    static func stroke(_ pts: [CGPoint], color: UIColor, width: CGFloat, ink: PKInk.InkType = .pen) -> PKStroke {
        let type: PKInk.InkType = ink == .pen ? .monoline : ink
        // measured in the simulator: code-made pen lines come out about 1.7 pt thinner than asked
        let w = ink == .marker ? width * 2 : width * 0.6 + 2
        let sp = pts.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.02, size: CGSize(width: w, height: w),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(type, color: color), path: PKStrokePath(controlPoints: sp, creationDate: Date()))
    }

    /// A line of cursive-looking scribble: words of looped letters, slanted, with some tall letters.
    static func writeLine(x0: CGFloat, x1: CGFloat, baseline: CGFloat, size: CGFloat, color: UIColor, rng: inout Rng) -> [PKStroke] {
        var out: [PKStroke] = []
        var x = x0
        while x < x1 - size * 3 {
            let letters = 2 + Int(rng.next() * 6)
            var pts: [CGPoint] = []
            var cx = x
            for _ in 0..<letters {
                let tall = rng.next() < 0.2
                let h = (tall ? 2.2 : 1) * size * (0.9 + rng.next() * 0.2)
                let w = size * (0.8 + rng.next() * 0.45)
                let n = 12
                for i in 0...n {
                    let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                    var px = cx + w * t / (2 * .pi) - w * 0.42 * sin(t)
                    let py = baseline - h * (1 + cos(t)) / 2 + (rng.next() - 0.5) * 0.6
                    px += (baseline - py) * 0.28
                    pts.append(CGPoint(x: px, y: py))
                }
                cx += w
                if cx > x1 { break }
            }
            out.append(stroke(pts, color: color, width: 1.5))
            x = cx + size * (1.1 + rng.next() * 0.6)
        }
        return out
    }

    static func marker(from a: CGPoint, to b: CGPoint, color: UIColor) -> [PKStroke] {
        [stroke([a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 1), b], color: color, width: 16, ink: .marker)]
    }

    static func arrow(from a: CGPoint, to b: CGPoint, color: UIColor) -> [PKStroke] {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let head: CGFloat = 13
        let l = CGPoint(x: b.x - head * cos(ang - 0.45), y: b.y - head * sin(ang - 0.45))
        let r = CGPoint(x: b.x - head * cos(ang + 0.45), y: b.y - head * sin(ang + 0.45))
        return [stroke([a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), b], color: color, width: 2.2),
                stroke([l, b, r], color: color, width: 2.2)]
    }

    static func wobblyRect(_ r: CGRect, color: UIColor, width: CGFloat, rng: inout Rng) -> PKStroke {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + 3, y: r.minY - 2)]
        var pts: [CGPoint] = []
        for i in 0..<(corners.count - 1) {
            for k in 0..<8 {
                let t = CGFloat(k) / 8
                pts.append(CGPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t + (rng.next() - 0.5) * 1.6,
                                   y: corners[i].y + (corners[i + 1].y - corners[i].y) * t + (rng.next() - 0.5) * 1.6))
            }
        }
        pts.append(corners.last!)
        return stroke(pts, color: color, width: width)
    }

    static func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat, color: UIColor, width: CGFloat, rng: inout Rng) -> PKStroke {
        var pts: [CGPoint] = []
        for i in 0...44 {
            let t = CGFloat(i) / 40 * 2 * .pi - 0.3
            let k = 1 + (rng.next() - 0.5) * 0.03
            pts.append(CGPoint(x: c.x + rx * k * cos(t), y: c.y + ry * k * sin(t)))
        }
        return stroke(pts, color: color, width: width)
    }

    static func text(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat, color: String, bold: Bool = false) -> PageItem {
        var item = PageItem(kind: .text, x: x, y: y, w: w, h: size + 18)
        item.text = s
        item.fontSize = size
        item.color = color
        item.bold = bold
        return item
    }

    /// A small drawn "photo": sky, sun, mountains and a pagoda roof line.
    static func landscape() -> UIImage {
        let size = CGSize(width: 900, height: 600)
        return UIGraphicsImageRenderer(size: size).image { r in
            let c = r.cgContext
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [UIColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1).cgColor,
                                          UIColor(red: 0.99, green: 0.86, blue: 0.62, alpha: 1).cgColor] as CFArray,
                                 locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 420), options: [.drawsAfterEndLocation])
            UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 560, y: 120, width: 120, height: 120))
            UIColor(red: 0.42, green: 0.36, blue: 0.52, alpha: 1).setFill()
            c.move(to: CGPoint(x: 0, y: 470)); c.addLine(to: CGPoint(x: 260, y: 200)); c.addLine(to: CGPoint(x: 330, y: 260))
            c.addLine(to: CGPoint(x: 470, y: 150)); c.addLine(to: CGPoint(x: 900, y: 480)); c.addLine(to: CGPoint(x: 900, y: 600))
            c.addLine(to: CGPoint(x: 0, y: 600)); c.fillPath()
            UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1).setFill()
            c.move(to: CGPoint(x: 430, y: 180)); c.addLine(to: CGPoint(x: 470, y: 150)); c.addLine(to: CGPoint(x: 510, y: 182)); c.fillPath()
            UIColor(red: 0.24, green: 0.2, blue: 0.3, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 520, width: 900, height: 80))
            UIColor(red: 0.62, green: 0.16, blue: 0.14, alpha: 1).setFill()
            for (i, w) in [CGFloat(150), 120, 92].enumerated() {
                let y = 380 + CGFloat(i) * 46
                c.move(to: CGPoint(x: 160 - w / 2 - 20, y: y + 26)); c.addLine(to: CGPoint(x: 160, y: y)); c.addLine(to: CGPoint(x: 160 + w / 2 + 20, y: y + 26)); c.fillPath()
            }
            c.fill(CGRect(x: 125, y: 470, width: 70, height: 60))
        }
    }

    /// A one-page course handout, written into a temporary PDF.
    static func handoutPDF() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dispensa termodinamica.pdf")
        let lines = [
            "1. Il primo principio",
            "",
            "Il primo principio della termodinamica esprime la conservazione dell'energia:",
            "la variazione dell'energia interna di un sistema chiuso è uguale al calore",
            "scambiato con l'ambiente meno il lavoro compiuto dal sistema, ΔU = Q − L.",
            "Il calore e il lavoro non sono funzioni di stato: dipendono dalla trasformazione",
            "seguita, mentre l'energia interna dipende solo dallo stato iniziale e finale.",
            "",
            "2. Trasformazioni notevoli",
            "In una trasformazione isoterma di un gas perfetto l'energia interna non cambia,",
            "quindi tutto il calore assorbito viene convertito in lavoro. In una adiabatica",
            "non c'è scambio di calore e il lavoro avviene a spese dell'energia interna.",
            "",
            "3. Il secondo principio",
            "Non è possibile realizzare una trasformazione il cui unico risultato sia",
            "convertire in lavoro tutto il calore preso da una sola sorgente (Kelvin–Planck).",
            "Il rendimento di una macchina termica reversibile tra due sorgenti dipende solo",
            "dalle loro temperature: η = 1 − T₂ / T₁.",
            "",
            "4. Entropia",
            "L'entropia di un sistema isolato non diminuisce mai: resta costante nelle",
            "trasformazioni reversibili e aumenta in quelle irreversibili.",
        ]
        let page = CGRect(origin: .zero, size: PageFormat.a4Portrait.size)
        do {
            try UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { ctx in
                ctx.beginPage()
                ("Termodinamica — dispensa del corso" as NSString).draw(at: CGPoint(x: 62, y: 70), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor(white: 0.1, alpha: 1)])
                ("Fisica tecnica · lezione 7" as NSString).draw(at: CGPoint(x: 62, y: 100), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.gray])
                for (i, l) in lines.enumerated() {
                    let heading = l.first?.isNumber == true
                    (l as NSString).draw(at: CGPoint(x: 62, y: 140 + CGFloat(i) * 20), withAttributes: [
                        .font: UIFont.systemFont(ofSize: heading ? 13 : 11.5, weight: heading ? .semibold : .regular),
                        .foregroundColor: UIColor(white: 0.12, alpha: 1)])
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
