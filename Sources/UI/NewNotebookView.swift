import SwiftUI

/// Title, cover, ruling, paper and size of a new notebook.
struct NewNotebookView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: UUID?
    let onCreate: (Notebook) -> Void

    @State private var title = ""
    @State private var cover = 0
    @State private var template: PageTemplate = .lined
    @State private var paper: Paper = .white
    @State private var format: PageFormat = .a4Portrait
    @State private var folderID: UUID?

    init(folder: UUID?, onCreate: @escaping (Notebook) -> Void) {
        self.folder = folder
        self.onCreate = onCreate
        _folderID = State(initialValue: folder)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Panel("Titolo") {
                        TextField("Es. Analisi 2", text: $title)
                            .padding(11)
                            .background(Theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
                    }
                    Panel("Copertina") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                            ForEach(Covers.colors.indices, id: \.self) { i in
                                Button { cover = i } label: {
                                    RoundedRectangle(cornerRadius: 8).fill(Covers.color(i).gradient)
                                        .aspectRatio(0.74, contentMode: .fit)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cover == i ? Theme.text : .clear, lineWidth: 2.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Covers.names[i])
                            }
                        }
                    }
                    Panel("Pagine") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(PageTemplate.allCases) { t in
                                    Button { template = t } label: {
                                        VStack(spacing: 6) {
                                            TemplatePreview(template: t, paper: paper)
                                                .frame(width: 70, height: 99)
                                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(template == t ? Theme.accent : Theme.line,
                                                                                                  lineWidth: template == t ? 3 : 1))
                                            Text(t.label).font(.caption).foregroundStyle(template == t ? Theme.accent : Theme.sub)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(2)
                        }
                        Picker("Carta", selection: $paper) {
                            ForEach(Paper.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Formato", selection: $format) {
                            ForEach(PageFormat.allCases) { Text($0.label).tag($0) }
                        }
                        .tint(Theme.accent)
                    }
                    if !library.folders.isEmpty {
                        Panel("Cartella") {
                            Picker("Cartella", selection: $folderID) {
                                Text("Nessuna").tag(UUID?.none)
                                ForEach(library.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                            .tint(Theme.accent)
                        }
                    }
                    Button("Crea quaderno") {
                        let nb = library.create(title: title, cover: cover, template: template, paper: paper, format: format, folder: folderID)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCreate(nb) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
            }
            .navigationTitle("Nuovo quaderno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
            .screen()
        }
        .preferredColorScheme(.dark)
    }
}

/// A small drawing of a page ruling.
struct TemplatePreview: View {
    let template: PageTemplate
    let paper: Paper

    var body: some View {
        let size = PageFormat.a4Portrait.size
        Image(uiImage: PageRenderer.templateImage(template, paper: paper, size: size))
            .resizable()
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension PageRenderer {
    static func templateImage(_ t: PageTemplate, paper: Paper, size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 0.5
        return UIGraphicsImageRenderer(size: size, format: fmt).image { r in
            r.cgContext.setFillColor(paper.uiColor.cgColor)
            r.cgContext.fill(CGRect(origin: .zero, size: size))
            drawTemplate(t, size: size, in: r.cgContext)
        }
    }
}
