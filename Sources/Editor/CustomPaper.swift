import PDFKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Custom papers: pictures (a photo, or the pages of a PDF such as a planner or a form) kept in
/// Documents/Carte to use as the paper of any page.
@MainActor
@Observable
final class PaperStore {
    static let shared = PaperStore()

    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        var file: String
        var created = Date()
    }

    private(set) var items: [Item] = []
    static let dir = Store.documents.appendingPathComponent("Carte", isDirectory: true)
    private static let listFile = dir.appendingPathComponent("carte.json")

    private init() {
        if let d = try? Data(contentsOf: Self.listFile), let list = try? Store.decoder.decode([Item].self, from: d) {
            items = list.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
        }
    }

    /// Reads the list again (after a copy of the library was put back).
    func reload() {
        if let d = try? Data(contentsOf: Self.listFile), let list = try? Store.decoder.decode([Item].self, from: d) {
            items = list.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
        }
    }

    func image(_ p: Item) -> UIImage? { UIImage(contentsOfFile: Self.dir.appendingPathComponent(p.file).path) }

    /// Keeps a picture as a paper, at most 2400 pixels on its longer side.
    @discardableResult
    func add(_ img: UIImage) -> Item? {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return nil }
        let k = min(1, 2400 / max(s.width, s.height))
        let target = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let scaled = UIGraphicsImageRenderer(size: target, format: fmt).image { r in
            UIColor.white.setFill()
            r.fill(CGRect(origin: .zero, size: target))
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.88) else { return nil }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let item = Item(file: UUID().uuidString + ".jpg")
        do { try data.write(to: Self.dir.appendingPathComponent(item.file), options: .atomic) } catch { return nil }
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// Every page of a PDF (up to 24) becomes a paper. Returns how many were added.
    func addPDF(_ url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { return 0 }
        var added = 0
        for i in (0..<min(doc.pageCount, 24)).reversed() {
            guard let page = doc.page(at: i) else { continue }
            let size = PageRenderer.pdfPageSize(page)
            let k = 1600 / max(1, max(size.width, size.height))
            let img = page.thumbnail(of: CGSize(width: size.width * k, height: size.height * k), for: .cropBox)
            if add(img) != nil { added += 1 }
        }
        return added
    }

    func remove(_ p: Item) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(p.file))
        items.removeAll { $0.id == p.id }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let d = try? Store.encoder.encode(items) { try? d.write(to: Self.listFile, options: .atomic) }
    }
}

/// The custom papers: add one from a photo or a PDF, then use it for this page or for all of them.
struct PaperSheet: View {
    /// The picture chosen, and whether it goes on every page.
    let onPick: (UIImage, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = PaperStore.shared
    @State private var photo: PhotosPickerItem?
    @State private var showPDF = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Da una foto", systemImage: "photo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button { showPDF = true } label: {
                            Label("Da un PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Text("Una foto o le pagine di un PDF (un'agenda, un modulo, una carta che ti piace) diventano carte da usare per una pagina o per tutto il quaderno. La carta resta sotto la scrittura e va con il quaderno quando lo sincronizzi o lo condividi.")
                        .font(.caption).foregroundStyle(Theme.sub)
                    if let message {
                        Label(message, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
                    }
                    if store.items.isEmpty {
                        Text("Non hai ancora carte personalizzate.")
                            .font(.subheadline).foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        Text("Le tue carte").font(.headline).foregroundStyle(Theme.text)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.items) { p in tile(p) }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Carta personalizzata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .screen()
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data), store.add(img) != nil {
                    message = String(localized: "Carta aggiunta: toccala per usarla.")
                } else {
                    message = String(localized: "Non riesco a leggere la foto.")
                }
            }
        }
        .fileImporter(isPresented: $showPDF, allowedContentTypes: [.pdf]) { result in
            guard case let .success(url) = result else { return }
            let n = store.addPDF(url)
            message = n == 0 ? String(localized: "Non riesco a leggere il PDF.")
                : (n == 1 ? String(localized: "1 carta aggiunta: toccala per usarla.") : String(localized: "\(n) carte aggiunte: toccane una per usarla."))
        }
        .preferredColorScheme(.dark)
    }

    private func tile(_ p: PaperStore.Item) -> some View {
        Menu {
            Button { use(p, all: false) } label: { Label("Usa per questa pagina", systemImage: "doc") }
            Button { use(p, all: true) } label: { Label("Usa per tutte le pagine", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { store.remove(p) } label: { Label("Elimina questa carta", systemImage: "trash") }
        } label: {
            Group {
                if let img = store.image(p) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Color.white
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.72, contentMode: .fit)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
    }

    private func use(_ p: PaperStore.Item, all: Bool) {
        guard let img = store.image(p) else { return }
        onPick(img, all)
        dismiss()
    }
}
