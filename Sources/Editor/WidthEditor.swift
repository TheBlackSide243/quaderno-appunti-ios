import SwiftUI

/// One of the three sizes of a tool.
struct WidthSlot: Hashable {
    let tool: Tool
    let index: Int

    /// How thick a size is drawn in the bar (thin sizes still show, thick ones stay in the button).
    static func barHeight(_ tool: Tool, _ w: CGFloat) -> CGFloat { 1.5 + sqrt(tool.widthFraction(w)) * 10 }

    /// A size as written for people: "1,5 pt".
    static func text(_ w: CGFloat) -> String {
        let n = Double(w).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(n) pt")
    }
}

/// The small panel that changes one of the three sizes of a tool: a slider from the thinnest to the
/// thickest and the usual sizes ready to tap, with a line drawn as thick as the size chosen.
struct WidthEditor: View {
    let model: EditorModel
    let slot: WidthSlot

    private var tool: Tool { slot.tool }

    var body: some View {
        let w = model.widths(of: tool)[slot.index]
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "Spessore \(slot.index + 1)")).font(.headline).foregroundStyle(Theme.text)
                Spacer()
                Text(WidthSlot.text(w)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.sub)
            }
            preview(w)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            Slider(value: Binding(get: { Double(w) }, set: { model.setWidth(slot.index, of: tool, to: CGFloat($0)) }),
                   in: Double(tool.widthRange.lowerBound)...Double(tool.widthRange.upperBound), step: 0.5)
                .tint(Theme.accent)
                .accessibilityLabel(String(localized: "Spessore"))
                .accessibilityValue(WidthSlot.text(w))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(tool.widthSteps, id: \.self) { s in
                    let on = abs(s - w) < 0.01
                    Button { model.setWidth(slot.index, of: tool, to: s) } label: {
                        Text(Double(s).formatted(.number.precision(.fractionLength(0...1))))
                            .font(.subheadline.weight(on ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? Theme.accent : Theme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(WidthSlot.text(s))
                }
            }
            Button(String(localized: "Ripristina gli spessori")) { model.resetWidths(tool) }
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.panel)
    }

    /// A wave drawn as thick as the size; the eraser shows the circle it rubs out with.
    @ViewBuilder private func preview(_ w: CGFloat) -> some View {
        if tool == .eraser {
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5)
                .frame(width: min(w, 60), height: min(w, 60))
        } else {
            let color = Color(uiColor: UIColor(hex: model.color(of: tool)))
            let factor = (tool == .pen || tool == .pencil) ? (model.style(of: tool)?.widthFactor ?? 1) : 1
            Canvas { ctx, size in
                var p = Path()
                let mid = size.height / 2, amp = min(14, size.height / 4)
                p.move(to: CGPoint(x: 24, y: mid))
                p.addCurve(to: CGPoint(x: size.width - 24, y: mid),
                           control1: CGPoint(x: size.width * 0.35, y: mid - amp * 2),
                           control2: CGPoint(x: size.width * 0.65, y: mid + amp * 2))
                let style = StrokeStyle(lineWidth: min(w * factor, 56), lineCap: tool == .highlighter ? .butt : .round, lineJoin: .round)
                ctx.stroke(p, with: .color(tool == .highlighter ? color.opacity(0.6) : color), style: style)
            }
        }
    }
}
