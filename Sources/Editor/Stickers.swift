import PencilKit
import SwiftUI
import UIKit

/// Stickers: pictures to put on any page. Some come with the app; the others are parts of pages
/// saved by the user (ink, text and photos, without the paper), kept in Documents/Adesivi.
@MainActor
@Observable
final class StickerStore {
    static let shared = StickerStore()

    struct Sticker: Codable, Identifiable, Hashable {
        var id = UUID()
        var file: String
        var created = Date()
    }

    private(set) var saved: [Sticker] = []
    private static let dir = Store.documents.appendingPathComponent("Adesivi", isDirectory: true)
    private static let listFile = dir.appendingPathComponent("adesivi.json")

    private init() {
        builtIn = Self.makeBuiltIn()
        if let d = try? Data(contentsOf: Self.listFile), let list = try? Store.decoder.decode([Sticker].self, from: d) {
            saved = list.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
        }
    }

    func image(_ s: Sticker) -> UIImage? { UIImage(contentsOfFile: Self.dir.appendingPathComponent(s.file).path) }

    func add(_ img: UIImage) {
        guard let data = img.pngData() else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let s = Sticker(file: UUID().uuidString + ".png")
        do { try data.write(to: Self.dir.appendingPathComponent(s.file), options: .atomic) } catch { return }
        saved.insert(s, at: 0)
        persist()
    }

    func remove(_ s: Sticker) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(s.file))
        saved.removeAll { $0.id == s.id }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let d = try? Store.encoder.encode(saved) { try? d.write(to: Self.listFile, options: .atomic) }
    }

    // MARK: The stickers that come with the app

    struct BuiltIn: Identifiable {
        let id: String
        let image: UIImage
    }

    let builtIn: [BuiltIn]

    private static func makeBuiltIn() -> [BuiltIn] {
        var out: [BuiltIn] = []
        let symbols: [(String, String)] = [
            ("star.fill", "F59E0B"), ("checkmark.circle.fill", "16A34A"), ("xmark.circle.fill", "DC2626"),
            ("exclamationmark.triangle.fill", "EA580C"), ("questionmark.circle.fill", "2563EB"), ("heart.fill", "E11D48"),
            ("lightbulb.fill", "EAB308"), ("flag.fill", "DC2626"), ("pin.fill", "DB2777"), ("bookmark.fill", "7C3AED"),
            ("arrow.right.circle.fill", "0EA5E9"), ("hand.thumbsup.fill", "16A34A"), ("clock.fill", "475569"),
            ("calendar", "2563EB"), ("graduationcap.fill", "1E293B"), ("bolt.fill", "F59E0B"),
        ]
        for (name, hex) in symbols {
            if let img = symbol(name, color: UIColor(hex: hex)) { out.append(BuiltIn(id: name, image: img)) }
        }
        let labels: [(String, String)] = [
            (String(localized: "Importante"), "DC2626"), (String(localized: "Da ripassare"), "2563EB"), (String(localized: "Esame!"), "7C3AED"),
            (String(localized: "Fatto"), "16A34A"), (String(localized: "Idea"), "EAB308"), (String(localized: "Domanda"), "EA580C"),
        ]
        for (text, hex) in labels { out.append(BuiltIn(id: "label." + text, image: label(text, color: UIColor(hex: hex)))) }
        return out
    }

    private static func symbol(_ name: String, color: UIColor) -> UIImage? {
        let conf = UIImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
        guard let base = UIImage(systemName: name, withConfiguration: conf)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        let size = CGSize(width: base.size.width + 8, height: base.size.height + 8)
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in base.draw(at: CGPoint(x: 4, y: 4)) }
    }

    private static func label(_ text: String, color: UIColor) -> UIImage {
        let font = UIFont.systemFont(ofSize: 54, weight: .heavy)
        let t = text.uppercased() as NSString
        let ts = t.size(withAttributes: [.font: font])
        let size = CGSize(width: ts.width + 56, height: ts.height + 30)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            color.setFill()
            UIBezierPath(roundedRect: r, cornerRadius: r.height / 2).fill()
            UIColor.white.setStroke()
            let inner = UIBezierPath(roundedRect: r.insetBy(dx: 6, dy: 6), cornerRadius: (r.height - 12) / 2)
            inner.lineWidth = 3
            inner.stroke()
            t.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2),
                   withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
}

/// The sticker book: the stickers of the app and the saved ones; a tap puts one on the page.
struct StickerSheet: View {
    let onPick: (UIImage) -> Void
    let onMake: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var store = StickerStore.shared

    init(onPick: @escaping (UIImage) -> Void, onMake: @escaping () -> Void) {
        self.onPick = onPick
        self.onMake = onMake
    }

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        dismiss()
                        onMake()
                    } label: {
                        Label("Crea un adesivo da questa pagina", systemImage: "plus.rectangle.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    if !store.saved.isEmpty {
                        Text("I tuoi adesivi").font(.headline).foregroundStyle(Theme.text)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.saved) { s in
                                if let img = store.image(s) {
                                    cell(img)
                                        .contextMenu {
                                            Button(role: .destructive) { store.remove(s) } label: { Label("Elimina", systemImage: "trash") }
                                        }
                                }
                            }
                        }
                    }
                    Text("Adesivi dell'app").font(.headline).foregroundStyle(Theme.text)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.builtIn) { b in cell(b.image) }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Adesivi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cell(_ img: UIImage) -> some View {
        Button {
            onPick(img)
            dismiss()
        } label: {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
