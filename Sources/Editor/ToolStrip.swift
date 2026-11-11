import SwiftUI
import UIKit

/// The bar under the title: tools, then thickness and colours of the chosen tool.
struct ToolStrip: View {
    let model: EditorModel
    let onPhoto: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { t in
                    toolButton(t.icon, label: t.label, on: model.tool == t) { model.select(t) }
                }
                separator
                toolButton("textformat", label: String(localized: "Testo"), on: false) { model.addText() }
                toolButton("photo", label: String(localized: "Foto"), on: false) { onPhoto() }
                toolButton("ruler", label: String(localized: "Righello"), on: model.ruler) { model.toggleRuler() }
                toolButton("waveform", label: String(localized: "Registrazione audio"), on: model.audio.panel || model.audio.recording) {
                    model.audio.panel.toggle()
                }
                if model.tool == .shape {
                    separator
                    ForEach(ShapeKind.allCases) { k in
                        toolButton(k.icon, label: k.label, on: model.shapeKind == k) { model.setShape(k) }
                    }
                }
                if !model.tool.widths.isEmpty {
                    separator
                    // The tool and its widths are read once here and passed down: SwiftUI can update
                    // these buttons once more after the tool changed (to the lasso, which has no
                    // widths), and reading model.tool.widths[i] inside them then crashed the app.
                    let tool = model.tool
                    ForEach(Array(tool.widths.enumerated()), id: \.offset) { i, w in
                        widthButton(tool, i, w)
                    }
                    .id(tool)
                }
                if model.tool.inks {
                    separator
                    ForEach(model.tool.presets, id: \.self) { hex in
                        swatch(hex)
                    }
                    ColorPicker(String(localized: "Colore"), selection: Binding(
                        get: { Color(uiColor: UIColor(hex: model.color(of: model.tool))) },
                        set: { model.setColor(UIColor($0).hexString) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 52)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var separator: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 26).padding(.horizontal, 6)
    }

    private func toolButton(_ icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.text)
                .frame(width: 42, height: 40)
                .background(on ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func widthButton(_ tool: Tool, _ i: Int, _ w: CGFloat) -> some View {
        let on = model.widthIndex(of: tool) == i
        let eraser = tool == .eraser
        return Button { model.setWidth(i) } label: {
            Group {
                if eraser && w == 0 {
                    Image(systemName: "scribble.variable").font(.system(size: 15, weight: .semibold))
                } else if eraser {
                    Circle().stroke(Theme.text, lineWidth: 1.5).frame(width: i == 1 ? 10 : 20, height: i == 1 ? 10 : 20)
                } else {
                    Capsule().fill(Theme.text).frame(width: 24, height: CGFloat(i == 0 ? 2 : (i == 1 ? 4 : 7)))
                }
            }
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: 36)
            .background(on ? Theme.input : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? Theme.line : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(eraser ? (w == 0 ? String(localized: "Cancella tratto intero") : (i == 1 ? String(localized: "Gomma piccola") : String(localized: "Gomma grande"))) : String(localized: "Spessore \(i + 1)"))
    }

    private func swatch(_ hex: String) -> some View {
        let on = model.color(of: model.tool).uppercased() == hex.uppercased()
        return Button { model.setColor(hex) } label: {
            Circle().fill(Color(uiColor: UIColor(hex: hex)))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(on ? Theme.accent : Theme.line, lineWidth: on ? 2.5 : 1).padding(-3))
                .frame(width: 38, height: 40)
        }
        .buttonStyle(.plain)
    }
}

extension UIColor {
    /// RRGGBB of the colour as seen in light mode.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "1C1C20" }
        func v(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", v(r), v(g), v(b))
    }
}
