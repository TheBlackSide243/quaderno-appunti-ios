import SwiftUI
import UIKit

/// The pictures of a flashcard, cut out of its page.
@MainActor
enum CardImages {
    /// The question (with the answer covered where the two overlap) and the answer.
    static func render(_ nb: Notebook, _ card: Flashcard, pageCache: inout [UUID: UIImage]) -> (UIImage, UIImage)? {
        guard let page = nb.pages.first(where: { $0.id == card.page }) else { return nil }
        let width: CGFloat = 1600
        let full: UIImage
        if let c = pageCache[page.id] {
            full = c
        } else {
            full = PageRenderer.render(nb, page, width: width)
            pageCache[page.id] = full
        }
        let k = width / page.size.width
        func cut(_ r: CGRect, cover: CGRect?) -> UIImage {
            let area = r.insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: page.size))
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = k
            fmt.opaque = true
            return UIGraphicsImageRenderer(size: area.size, format: fmt).image { ctx in
                full.draw(at: CGPoint(x: -area.minX, y: -area.minY))
                if let cover {
                    let hide = cover.intersection(area).offsetBy(dx: -area.minX, dy: -area.minY)
                    // only a real overlap: two boxes that just touch leave the question alone
                    if !hide.isNull, hide.width > 8, hide.height > 8 {
                        UIColor(patternImage: ItemView.tapePattern(UIColor(hex: TapeColors.all[0]))).setFill()
                        UIBezierPath(roundedRect: hide, cornerRadius: 3).fill()
                        let q = "?" as NSString
                        let font = UIFont.systemFont(ofSize: min(hide.height * 0.6, 40), weight: .heavy)
                        let size = q.size(withAttributes: [.font: font])
                        q.draw(at: CGPoint(x: hide.midX - size.width / 2, y: hide.midY - size.height / 2),
                               withAttributes: [.font: font, .foregroundColor: UIColor.white])
                    }
                }
                _ = ctx
            }
        }
        return (cut(card.front, cover: card.back), cut(card.back, cover: nil))
    }
}

struct CardPair {
    let front: UIImage
    let back: UIImage
}

