import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Things any shelf can ask the root to do.
@MainActor
@Observable
final class Router {
    var open: OpenRequest?
    var showSearch = false
    var showSettings = false
    var showNew = false
    var showIntro = false
    var showTrash = false
}

/// The notebook shelf: the root, and one level of folders pushed on top.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(CloudBackup.self) private var backup
    @Environment(\.scenePhase) private var phase
    @AppStorage("intro.seen") private var introSeen = false
    @State private var router = Router()

    var body: some View {
        NavigationStack {
            ShelfView(folder: nil)
                .navigationDestination(for: UUID.self) { ShelfView(folder: $0) }
        }
        .environment(router)
        .fullScreenCover(item: $router.open) { req in
            if let nb = library.notebook(req.notebookID) {
                EditorView(library: library, notebook: nb, page: req.page)
                    .environment(library)
                    .environment(backup)
            }
        }
        .sheet(isPresented: $router.showSearch) {
            SearchView(initialQuery: Demo.searchQuery) { req in
                router.showSearch = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.open = req }
            }
            .environment(library)
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView(onIntro: {
                router.showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { router.showIntro = true }
            })
            .environment(library).environment(backup)
        }
        .fullScreenCover(isPresented: $router.showIntro) {
            IntroView(offerBackup: !backup.configured,
                      onBackup: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { router.showSettings = true } },
                      onFinish: { introSeen = true })
        }
        .sheet(isPresented: $router.showNew) {
            NewNotebookView(folder: nil) { nb in router.open = OpenRequest(notebookID: nb.id) }
                .environment(library)
                .pageSized()
        }
        .sheet(isPresented: $router.showTrash) {
            NavigationStack { TrashView() }
                .environment(library)
                .preferredColorScheme(.dark)
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            if let nb = library.importPDF(url, folder: nil) { router.open = OpenRequest(notebookID: nb.id) }
            try? FileManager.default.removeItem(at: url)
        }
        .onChange(of: phase) { _, p in if p == .background { backup.backupIfAuto(library) } }
        .task {
            if !introSeen && !Demo.enabled { router.showIntro = true }
            Demo.seedIfNeeded(library)
            Indexer.shared.catchUp(library.notebooks)
            await Demo.route(library: library, router: router)
        }
    }
}

