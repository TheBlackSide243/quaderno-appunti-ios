import SwiftUI

/// Title, cover, paper and size of a new notebook. Two tabs on top (cover and paper) show what you
/// picked; the gallery below changes with the tab.
struct NewNotebookView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    let folder: UUID?
    let onCreate: (Notebook) -> Void

    enum Tab { case cover, paper }

    @State private var tab: Tab = Demo.screen == "covers" ? .cover : .paper
    @State private var title = ""
    @State private var cover: Int? = 10
    @State private var style: CoverStyle = .plain
    @State private var template: PageTemplate = .grid
    @State private var paper: Paper = .ivory
    @State private var format: PageFormat = .a4Portrait
    @State private var board = false
    @State private var textDoc = false
    @State private var folderID: UUID?
    @FocusState private var titleFocused: Bool

    init(folder: UUID?, onCreate: @escaping (Notebook) -> Void) {
        self.folder = folder
        self.onCreate = onCreate
        _folderID = State(initialValue: folder)
    }

    private var regular: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.line)
                if tab == .paper { paperOptions; Divider().overlay(Theme.line) }
                ScrollView {
                    if tab == .paper { paperGallery } else { coverGallery }
                }
                .background(Theme.bg)
            }
            .background(Theme.bg)
            .navigationTitle("Nuovo quaderno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .toolbarBackground(Theme.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        let layout = regular ? AnyLayout(HStackLayout(alignment: .center, spacing: 22)) : AnyLayout(VStackLayout(spacing: 14))
        return layout {
            HStack(spacing: 12) {
                tabButton(.cover, caption: String(localized: "COPERTINA"),
                          name: cover.map { "\(style.label), \(Covers.names[$0].lowercased())" } ?? String(localized: "Prima pagina")) {
                    if let cover {
                        CoverArt(color: Covers.color(cover), style: style, title: title)
                    } else {
                        TemplatePreview(template: template, paper: paper, format: format)
                    }
                }
                tabButton(.paper, caption: String(localized: "CARTA"), name: template.label) {
                    TemplatePreview(template: template, paper: paper, format: format)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("TITOLO").font(.caption.weight(.bold)).foregroundStyle(Theme.sub).tracking(0.6)
                    TextField("Quaderno senza titolo", text: $title)
                        .font(.title3)
                        .focused($titleFocused)
                        .submitLabel(.done)
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(spacing: 12) {
                    if !library.folders.isEmpty {
                        Menu {
                            Button { folderID = nil } label: { Label("Documenti", systemImage: folderID == nil ? "checkmark" : "tray") }
                            ForEach(library.folders) { f in
                                Button { folderID = f.id } label: {
                                    if folderID == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                                }
                            }
                        } label: {
                            Label(library.folders.first { $0.id == folderID }?.name ?? String(localized: "Documenti"), systemImage: "folder")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(height: 48)
                                .background(Theme.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                                .foregroundStyle(Theme.text)
                        }
                    }
                    Button("Crea") { create() }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: regular ? 220 : .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(regular ? 22 : 16)
        .background(Theme.panel)
    }

    private func tabButton<P: View>(_ t: Tab, caption: String, name: String, @ViewBuilder preview: () -> P) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
            VStack(spacing: 6) {
                Text(caption).font(.caption2.weight(.bold)).foregroundStyle(Theme.sub).tracking(0.6)
                Text(name).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                preview()
                    .frame(width: regular ? 92 : 74, height: regular ? 121 : 97)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            }
            .frame(width: regular ? 138 : 124)
            .padding(.vertical, 12)
            .background(tab == t ? Theme.bg : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) {
                if tab == t { Capsule().fill(Theme.accent).frame(width: 44, height: 4).offset(y: -2) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Paper

    private var paperOptions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                optionMenu(icon: "paintpalette", text: String(localized: "Carta \(paper.label.lowercased())")) {
                    ForEach(Paper.allCases) { p in
                        Button { paper = p } label: { if paper == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) } }
                    }
                }
                optionMenu(icon: textDoc ? "doc.text" : (board ? "rectangle.expand.vertical" : "rectangle.portrait"),
                           text: textDoc ? String(localized: "Documento di testo") : (board ? String(localized: "Lavagna infinita") : format.label)) {
                    ForEach(PageFormat.allCases) { f in
                        Button { format = f; board = false; textDoc = false } label: {
                            if format == f && !board && !textDoc { Label(f.label, systemImage: "checkmark") } else { Text(f.label) }
                        }
                    }
                    Divider()
                    Button { board = true; textDoc = false } label: {
                        if board { Label("Lavagna infinita", systemImage: "checkmark") } else { Label("Lavagna infinita", systemImage: "rectangle.expand.vertical") }
                    }
                    Button { textDoc = true; board = false } label: {
                        if textDoc { Label("Documento di testo", systemImage: "checkmark") } else { Label("Documento di testo", systemImage: "doc.text") }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.panel.opacity(0.6))
    }

    private func optionMenu<C: View>(icon: String, text: String, @ViewBuilder content: () -> C) -> some View {
        Menu { content() } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(text)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Theme.sub)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.input, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
    }

    private var galleryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: regular ? 130 : 96, maximum: 170), spacing: regular ? 26 : 16, alignment: .top)]
    }

    private var paperGallery: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(PageTemplate.groups, id: \.0) { name, list in
                Text(name.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.sub).tracking(0.6)
                LazyVGrid(columns: galleryColumns, spacing: 20) {
                    ForEach(list) { t in
                        Button { template = t } label: {
                            VStack(spacing: 8) {
                                TemplatePreview(template: t, paper: paper, format: format)
                                    .aspectRatio(format.size.width / format.size.height, contentMode: .fit)
                                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                                    .overlay(alignment: .bottom) { check(template == t).offset(y: 14) }
                                Text(t.label).font(.footnote).foregroundStyle(template == t ? Theme.accent : Theme.text)
                                    .padding(.top, 10)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(regular ? 26 : 16)
    }

    // MARK: Cover

    private var coverGallery: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("SENZA COPERTINA").font(.caption.weight(.bold)).foregroundStyle(Theme.sub).tracking(0.6)
            LazyVGrid(columns: galleryColumns, spacing: 20) {
                Button { cover = nil } label: {
                    VStack(spacing: 8) {
                        TemplatePreview(template: template, paper: paper, format: format)
                            .aspectRatio(0.76, contentMode: .fit)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                            .overlay(alignment: .bottom) { check(cover == nil).offset(y: 14) }
                        Text("Prima pagina").font(.footnote).foregroundStyle(cover == nil ? Theme.accent : Theme.text).padding(.top, 10)
                    }
                }
                .buttonStyle(.plain)
            }
            // the demo screenshot of the covers starts from the illustrated ones
            ForEach(Demo.screen == "covers" ? [(String(localized: "Illustrate"), CoverStyle.illustrated), (String(localized: "Classiche"), CoverStyle.classic)]
                                            : [(String(localized: "Classiche"), CoverStyle.classic), (String(localized: "Illustrate"), CoverStyle.illustrated)], id: \.0) { group in
                Text(group.0).font(.headline).foregroundStyle(Theme.text).padding(.top, 4)
                ForEach(group.1) { st in
                    Text(st.label.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.sub).tracking(0.6)
                    // one row per style, scrolled sideways through the colours
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: regular ? 22 : 14) {
                            ForEach(Covers.colors.indices, id: \.self) { i in
                                let on = cover == i && style == st
                                Button { cover = i; style = st } label: {
                                    VStack(spacing: 8) {
                                        CoverArt(color: Covers.color(i), style: st, title: title)
                                            .frame(width: regular ? 112 : 86, height: (regular ? 112 : 86) / 0.76)
                                            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                                            .overlay(alignment: .bottom) { check(on).offset(y: 14) }
                                        Text(Covers.names[i]).font(.footnote).foregroundStyle(on ? Theme.accent : Theme.text).padding(.top, 10)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(regular ? 26 : 16)
    }

    @ViewBuilder
    private func check(_ on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.bg)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
    }

    private func create() {
        let nb = library.create(title: title, cover: cover, style: style, template: template, paper: paper, format: format, folder: folderID, board: board, text: textDoc)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCreate(nb) }
    }
}

/// A small drawing of a page ruling on its paper.
struct TemplatePreview: View {
    let template: PageTemplate
    let paper: Paper
    var format: PageFormat = .a4Portrait

    var body: some View {
        Image(uiImage: PageRenderer.templateImage(template, paper: paper, size: format.size))
            .resizable()
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

extension PageRenderer {
    static func templateImage(_ t: PageTemplate, paper: Paper, size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 0.6
        return UIGraphicsImageRenderer(size: size, format: fmt).image { r in
            r.cgContext.setFillColor(paper.uiColor.cgColor)
            r.cgContext.fill(CGRect(origin: .zero, size: size))
            drawTemplate(t, size: size, in: r.cgContext, emphasis: 2.6)
        }
    }
}
