import SwiftUI

/// The earlier versions of the page in view: a tap shows one big, and it can be put back.
struct PageHistoryView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [PageHistory.Version] = []
    @State private var chosen: PageHistory.Version?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Mentre scrivi, l'app tiene una copia di com'era la pagina al massimo ogni dieci minuti (le ultime 30). Restano solo su questo dispositivo.")
                        .font(.caption).foregroundStyle(Theme.sub)
                    if versions.isEmpty {
                        Text("Questa pagina non ha ancora versioni precedenti.")
                            .font(.subheadline).foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(versions) { v in
                                Button { chosen = v } label: {
                                    VStack(spacing: 6) {
                                        VersionThumb(version: v, notebook: model.notebook)
                                        Text(v.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                                        Text(v.date.formatted(.relative(presentation: .named)))
                                            .font(.caption2).foregroundStyle(Theme.sub)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Versioni precedenti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .screen()
        }
        .task {
            model.canvas.saveNow()
            versions = PageHistory.versions(model.notebook.id, model.page.id)
        }
        .sheet(item: $chosen) { v in
            NavigationStack {
                VStack(spacing: 16) {
                    VersionThumb(version: v, notebook: model.notebook, width: 900)
                        .padding(.horizontal, 20)
                    Button {
                        model.restoreVersion(v)
                        chosen = nil
                        dismiss()
                    } label: {
                        Label("Ripristina questa versione", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 20)
                    Text("La pagina com'è adesso resta tra le versioni: puoi tornarci quando vuoi.")
                        .font(.caption).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle(v.date.formatted(.dateTime.day().month().hour().minute()))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { chosen = nil } } }
                .screen()
            }
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
    }
}

/// A version of a page, drawn in the background.
struct VersionThumb: View {
    let version: PageHistory.Version
    let notebook: Notebook
    var width: CGFloat = 320
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color(uiColor: notebook.paper.uiColor).aspectRatio(0.71, contentMode: .fit)
                    .overlay(ProgressView())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .task(id: version.id) {
            let v = version, nb = notebook, w = width
            image = await Task.detached(priority: .userInitiated) { PageHistory.preview(v, nb, width: w) }.value
        }
    }
}
