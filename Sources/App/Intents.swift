import AppIntents
import Foundation

/// What a shortcut asked the app to do; the shelf carries it out when it is on screen.
enum IntentAction: Equatable {
    case open(UUID)
    case last
    case new(String?)
    case review(UUID?)
}

@MainActor
@Observable
final class IntentInbox {
    static let shared = IntentInbox()
    var pending: IntentAction?
    private init() {}
}

/// A notebook, as Shortcuts and Siri see it.
struct NotebookEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quaderno")
    static var defaultQuery = NotebookQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// The notebooks on the shelf, read from their files (Shortcuts may ask before the shelf is loaded).
enum NotebookCatalog {
    static func all() -> [Notebook] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Store.root, includingPropertiesForKeys: nil)) ?? []
        var list: [Notebook] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("notebook.json")),
                  let nb = try? Store.decoder.decode(Notebook.self, from: data), nb.deletedAt == nil else { continue }
            list.append(nb)
        }
        return list.sorted { $0.modified > $1.modified }
    }

    static func entities() -> [NotebookEntity] { all().map { NotebookEntity(id: $0.id, title: $0.title) } }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "it_IT"))
    }
}

struct NotebookQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [NotebookEntity] {
        NotebookCatalog.entities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [NotebookEntity] {
        let q = NotebookCatalog.fold(string.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return NotebookCatalog.entities() }
        return NotebookCatalog.entities().filter { NotebookCatalog.fold($0.title).contains(q) }
    }

    func suggestedEntities() async throws -> [NotebookEntity] {
        Array(NotebookCatalog.entities().prefix(30))
    }
}

struct OpenNotebookIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri un quaderno"
    static var description = IntentDescription("Apre un quaderno di Quaderno Appunti.")
    static var openAppWhenRun = true

    @Parameter(title: "Quaderno")
    var notebook: NotebookEntity

    init() {}
    init(notebook: NotebookEntity) { self.notebook = notebook }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pending = .open(notebook.id)
        return .result()
    }
}

struct OpenLastNotebookIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri l'ultimo quaderno"
    static var description = IntentDescription("Riapre il quaderno su cui hai scritto per ultimo.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pending = .last
        return .result()
    }
}

struct NewNotebookIntent: AppIntent {
    static var title: LocalizedStringResource = "Nuovo quaderno"
    static var description = IntentDescription("Crea un quaderno a righe e lo apre.")
    static var openAppWhenRun = true

    @Parameter(title: "Titolo")
    var name: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pending = .new(name)
        return .result()
    }
}

struct ReviewCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Ripassa le flashcard"
    static var description = IntentDescription("Apre il ripasso delle flashcard: di un quaderno, o di quello con più carte da ripassare oggi.")
    static var openAppWhenRun = true

    @Parameter(title: "Quaderno")
    var notebook: NotebookEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pending = .review(notebook?.id)
        return .result()
    }
}

/// Ready-made shortcuts: they show up in Shortcuts, in Spotlight, for Siri and for the Action button.
struct AppuntiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewNotebookIntent(),
                    phrases: ["Nuovo quaderno in \(.applicationName)", "Crea un quaderno in \(.applicationName)"],
                    shortTitle: "Nuovo quaderno", systemImageName: "plus.rectangle.on.rectangle")
        AppShortcut(intent: OpenLastNotebookIntent(),
                    phrases: ["Apri l'ultimo quaderno in \(.applicationName)", "Riprendi a scrivere in \(.applicationName)"],
                    shortTitle: "Ultimo quaderno", systemImageName: "book")
        AppShortcut(intent: OpenNotebookIntent(),
                    phrases: ["Apri \(\.$notebook) in \(.applicationName)"],
                    shortTitle: "Apri un quaderno", systemImageName: "book.closed")
        AppShortcut(intent: ReviewCardsIntent(),
                    phrases: ["Ripassa le flashcard in \(.applicationName)"],
                    shortTitle: "Ripassa le flashcard", systemImageName: "rectangle.on.rectangle.angled")
    }
}
