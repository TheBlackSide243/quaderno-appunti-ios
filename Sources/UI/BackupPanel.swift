import SwiftUI
import UniformTypeIdentifiers

/// Makes a copy of the whole library in one file and puts one back.
@MainActor
@Observable
final class LibraryCopy {
    private(set) var working = false
    var message: String?
    var error: String?
    /// A copy just made, to save in Files or send.
    var made: ShareFile?
    /// A copy picked to restore, waiting for the user's yes.
    var pending: (url: URL, manifest: LibraryBackup.Manifest?)?

    func make() {
        guard !working else { return }
        working = true
        message = nil
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try LibraryBackup.export() }
            await MainActor.run {
                self.working = false
                switch result {
                case .success(let url):
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    self.message = String(localized: "Copia pronta (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))): salvala in File o su un computer.")
                    self.made = ShareFile(url: url)
                case .failure(let e):
                    self.error = String(localized: "Copia non riuscita: \(e.localizedDescription)")
                }
            }
        }
    }

    /// A file was picked: read what it says before asking.
    func picked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let m = LibraryBackup.manifest(url) else {
            // an archive without the description may still hold notebooks
            pending = (url, nil)
            return
        }
        pending = (url, m)
    }

    func restore(_ url: URL, library: Library) {
        guard !working else { return }
        working = true
        message = nil
        error = nil
        let tombs = Tombstones.load()
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            let result = Result { try LibraryBackup.restore(url, tombstones: tombs) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                self.working = false
                switch result {
                case .success(let s):
                    library.load()
                    StickerStore.shared.reload()
                    PaperStore.shared.reload()
                    StudyLog.shared.reload()
                    let back = library.notebooks.filter { s.restored.contains($0.id) }
                    for nb in back {
                        Tombstones.remove(nb.id)
                        library.refreshThumb(nb.id)
                        Spotlight.shared.schedule(nb)
                    }
                    Indexer.shared.catchUp(back)
                    self.message = Self.describe(s)
                case .failure(let e):
                    self.error = (e as? LocalizedError)?.errorDescription ?? String(localized: "Ripristino non riuscito: \(e.localizedDescription)")
                }
            }
        }
    }

    static func describe(_ s: LibraryBackup.Summary) -> String {
        if s.restored.isEmpty {
            return s.skipped > 0 ? String(localized: "Non manca nessun quaderno: quelli della copia ci sono già tutti.") : String(localized: "Nella copia non ci sono quaderni.")
        }
        var text = String(localized: "Quaderni ripristinati: \(s.restored.count).")
        if s.skipped > 0 { text += " " + String(localized: "Già presenti, lasciati come sono: \(s.skipped).") }
        return text
    }
}

struct BackupPanel: View {
    @Environment(Library.self) private var library
    @State private var copy = LibraryCopy()
    @State private var picking = false

    var body: some View {
        Panel("Copia della libreria") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "archivebox.fill").font(.title2).foregroundStyle(Theme.accent)
                Text("Un solo file con tutti i quaderni, le cartelle, gli adesivi, le carte e le statistiche di studio. Tienilo in File, su iCloud Drive o su un computer: se cambi telefono o reinstalli l'app, da qui rimetti tutto com'era.")
                    .font(.footnote).foregroundStyle(Theme.sub)
            }
            Button { copy.make() } label: {
                Label(copy.working ? String(localized: "Preparo la copia…") : String(localized: "Crea una copia"), systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(copy.working || library.notebooks.isEmpty)
            Button { picking = true } label: {
                Label("Ripristina da una copia…", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(copy.working)
            if copy.working { ProgressView().frame(maxWidth: .infinity) }
            if let m = copy.message {
                Label(m, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
            }
            Text("Il ripristino non sostituisce niente: i quaderni che hai già restano come sono e tornano solo quelli che mancano.")
                .font(.caption).foregroundStyle(Theme.sub)
            ErrorBanner(error: $copy.error)
        }
        .sheet(item: $copy.made) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
            if case let .success(url) = result { copy.picked(url) }
        }
        .confirmationDialog(title, isPresented: Binding(get: { copy.pending != nil }, set: { if !$0 { copy.pending = nil } }),
                            titleVisibility: .visible) {
            Button("Ripristina") {
                if let p = copy.pending { copy.restore(p.url, library: library) }
                copy.pending = nil
            }
            Button("Annulla", role: .cancel) { copy.pending = nil }
        } message: {
            Text("I quaderni che hai già restano come sono; tornano solo quelli che mancano.")
        }
    }

    private var title: String {
        guard let p = copy.pending else { return "" }
        guard let m = p.manifest else { return String(localized: "Ripristinare i quaderni da questo archivio?") }
        let when = m.created.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Ripristinare la copia del \(when) con \(m.notebooks) quaderni?")
    }
}
