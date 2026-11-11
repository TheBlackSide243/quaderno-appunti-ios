import SwiftUI

/// All pages of the open notebook: tap to open, hold for bookmark, duplicate, move, ruling and delete.
struct PagesView: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    @State private var confirmDelete: Int?
    @State private var bookmarksOnly = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 14)]

    /// The pages to show, with their position in the notebook.
    private var shown: [(Int, PageInfo)] {
        Array(model.notebook.pages.enumerated())
            .filter { !bookmarksOnly || $0.element.isBookmarked }
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Mostra", selection: $bookmarksOnly) {
                        Text("Tutte (\(model.notebook.pages.count))").tag(false)
                        Text("Segnalibri (\(model.bookmarkCount))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    if bookmarksOnly && shown.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bookmark").font(.system(size: 30)).foregroundStyle(Theme.accent)
                            Text("Nessun segnalibro").font(.headline).foregroundStyle(Theme.text)
                            Text("Tocca il segnalibro mentre scrivi, o tieni premuta una pagina qui, per ritrovarla subito.")
                                .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 30)
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(shown, id: \.1.id) { i, page in
                            tile(i, page)
                        }
                        if !bookmarksOnly { newTile }
                    }
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

    private func tile(_ i: Int, _ page: PageInfo) -> some View {
        let current = i == model.pageIndex
        return Button {
            model.go(to: i)
            dismiss()
        } label: {
            VStack(spacing: 6) {
                PageThumb(notebook: model.notebook, page: page, version: model.pageVersion[page.id, default: 0])
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? Theme.accent : Theme.line, lineWidth: current ? 3 : 1))
                    .overlay(alignment: .topTrailing) {
                        if page.isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.bad)
                                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                                .padding(.trailing, 8)
                                .offset(y: -3)
                        }
                    }
                Text("\(i + 1)").font(.caption.monospacedDigit().weight(current ? .bold : .regular))
                    .foregroundStyle(current ? Theme.accent : Theme.sub)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu(i, page) }
    }

    private var newTile: some View {
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

    @ViewBuilder
    private func menu(_ i: Int, _ page: PageInfo) -> some View {
        Button { model.toggleBookmark(i) } label: {
            Label(page.isBookmarked ? String(localized: "Togli il segnalibro") : String(localized: "Aggiungi un segnalibro"), systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark")
        }
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
