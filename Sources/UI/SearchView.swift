import SwiftUI

/// Searches handwriting, typed text, PDF text and titles of every notebook.
struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onOpen: (OpenRequest) -> Void

    @State private var query: String

    init(initialQuery: String = "", onOpen: @escaping (OpenRequest) -> Void) {
        self.onOpen = onOpen
        _query = State(initialValue: initialQuery)
    }
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Label {
                            Text("Cerca nei titoli, nella scrittura a mano, nei testi e nei PDF. La scrittura viene letta sul telefono qualche secondo dopo che hai finito una pagina.")
                                .font(.footnote).foregroundStyle(Theme.sub)
                        } icon: {
                            Image(systemName: "text.viewfinder").foregroundStyle(Theme.accent)
                        }
                    }
                    .listRowBackground(Theme.panel)
                } else if hits.isEmpty && !searching {
                    Text("Nessun risultato per «\(query)».").foregroundStyle(Theme.sub).listRowBackground(Theme.panel)
                }
                ForEach(groups, id: \.0) { id, list in
                    Section(library.notebook(id)?.title ?? "Quaderno") {
                        ForEach(list) { hit in
                            Button {
                                onOpen(OpenRequest(notebookID: hit.notebookID, page: hit.pageIndex))
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    if let p = hit.pageIndex {
                                        Text("p. \(p + 1)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(Theme.accent)
                                            .frame(width: 40, alignment: .leading)
                                    } else {
                                        Image(systemName: "book.closed").foregroundStyle(Theme.accent).frame(width: 40, alignment: .leading)
                                    }
                                    Text(highlight(hit.snippet)).font(.subheadline).foregroundStyle(Theme.text).lineLimit(3)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca negli appunti")
            .navigationTitle("Cerca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .screen()
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                searching = true
                let r = await Indexer.shared.search(query, in: library.notebooks)
                guard !Task.isCancelled else { return }
                hits = r
                searching = false
            }
        }
        .preferredColorScheme(.dark)
    }

    private var groups: [(UUID, [SearchHit])] {
        var order: [UUID] = []
        var map: [UUID: [SearchHit]] = [:]
        for h in hits {
            if map[h.notebookID] == nil { order.append(h.notebookID) }
            map[h.notebookID, default: []].append(h)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let q = query.trimmingCharacters(in: .whitespaces)
        if let r = a.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].foregroundColor = Theme.accent
            a[r].font = .subheadline.bold()
        }
        return a
    }
}
