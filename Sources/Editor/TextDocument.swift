import Observation
import SwiftUI
import UIKit

/// A text document: typed text with titles, bold, lists and colours, stored as RTF in the
/// notebook's folder (documento.rtf). It sits on the shelf like a notebook.
enum TextDoc {
    static func url(_ id: UUID) -> URL { Store.dir(id).appendingPathComponent("documento.rtf") }

    static let pageSize = PageFormat.a4Portrait.size
    static let margins = UIEdgeInsets(top: 60, left: 56, bottom: 60, right: 56)

    enum Style: String, CaseIterable, Identifiable {
        case title, heading, body
        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: String(localized: "Titolo")
            case .heading: String(localized: "Intestazione")
            case .body: String(localized: "Testo")
            }
        }

        var font: UIFont {
            switch self {
            case .title: .systemFont(ofSize: 28, weight: .bold)
            case .heading: .systemFont(ofSize: 21, weight: .semibold)
            case .body: .systemFont(ofSize: 17)
            }
        }
    }

    static let ink = UIColor(hex: "1C1C20")
    static var bodyAttributes: [NSAttributedString.Key: Any] { [.font: Style.body.font, .foregroundColor: ink] }

    static func load(_ id: UUID) -> NSAttributedString {
        guard let data = try? Data(contentsOf: url(id)),
              let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return NSAttributedString(string: "", attributes: bodyAttributes) }
        return s
    }

    static func save(_ s: NSAttributedString, _ id: UUID) {
        Store.ensureDirs(id)
        let range = NSRange(location: 0, length: s.length)
        guard let data = try? s.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
        try? data.write(to: url(id), options: .atomic)
    }

    static func plain(_ id: UUID) -> String { load(id).string }

    /// The first page of the document, for the shelf.
    static func drawFirstPage(_ nb: Notebook, size: CGSize, in ctx: CGContext) {
        ctx.setFillColor(nb.paper.uiColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let s = load(nb.id)
        let r = CGRect(origin: .zero, size: size).inset(by: margins)
        s.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// The whole document on A4 pages.
    static func exportPDF(_ nb: Notebook) throws -> URL {
        let safe = nb.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Documento" : safe).pdf")
        let formatter = UISimpleTextPrintFormatter(attributedText: load(nb.id))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(origin: .zero, size: pageSize)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.inset(by: margins)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, [kCGPDFContextTitle as String: nb.title, kCGPDFContextCreator as String: "Quaderno Appunti"])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: max(1, renderer.numberOfPages)))
        for i in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        try data.write(to: url, options: .atomic)
        return url
    }

    static func exportFile(_ nb: Notebook, rtf: Bool) throws -> URL {
        let safe = nb.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = (safe.isEmpty ? "Documento" : safe) + (rtf ? ".rtf" : ".txt")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if rtf {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: Self.url(nb.id), to: url)
        } else {
            try plain(nb.id).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

/// The text view of a document and what the format bar does to it.
@MainActor
@Observable
final class TextDocController: NSObject, UITextViewDelegate {
    let library: Library
    var notebook: Notebook
    @ObservationIgnored weak var textView: UITextView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// What the selection looks like, for the buttons of the bar.
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var style: TextDoc.Style = .body

    init(library: Library, notebook: Notebook) {
        self.library = library
        self.notebook = notebook
        super.init()
    }

    func attach(_ tv: UITextView) {
        textView = tv
        tv.delegate = self
        tv.attributedText = TextDoc.load(notebook.id)
        if tv.attributedText.length == 0 { tv.typingAttributes = TextDoc.bodyAttributes }
        refresh()
    }

    // MARK: Saving

    private func changed() {
        dirty = true
        refresh()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty, let tv = textView else { return }
        dirty = false
        TextDoc.save(tv.attributedText, notebook.id)
        library.save(notebook)
        library.refreshThumb(notebook.id)
        Indexer.shared.schedule(notebook, page: notebook.pages.first?.id ?? notebook.id)
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        notebook.title = t
        library.save(notebook, touch: false)
    }

    // MARK: Delegate

    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }

    /// Lists go on by themselves: a new line after "• " or "3. " starts with the next one, and an
    /// empty item ends the list.
    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", range.length == 0 else { return true }
        let ns = tv.textStorage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
        guard let prefix = Self.listPrefix(line) else { return true }
        if line == prefix.trimmingCharacters(in: .whitespaces) || line == prefix {
            // empty item: end the list
            tv.textStorage.replaceCharacters(in: NSRange(location: para.location, length: (prefix as NSString).length), with: "")
            tv.selectedRange = NSRange(location: para.location, length: 0)
            changed()
            return false
        }
        tv.insertText("\n" + Self.next(prefix))
        return false
    }

    nonisolated static func listPrefix(_ line: String) -> String? {
        if line.hasPrefix("• ") { return "• " }
        if line.hasPrefix("☐ ") { return "☐ " }
        if line.hasPrefix("☑ ") { return "☐ " }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return digits + ". " }
        return nil
    }

    private nonisolated static func next(_ prefix: String) -> String {
        if let n = Int(prefix.dropLast(2)) { return "\(n + 1). " }
        return prefix
    }

    // MARK: Formatting

    private var selection: NSRange { textView?.selectedRange ?? NSRange(location: 0, length: 0) }

    private func currentFont() -> UIFont {
        guard let tv = textView else { return TextDoc.Style.body.font }
        if selection.length == 0 {
            return (tv.typingAttributes[.font] as? UIFont) ?? TextDoc.Style.body.font
        }
        return (tv.textStorage.attribute(.font, at: selection.location, effectiveRange: nil) as? UIFont) ?? TextDoc.Style.body.font
    }

    private func refresh() {
        guard let tv = textView else { return }
        let f = currentFont()
        bold = f.fontDescriptor.symbolicTraits.contains(.traitBold) && f.pointSize < 20
        italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
        let attrs: [NSAttributedString.Key: Any] = selection.length == 0 || tv.textStorage.length == 0
            ? tv.typingAttributes
            : tv.textStorage.attributes(at: min(selection.location, tv.textStorage.length - 1), effectiveRange: nil)
        underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        style = f.pointSize >= 26 ? .title : (f.pointSize >= 20 ? .heading : .body)
    }

    /// Changes the attributes of the selection, or of what is typed next when nothing is selected.
    private func edit(_ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView else { return }
        let r = selection
        if r.length == 0 {
            var ta = tv.typingAttributes
            change(&ta)
            tv.typingAttributes = ta
            refresh()
            return
        }
        let storage = tv.textStorage
        storage.beginEditing()
        storage.enumerateAttributes(in: r) { attrs, sub, _ in
            var a = attrs
            change(&a)
            storage.setAttributes(a, range: sub)
        }
        storage.endEditing()
        tv.selectedRange = r
        changed()
    }

    func toggle(_ trait: UIFontDescriptor.SymbolicTraits) {
        let on = trait == .traitBold ? !bold : !italic
        edit { a in
            let f = (a[.font] as? UIFont) ?? TextDoc.Style.body.font
            var traits = f.fontDescriptor.symbolicTraits
            if on { traits.insert(trait) } else { traits.remove(trait) }
            if let d = f.fontDescriptor.withSymbolicTraits(traits) { a[.font] = UIFont(descriptor: d, size: f.pointSize) }
        }
    }

    func toggleUnderline() {
        let on = !underline
        edit { $0[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    func toggleStrike() {
        let on = !strike
        edit { $0[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    func setColor(_ hex: String) {
        edit { $0[.foregroundColor] = UIColor(hex: hex) }
    }

    /// Titles, headings and plain text apply to whole paragraphs.
    func apply(_ s: TextDoc.Style) {
        guard let tv = textView else { return }
        let ns = tv.textStorage.string as NSString
        let para = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.paragraphRange(for: selection)
        var ta = tv.typingAttributes
        ta[.font] = s.font
        tv.typingAttributes = ta
        guard para.length > 0 else { refresh(); return }
        let storage = tv.textStorage
        storage.beginEditing()
        storage.addAttribute(.font, value: s.font, range: para)
        storage.endEditing()
        changed()
    }

    /// Starts (or ends) a list on the selected paragraphs: bullets, numbers or boxes to tick.
    func list(_ kind: String) {
        guard let tv = textView else { return }
        let ns = tv.textStorage.string as NSString
        let all = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.paragraphRange(for: selection)
        var paras: [NSRange] = []
        if all.length == 0 {
            paras = [NSRange(location: all.location, length: 0)]
        } else {
            ns.enumerateSubstrings(in: all, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in paras.append(r) }
            if paras.isEmpty { paras = [NSRange(location: all.location, length: 0)] }
        }
        let lines = paras.map { ns.substring(with: $0) }
        let removing = lines.allSatisfy { Self.listPrefix($0) != nil }
        let storage = tv.textStorage
        let attrs = storage.length > 0 ? storage.attributes(at: min(all.location, storage.length - 1), effectiveRange: nil) : tv.typingAttributes
        storage.beginEditing()
        var n = paras.count
        for (r, line) in zip(paras, lines).reversed() {
            if let old = Self.listPrefix(line) {
                storage.replaceCharacters(in: NSRange(location: r.location, length: (old as NSString).length), with: "")
            }
            if !removing {
                let p = kind == "number" ? "\(n). " : (kind == "check" ? "☐ " : "• ")
                storage.insert(NSAttributedString(string: p, attributes: attrs), at: r.location)
            }
            n -= 1
        }
        storage.endEditing()
        changed()
    }

    /// A tap on a box of a checklist ticks it.
    func tapped(at index: Int) -> Bool {
        guard let tv = textView, index < tv.textStorage.length else { return false }
        let ns = tv.textStorage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: index, length: 0))
        guard index - para.location <= 1 else { return false }
        let first = ns.substring(with: NSRange(location: para.location, length: min(1, para.length)))
        guard first == "☐" || first == "☑" else { return false }
        tv.textStorage.replaceCharacters(in: NSRange(location: para.location, length: 1), with: first == "☐" ? "☑" : "☐")
        changed()
        return true
    }
}

/// The text view, on paper.
struct TextDocEditor: UIViewRepresentable {
    let controller: TextDocController

    func makeUIView(context: Context) -> DocTextView {
        let tv = DocTextView()
        tv.overrideUserInterfaceStyle = .light
        tv.backgroundColor = controller.notebook.paper.uiColor
        tv.allowsEditingTextAttributes = true
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.adjustsFontForContentSizeCategory = false
        tv.onTapIndex = { [weak controller] i in controller?.tapped(at: i) ?? false }
        controller.attach(tv)
        return tv
    }

    func updateUIView(_ uiView: DocTextView, context: Context) {}
}

/// A text view that keeps the text in a comfortable column on wide screens and ticks checklist boxes.
final class DocTextView: UITextView {
    var onTapIndex: ((Int) -> Bool)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = max(22, (bounds.width - 720) / 2)
        let inset = UIEdgeInsets(top: 28, left: side, bottom: 120, right: side)
        if textContainerInset != inset { textContainerInset = inset }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        var p = g.location(in: self)
        p.x -= textContainerInset.left
        p.y -= textContainerInset.top
        let i = layoutManager.characterIndex(for: p, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        _ = onTapIndex?(i)
    }
}

/// A text document open: the format bar, then the text.
struct TextDocView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var controller: TextDocController
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var share: ShareFile?
    @State private var error: String?
    /// Kept in state: SwiftUI makes this view again and again, and by then the document is open (here).
    @State private var openElsewhere: Bool
    private var onClose: (() -> Void)?

    init(library: Library, notebook: Notebook, onClose: (() -> Void)? = nil) {
        _controller = State(initialValue: TextDocController(library: library, notebook: notebook))
        let elsewhere = library.isOpen(notebook.id)
        _openElsewhere = State(initialValue: elsewhere)
        if !elsewhere { library.opened(notebook.id) }
        self.onClose = onClose
    }

    private func leave() {
        if !openElsewhere {
            controller.saveNow()
            controller.library.closed(controller.notebook.id)
        }
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        if openElsewhere {
            VStack(spacing: 16) {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 50)).foregroundStyle(Theme.accent)
                Text("«\(controller.notebook.title)» è già aperto in un'altra finestra.")
                    .font(.headline).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                Button("Chiudi") { leave() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        } else {
            editor
        }
    }

    private var editor: some View {
        NavigationStack {
            TextDocEditor(controller: controller)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) { FormatBar(controller: controller) }
                .overlay(alignment: .top) { ErrorBanner(error: $error).padding(12).padding(.top, 52) }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { leave() } label: { Image(systemName: "chevron.backward").fontWeight(.semibold) }
                            .accessibilityLabel("Indietro")
                    }
                    ToolbarItem(placement: .principal) {
                        Button { newTitle = controller.notebook.title; renaming = true } label: {
                            VStack(spacing: 0) {
                                Text(controller.notebook.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text("Documento di testo").font(.caption2).foregroundStyle(Theme.sub)
                            }
                        }
                        .accessibilityLabel("Rinomina")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { export { try TextDoc.exportPDF(controller.notebook) } } label: { Label("PDF", systemImage: "doc.richtext") }
                            Button { export { try TextDoc.exportFile(controller.notebook, rtf: true) } } label: { Label("Testo formattato (RTF)", systemImage: "doc.text") }
                            Button { export { try TextDoc.exportFile(controller.notebook, rtf: false) } } label: { Label("Testo semplice", systemImage: "text.alignleft") }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Esporta")
                    }
                }
        }
        .alert("Rinomina documento", isPresented: $renaming) {
            TextField("Titolo", text: $newTitle)
            Button("Annulla", role: .cancel) {}
            Button("Salva") { controller.rename(newTitle) }
        }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .onChange(of: phase) { _, p in if p != .active { controller.saveNow() } }
        .onDisappear {
            controller.saveNow()
            controller.library.closed(controller.notebook.id)
        }
        .preferredColorScheme(.dark)
    }

    private func export(_ make: () throws -> URL) {
        controller.saveNow()
        do { share = ShareFile(url: try make()) } catch { self.error = String(localized: "Esportazione non riuscita: \(error.localizedDescription)") }
    }
}