/// One shelf: the folders (at the root) and the notebooks, in a grid or a list.
struct ShelfView: View {
    let folder: UUID?
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    @AppStorage("shelf.sort") private var sortRaw = SortOrder.date.rawValue
    @AppStorage("shelf.list") private var listMode = false
    @State private var favoritesOnly = false
    @State private var showNew = false
    @State private var showImport = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var renaming: Notebook?
    @State private var newName = ""
    @State private var askFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder?
    @State private var confirmDelete: Notebook?
    @State private var confirmDeleteFolder: Folder?
    @State private var share: ShareFile?
    @State private var busy = false
    @State private var showScanner = false

    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .date }
    private var regular: Bool { hSize == .regular }

    private var notebooks: [Notebook] { library.notebooks(in: folder, order: sort, favoritesOnly: favoritesOnly) }

    private var folders: [Folder] {
        guard folder == nil, !favoritesOnly else { return [] }
        return sort == .date ? library.folders : library.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var title: String {
        if favoritesOnly { return "Preferiti" }
        if let folder { return library.folders.first { $0.id == folder }?.name ?? "Cartella" }
        return "Documenti"
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: regular ? 150 : 100, maximum: 210), spacing: regular ? 34 : 18, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(title)
                    .font(.system(size: regular ? 40 : 34, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                ErrorBanner(error: Binding(get: { library.error }, set: { library.error = $0 }))
                controls
                if listMode { list } else { grid }
                if notebooks.isEmpty && folders.isEmpty && (folder != nil || favoritesOnly) {
                    Text(favoritesOnly ? "Nessun preferito: tieni premuto un quaderno o usa il suo menu per aggiungerlo."
                                       : "Questa cartella è vuota. Crea un quaderno qui o spostane uno dal suo menu.")
                        .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, regular ? 34 : 16)
            .padding(.bottom, 30)
        }
        .overlay { if busy { ProgressView().controlSize(.large).padding(30).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16)) } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // the big title is drawn in the page itself, so the bar stays clean
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Cerca")
                if folder == nil {
                    Button { router.showIntro = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("Introduzione")
                    Button { router.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Impostazioni")
                }
            }
        }
        .screen()
        .sheet(isPresented: $showNew) {
            NewNotebookView(folder: folder) { nb in router.open = OpenRequest(notebookID: nb.id) }
                .environment(library)
                .pageSized()
        }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            var last: Notebook?
            for url in urls { if let nb = library.importPDF(url, folder: folder) { last = nb } }
            if urls.count == 1, let last { router.open = OpenRequest(notebookID: last.id) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerView { images in
                showScanner = false
                guard let images, !images.isEmpty else { return }
                let title = "Scansione del " + Date().formatted(.dateTime.day().month(.abbreviated))
                if let nb = library.importImages(images, title: title, folder: folder) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { router.open = OpenRequest(notebookID: nb.id) }
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            busy = true
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { images.append(img) }
                }
                let title = "Foto del " + Date().formatted(.dateTime.day().month(.abbreviated))
                let nb = library.importImages(images, title: title, folder: folder)
                busy = false
                if let nb { router.open = OpenRequest(notebookID: nb.id) }
            }
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
        .confirmationDialog("Spostare «\(confirmDelete?.title ?? "")» nel cestino? Resta lì \(Store.trashDays) giorni: lo ripristini da Impostazioni → Cestino.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Sposta nel cestino", role: .destructive) {
                if let nb = confirmDelete { library.delete(nb.id) }
                confirmDelete = nil
            }
        }
        .confirmationDialog("Eliminare la cartella «\(confirmDeleteFolder?.name ?? "")»? I quaderni dentro non vengono cancellati: tornano in Documenti.",
                            isPresented: Binding(get: { confirmDeleteFolder != nil }, set: { if !$0 { confirmDeleteFolder = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina cartella", role: .destructive) {
                if let f = confirmDeleteFolder { library.deleteFolder(f.id) }
                confirmDeleteFolder = nil
            }
        }
    }

    // MARK: Pieces

    private var controls: some View {
        HStack(spacing: 12) {
            if regular { Spacer(minLength: 0) }
            Picker("Ordina", selection: $sortRaw) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
            Button { withAnimation { favoritesOnly.toggle() } } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
            }
            .foregroundStyle(favoritesOnly ? Theme.accent : Theme.sub)
            .accessibilityLabel("Solo preferiti")
            Button { withAnimation { listMode.toggle() } } label: {
                Image(systemName: listMode ? "square.grid.2x2" : "list.bullet")
            }
            .foregroundStyle(Theme.sub)
            .accessibilityLabel(listMode ? "Griglia" : "Elenco")
        }
        .font(.title3)
    }

    private var newMenu: some View {
        Group {
            Button { showNew = true } label: { Label("Quaderno", systemImage: "book.closed") }
            Button { showImport = true } label: { Label("Importa PDF", systemImage: "doc.richtext") }
            Button { showPhotos = true } label: { Label("Da foto", systemImage: "photo.on.rectangle") }
            if ScannerView.isSupported {
                Button { showScanner = true } label: { Label("Scansiona documento", systemImage: "doc.viewfinder") }
            }
            if folder == nil {
                Button { renamingFolder = nil; folderName = ""; askFolder = true } label: { Label("Cartella", systemImage: "folder.badge.plus") }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: regular ? 34 : 24) {
            if !favoritesOnly {
                VStack(spacing: 8) {
                    Menu { newMenu } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .background(Theme.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .aspectRatio(0.76, contentMode: .fit)
                            .overlay(Image(systemName: "plus").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent))
                    }
                    Text("Nuovo…").font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                    Text(" ").font(.caption)
                }
            }
            ForEach(folders) { f in
                VStack(spacing: 8) {
                    NavigationLink(value: f.id) { FolderArt(count: library.count(in: f.id)) }
                        .buttonStyle(.plain)
                        .contextMenu { folderMenu(f) }
                    caption(f.name) { folderMenu(f) }
                    Text(library.count(in: f.id) == 1 ? "1 quaderno" : "\(library.count(in: f.id)) quaderni")
                        .font(.caption).foregroundStyle(Theme.sub)
                }
            }
            ForEach(notebooks) { nb in
                VStack(spacing: 8) {
                    Button { router.open = OpenRequest(notebookID: nb.id) } label: {
                        NotebookCover(notebook: nb, version: library.thumbVersion[nb.id, default: 0])
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(nb) }
                    caption(nb.title) { menu(nb) }
                    Text(nb.modified.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                        .font(.caption).foregroundStyle(Theme.sub).lineLimit(1)
                }
            }
        }
        .padding(.top, 4)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !favoritesOnly {
                Menu { newMenu } label: {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            .frame(width: 40, height: 52)
                            .overlay(Image(systemName: "plus").foregroundStyle(Theme.accent))
                        Text("Nuovo…").font(.body.weight(.medium)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                Divider().overlay(Theme.line)
            }
            ForEach(folders) { f in
                NavigationLink(value: f.id) {
                    row(art: AnyView(FolderArt(count: library.count(in: f.id))), title: f.name,
                        subtitle: "\(library.count(in: f.id)) quaderni") { folderMenu(f) }
                }
                .buttonStyle(.plain)
                .contextMenu { folderMenu(f) }
                Divider().overlay(Theme.line)
            }
            ForEach(notebooks) { nb in
                Button { router.open = OpenRequest(notebookID: nb.id) } label: {
                    row(art: AnyView(NotebookCover(notebook: nb, version: library.thumbVersion[nb.id, default: 0])), title: nb.title,
                        subtitle: "\(nb.pages.count) pag. · " + nb.modified.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())) { menu(nb) }
                }
                .buttonStyle(.plain)
                .contextMenu { menu(nb) }
                Divider().overlay(Theme.line)
            }
        }
        .padding(.horizontal, 14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func row<M: View>(art: AnyView, title: String, subtitle: String, @ViewBuilder menu: @escaping () -> M) -> some View {
        HStack(spacing: 14) {
            art.frame(width: 40, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.sub).lineLimit(1)
            }
            Spacer()
            Menu { menu() } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.sub).frame(width: 40, height: 40)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The title under a tile, in the accent colour, opening the item's menu.
    private func caption<M: View>(_ text: String, @ViewBuilder menu: @escaping () -> M) -> some View {
        Menu { menu() } label: {
            HStack(spacing: 3) {
                Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private func folderMenu(_ f: Folder) -> some View {
        Button { renamingFolder = f; folderName = f.name; askFolder = true } label: { Label("Rinomina", systemImage: "pencil") }
        Button(role: .destructive) { confirmDeleteFolder = f } label: { Label("Elimina cartella", systemImage: "folder.badge.minus") }
    }

    @ViewBuilder
    private func menu(_ nb: Notebook) -> some View {
        Button { router.open = OpenRequest(notebookID: nb.id) } label: { Label("Apri", systemImage: "book") }
        Button { library.toggleFavorite(nb.id) } label: {
            Label(nb.favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", systemImage: nb.favorite ? "star.slash" : "star")
        }
        Button { newName = nb.title; renaming = nb } label: { Label("Rinomina", systemImage: "pencil") }
        Menu {
            Button { library.setCover(nb.id, nil) } label: { Label("Prima pagina", systemImage: "doc") }
            Menu("Stile") {
                ForEach(CoverStyle.allCases) { st in
                    Button { library.setCoverStyle(nb.id, st) } label: {
                        if nb.cover != nil && (nb.coverStyle ?? .plain) == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) }
                    }
                }
            }
            Menu("Colore") {
                ForEach(Covers.colors.indices, id: \.self) { i in
                    Button { library.setCover(nb.id, i) } label: {
                        if nb.cover == i { Label(Covers.names[i], systemImage: "checkmark") } else { Text(Covers.names[i]) }
                    }
                }
            }
        } label: { Label("Copertina", systemImage: "paintbrush") }
        Menu {
            Button { library.move(nb.id, to: nil) } label: { Label("Documenti", systemImage: "tray") }
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

extension View {
    /// Full page sheet on iPad (iOS 18+), so galleries are not squeezed into a small form.
    @ViewBuilder
    func pageSized() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}
