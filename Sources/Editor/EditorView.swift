import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CanvasHost: UIViewRepresentable {
    let view: PageCanvasView
    func makeUIView(context: Context) -> PageCanvasView { view }
    func updateUIView(_ uiView: PageCanvasView, context: Context) {}
}

/// An open notebook: navigation bar, tool bar, then the page.
struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(CloudBackup.self) private var backup
    @State private var model: EditorModel
    @State private var showPages = false
    @State private var showSearch = false
    @State private var showText = false
    @State private var showScanner = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showPDFPicker = false
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var confirmClear = false
    @State private var renaming = false
    @State private var newTitle = ""

    init(library: Library, notebook: Notebook, page: Int?) {
        _model = State(initialValue: EditorModel(library: library, notebook: notebook, page: page))
    }

    private var regular: Bool { hSize == .regular }

    var body: some View {
        dialogs
            .onChange(of: phase) { _, p in
                if p != .active { model.canvas.saveNow() }
                if p == .background { backup.backupIfAuto(model.library, open: model.notebook.id) }
            }
            .task { await runDemo() }
            .onDisappear {
                model.close()
                backup.scheduleAuto(model.library)
            }
            .preferredColorScheme(.dark)
    }

    // The screen is built in layers so each piece stays quick to compile.

    private var editor: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CanvasHost(view: model.canvas)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 10) {
                    if model.audio.panel || model.audio.recording {
                        AudioBar(model: model, onShare: { share = ShareFile(url: $0) })
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let item = model.selected, !model.drawMode {
                        ItemBar(item: item, model: model)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !regular {
                        PageNav(model: model, onPages: { showPages = true })
                    }
                }
                .padding(.bottom, 10)
                VStack(spacing: 8) {
                    ErrorBanner(error: $error)
                    if model.audio.listening {
                        Label("Tocca una parola scritta per sentire cosa si diceva", systemImage: "hand.tap")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.bg)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                    }
                    if let n = model.notice {
                        Text(n).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                            .task(id: n) {
                                try? await Task.sleep(for: .seconds(2.5))
                                if model.notice == n { model.notice = nil }
                            }
                    }
                }
                .padding(12).frame(maxHeight: .infinity, alignment: .top)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ToolStrip(model: model, onPhoto: { showPhotos = true })
            }
            .animation(.easeOut(duration: 0.18), value: model.selected?.id)
            .animation(.easeOut(duration: 0.18), value: model.audio.panel)
            .animation(.easeOut(duration: 0.18), value: model.notice)
            .background(Theme.desk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var sheets: some View {
        editor
            .sheet(isPresented: $showPages) {
                PagesView(model: model)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSearch) {
                SearchView(scope: model.notebook.id) { req in
                    showSearch = false
                    if let p = req.page { model.go(to: p) }
                }
                .environment(model.library)
            }
            .sheet(isPresented: $showText) {
                RecognizedTextView(model: model)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerView { images in
                    showScanner = false
                    if let images { model.appendImages(images) }
                }
                .ignoresSafeArea()
            }
    }

    private var pickers: some View {
        sheets
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        model.addImage(img)
                    } else {
                        error = "Non riesco a leggere la foto."
                    }
                }
            }
            .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
                if case let .success(url) = result { model.appendPDF(url) }
                if let e = model.library.error { error = e; model.library.error = nil }
            }
    }

    private var dialogs: some View {
        pickers
            .confirmationDialog("Cancellare tutto l'inchiostro di questa pagina?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Cancella inchiostro", role: .destructive) { model.canvas.clearInk() }
            } message: {
                Text("Testi e foto restano. Puoi annullare con la freccia indietro.")
            }
            .alert("Rinomina quaderno", isPresented: $renaming) {
                TextField("Titolo", text: $newTitle)
                Button("Annulla", role: .cancel) {}
                Button("Salva") { model.rename(newTitle) }
            }
    }

    /// Opens the screens the screenshot script asks for.
    private func runDemo() async {
        guard let screen = Demo.screen else { return }
        try? await Task.sleep(for: .seconds(1.5))
        switch screen {
        case "pages": showPages = true
        case "ocr": showText = true
        case "shapes": Demo.drawShapes(model)
        default: break
        }
    }

    // MARK: Bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                model.close()
                dismiss()
            } label: {
                Image(systemName: "chevron.backward").fontWeight(.semibold)
            }
            .accessibilityLabel("Indietro")
            // on iPhone the page grid opens from the page counter at the bottom, to leave room for the title
            if regular {
                Button { showPages = true } label: { Image(systemName: "square.grid.2x2") }
                    .accessibilityLabel("Tutte le pagine")
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Cerca nel quaderno")
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                if regular {
                    Button { model.previous() } label: { Image(systemName: "chevron.left") }
                        .disabled(model.pageIndex == 0)
                }
                Menu {
                    Button { newTitle = model.notebook.title; renaming = true } label: { Label("Rinomina", systemImage: "pencil") }
                    Button { showPages = true } label: { Label("Tutte le pagine", systemImage: "square.grid.2x2") }
                    Button { showSearch = true } label: { Label("Cerca nel quaderno", systemImage: "magnifyingglass") }
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 3) {
                            Text(model.notebook.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Theme.text)
                        Text("Pagina \(model.pageIndex + 1) di \(model.notebook.pages.count)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.sub)
                    }
                    .frame(maxWidth: regular ? 220 : 130)
                }
                if regular {
                    Button { model.next() } label: {
                        Image(systemName: model.pageIndex + 1 < model.notebook.pages.count ? "chevron.right" : "plus")
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.canvas.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .accessibilityLabel("Annulla")
            Button { model.canvas.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .accessibilityLabel("Ripeti")
            if regular {
                Button { model.toggleBookmark(model.pageIndex) } label: {
                    Image(systemName: model.page.isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(model.page.isBookmarked ? "Togli il segnalibro" : "Aggiungi un segnalibro")
                Menu {
                    ForEach(PageTemplate.allCases) { t in
                        Button(t.label) { model.addPage(after: model.pageIndex, template: t) }
                    }
                } label: {
                    Image(systemName: "doc.badge.plus")
                } primaryAction: {
                    model.addPage(after: model.pageIndex, template: nil)
                }
                .accessibilityLabel("Nuova pagina")
            }
            Menu { moreMenu } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Altro")
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Section {
            Toggle(isOn: Binding(get: { model.fingerDraws }, set: { model.setFingerDraws($0) })) {
                Label("Scrivi anche col dito", systemImage: "hand.draw")
            }
        }
        Section("Aggiungi") {
            if !regular {
                Menu {
                    ForEach(PageTemplate.allCases) { t in
                        Button(t.label) { model.addPage(after: model.pageIndex, template: t) }
                    }
                } label: { Label("Nuova pagina dopo questa", systemImage: "doc.badge.plus") }
            }
            Button {
                if !model.paste() { error = "Negli appunti del telefono non c'è niente da incollare (testo o immagine)." }
            } label: { Label("Incolla", systemImage: "doc.on.clipboard") }
            if ScannerView.isSupported {
                Button { showScanner = true } label: { Label("Scansiona pagine", systemImage: "doc.viewfinder") }
            }
            Button { showPDFPicker = true } label: { Label("Pagine da un PDF", systemImage: "doc.richtext") }
            Button { model.audio.panel = true } label: { Label("Registrazione audio", systemImage: "waveform") }
        }
        Section("Pagina") {
            Button { model.toggleBookmark(model.pageIndex) } label: {
                Label(model.page.isBookmarked ? "Togli il segnalibro" : "Aggiungi un segnalibro",
                      systemImage: model.page.isBookmarked ? "bookmark.slash" : "bookmark")
            }
            Menu {
                ForEach(PageTemplate.allCases) { t in
                    Button { model.setTemplate(t, for: model.pageIndex) } label: {
                        if model.page.template == t { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                    }
                }
                Divider()
                Menu("A tutte le pagine") {
                    ForEach(PageTemplate.allCases) { t in Button(t.label) { model.setTemplateForAll(t) } }
                }
            } label: { Label("Modello pagina", systemImage: "squareshape.split.2x2") }
            Menu {
                ForEach(Paper.allCases) { p in
                    Button { model.setPaper(p) } label: {
                        if model.notebook.paper == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                    }
                }
            } label: { Label("Carta", systemImage: "paintpalette") }
            Button { showText = true } label: { Label("Testo riconosciuto", systemImage: "text.viewfinder") }
            Button(role: .destructive) { confirmClear = true } label: { Label("Cancella inchiostro", systemImage: "eraser") }
        }
        Section("Quaderno") {
            Button { model.insertContents() } label: {
                Label(model.bookmarkCount > 0 ? "Inserisci indice dei segnalibri" : "Inserisci indice", systemImage: "list.bullet.rectangle")
            }
            Button { showSearch = true } label: { Label("Cerca nel quaderno", systemImage: "magnifyingglass") }
            Button { showPages = true } label: { Label("Tutte le pagine", systemImage: "square.grid.2x2") }
        }
        Section("Esporta") {
            Button { export { try model.exportPDF(currentOnly: false) } } label: { Label("Quaderno in PDF", systemImage: "square.and.arrow.up") }
            Button { export { try model.exportPDF(currentOnly: true) } } label: { Label("Questa pagina in PDF", systemImage: "doc") }
            Button { export { try model.exportImage() } } label: { Label("Questa pagina come immagine", systemImage: "photo") }
        }
    }

    private func export(_ make: () throws -> URL) {
        do {
            share = ShareFile(url: try make())
        } catch {
            self.error = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }
}

/// On iPhone the page arrows live at the bottom, where the thumb is, not in the crowded title bar.
struct PageNav: View {
    let model: EditorModel
    /// Opens the grid of all pages (a tap on the page counter).
    let onPages: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { model.previous() } label: {
                Image(systemName: "chevron.left").frame(width: 40, height: 36)
            }
            .disabled(model.pageIndex == 0)
            .accessibilityLabel("Pagina precedente")
            Button(action: onPages) {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text("\(model.pageIndex + 1) / \(model.notebook.pages.count)")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.text)
                }
                .frame(minWidth: 62, minHeight: 36)
            }
            .accessibilityLabel("Tutte le pagine")
            Button { model.next() } label: {
                Image(systemName: model.pageIndex + 1 < model.notebook.pages.count ? "chevron.right" : "plus")
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel(model.pageIndex + 1 < model.notebook.pages.count ? "Pagina successiva" : "Nuova pagina")
            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            Button { model.toggleBookmark(model.pageIndex) } label: {
                Image(systemName: model.page.isBookmarked ? "bookmark.fill" : "bookmark")
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel(model.page.isBookmarked ? "Togli il segnalibro" : "Aggiungi un segnalibro")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
