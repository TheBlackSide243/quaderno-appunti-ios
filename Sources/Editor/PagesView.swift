import SwiftUI

/// All pages of the open notebook: tap to open, hold for bookmark, duplicate, move, ruling and
/// delete. "Seleziona" chooses several pages to bookmark, copy, move, share or delete together.
struct PagesView: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    @State private var confirmDelete: Int?
    @State private var bookmarksOnly = false
    @State private var selecting = Demo.screen == "select"
    @State private var chosen: Set<UUID> = []
    @State private var confirmDeleteChosen = false
    @State private var share: ShareFile?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 14)]

    /// The pages to show, with their position in the notebook.
    private var shown: [(Int, PageInfo)] {
        Array(model.notebook.pages.enumerated())
            .filter { !bookmarksOnly || $0.element.isBookmarked }
            .map { ($0.offset, $0.element) }
    }

    /// Only ids of pages that still exist.
    private var picked: Set<UUID> { chosen.intersection(model.notebook.pages.map(\.id)) }

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
                    ErrorBanner(error: $error)
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
                        if !bookmarksOnly && !selecting { newTile }
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar }
            }
            .navigationTitle(selecting ? String(localized: "Pagine scelte: \(picked.count)") : String(localized: "Pagine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? String(localized: "Annulla") : String(localized: "Seleziona")) {
                        selecting.toggle()
                        chosen = []
                    }
                }
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
        .confirmationDialog("Eliminare \(picked.count) pagine? Non si può annullare.", isPresented: $confirmDeleteChosen, titleVisibility: .visible) {
            Button("Elimina le pagine", role: .destructive) {
                model.deletePages(picked)
                chosen = []
                selecting = false
            }
        }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .onAppear {
            if Demo.screen == "select" { chosen = Set(model.notebook.pages.prefix(2).map(\.id)) }
        }
        .preferredColorScheme(.dark)
    }

    private func tile(_ i: Int, _ page: PageInfo) -> some View {
        let current = i == model.pageIndex
        let isChosen = chosen.contains(page.id)
        return Button {
            if selecting {
                if isChosen { chosen.remove(page.id) } else { chosen.insert(page.id) }
            } else {
                model.go(to: i)
                dismiss()
            }
        } label: {
            VStack(spacing: 6) {
                PageThumb(notebook: model.notebook, page: page, version: model.pageVersion[page.id, default: 0])
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selecting ? (isChosen ? Theme.accent : Theme.line) : (current ? Theme.accent : Theme.line),
                                                                     lineWidth: (selecting ? isChosen : current) ? 3 : 1))
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
                    .overlay(alignment: .bottomTrailing) {
                        if selecting {
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(isChosen ? Theme.accent : Color.white.opacity(0.9))
                                .background(Circle().fill(isChosen ? Theme.bg : Color.black.opacity(0.35)).padding(2))
                                .padding(6)
                        }
                    }
                Text("\(i + 1)").font(.caption.monospacedDigit().weight(current ? .bold : .regular))
                    .foregroundStyle(current ? Theme.accent : Theme.sub)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selecting && isChosen ? .isSelected : [])
        .contextMenu { if !selecting { menu(i, page) } }
    }

    /// The actions on the chosen pages, at the bottom.
    private var selectionBar: some View {
        let ids = picked
        let none = ids.isEmpty
        let allShown = Set(shown.map(\.1.id))
        let allBookmarked = !none && model.pages(ids).allSatisfy(\.isBookmarked)
        return HStack(spacing: 4) {
            Button(allShown.isSubset(of: ids) && !allShown.isEmpty ? String(localized: "Nessuna") : String(localized: "Tutte")) {
                chosen = allShown.isSubset(of: ids) ? [] : allShown
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            Spacer(minLength: 4)
            barButton(allBookmarked ? "bookmark.slash" : "bookmark",
                      allBookmarked ? String(localized: "Togli il segnalibro") : String(localized: "Aggiungi un segnalibro")) {
                model.setBookmarks(ids, on: !allBookmarked)
            }
            .disabled(none)
            barButton("plus.square.on.square", String(localized: "Duplica")) { model.duplicatePages(ids) }
                .disabled(none)
            Menu {
                Button { model.movePages(ids, toStart: true) } label: { Label("Sposta all'inizio", systemImage: "arrow.up.to.line") }
                Button { model.movePages(ids, toStart: false) } label: { Label("Sposta alla fine", systemImage: "arrow.down.to.line") }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 18)).frame(width: 44, height: 40)
            }
            .disabled(none)
            .accessibilityLabel("Sposta")
            barButton("square.and.arrow.up", String(localized: "Condividi in PDF")) {
                do { share = ShareFile(url: try model.exportPDF(pages: ids)) } catch {
                    self.error = String(localized: "Esportazione non riuscita: \(error.localizedDescription)")
                }
            }
            .disabled(none)
            barButton("trash", String(localized: "Elimina"), color: Theme.bad) { confirmDeleteChosen = true }
                .disabled(none || ids.count >= model.notebook.pages.count)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func barButton(_ icon: String, _ label: String, color: Color = Theme.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(width: 44, height: 40)
        }
        .accessibilityLabel(label)
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
        .task(id: "\(page.id)-\(version)-\(page.template.rawValue)-\(notebook.paper.rawValue)-\(page.backdrop ?? "")") {
            let nb = notebook, pg = page
            image = await Task.detached(priority: .userInitiated) { PageRenderer.render(nb, pg, width: 300) }.value
        }
    }
}
