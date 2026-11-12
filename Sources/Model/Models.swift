import Foundation
import SwiftUI
import UIKit

/// The ruling printed on a page.
enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted, cornell, narrow, checklist, music
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: String(localized: "Bianca")
        case .lined: String(localized: "Righe")
        case .grid: String(localized: "Quadretti")
        case .dotted: String(localized: "Puntini")
        case .cornell: String(localized: "Cornell")
        case .narrow: String(localized: "Righe strette")
        case .checklist: String(localized: "Elenco")
        case .music: String(localized: "Pentagramma")
        }
    }

    /// How the gallery of the new notebook groups the rulings.
    static let groups: [(String, [PageTemplate])] = [
        (String(localized: "Essenziali"), [.blank, .dotted, .grid, .lined, .narrow]),
        (String(localized: "Studio e organizzazione"), [.cornell, .checklist, .music]),
    ]
}

/// The look of a notebook cover: the three classic ones and the illustrated ones, each in every
/// cover colour.
enum CoverStyle: String, Codable, CaseIterable, Identifiable {
    case plain, elastic, label
    case waves, mosaic, dots, marble, leaves, mountains, stars, terrazzo, aurora
    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: String(localized: "Semplice")
        case .elastic: String(localized: "Con elastico")
        case .label: String(localized: "Con etichetta")
        case .waves: String(localized: "Onde")
        case .mosaic: String(localized: "Mosaico")
        case .dots: String(localized: "Pois")
        case .marble: String(localized: "Marmo")
        case .leaves: String(localized: "Foglie")
        case .mountains: String(localized: "Montagne")
        case .stars: String(localized: "Notte stellata")
        case .terrazzo: String(localized: "Terrazzo")
        case .aurora: String(localized: "Aurora")
        }
    }

    static let classic: [CoverStyle] = [.plain, .elastic, .label]
    static let illustrated: [CoverStyle] = [.waves, .mosaic, .dots, .marble, .leaves, .mountains, .stars, .terrazzo, .aurora]

    var isIllustrated: Bool { !Self.classic.contains(self) }

    /// Seed of the pattern, so each style always draws the same picture.
    var seed: UInt64 {
        rawValue.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    }

    /// A style this version does not know (written by a newer one) opens as a plain cover.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CoverStyle(rawValue: raw) ?? .plain
    }
}

/// The shapes of the shape tool.
enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse
    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: String(localized: "Linea")
        case .arrow: String(localized: "Freccia")
        case .rectangle: String(localized: "Rettangolo")
        case .ellipse: String(localized: "Ellisse")
        }
    }

    var icon: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }
}

/// How the shelf is ordered.
enum SortOrder: String, CaseIterable, Identifiable {
    case date, name, kind
    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: String(localized: "Data")
        case .name: String(localized: "Nome")
        case .kind: String(localized: "Tipo")
        }
    }
}

/// The colour of the paper. Ink keeps its real colour, so the paper is always light.
enum Paper: String, Codable, CaseIterable, Identifiable {
    case white, ivory, yellow, gray
    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: String(localized: "paper.white", defaultValue: "Bianca")
        case .ivory: String(localized: "Avorio")
        case .yellow: String(localized: "Gialla")
        case .gray: String(localized: "Grigio chiaro")
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: UIColor(white: 1, alpha: 1)
        case .ivory: UIColor(red: 0.992, green: 0.973, blue: 0.918, alpha: 1)
        case .yellow: UIColor(red: 0.973, green: 0.957, blue: 0.890, alpha: 1)
        case .gray: UIColor(red: 0.925, green: 0.929, blue: 0.937, alpha: 1)
        }
    }
}

/// Page sizes in PDF points.
enum PageFormat: String, Codable, CaseIterable, Identifiable {
    case a4Portrait, a4Landscape, letter, square
    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4Portrait: String(localized: "A4 verticale")
        case .a4Landscape: String(localized: "A4 orizzontale")
        case .letter: String(localized: "Lettera")
        case .square: String(localized: "Quadrato")
        }
    }

    var size: CGSize {
        switch self {
        case .a4Portrait: CGSize(width: 595, height: 842)
        case .a4Landscape: CGSize(width: 842, height: 595)
        case .letter: CGSize(width: 612, height: 792)
        case .square: CGSize(width: 700, height: 700)
        }
    }
}

/// Cover colours for notebooks.
enum Covers {
    static let colors: [Color] = [
        Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255),
        Color(red: 59 / 255, green: 158 / 255, blue: 255 / 255),
        Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255),
        Color(red: 240 / 255, green: 96 / 255, blue: 80 / 255),
        Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255),
        Color(red: 236 / 255, green: 72 / 255, blue: 153 / 255),
        Color(red: 255 / 255, green: 138 / 255, blue: 20 / 255),
        Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255),
        Color(red: 30 / 255, green: 41 / 255, blue: 59 / 255),
        Color(red: 120 / 255, green: 85 / 255, blue: 60 / 255),
        Color(red: 181 / 255, green: 160 / 255, blue: 132 / 255),
        Color(red: 120 / 255, green: 150 / 255, blue: 122 / 255),
        Color(red: 52 / 255, green: 58 / 255, blue: 68 / 255),
    ]

    static let names = [String(localized: "Giallo"), String(localized: "Blu"), String(localized: "Verde"), String(localized: "Rosso"), String(localized: "Viola"), String(localized: "Rosa"), String(localized: "Arancione"), String(localized: "Ardesia"), String(localized: "Notte"), String(localized: "Cuoio"), String(localized: "Kraft"), String(localized: "Salvia"), String(localized: "Antracite")]

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// One page of a notebook. The ink and the boxes live in their own files, keyed by `id`.
struct PageInfo: Codable, Identifiable, Hashable {
    var id = UUID()
    var template: PageTemplate
    /// Index of the page in the notebook's `source.pdf`, when the page is a PDF page.
    var pdfIndex: Int?
    var width: Double
    var height: Double
    /// nil = not bookmarked (optional so older notebooks still open).
    var bookmarked: Bool?
    /// Layers of ink, bottom first; nil = one layer, stored in the page's own drawing file.
    var layers: [InkLayer]?

