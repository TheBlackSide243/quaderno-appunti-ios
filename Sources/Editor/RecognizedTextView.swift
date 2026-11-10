import SwiftUI

/// The text of the current page: handwriting read on the device, typed boxes and PDF text, to
/// select, copy or share. Typed and PDF text show at once; the handwriting follows when read.
struct RecognizedTextView: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    @State private var text = PageText()
    @State private var reading = true
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if reading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Leggo la scrittura a mano…").font(.subheadline).foregroundStyle(Theme.sub)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, text.all.isEmpty ? 40 : 4)
                    } else if text.all.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.viewfinder").font(.system(size: 36)).foregroundStyle(Theme.accent)
                            Text("In questa pagina non ho trovato testo.").font(.headline).foregroundStyle(Theme.text)
                            Text("La scrittura a mano viene letta meglio se è ordinata e abbastanza grande.")
                                .font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    section("Scrittura a mano", text.ink)
                    section("Testo digitato", text.typed)
                    section("Dal PDF", text.pdf)
                }
                .padding(16)
            }
            .navigationTitle("Testo della pagina \(model.pageIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !text.all.isEmpty {
                        ShareLink(item: text.all) { Image(systemName: "square.and.arrow.up") }
                        Button {
                            UIPasteboard.general.string = text.all
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel("Copia tutto")
                    }
                }
            }
            .screen()
        }
        .task {
            text = model.quickPageText()
            text = await model.pageText()
            reading = false
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section(_ title: String, _ content: String) -> some View {
        if !content.isEmpty {
            Panel(title) {
                Text(content)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
