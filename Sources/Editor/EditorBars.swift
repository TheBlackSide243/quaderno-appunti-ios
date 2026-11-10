import SwiftUI
import UIKit

/// Controls for the selected text box or picture.
struct ItemBar: View {
    let item: PageItem
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            if item.kind == .text {
                Button { model.update { $0.fontSize = max(8, $0.fontSize - 2) } } label: { Image(systemName: "textformat.size.smaller") }
                Text("\(Int(item.fontSize))").font(.footnote.monospacedDigit()).foregroundStyle(Theme.sub).frame(minWidth: 22)
                Button { model.update { $0.fontSize = min(120, $0.fontSize + 2) } } label: { Image(systemName: "textformat.size.larger") }
                Button { model.update { $0.bold.toggle() } } label: { Image(systemName: "bold") }
                    .foregroundStyle(item.bold ? Theme.accent : Theme.text)
                Divider().frame(height: 22)
                ForEach(TextColors.all, id: \.self) { hex in
                    Button { model.update { $0.color = hex } } label: {
                        Circle().fill(Color(uiColor: UIColor(hex: hex)))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(item.color == hex ? Theme.accent : Theme.line, lineWidth: item.color == hex ? 2.5 : 1))
                    }
                }
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.sub)
                Text("Trascina per spostare, pizzica o usa l'angolo per ridimensionare")
                    .font(.caption).foregroundStyle(Theme.sub).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button { model.canvas.bringSelectedToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }
            Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash").foregroundStyle(Theme.bad) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .frame(maxWidth: 620)
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
