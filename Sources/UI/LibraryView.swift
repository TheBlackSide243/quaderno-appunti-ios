import SwiftUI
import UniformTypeIdentifiers

/// The notebook shelf: folders on top, notebooks in a grid.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize

    /// nil = all, `favoritesID` = favourites, otherwise a folder.
    @State private var folder: UUID?
    @State private var open: OpenRequest?
    @State private var showNew = false
    @State private var showImport = false
    @State private var showSearch = false
    @State private var renaming: Notebook?
    @State private var newName = ""
    @State private var askFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder?
    @State private var confirmDelete: Notebook?
    @State private var share: ShareFile?

    static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: hSize == .regular ? 170 : 104, maximum: 240), spacing: hSize == .regular ? 26 : 16)]
    }

    private var shown: [Notebook] {
        switch folder {
        case nil: library.notebooks
        case Self.favoritesID: library.notebooks.filter(\.favorite)
        case let id?: library.notebooks.filter { $0.folderID == id }
        }
    }

    private var folderForNew: UUID? { folder == Self.favoritesID ? nil : folder }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ErrorBanner(error: Binding(get: { library.error }, set: { library.error = $0 }))
                    folderBar
                    if shown.isEmpty {
                        empty
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(shown) { nb in
                                Button { open = OpenRequest(notebookID: nb.id) } label: {
                                    NotebookCard(notebook: nb, version: library.thumbVersion[nb.id, default: 0])
                                }
                                .buttonStyle(.plain)
                                .contextMenu { menu(nb) }
                            }
                        }
                    }
                }
                .padding(.horizontal, hSize == .regular ? 28 : 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.and.scribble").foregroundStyle(Theme.accent)
                        Text("APPUNTI").font(.headline.weight(.heavy)).foregroundStyle(Theme.accent).tracking(1)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    Menu {
                        Button { showNew = true } label: { Label("Nuovo quaderno", systemImage: "book.closed") }
                        Button { showImport = true } label: { Label("Importa PDF", systemImage: "doc.richtext") }
                        Button { folderName = ""; askFolder = true } label: { Label("Nuova cartella", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .screen()
        }
        .sheet(isPresented: $showNew) {
            NewNotebookView(folder: folderForNew) { nb in open = OpenRequest(notebookID: nb.id) }
        }
        .sheet(isPresented: $showSearch) {
            SearchView { req in
                showSearch = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open = req }
            }
        }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .fullScreenCover(item: $open) { req in
            if let nb = library.notebook(req.notebookID) {
                EditorView(library: library, notebook: nb, page: req.page)
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            var last: Notebook?
            for url in urls { if let nb = library.importPDF(url, folder: folderForNew) { last = nb } }
            if urls.count == 1, let last { open = OpenRequest(notebookID: last.id) }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            if let nb = library.importPDF(url, folder: nil) { open = OpenRequest(notebookID: nb.id) }
            try? FileManager.default.removeItem(at: url)
        }
        .alert("Rinomina quaderno", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titolo", text: $newName)
            Button("Annulla", role: .cancel) {}
            Button("Salva") { if let nb = renaming { library.rename(nb.id, to: newName) } }
        }
        .alert(renamingFolder == nil ? "Nuova cartella" : "Rinomina cartella", isPresented: $askFolder) {
            TextField("Nome", text: $folderName)
            Button("Annulla", role: .cancel) { renamingFolder = nil }
            Button(renamingFolder == nil ? "Crea" : "Salva") {
                if let f = renamingFolder { library.renameFolder(f.id, folderName) } else { library.addFolder(folderName) }
                renamingFolder = nil
            }
        }
        .confirmationDialog("Eliminare «\(confirmDelete?.title ?? "")»? Pagine, inchiostro e PDF verranno cancellati e non si possono recuperare.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina quaderno", role: .destructive) {
                if let nb = confirmDelete { library.delete(nb.id) }
                confirmDelete = nil
            }
        }
        .task { Indexer.shared.catchUp(library.notebooks) }
    }

    private var title: String {
        switch folder {
        case nil: "Tutti i quaderni"
        case Self.favoritesID: "Preferiti"
        case let id?: library.folders.first { $0.id == id }?.name ?? "Cartella"
        }
    }

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Tutti", icon: "books.vertical.fill", on: folder == nil) { folder = nil }
                Chip(title: "Preferiti", icon: "star.fill", on: folder == Self.favoritesID) { folder = Self.favoritesID }
                ForEach(library.folders) { f in
                    Chip(title: f.name, icon: "folder.fill", on: folder == f.id) { folder = f.id }
                        .contextMenu {
                            Button { renamingFolder = f; folderName = f.name; askFolder = true } label: { Label("Rinomina", systemImage: "pencil") }
                            Button(role: .destructive) {
                                if folder == f.id { folder = nil }
                                library.deleteFolder(f.id)
                            } label: { Label("Elimina cartella (i quaderni restano)", systemImage: "folder.badge.minus") }
                        }
                }
                Button { renamingFolder = nil; folderName = ""; askFolder = true } label: {
                    Image(systemName: "plus").font(.footnote.weight(.bold)).padding(9)
                        .background(Theme.input, in: Circle())
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text(folder == nil ? "Nessun quaderno" : "Qui non c'è ancora niente").font(.headline).foregroundStyle(Theme.text)
            Text("Crea un quaderno per scrivere a mano o importa un PDF da annotare.")
                .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { showNew = true } label: { Label("Nuovo quaderno", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
                Button { showImport = true } label: { Label("Importa PDF", systemImage: "doc.richtext") }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func menu(_ nb: Notebook) -> some View {
        Button { library.toggleFavorite(nb.id) } label: {
            Label(nb.favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", systemImage: nb.favorite ? "star.slash" : "star")
        }
        Button { newName = nb.title; renaming = nb } label: { Label("Rinomina", systemImage: "pencil") }
        Menu {
            Button { library.setCover(nb.id, nil) } label: { Label("Prima pagina", systemImage: "doc") }
            ForEach(Covers.colors.indices, id: \.self) { i in
                Button { library.setCover(nb.id, i) } label: { Text(Covers.names[i]) }
            }
        } label: { Label("Copertina", systemImage: "paintbrush") }
        Menu {
            Button { library.move(nb.id, to: nil) } label: { Label("Nessuna cartella", systemImage: "tray") }
            ForEach(library.folders) { f in
                Button { library.move(nb.id, to: f.id) } label: {
                    if nb.folderID == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                }
            }
        } label: { Label("Sposta in cartella", systemImage: "folder") }
        Button { library.duplicate(nb.id) } label: { Label("Duplica", systemImage: "plus.square.on.square") }
        Button {
            do { share = ShareFile(url: try PageRenderer.exportPDF(nb)) } catch { library.error = "Esportazione non riuscita: \(error.localizedDescription)" }
        } label: { Label("Esporta PDF", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { confirmDelete = nb } label: { Label("Elimina", systemImage: "trash") }
    }
}

struct Chip: View {
    let title: String
    let icon: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(on ? Theme.accent : Theme.input, in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.accent : Theme.line, lineWidth: 1))
                .foregroundStyle(on ? Theme.bg : Theme.text)
        }
        .buttonStyle(.plain)
    }
}

/// A notebook on the shelf: a coloured cover with its title, or its first page.
struct NotebookCard: View {
    let notebook: Notebook
    var version = 0
    @State private var thumb: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            cover
                .aspectRatio(0.74, contentMode: .fit)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            HStack(spacing: 4) {
                if notebook.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.accent) }
                Text(notebook.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
            }
            Text("\(notebook.pages.count) pag. · \(notebook.modified.formatted(.relative(presentation: .named)))")
                .font(.caption2).foregroundStyle(Theme.sub).lineLimit(1)
        }
        .task(id: version) {
            let id = notebook.id
            thumb = await Task.detached { UIImage(contentsOfFile: Store.thumb(id).path) }.value
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let c = notebook.cover {
            let color = Covers.color(c)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.gradient)
                Rectangle().fill(.black.opacity(0.22)).frame(width: 12)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(notebook.title)
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .lineLimit(3)
                    Spacer()
                    if notebook.hasPDF { Image(systemName: "doc.richtext").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                }
                .padding(.leading, 22).padding(.trailing, 10).padding(.vertical, 14)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: notebook.paper.uiColor))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}