    /// The layers, always at least one. The first layer of every page has the page's id, so its ink
    /// is in the same file as before layers existed.
    var inkLayers: [InkLayer] { layers ?? [InkLayer(id: id, name: String(localized: "Livello 1"))] }

    var isBookmarked: Bool { bookmarked ?? false }
    var size: CGSize { CGSize(width: width, height: height) }

    init(template: PageTemplate, size: CGSize, pdfIndex: Int? = nil) {
        self.template = template
        self.width = Double(size.width)
        self.height = Double(size.height)
        self.pdfIndex = pdfIndex
    }
}

/// A layer of ink on a page: a sheet of clear film that can be hidden or drawn on alone.
struct InkLayer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hidden: Bool?

    var isHidden: Bool { hidden ?? false }
}

struct Notebook: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Index in `Covers.colors`, or nil to show the first page as the cover.
    var cover: Int?
    /// nil = plain.
    var coverStyle: CoverStyle?
    var paper: Paper = .white
    var folderID: UUID?
    var created = Date()
    var modified = Date()
    var pages: [PageInfo]
    var hasPDF = false
    var lastPage = 0
    var favorite = false
    /// When it was moved to the trash; nil for notebooks on the shelf.
    var deletedAt: Date?
    /// Labels chosen by the user (nil = none; optional so older notebooks still open).
    var tags: [String]?
    /// Sound recorded while writing in this notebook.
    var recordings: [Recording]?
    /// Flashcards made from parts of the pages.
    var cards: [Flashcard]?
    /// A whiteboard: one page that grows while you write (nil = an ordinary notebook).
    var board: Bool?

    var isBoard: Bool { board ?? false }
    /// A document of typed text instead of pages to write on (nil = a notebook).
    var textDocument: Bool?

    var isText: Bool { textDocument ?? false }

    var tagList: [String] { tags ?? [] }
}

extension Notebook {
    /// The size a whiteboard starts with; it grows while you write near its edges.
    static let boardStart = CGSize(width: 1600, height: 1100)
    static let boardMax: Double = 20000
}

/// A sound recording of a notebook. Each stroke knows when it was written, so a tap on the
/// writing plays what was being said at that moment.
struct Recording: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var duration: Double
    /// What was said, once transcribed.
    var transcript: String? = nil

    var end: Date { start.addingTimeInterval(duration) }
}

/// A flashcard: a part of a page as the question and another as the answer, reviewed with spaced
/// repetition (each answer moves the next review further away, or back to the start).
struct Flashcard: Codable, Identifiable, Hashable {
    var id = UUID()
    var page: UUID
    var front: CGRect
    var back: CGRect
    var created = Date()
    var due = Date()
    /// Days until the next review after the last good answer.
    var interval: Double = 0
    var ease: Double = 2.5
    var reps = 0
    var lapses = 0
    /// Cards written as text (a quiz made by the assistant) instead of parts of a page.
    var question: String?
    var answer: String?

    var isText: Bool { question != nil }

    enum Grade: Int, CaseIterable, Identifiable {
        case again, hard, good, easy
        var id: Int { rawValue }
    }

    /// The card after an answer given at `now`.
    func answered(_ g: Grade, now: Date = Date()) -> Flashcard {
        var c = self
        switch g {
        case .again:
            c.reps = 0
            c.lapses += 1
            c.interval = 0
            c.ease = max(1.3, ease - 0.2)
            c.due = now.addingTimeInterval(60)
            return c
        case .hard:
            c.interval = max(1, interval * 1.2)
            c.ease = max(1.3, ease - 0.15)
        case .good:
            c.interval = reps == 0 ? 1 : (reps == 1 ? 3 : max(interval + 1, interval * ease))
        case .easy:
            c.interval = reps == 0 ? 4 : max(interval + 1, interval * ease * 1.3)
            c.ease = ease + 0.15
        }
        c.reps += 1
        c.due = now.addingTimeInterval(c.interval * 86400)
        return c
    }

    /// When the card would come back after answering `g` now, for the buttons.
    func nextInterval(_ g: Grade) -> TimeInterval {
        let now = Date()
        return answered(g, now: now).due.timeIntervalSince(now)
    }

    func isDue(_ now: Date = Date()) -> Bool { due <= now }
}

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// A text box or a picture placed on a page, in page points.
struct PageItem: Codable, Identifiable, Hashable {
    /// `tape` covers part of the page, to study: a tap shows what is under it.
    enum Kind: String, Codable { case text, image, tape }

    var id = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var text: String = ""
    var fontSize: Double = 18
    var color: String = "1C1C20"
    var bold = false
    var image: String?
    /// The page this box leads to when its link button is tapped.
    var link: UUID?
    /// For tape: false once uncovered (nil = covered).
    var covered: Bool?

    var isCovered: Bool { covered ?? true }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

/// Colours offered for text boxes.
enum TextColors {
    static let all = ["1C1C20", "1D4ED8", "DC2626", "15803D", "7C3AED", "EA580C"]
}

/// Colours of the study tape.
enum TapeColors {
    static let all = ["F59E0B", "38BDF8", "F472B6", "A3E635", "94A3B8"]
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
