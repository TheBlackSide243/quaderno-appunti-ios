import SwiftUI

/// All pages of the open notebook: tap to open, hold for duplicate, move, ruling and delete.
struct PagesView: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    @State private var confirmDelete: Int?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(model.notebook.pages.enumerated()), id: \.element.id) { i, page in
                        Button {
                            model.go(to: i)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                PageThumb(notebook: model.notebook, page: page, version: model.pageVersion[page.id, default: 0])
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == model.pageIndex ? Theme.accent : Theme.line,
                                                                                      lineWidth: i == model.pageIndex ? 3 : 1))
                                Text("\(i + 1)").font(.caption.monospacedDigit().weight(i == model.pageIndex ? .bold : .regular))
                                    .foregroundStyle(i == model.pageIndex ? Theme.accent : Theme.sub)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(i, page) }
                    }
                    Button {
                        model.addPage(after: model.notebook.pages.count - 1, template: nil)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                .aspectRatio(595.0 / 842.0, contentMode: .fit)
                                .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(Theme.accent))
                            Text("Nuova").font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .navigationTitle("Pagine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .screen()
        }
        .confirmationDialog("Eliminare la pagina \((confirmDelete ?? 0) + 1)? Non si può annullare.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina pagina", role: .destructive) {
                if let i = confirmDelete { model.deletePage(i) }
                confirmDelete = nil
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func menu(_ i: Int, _ page: PageInfo) -> some View {
        Button { model.duplicatePage(i) } label: { Label("Duplica", systemImage: "plus.square.on.square") }
        Menu {
            ForEach(PageTemplate.allCases) { t in Button(t.label) { model.addPage(after: i, template: t) } }
        } label: { Label("Inserisci pagina dopo", systemImage: "doc.badge.plus") }
        if page.pdfIndex == nil {
            Menu {
                ForEach(PageTemplate.allCases) { t in Button(t.label) { model.setTemplate(t, for: i) } }
            } label: { Label("Modello", systemImage: "squareshape.split.2x2") }
        }
        Button { model.movePage(i, by: -1) } label: { Label("Sposta prima", systemImage: "arrow.left") }
            .disabled(i == 0)
        Button { model.movePage(i, by: 1) } label: { Label("Sposta dopo", systemImage: "arrow.right") }
            .disabled(i == model.notebook.pages.count - 1)
        if model.notebook.pages.count > 1 {
            Button(role: .destructive) { confirmDelete = i } label: { Label("Elimina", systemImage: "trash") }
        }
    }
}

/// A page drawn small, in the background.
struct PageThumb: View {
    let notebook: Notebook
    let page: PageInfo
    var version = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: notebook.paper.uiColor)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .aspectRatio(page.size.width / page.size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(page.id)-\(version)-\(page.template.rawValue)-\(notebook.paper.rawValue)") {
            let nb = notebook, pg = page
            image = await Task.detached(priority: .userInitiated) { PageRenderer.render(nb, pg, width: 300) }.value
        }
    }
}
