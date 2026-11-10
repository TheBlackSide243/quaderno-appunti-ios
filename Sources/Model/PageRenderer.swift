import PDFKit
import PencilKit
import UIKit

/// Draws pages: paper and ruling (or the PDF page), boxes and ink. Used for the editor background,
/// thumbnails, handwriting recognition and the PDF export.
enum PageRenderer {
    static let lineColor = UIColor(red: 0.62, green: 0.70, blue: 0.82, alpha: 0.75)
    static let marginColor = UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 0.65)

    /// Size of a PDF page as shown (crop box, with its rotation applied).
    static func pdfPageSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox).size
        let r = ((page.rotation % 360) + 360) % 360
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b
    }

    /// Paper, ruling and PDF page, in page coordinates (top-left origin), into a UIKit context.
    static func drawBackground(_ nb: Notebook, _ page: PageInfo, in ctx: CGContext) {
        let rect = CGRect(origin: .zero, size: page.size)
        ctx.setFillColor(nb.paper.uiColor.cgColor)
        ctx.fill(rect)
        if let i = page.pdfIndex {
            if let doc = PDFCache.shared.document(nb.id), let p = doc.page(at: i), let ref = p.pageRef {
                ctx.saveGState()
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(rect)
                ctx.translateBy(x: 0, y: rect.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(ref)
                ctx.restoreGState()
            }
        }
        drawTemplate(page.template, size: page.size, in: ctx)
    }

    static func drawTemplate(_ t: PageTemplate, size: CGSize, in ctx: CGContext) {
        let w = size.width, h = size.height
        let step: CGFloat = 24
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch t {
        case .blank:
            break
        case .lined, .cornell:
            ctx.setStrokeColor(lineColor.cgColor)
            ctx.setLineWidth(0.6)
            var y: CGFloat = t == .cornell ? 96 : 84
            let bottom = t == .cornell ? h - 150 : h - 30
            let left: CGFloat = t == .cornell ? w * 0.3 : 0
            while y < bottom {
                ctx.move(to: CGPoint(x: left, y: y))
                ctx.addLine(to: CGPoint(x: w, y: y))
                y += step
            }
            ctx.strokePath()
            ctx.setStrokeColor(marginColor.cgColor)
            ctx.setLineWidth(0.9)
            if t == .lined {
                ctx.move(to: CGPoint(x: 64, y: 0))
                ctx.addLine(to: CGPoint(x: 64, y: h))
            } else {
                ctx.move(to: CGPoint(x: 0, y: 72)); ctx.addLine(to: CGPoint(x: w, y: 72))
                ctx.move(to: CGPoint(x: left, y: 72)); ctx.addLine(to: CGPoint(x: left, y: h - 140))
                ctx.move(to: CGPoint(x: 0, y: h - 140)); ctx.addLine(to: CGPoint(x: w, y: h - 140))
            }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(lineColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(0.5)
            let g: CGFloat = 20
            var x = (w.truncatingRemainder(dividingBy: g)) / 2
            while x <= w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += g }
            var y = (h.truncatingRemainder(dividingBy: g)) / 2
            while y <= h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += g }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(lineColor.cgColor)
            let g: CGFloat = 20
            var y = (h.truncatingRemainder(dividingBy: g)) / 2 + g / 2
            while y < h {
                var x = (w.truncatingRemainder(dividingBy: g)) / 2 + g / 2
                while x < w {
                    ctx.fillEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    x += g
                }
                y += g
            }
        }
    }

    static func textAttributes(_ item: PageItem) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: item.fontSize, weight: item.bold ? .bold : .regular),
         .foregroundColor: UIColor(hex: item.color)]
    }

    /// Insets of the text inside a box; the editor's UITextView uses the same so nothing jumps on export.
    static let textInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

    static func drawItems(_ nb: Notebook, _ items: [PageItem]) {
        for item in items {
            switch item.kind {
            case .text:
                let r = item.frame.inset(by: textInset)
                (item.text as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: textAttributes(item), context: nil)
            case .image:
                if let name = item.image, let img = UIImage(contentsOfFile: Store.image(nb.id, name).path) {
                    img.draw(in: item.frame)
                }
            }
        }
    }

    /// The ink as an image, always with light-mode colours (PencilKit inverts ink in dark mode).
    static func inkImage(_ d: PKDrawing, size: CGSize, scale: CGFloat) -> UIImage {
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = d.image(from: CGRect(origin: .zero, size: size), scale: scale)
        }
        return img
    }

    /// The whole page as an image `width` pixels wide.
    static func render(_ nb: Notebook, _ page: PageInfo, width: CGFloat) -> UIImage {
        let k = width / page.size.width
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = k
        fmt.opaque = true
        let drawing = Store.loadDrawing(nb.id, page.id)
        let items = Store.loadItems(nb.id, page.id)
        return UIGraphicsImageRenderer(size: page.size, format: fmt).image { r in
            drawBackground(nb, page, in: r.cgContext)
            drawItems(nb, items)
            if !drawing.strokes.isEmpty {
                inkImage(drawing, size: page.size, scale: k).draw(in: CGRect(origin: .zero, size: page.size))
            }
        }
    }

    /// Only the paper and the ruling/PDF, used behind the editor's canvas.
    static func background(_ nb: Notebook, _ page: PageInfo, scale: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: page.size, format: fmt).image { r in drawBackground(nb, page, in: r.cgContext) }
    }

    /// Exports the notebook (or some of its pages) as a PDF. PDF pages and text stay vector; ink is
    /// embedded as a sharp image.
    static func exportPDF(_ nb: Notebook, pages: [PageInfo]? = nil) throws -> URL {
        let list = pages ?? nb.pages
        let safe = nb.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Appunti" : safe).pdf")
        try? FileManager.default.removeItem(at: url)
        let first = list.first?.size ?? PageFormat.a4Portrait.size
        let info: [String: Any] = [kCGPDFContextTitle as String: nb.title, kCGPDFContextCreator as String: "Appunti"]
        let fmt = UIGraphicsPDFRendererFormat()
        fmt.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first), format: fmt)
        try renderer.writePDF(to: url) { ctx in
            for page in list {
                autoreleasepool {
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                    drawBackground(nb, page, in: ctx.cgContext)
                    drawItems(nb, Store.loadItems(nb.id, page.id))
                    let d = Store.loadDrawing(nb.id, page.id)
                    if !d.strokes.isEmpty {
                        inkImage(d, size: page.size, scale: 3).draw(in: CGRect(origin: .zero, size: page.size))
                    }
                }
            }
        }
        return url
    }
}
