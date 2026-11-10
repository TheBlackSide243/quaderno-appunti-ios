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
    }
}

/// Which notebook to open, and at which page.
struct OpenRequest: Identifiable, Hashable {
    let id = UUID()
    let notebookID: UUID
    var page: Int?
}
