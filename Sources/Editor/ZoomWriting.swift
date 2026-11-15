import PencilKit
import SwiftUI
import UIKit

/// The zoom window: a strip at the bottom of the screen where you write big. Each stroke goes,
/// small, into the box shown on the page; when the writing reaches the right end of the strip the
/// box moves on by itself, and at the end of the line it goes to the next one.
@MainActor
final class ZoomPadView: UIView, PKCanvasViewDelegate {
    let pad = PKCanvasView()
    private let preview = UIImageView()
    private let hint = UILabel()
    weak var page: PageCanvasView?
    /// How much bigger the strip is than the box on the page.
    var zoom: CGFloat = 2.5 { didSet { if zoom != oldValue { setNeedsLayout() } } }
    /// The box on the page, in page points.
    var box: CGRect = .zero
    /// The strip got another size: the box must follow (width, height in page points).
    var onSize: ((CGSize) -> Void)?
    /// Strokes were moved onto the page; the value is how far right they ended (0…1 of the strip).
    var onCommit: ((CGFloat) -> Void)?
    private var clearing = false
    private var lastSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.cornerRadius = 14
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor(Theme.line).cgColor
        preview.contentMode = .scaleToFill
        addSubview(preview)
        pad.backgroundColor = .clear
        pad.isOpaque = false
        pad.isScrollEnabled = false
        pad.contentInsetAdjustmentBehavior = .never
        pad.delegate = self
        addSubview(pad)
        hint.text = String(localized: "Scegli la penna, la matita o l'evidenziatore per scrivere qui")
        hint.font = .systemFont(ofSize: 14, weight: .semibold)
        hint.textColor = UIColor(white: 0.35, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.isHidden = true
        addSubview(hint)
        // a line to write on, like on a guide sheet
        let base = CAShapeLayer()
        base.name = "base"
        base.strokeColor = UIColor(Theme.accent).withAlphaComponent(0.5).cgColor
        base.lineDashPattern = [6, 6]
        base.lineWidth = 1
        layer.addSublayer(base)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        pad.frame = bounds
        hint.frame = bounds.insetBy(dx: 20, dy: 10)
        if let base = layer.sublayers?.first(where: { $0.name == "base" }) as? CAShapeLayer {
            base.frame = bounds
            let y = bounds.height * 0.72
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: bounds.width, y: y))
            base.path = p.cgPath
        }
        let size = CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        if bounds.width > 40, size != lastSize {
            lastSize = size
            onSize?(size)
        }
    }

    /// The pen of the page, made as much bigger as the strip is.
    func syncTool() {
        guard let page else { return }
        pad.drawingPolicy = page.canvas.drawingPolicy
        pad.overrideUserInterfaceStyle = page.canvas.overrideUserInterfaceStyle
        if let ink = page.canvas.tool as? PKInkingTool {
            pad.tool = PKInkingTool(ink.inkType, color: ink.color, width: ink.width * zoom)
            pad.isUserInteractionEnabled = true
            hint.isHidden = true
        } else {
            pad.isUserInteractionEnabled = false
            hint.isHidden = false
        }
    }

    /// Draws behind the strip what is on the page inside the box.
    func refresh() {
        guard let page, box.width > 1, bounds.width > 1 else { return }
        let scale = (window?.screen.scale ?? 2) * bounds.width / box.width
        preview.image = page.snapshot(of: box, scale: min(scale, 8))
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !clearing, !pad.drawing.strokes.isEmpty else { return }
        // not inside PencilKit's own change
        DispatchQueue.main.async { [weak self] in self?.commit() }
    }

    private func commit() {
        guard let page, !pad.drawing.strokes.isEmpty, bounds.width > 1 else { return }
        let strokes = pad.drawing.strokes
        let k = box.width / bounds.width
        let moved = strokes.map { Self.scaled($0, by: k, to: box.origin) }
        page.appendStrokes(moved)
        clearing = true
        pad.drawing = PKDrawing()
        clearing = false
        let right = strokes.map(\.renderBounds.maxX).max() ?? 0
        refresh()
        onCommit?(right / bounds.width)
    }

    /// A stroke written on the strip, made small and put at its place on the page.
    nonisolated static func scaled(_ s: PKStroke, by k: CGFloat, to origin: CGPoint) -> PKStroke {
        let pts = s.path.map { p -> PKStrokePoint in
            let q = p.location.applying(s.transform)
            return PKStrokePoint(location: CGPoint(x: origin.x + q.x * k, y: origin.y + q.y * k), timeOffset: p.timeOffset,
                                 size: CGSize(width: p.size.width * k, height: p.size.height * k),
                                 opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
        }
        return PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: pts, creationDate: s.path.creationDate))
    }
}

struct ZoomPadHost: UIViewRepresentable {
    let view: ZoomPadView
    func makeUIView(context: Context) -> ZoomPadView { view }
    func updateUIView(_ uiView: ZoomPadView, context: Context) {}
}

/// The zoom window with its buttons: back, forward, new line, how big, close.
struct ZoomBar: View {
    let model: EditorModel
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Label("Finestra di zoom", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Spacer(minLength: 6)
                button("arrow.left", String(localized: "Indietro")) { model.zoomStep(-1) }
                button("arrow.right", String(localized: "Avanti")) { model.zoomStep(1) }
                button("return", String(localized: "A capo")) { model.zoomNewLine() }
                Menu {
                    ForEach([2.0, 2.5, 3.0, 4.0], id: \.self) { z in
                        Button { model.setZoomLevel(CGFloat(z)) } label: {
                            let name = String(format: "%g×", z)
                            if abs(model.zoomLevel - CGFloat(z)) < 0.01 { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    Text(String(format: "%g×", model.zoomLevel)).font(.footnote.weight(.bold).monospacedDigit())
                        .frame(minWidth: 40, minHeight: 32)
                }
                .accessibilityLabel("Ingrandimento")
                button("xmark", String(localized: "Chiudi la finestra di zoom")) { model.toggleZoom() }
            }
            .foregroundStyle(Theme.accent)
            ZoomPadHost(view: model.zoomPad)
                .frame(height: hSize == .regular ? 220 : 160)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 40, height: 32)
        }
        .accessibilityLabel(label)
    }
}
