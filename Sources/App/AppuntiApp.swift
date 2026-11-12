import SwiftUI

@main
struct AppuntiApp: App {
    @State private var library = Library()
    @State private var backup = CloudBackup()

    init() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.bg)
        nav.shadowColor = UIColor(Theme.line)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(backup)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        // iPad: a notebook in a window of its own, to keep two side by side
        WindowGroup(id: "notebook", for: UUID.self) { $id in
            NotebookWindow(id: id)
                .environment(library)
                .environment(backup)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

/// A window with one notebook open.
struct NotebookWindow: View {
    let id: UUID?
    @Environment(Library.self) private var library
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let id, let nb = library.notebook(id) {
            if nb.isText {
                TextDocView(library: library, notebook: nb, onClose: { dismissWindow() })
            } else {
                EditorView(library: library, notebook: nb, page: nil, onClose: { dismissWindow() })
            }
        } else {
            ContentUnavailableView("Quaderno non trovato", systemImage: "book.closed",
                                   description: Text("Forse è stato eliminato. Chiudi questa finestra."))
                .background(Theme.bg)
        }
    }
}

/// Which notebook to open, and at which page.
struct OpenRequest: Identifiable, Hashable {
    let id = UUID()
    let notebookID: UUID
    var page: Int?
}
