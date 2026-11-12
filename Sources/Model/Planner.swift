import UIKit

/// A planner for a year, ready to write in: the year, one page per month and one per week, with
/// links between them (from the year to the months, from a month to its weeks and back).
/// The calendars are drawn into a PDF that becomes the paper of the notebook.
@MainActor
enum Planner {
    static let size = PageFormat.a4Portrait.size

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale.current
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// The Mondays of the weeks that touch the year.
    static func weeks(_ year: Int) -> [Date] {
        let cal = calendar
        let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31))!
        let back = (cal.component(.weekday, from: jan1) + 5) % 7
        var monday = cal.date(byAdding: .day, value: -back, to: jan1)!
        var out: [Date] = []
        while monday <= dec31 {
            out.append(monday)
            monday = cal.date(byAdding: .day, value: 7, to: monday)!
        }
        return out
    }

    private static func monthName(_ m: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        return f.standaloneMonthSymbols[m - 1].capitalized(with: Locale.current)
    }

    private static func dayNames() -> [String] {
        let f = DateFormatter()
        f.locale = Locale.current
        let s = f.shortStandaloneWeekdaySymbols ?? []
        // Monday first
        return s.count == 7 ? Array(s[1...] + s[..<1]) : ["L", "M", "M", "G", "V", "S", "D"]
    }

    private static func longDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEE d")
        return f.string(from: d).capitalized(with: Locale.current)
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d)
    }

    // MARK: Making it

    static func make(_ year: Int, library: Library, folder: UUID?) -> Notebook? {
        let weekList = weeks(year)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(localized: "Agenda \(String(year))") + ".pdf")
        do {
            try drawPDF(year, weeks: weekList, to: url)
        } catch {
            library.error = String(localized: "Non riesco a preparare l'agenda: \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard var nb = library.importPDF(url, folder: folder) else { return nil }
        nb.title = String(localized: "Agenda \(String(year))")
        nb.cover = 9
        nb.coverStyle = .label
        let ids = nb.pages.map(\.id)
        guard ids.count == 1 + 12 + weekList.count else { library.save(nb); return nb }
        let cal = calendar
        func month(_ m: Int) -> UUID { ids[m] }
        func week(_ i: Int) -> UUID { ids[13 + i] }
        func weekIndex(_ d: Date) -> Int {
            let days = cal.dateComponents([.day], from: weekList[0], to: d).day ?? 0
            return max(0, min(weekList.count - 1, days / 7))
        }

        // the year: each month leads to its page
        var yearItems: [PageItem] = []
        for m in 1...12 {
            let r = yearCell(m)
            yearItems.append(link(monthName(m), x: r.minX + 6, y: r.minY, w: r.width - 34, size: 14, bold: true, to: month(m)))
        }
        Store.saveItems(yearItems, nb.id, ids[0])

        // the months: back to the year, and the list of their weeks
        for m in 1...12 {
            var items = [link(String(year), x: size.width - 150, y: 34, w: 100, size: 14, bold: true, to: ids[0])]
            let first = cal.date(from: DateComponents(year: year, month: m, day: 1))!
            let days = cal.range(of: .day, in: .month, for: first)!.count
            let last = cal.date(byAdding: .day, value: days - 1, to: first)!
            var y: CGFloat = monthListTop
            for w in weekIndex(first)...weekIndex(last) {
                let mon = weekList[w], sun = cal.date(byAdding: .day, value: 6, to: mon)!
                let n = cal.component(.weekOfYear, from: mon)
                items.append(link(String(localized: "Settimana \(n) · \(shortDate(mon)) – \(shortDate(sun))"), x: 56, y: y, w: 300, size: 13, bold: false, to: week(w)))
                y += 26
            }
            Store.saveItems(items, nb.id, month(m))
        }

        // the weeks: back to their month and to the year
        for (i, mon) in weekList.enumerated() {
            let thu = cal.date(byAdding: .day, value: 3, to: mon)!
            var m = cal.component(.month, from: thu)
            if cal.component(.year, from: thu) != year { m = cal.component(.year, from: thu) < year ? 1 : 12 }
            let items = [
                link(monthName(m), x: size.width - 250, y: 34, w: 110, size: 13, bold: true, to: month(m)),
                link(String(year), x: size.width - 120, y: 34, w: 70, size: 13, bold: true, to: ids[0]),
            ]
            Store.saveItems(items, nb.id, week(i))
        }
        library.save(nb)
        library.refreshThumb(nb.id)
        for p in nb.pages { Indexer.shared.schedule(nb, page: p.id) }
        return nb
    }

    private static func link(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, size: Double, bold: Bool, to page: UUID) -> PageItem {
        var item = PageItem(kind: .text, x: Double(x), y: Double(y), w: Double(w), h: size + 14)
        item.text = text
        item.fontSize = size
        item.bold = bold
        item.color = "1D4ED8"
        item.link = page
        return item
    }

    // MARK: Drawing

    private static let ink = UIColor(hex: "1C1C20")
    private static let soft = UIColor(hex: "94A3B8")
    private static let line = UIColor(red: 0.62, green: 0.70, blue: 0.82, alpha: 0.8)
    private static let accent = UIColor(hex: "1D4ED8")
    private static let monthListTop: CGFloat = 640

    private static func yearCell(_ m: Int) -> CGRect {
        let cols = 3, w: CGFloat = 160, h: CGFloat = 160
        let x0: CGFloat = (size.width - CGFloat(cols) * w) / 2
        let i = m - 1
        return CGRect(x: x0 + CGFloat(i % cols) * w, y: 120 + CGFloat(i / cols) * (h + 10), width: w, height: h)
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink, center: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let ns = s as NSString
        if let w = center {
            let sz = ns.size(withAttributes: attrs)
            ns.draw(at: CGPoint(x: p.x + (w - sz.width) / 2, y: p.y), withAttributes: attrs)
        } else {
            ns.draw(at: p, withAttributes: attrs)
        }
    }

    private static func drawPDF(_ year: Int, weeks: [Date], to url: URL) throws {
        let cal = calendar
        let names = dayNames()
        let bounds = CGRect(origin: .zero, size: size)
        let fmt = UIGraphicsPDFRendererFormat()
        fmt.documentInfo = [kCGPDFContextTitle as String: String(localized: "Agenda \(String(year))"), kCGPDFContextCreator as String: "Quaderno Appunti"]
        try UIGraphicsPDFRenderer(bounds: bounds, format: fmt).writePDF(to: url) { ctx in
            let c = ctx.cgContext

            // the year
            ctx.beginPage()
            text(String(year), at: CGPoint(x: 56, y: 40), size: 40, weight: .heavy, color: accent)
            for m in 1...12 {
                let r = yearCell(m)
                let first = cal.date(from: DateComponents(year: year, month: m, day: 1))!
                let days = cal.range(of: .day, in: .month, for: first)!.count
                let offset = (cal.component(.weekday, from: first) + 5) % 7
                let cw = (r.width - 12) / 7
                for (k, n) in names.enumerated() {
                    text(String(n.prefix(1)).uppercased(), at: CGPoint(x: r.minX + 6 + CGFloat(k) * cw, y: r.minY + 26), size: 8, weight: .semibold, color: soft, center: cw)
                }
                for d in 0..<days {
                    let cell = offset + d
                    let col = cell % 7, row = cell / 7
                    text("\(d + 1)", at: CGPoint(x: r.minX + 6 + CGFloat(col) * cw, y: r.minY + 42 + CGFloat(row) * 18), size: 9,
                         color: col >= 5 ? UIColor(hex: "DC2626") : ink, center: cw)
                }
            }

            // the months
            for m in 1...12 {
                ctx.beginPage()
                text(monthName(m), at: CGPoint(x: 56, y: 36), size: 30, weight: .bold, color: accent)
                text(String(year), at: CGPoint(x: 56, y: 74), size: 14, weight: .medium, color: soft)
                let first = cal.date(from: DateComponents(year: year, month: m, day: 1))!
                let days = cal.range(of: .day, in: .month, for: first)!.count
                let offset = (cal.component(.weekday, from: first) + 5) % 7
                let rows = Int((Double(offset + days) / 7).rounded(.up))
                let grid = CGRect(x: 40, y: 120, width: size.width - 80, height: monthListTop - 150)
                let cw = grid.width / 7, ch = (grid.height - 22) / CGFloat(rows)
                for (k, n) in names.enumerated() {
                    text(n.uppercased(), at: CGPoint(x: grid.minX + CGFloat(k) * cw, y: grid.minY), size: 10, weight: .semibold, color: soft, center: cw)
                }
                c.setStrokeColor(line.cgColor)
                c.setLineWidth(0.6)
                for r in 0...rows {
                    let y = grid.minY + 22 + CGFloat(r) * ch
                    c.move(to: CGPoint(x: grid.minX, y: y)); c.addLine(to: CGPoint(x: grid.maxX, y: y))
                }
                for k in 0...7 {
                    let x = grid.minX + CGFloat(k) * cw
                    c.move(to: CGPoint(x: x, y: grid.minY + 22)); c.addLine(to: CGPoint(x: x, y: grid.minY + 22 + CGFloat(rows) * ch))
                }
                c.strokePath()
                for d in 0..<days {
                    let cell = offset + d
                    let col = cell % 7, row = cell / 7
                    text("\(d + 1)", at: CGPoint(x: grid.minX + CGFloat(col) * cw + 6, y: grid.minY + 26 + CGFloat(row) * ch), size: 11,
                         weight: .semibold, color: col >= 5 ? UIColor(hex: "DC2626") : ink)
                }
                text(String(localized: "Settimane"), at: CGPoint(x: 56, y: monthListTop - 24), size: 12, weight: .semibold, color: soft)
            }

            // the weeks
            for mon in weeks {
                ctx.beginPage()
                let n = cal.component(.weekOfYear, from: mon)
                let sun = cal.date(byAdding: .day, value: 6, to: mon)!
                text(String(localized: "Settimana \(n)"), at: CGPoint(x: 56, y: 32), size: 24, weight: .bold, color: accent)
                text("\(shortDate(mon)) – \(shortDate(sun))", at: CGPoint(x: 56, y: 64), size: 13, weight: .medium, color: soft)
                let top: CGFloat = 96, bottom = size.height - 36
                let h = (bottom - top) / 7
                for d in 0..<7 {
                    let day = cal.date(byAdding: .day, value: d, to: mon)!
                    let y = top + CGFloat(d) * h
                    text(longDay(day), at: CGPoint(x: 56, y: y + 6), size: 12, weight: .semibold, color: d >= 5 ? UIColor(hex: "DC2626") : ink)
                    c.setStrokeColor(line.cgColor)
                    c.setLineWidth(0.8)
                    c.move(to: CGPoint(x: 40, y: y)); c.addLine(to: CGPoint(x: size.width - 40, y: y))
                    c.strokePath()
                    c.setLineWidth(0.4)
                    var ly = y + 46
                    while ly < y + h - 6 {
                        c.move(to: CGPoint(x: 56, y: ly)); c.addLine(to: CGPoint(x: size.width - 40, y: ly))
                        ly += 22
                    }
                    c.strokePath()
                }
            }
        }
    }
}