/// Styles, bold, italic, underline, lists and colours.
struct FormatBar: View {
    let controller: TextDocController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    ForEach(TextDoc.Style.allCases) { s in
                        Button { controller.apply(s) } label: {
                            if controller.style == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(controller.style.label).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Theme.input, in: Capsule())
                }
                sep
                button("bold", String(localized: "Grassetto"), controller.bold) { controller.toggle(.traitBold) }
                button("italic", String(localized: "Corsivo"), controller.italic) { controller.toggle(.traitItalic) }
                button("underline", String(localized: "Sottolineato"), controller.underline) { controller.toggleUnderline() }
                button("strikethrough", String(localized: "Barrato"), controller.strike) { controller.toggleStrike() }
                sep
                button("list.bullet", String(localized: "Elenco puntato"), false) { controller.list("bullet") }
                button("list.number", String(localized: "Elenco numerato"), false) { controller.list("number") }
                button("checklist", String(localized: "Elenco da spuntare"), false) { controller.list("check") }
                sep
                ForEach(TextColors.all, id: \.self) { hex in
                    Button { controller.setColor(hex) } label: {
                        Circle().fill(Color(uiColor: UIColor(hex: hex))).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                            .frame(width: 34, height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 52)
        .clipped()
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var sep: some View { Rectangle().fill(Theme.line).frame(width: 1, height: 26).padding(.horizontal, 6) }

    private func button(_ icon: String, _ label: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.text)
                .frame(width: 42, height: 40)
                .background(on ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
