import SwiftUI

/// The study assistant: summaries, a quiz turned into flashcards, and questions about the notes.
struct AssistantView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    struct Message: Identifiable, Hashable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    @State private var messages: [Message] = []
    @State private var quiz: [NoteAI.QA] = []
    @State private var input = ""
    @State private var busy: String?
    @State private var error: String?
    @State private var chat = NoteAI.Chat()
    @State private var status = NoteAI.status
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if case .unavailable(let why) = status {
                    unavailable(why)
                } else {
                    conversation
                    askBar
                }
            }
            .background(Theme.bg)
            .navigationTitle("Assistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func unavailable(_ why: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("L'assistente usa Apple Intelligence").font(.headline).foregroundStyle(Theme.text)
                Text(why).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                Text("Funziona sul dispositivo, senza internet e senza mandare gli appunti a nessuno. Il controllo dell'ortografia (menu … → Studio) funziona anche senza.")
                    .font(.footnote).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                Button("Riprova") { status = NoteAI.status }
                    .buttonStyle(.bordered)
            }
            .padding(28)
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    actions
                    ForEach(messages) { m in bubble(m).id(m.id) }
                    if !quiz.isEmpty { quizCard }
                    if let b = busy {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.accent)
                            Text(b).font(.subheadline).foregroundStyle(Theme.sub)
                        }
                        .id("busy")
                    }
                    if let e = error {
                        Text(e).font(.footnote).foregroundStyle(Theme.bad)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sui tuoi appunti, sul dispositivo").font(.caption.weight(.semibold)).foregroundStyle(Theme.sub)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(String(localized: "Riassumi la pagina"), "text.alignleft") { Task { await summarizePage() } }
                    chip(String(localized: "Riassumi il quaderno"), "books.vertical") { Task { await summarizeNotebook() } }
                    chip(String(localized: "Quiz sulla pagina"), "questionmark.bubble") { Task { await makeQuiz() } }
                }
            }
        }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .disabled(busy != nil)
    }

    private func bubble(_ m: Message) -> some View {
        HStack {
            if m.mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(m.text).textSelection(.enabled).foregroundStyle(m.mine ? Theme.bg : Theme.text)
                if !m.mine {
                    HStack(spacing: 14) {
                        Button { UIPasteboard.general.string = m.text } label: { Label("Copia", systemImage: "doc.on.doc") }
                        Button {
                            model.insertText(m.text)
                            dismiss()
                        } label: { Label("Metti nella pagina", systemImage: "text.badge.plus") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(m.mine ? Theme.accent : Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !m.mine { Spacer(minLength: 20) }
        }
    }

    private var quizCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quiz").font(.headline).foregroundStyle(Theme.text)
            ForEach(quiz) { qa in
                VStack(alignment: .leading, spacing: 3) {
                    Text(qa.question).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(qa.answer).font(.subheadline).foregroundStyle(Theme.sub)
                }
            }
            Button {
                model.addTextCards(quiz)
                quiz = []
                messages.append(Message(mine: false, text: String(localized: "Ho aggiunto le domande alle flashcard del quaderno: le trovi in … → Studio → Ripassa flashcard.")))
            } label: {
                Label("Aggiungi alle flashcard", systemImage: "rectangle.on.rectangle.angled").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            TextField("Chiedi qualcosa sui tuoi appunti", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .submitLabel(.send)
                .onSubmit { Task { await ask() } }
            Button { Task { await ask() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy != nil)
            .accessibilityLabel("Invia")
        }
        .padding(12)
        .background(Theme.panel)
    }

    // MARK: Work

    private func run(_ label: String, _ work: () async throws -> Void) async {
        error = nil
        busy = label
        defer { busy = nil }
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    private func notebookSources() async -> [NoteAI.Source] {
        var texts = Indexer.storedTexts(model.notebook.id)
        // the open page is read again now, so the latest writing counts
        texts[model.page.id.uuidString] = await model.pageText()
        return NoteAI.sources(model.notebook, texts)
    }

    private func summarizePage() async {
        await run(String(localized: "Riassumo la pagina…")) {
            let t = await model.pageText().all
            messages.append(Message(mine: true, text: String(localized: "Riassumi la pagina \(model.pageIndex + 1)")))
            messages.append(Message(mine: false, text: try await NoteAI.summary(of: t)))
        }
    }

    private func summarizeNotebook() async {
        await run(String(localized: "Riassumo il quaderno…")) {
            let src = await notebookSources()
            let all = src.map { (NoteAI.italian ? "[Pagina \($0.page)]\n" : "[Page \($0.page)]\n") + $0.text }.joined(separator: "\n\n")
            messages.append(Message(mine: true, text: String(localized: "Riassumi «\(model.notebook.title)»")))
            messages.append(Message(mine: false, text: try await NoteAI.summary(of: all)))
        }
    }

    private func makeQuiz() async {
        await run(String(localized: "Preparo le domande…")) {
            let t = await model.pageText().all
            messages.append(Message(mine: true, text: String(localized: "Fammi un quiz sulla pagina \(model.pageIndex + 1)")))
            quiz = try await NoteAI.quiz(from: t)
            if quiz.isEmpty { error = String(localized: "Non sono riuscito a fare domande su questa pagina.") }
        }
    }

    private func ask() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, busy == nil else { return }
        input = ""
        messages.append(Message(mine: true, text: q))
        await run(String(localized: "Cerco nei tuoi appunti…")) {
            let notes = NoteAI.context(await notebookSources(), question: q)
            guard !notes.isEmpty else { throw NoteAI.Failure.empty }
            messages.append(Message(mine: false, text: try await chat.ask(q, notes: notes)))
        }
    }
}
