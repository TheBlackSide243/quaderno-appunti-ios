import SwiftUI

/// The palette that opens next to the tip of the Apple Pencil Pro when it is squeezed: the
/// writing tools, the colours of the tool in use, undo and redo.
struct QuickPalette: View {
    let model: EditorModel

    private static let tools: [Tool] = [.pen, .pencil, .highlighter, .eraser, .lasso, .shape]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Self.tools) { t in
                    Button {
                        model.select(t)
                    } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 18, weight: model.tool == t ? .semibold : .regular))
                            .foregroundStyle(model.tool == t ? Theme.accent : Theme.text)
                            .frame(width: 40, height: 38)
                            .background(model.tool == t ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.label)
                }
            }
            if model.tool.inks || model.style(of: model.tool) != nil {
                HStack(spacing: 6) {
                    ForEach(model.tool.presets, id: \.self) { hex in
                        let on = model.color(of: model.tool).uppercased() == hex.uppercased()
                        Button { model.setColor(hex) } label: {
                            Circle().fill(Color(uiColor: UIColor(hex: hex)))
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(on ? Theme.accent : Theme.line, lineWidth: on ? 2.5 : 1).padding(-3))
                                .frame(width: 36, height: 34)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(PenStyle.options(for: model.tool)) { s in
                        let on = model.style(of: model.tool) == s
                        Button { model.setStyle(s) } label: {
                            Image(systemName: s.icon).font(.system(size: 15))
                                .foregroundStyle(on ? Theme.accent : Theme.sub)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.label)
                    }
                }
            }
            HStack(spacing: 4) {
                Button { model.canvas.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 32)
                }
                .disabled(!model.canUndo)
                .accessibilityLabel("Annulla")
                Button { model.canvas.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 32)
                }
                .disabled(!model.canRedo)
                .accessibilityLabel("Ripeti")
                Spacer(minLength: 8)
                Button { model.palette = nil } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Chiudi")
            }
            .foregroundStyle(Theme.accent)
        }
        .padding(10)
        .frame(width: 270)
        .background(Theme.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

/// Puts the quick palette next to where the Pencil was squeezed, inside the page view.
struct QuickPaletteLayer: View {
    let model: EditorModel

    var body: some View {
        GeometryReader { g in
            if let p = model.palette {
                ZStack(alignment: .topLeading) {
                    // a tap elsewhere closes it
                    Color.black.opacity(0.001)
                        .onTapGesture { model.palette = nil }
                    QuickPalette(model: model)
                        .position(x: min(max(150, p.x + 150), g.size.width - 145),
                                  y: min(max(90, p.y - 70), g.size.height - 90))
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(model.palette != nil)
        .animation(.easeOut(duration: 0.15), value: model.palette)
    }
}
