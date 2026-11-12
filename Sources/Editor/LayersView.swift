import SwiftUI

/// The layers of the page: the one drawn on, which are shown, their order and names.
struct LayersView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: InkLayer?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // the top layer first, as they lie on the page
                    ForEach(Array(model.layers.enumerated().reversed()), id: \.element.id) { i, l in
                        row(l, index: i)
                    }
                } footer: {
                    Text("Scrivi sul livello evidenziato. Testi, foto e nastri stanno sempre sopra i livelli.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Livelli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.addLayer() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Nuovo livello")
                }
            }
            .alert("Rinomina livello", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nome", text: $newName)
                Button("Annulla", role: .cancel) { renaming = nil }
                Button("Salva") {
                    if let r = renaming { model.renameLayer(r.id, newName) }
                    renaming = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ l: InkLayer, index i: Int) -> some View {
        let active = l.id == model.layerID
        return HStack(spacing: 12) {
            Button { model.toggleLayerHidden(l.id) } label: {
                Image(systemName: l.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(active ? Theme.sub.opacity(0.5) : (l.isHidden ? Theme.sub : Theme.accent))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(active)
            .accessibilityLabel(l.isHidden ? String(localized: "Mostra il livello") : String(localized: "Nascondi il livello"))
            Button { model.selectLayer(l.id) } label: {
                HStack {
                    Text(l.name)
                        .font(.body.weight(active ? .semibold : .regular))
                        .foregroundStyle(l.isHidden ? Theme.sub : Theme.text)
                    Spacer()
                    if active { Image(systemName: "pencil.tip").foregroundStyle(Theme.accent) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(active ? Theme.accent.opacity(0.14) : Theme.panel)
        .swipeActions {
            if model.layers.count > 1 {
                Button(role: .destructive) { model.deleteLayer(l.id) } label: { Label("Elimina", systemImage: "trash") }
            }
            Button { newName = l.name; renaming = l } label: { Label("Rinomina", systemImage: "pencil") }
                .tint(.gray)
        }
        .contextMenu {
            Button { newName = l.name; renaming = l } label: { Label("Rinomina", systemImage: "pencil") }
            if i + 1 < model.layers.count {
                Button { model.moveLayer(l.id, by: 1) } label: { Label("Sposta su", systemImage: "arrow.up") }
            }
            if i > 0 {
                Button { model.moveLayer(l.id, by: -1) } label: { Label("Sposta giù", systemImage: "arrow.down") }
            }
            if model.layers.count > 1 {
                Button(role: .destructive) { model.deleteLayer(l.id) } label: { Label("Elimina", systemImage: "trash") }
            }
        }
    }
}
