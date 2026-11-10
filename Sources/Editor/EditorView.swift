import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CanvasHost: UIViewRepresentable {
    let view: PageCanvasView
    func makeUIView(context: Context) -> PageCanvasView { view }
    func updateUIView(_ uiView: PageCanvasView, context: Context) {}
}

/// An open notebook.
struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model: EditorModel
    @State private var showPages = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showPDFPicker = false
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var confirmClear = false

    init(library: Library, notebook: Notebook, page: Int?) {
        _model = State(initialValue: EditorModel(library: library, notebook: notebook, page: page))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CanvasHost(view: model.canvas)
                    .ignoresSafeArea(edges: .bottom)
                if let item = model.selected, !model.drawMode {
                    ItemBar(item: item, model: model)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ErrorBanner(error: $error).padding(12).frame(maxHeight: .infinity, alignment: .top)
            }
            .animation(.easeOut(duration: 0.18), value: model.selected?.id)
            .background(Theme.desk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showPages) {
            PagesView(model: model)
                .presentationDetents([.medium, .large])
        }
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
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .confirmationDialog("Cancellare tutto l'inchiostro di questa pagina?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Cancella inchiostro", role: .destructive) { model.canvas.clearInk() }
        }
        .onChange(of: phase) { _, p in if p != .active { model.canvas.saveNow() } }
        .onDisappear { model.close() }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.close()
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 14) {
                Button { model.previous() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.pageIndex == 0)
                Button { showPages = true } label: {
                    VStack(spacing: 0) {
                        Text(model.notebook.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(model.pageIndex + 1) / \(model.notebook.pages.count)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.sub)
                    }
                    .frame(maxWidth: 160)
                }
                Button { model.next() } label: {
                    Image(systemName: model.pageIndex + 1 < model.notebook.pages.count ? "chevron.right" : "plus")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.canvas.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.canvas.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
            Button { model.setDrawMode(!model.drawMode) } label: {
                Image(systemName: model.drawMode ? "pencil.tip.crop.circle.fill" : "hand.point.up.left.fill")
            }
            .accessibilityLabel(model.drawMode ? "Scrittura" : "Sposta testi e foto")
            Menu {
                Section("Aggiungi") {
                    Button { model.addText() } label: { Label("Testo", systemImage: "textformat") }
                    Button { showPhotos = true } label: { Label("Foto", systemImage: "photo") }
                    Button { model.addPage(after: model.pageIndex, template: nil) } label: { Label("Pagina dopo questa", systemImage: "doc.badge.plus") }
                    Button { showPDFPicker = true } label: { Label("Pagine da un PDF", systemImage: "doc.richtext") }
                }
                Section("Pagina") {
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
                    Button { showPages = true } label: { Label("Tutte le pagine", systemImage: "square.grid.2x2") }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Cancella inchiostro", systemImage: "eraser") }
                }
                Section("Esporta") {
                    Button { export(currentOnly: false) } label: { Label("Quaderno in PDF", systemImage: "square.and.arrow.up") }
                    Button { export(currentOnly: true) } label: { Label("Solo questa pagina", systemImage: "doc") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func export(currentOnly: Bool) {
        do {
            share = ShareFile(url: try model.exportPDF(currentOnly: currentOnly))
        } catch {
            self.error = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }
}

/// Controls for the selected text box or picture.
struct ItemBar: View {
    let item: PageItem
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            if item.kind == .text {
                Button { model.update { $0.fontSize = max(8, $0.fontSize - 2) } } label: { Image(systemName: "textformat.size.smaller") }
                Text("\(Int(item.fontSize))").font(.footnote.monospacedDigit()).foregroundStyle(Theme.sub).frame(minWidth: 22)
                Button { model.update { $0.fontSize = min(120, $0.fontSize + 2) } } label: { Image(systemName: "textformat.size.larger") }
                Button { model.update { $0.bold.toggle() } } label: { Image(systemName: "bold") }
                    .foregroundStyle(item.bold ? Theme.accent : Theme.text)
                Divider().frame(height: 22)
                ForEach(TextColors.all, id: \.self) { hex in
                    Button { model.update { $0.color = hex } } label: {
                        Circle().fill(Color(uiColor: UIColor(hex: hex)))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(item.color == hex ? Theme.accent : Theme.line, lineWidth: item.color == hex ? 2.5 : 1))
                    }
                }
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.sub)
                Text("Trascina per spostare, pizzica o usa l'angolo per ridimensionare")
                    .font(.caption).foregroundStyle(Theme.sub).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button { model.canvas.bringSelectedToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }
            Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash").foregroundStyle(Theme.bad) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .frame(maxWidth: 620)
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