/// Reviewing the flashcards of a notebook: the question, then the answer, then how well it went.
struct StudyView: View {
    let notebook: Notebook
    let onUpdate: (Flashcard) -> Void
    let onDelete: (Flashcard) -> Void
    /// Opens the page of a card (only from the editor).
    var onOpen: ((Flashcard) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var cards: [Flashcard]
    @State private var queue: [UUID] = []
    @State private var started = false
    @State private var showBack = false
    @State private var done = 0
    @State private var images: [UUID: CardPair] = [:]
    @State private var rendered = false
    @State private var showList = false

    init(notebook: Notebook, onUpdate: @escaping (Flashcard) -> Void, onDelete: @escaping (Flashcard) -> Void, onOpen: ((Flashcard) -> Void)? = nil) {
        self.notebook = notebook
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onOpen = onOpen
        let pages = Set(notebook.pages.map(\.id))
        _cards = State(initialValue: (notebook.cards ?? []).filter { pages.contains($0.page) })
    }

    private var current: Flashcard? {
        guard let id = queue.first else { return nil }
        return cards.first { $0.id == id }
    }

    private var due: [Flashcard] { cards.filter { $0.isDue() }.sorted { $0.due < $1.due } }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .navigationTitle("Ripasso")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fine") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showList = true } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("Tutte le flashcard")
                            .disabled(cards.isEmpty)
                    }
                }
                .sheet(isPresented: $showList) { list }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !started {
                queue = due.map(\.id)
                started = !queue.isEmpty
            }
        }
        .task {
            // after the sheet is on screen, so it opens at once
            try? await Task.sleep(for: .milliseconds(120))
            var cache: [UUID: UIImage] = [:]
            var out: [UUID: CardPair] = [:]
            for c in cards {
                if let r = CardImages.render(notebook, c, pageCache: &cache) { out[c.id] = CardPair(front: r.0, back: r.1) }
            }
            images = out
            rendered = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if cards.isEmpty {
            ContentUnavailableView {
                Label("Nessuna flashcard", systemImage: "rectangle.on.rectangle.angled")
            } description: {
                Text("Nel quaderno apri il menu … e scegli «Crea flashcard»: trascina un riquadro sulla domanda e uno sulla risposta.")
            }
        } else if let card = current {
            review(card)
        } else {
            finished
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: done > 0 ? "checkmark.seal.fill" : "clock")
                .font(.system(size: 54)).foregroundStyle(Theme.accent)
            Text(done > 0 ? String(localized: "Ripasso finito") : String(localized: "Niente da ripassare adesso"))
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            if let next = cards.map(\.due).filter({ $0 > Date() }).min() {
                Text("La prossima flashcard torna \(next.formatted(.relative(presentation: .named)))")
                    .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
            }
            Button {
                queue = cards.sorted { $0.due < $1.due }.map(\.id)
                showBack = false
            } label: {
                Label("Ripassa tutte lo stesso", systemImage: "arrow.counterclockwise")
                    .padding(.horizontal, 18).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.bg)
        }
        .padding(24)
    }

    private func review(_ card: Flashcard) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(queue.count) da ripassare").font(.footnote.monospacedDigit()).foregroundStyle(Theme.sub)
                Spacer()
                if let onOpen {
                    Button { onOpen(card); dismiss() } label: { Label("Vai alla pagina", systemImage: "doc.text") }
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 12) {
                    if let p = images[card.id] {
                        side(String(localized: "Domanda"), p.front)
                        if showBack {
                            side(String(localized: "Risposta"), p.back)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    } else if !rendered {
                        ProgressView().tint(Theme.accent).padding(.top, 60)
                    } else {
                        Text("La pagina di questa flashcard non c'è più.").foregroundStyle(Theme.sub).padding(.top, 40)
                    }
                }
            }
            if showBack {
                HStack(spacing: 8) {
                    ForEach(Flashcard.Grade.allCases) { g in gradeButton(card, g) }
                }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showBack = true }
                } label: {
                    Text("Mostra la risposta").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.bg)
            }
        }
        .padding(16)
        .frame(maxWidth: 760)
    }

    private func side(_ title: String, _ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.sub)
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }

    private func gradeButton(_ card: Flashcard, _ g: Flashcard.Grade) -> some View {
        let label: String
        let tint: Color
        switch g {
        case .again: label = String(localized: "Di nuovo"); tint = Theme.bad
        case .hard: label = String(localized: "Difficile"); tint = .orange
        case .good: label = String(localized: "Bene"); tint = Theme.accent
        case .easy: label = String(localized: "Facile"); tint = .green
        }
        return Button {
            answer(card, g)
        } label: {
            VStack(spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(Self.span(card.nextInterval(g))).font(.caption2.monospacedDigit()).opacity(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func answer(_ card: Flashcard, _ g: Flashcard.Grade) {
        let next = card.answered(g)
        if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = next }
        onUpdate(next)
        queue.removeFirst()
        // a card answered wrong comes back at the end of this review
        if g == .again { queue.append(card.id) }
        done += 1
        showBack = false
    }


    /// "1 min", "3 g", "2 mesi"…
    static func span(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = t < 3600 ? [.minute] : (t < 86400 ? [.hour] : (t < 86400 * 60 ? [.day] : [.month, .year]))
        return f.string(from: max(60, t)) ?? ""
    }

    private var list: some View {
        NavigationStack {
            List {
                ForEach(cards.sorted { $0.created < $1.created }) { card in
                    HStack(spacing: 12) {
                        if let p = images[card.id] {
                            Image(uiImage: p.front).resizable().scaledToFit().frame(width: 110, height: 60)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if let n = notebook.pages.firstIndex(where: { $0.id == card.page }) {
                                Text("Pagina \(n + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            }
                            Text(card.isDue() ? String(localized: "Da ripassare") : String(localized: "Torna \(card.due.formatted(.relative(presentation: .named)))"))
                                .font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    .listRowBackground(Theme.panel)
                    .swipeActions {
                        Button(role: .destructive) {
                            cards.removeAll { $0.id == card.id }
                            queue.removeAll { $0 == card.id }
                            onDelete(card)
                        } label: { Label("Elimina", systemImage: "trash") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Flashcard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { showList = false } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The handwriting read from an area: to copy, or to put on the page as typed text.
struct InkTextView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Group {
                if let read = model.inkText?.text {
                    if read.isEmpty && !filled {
                        ContentUnavailableView("Non riesco a leggere questa scrittura", systemImage: "text.viewfinder",
                                               description: Text("Prova con un riquadro più grande o una scrittura più ordinata."))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            TextEditor(text: $text)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .frame(minHeight: 140)
                            Text("Correggi il testo se serve, poi scegli cosa farne.").font(.footnote).foregroundStyle(Theme.sub)
                            VStack(spacing: 8) {
                                Button {
                                    model.placeInkText(text, replace: true)
                                    dismiss()
                                } label: {
                                    Label("Sostituisci la scrittura", systemImage: "character.cursor.ibeam").frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
                                Button {
                                    model.placeInkText(text, replace: false)
                                    dismiss()
                                } label: {
                                    Label("Aggiungi sotto come testo", systemImage: "text.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    UIPasteboard.general.string = text
                                    model.notice = String(localized: "Testo copiato.")
                                    model.inkText = nil
                                    dismiss()
                                } label: {
                                    Label("Copia", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(16)
                        .onAppear {
                            if !filled { text = read; filled = true }
                        }
                    }
                } else {
                    ProgressView("Leggo la scrittura…").tint(Theme.accent).foregroundStyle(Theme.sub)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
            .navigationTitle("Testo dalla scrittura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { model.inkText = nil; dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// While presenting: a small bar at the bottom to turn pages, switch between laser and pen, and stop.
struct PresentBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.previous() } label: { Image(systemName: "chevron.left").frame(width: 42, height: 38) }
                .disabled(model.pageIndex == 0)
                .accessibilityLabel("Pagina precedente")
            Text("\(model.pageIndex + 1) / \(model.notebook.pages.count)")
                .font(.footnote.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.text).frame(minWidth: 52)
            Button { model.go(to: model.pageIndex + 1) } label: { Image(systemName: "chevron.right").frame(width: 42, height: 38) }
                .disabled(model.pageIndex + 1 >= model.notebook.pages.count)
                .accessibilityLabel("Pagina successiva")
            Rectangle().fill(Theme.line).frame(width: 1, height: 22)
            Button { model.select(.laser) } label: {
                Image(systemName: Tool.laser.icon).frame(width: 42, height: 38)
                    .background(model.tool == .laser ? Theme.accent.opacity(0.18) : .clear, in: Capsule())
            }
            .accessibilityLabel(Tool.laser.label)
            Button { model.select(.pen) } label: {
                Image(systemName: Tool.pen.icon).frame(width: 42, height: 38)
                    .background(model.tool == .pen ? Theme.accent.opacity(0.18) : .clear, in: Capsule())
            }
            .accessibilityLabel(Tool.pen.label)
            Button { model.select(.highlighter) } label: {
                Image(systemName: Tool.highlighter.icon).frame(width: 42, height: 38)
                    .background(model.tool == .highlighter ? Theme.accent.opacity(0.18) : .clear, in: Capsule())
            }
            .accessibilityLabel(Tool.highlighter.label)
            Rectangle().fill(Theme.line).frame(width: 1, height: 22)
            Button { model.setPresenting(false) } label: {
                Image(systemName: "xmark").frame(width: 42, height: 38)
            }
            .accessibilityLabel("Esci dalla presentazione")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
