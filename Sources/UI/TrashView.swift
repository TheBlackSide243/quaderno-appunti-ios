import SwiftUI

/// Deleted notebooks: they wait here for 30 days and can be put back or removed for good.
struct TrashView: View {
    @Environment(Library.self) private var library
    @State private var confirmEmpty = false
    @State private var confirmDelete: Notebook?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ErrorBanner(error: Binding(get: { library.error }, set: { library.error = $0 }))
                if library.trashed.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "trash").font(.system(size: 38)).foregroundStyle(Theme.accent)
                        Text("Il cestino è vuoto").font(.headline).foregroundStyle(Theme.text)
                        Text("I quaderni che elimini restano qui \(Store.trashDays) giorni prima di essere cancellati del tutto.")
                            .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    Text("I quaderni restano qui \(Store.trashDays) giorni, poi vengono cancellati del tutto.")
                        .font(.footnote).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 0) {
                        ForEach(library.trashed) { nb in
                            HStack(spacing: 12) {
                                Group {
                                    if let c = nb.cover {
                                        CoverArt(color: Covers.color(c), style: nb.coverStyle ?? .plain)
                                    } else {
                                        RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: nb.paper.uiColor))
                                            .overlay(Image(systemName: nb.hasPDF ? "doc.richtext" : "doc.text").font(.caption).foregroundStyle(.gray))
                                    }
                                }
                                .frame(width: 34, height: 45)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(nb.title).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text("\(nb.pages.count) pag. · " + daysText(nb))
                                        .font(.caption).foregroundStyle(library.daysLeft(nb) <= 3 ? Theme.bad : Theme.sub)
                                }
                                Spacer(minLength: 8)
                                Button("Ripristina") { library.restore(nb.id) }
                                    .buttonStyle(SecondaryButtonStyle())
                                Button { confirmDelete = nb } label: {
                                    Image(systemName: "trash").foregroundStyle(Theme.bad).frame(width: 36, height: 36)
                                }
                                .accessibilityLabel("Elimina del tutto")
                            }
                            .padding(.vertical, 10)
                            if nb.id != library.trashed.last?.id { Divider().overlay(Theme.line) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
                }
            }
            .padding(16)
        }
        .navigationTitle("Cestino")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !library.trashed.isEmpty {
                    Button("Svuota", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .screen()
        .confirmationDialog(emptyQuestion, isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Svuota il cestino", role: .destructive) { library.emptyTrash() }
        }
        .confirmationDialog("Eliminare del tutto «\(confirmDelete?.title ?? "")»? Non si potrà recuperare.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina del tutto", role: .destructive) {
                if let nb = confirmDelete { library.deleteForever(nb.id) }
                confirmDelete = nil
            }
        }
    }

    private var emptyQuestion: String {
        let n = library.trashed.count
        let what = n == 1 ? String(localized: "Il quaderno verrà cancellato") : String(localized: "I \(n) quaderni verranno cancellati")
        return String(localized: "Svuotare il cestino? \(what) del tutto e non si potrà recuperare.")
    }

    private func daysText(_ nb: Notebook) -> String {
        let d = library.daysLeft(nb)
        return d == 0 ? String(localized: "ultimo giorno") : (d == 1 ? String(localized: "ancora 1 giorno") : String(localized: "ancora \(d) giorni"))
    }
}
