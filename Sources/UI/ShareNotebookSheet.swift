import SwiftUI
import UniformTypeIdentifiers

/// Sharing a notebook with other people through a folder shared in iCloud Drive, or opening one
/// that someone shared.
struct ShareNotebookSheet: View {
    enum Mode: Identifiable {
        case share(Notebook)
        case join

        var id: String {
            switch self {
            case .share(let nb): nb.id.uuidString
            case .join: "join"
            }
        }
    }

    let mode: Mode
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var busy = false
    @State private var done: String?
    @State private var error: String?

    private var sharing: Bool { if case .share = mode { true } else { false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "person.2.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                    if sharing {
                        step(1, String(localized: "Nell'app File, in iCloud Drive, crea una cartella (per esempio «Quaderno con Marco»)."))
                        step(2, String(localized: "Tienila premuta → Condividi → Collabora, e invita le persone con cui scrivere."))
                        step(3, String(localized: "Torna qui e scegli quella cartella: il quaderno viene copiato lì."))
                        step(4, String(localized: "Chi riceve l'invito lo accetta, poi in Quaderno Appunti sceglie + → «Apri un quaderno condiviso» e la stessa cartella."))
                    } else {
                        step(1, String(localized: "Accetta l'invito alla cartella condivisa che ti hanno mandato: la trovi in File → iCloud Drive."))
                        step(2, String(localized: "Scegli qui quella cartella: i quaderni condivisi lì compaiono nello scaffale."))
                    }
                    Text("Mentre il quaderno è aperto le modifiche vanno e vengono ogni pochi secondi, e quando torni allo scaffale. Se due persone scrivono nella stessa pagina nello stesso momento, resta l'ultima salvata. Funziona anche con l'app installata con Feather o Sideloadly.")
                        .font(.footnote).foregroundStyle(Theme.sub)
                    if let done {
                        Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline.weight(.semibold))
                    }
                    if let e = error ?? SharedNotebooks.shared.error {
                        Text(e).font(.footnote).foregroundStyle(Theme.bad)
                    }
                    Button { picking = true } label: {
                        HStack {
                            if busy { ProgressView().tint(Theme.bg) }
                            Text(sharing ? String(localized: "Scegli la cartella condivisa") : String(localized: "Scegli la cartella"))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
                    .disabled(busy || done != nil)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle(sharing ? String(localized: "Condividi il quaderno") : String(localized: "Quaderno condiviso"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? String(localized: "Annulla") : String(localized: "Fine")) { dismiss() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result else { return }
                Task { await chosen(url) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.bg)
                .frame(width: 26, height: 26).background(Theme.accent, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(Theme.text)
        }
    }

    private func chosen(_ url: URL) async {
        busy = true
        defer { busy = false }
        error = nil
        switch mode {
        case .share(let nb):
            let current = library.notebook(nb.id) ?? nb
            await SharedNotebooks.shared.share(current, in: url, library: library)
            if SharedNotebooks.shared.error == nil {
                done = String(localized: "«\(nb.title)» è condiviso nella cartella «\(url.lastPathComponent)».")
            }
        case .join:
            let n = await SharedNotebooks.shared.join(url, library: library)
            if n > 0 {
                done = n == 1 ? String(localized: "Un quaderno condiviso è nello scaffale.") : String(localized: "\(n) quaderni condivisi sono nello scaffale.")
            }
        }
    }
}
