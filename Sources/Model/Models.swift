import Foundation
import SwiftUI
import UIKit

/// The ruling printed on a page.
enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted, cornell, narrow, checklist, music
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: "Bianca"
        case .lined: "Righe"
        case .grid: "Quadretti"
        case .dotted: "Puntini"
        case .cornell: "Cornell"
        case .narrow: "Righe strette"
        case .checklist: "Elenco"
        case .music: "Pentagramma"
        }
    }

    /// How the gallery of the new notebook groups the rulings.
    static let groups: [(String, [PageTemplate])] = [
        ("Essenziali", [.blank, .dotted, .grid, .lined, .narrow]),
        ("Studio e organizzazione", [.cornell, .checklist, .music]),
    ]
}

/// The look of a notebook cover.
enum CoverStyle: String, Codable, CaseIterable, Identifiable {
    case plain, elastic, label
    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: "Semplice"
        case .elastic: "Con elastico"
        case .label: "Con etichetta"
        }
    }
}

/// How the shelf is ordered.
enum SortOrder: String, CaseIterable, Identifiable {
    case date, name, kind
    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: "Data"
        case .name: "Nome"
        case .kind: "Tipo"
        }
    }
}

/// The colour of the paper. Ink keeps its real colour, so the paper is always light.
enum Paper: String, Codable, CaseIterable, Identifiable {
    case white, ivory, yellow, gray
    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: "Bianca"
        case .ivory: "Avorio"
        case .yellow: "Gialla"
        case .gray: "Grigio chiaro"
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
        case .a4Portrait: "A4 verticale"
        case .a4Landscape: "A4 orizzontale"
        case .letter: "Lettera"
        case .square: "Quadrato"
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

    static let names = ["Giallo", "Blu", "Verde", "Rosso", "Viola", "Rosa", "Arancione", "Ardesia", "Notte", "Cuoio", "Kraft", "Salvia", "Antracite"]

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

    var size: CGSize { CGSize(width: width, height: height) }

    init(template: PageTemplate, size: CGSize, pdfIndex: Int? = nil) {
        self.template = template
        self.width = Double(size.width)
        self.height = Double(size.height)
        self.pdfIndex = pdfIndex
    }
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
}

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// A text box or a picture placed on a page, in page points.
struct PageItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image }

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

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

/// Colours offered for text boxes.
enum TextColors {
    static let all = ["1C1C20", "1D4ED8", "DC2626", "15803D", "7C3AED", "EA580C"]
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
