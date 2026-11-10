import SwiftUI

/// A short tour of the app: shown by itself at the first launch, and any time from the "?" of the
/// shelf or from Settings.
struct IntroView: View {
    @Environment(\.dismiss) private var dismiss
    /// Whether the last page offers to set up iCloud Drive (not when it already is).
    var offerBackup = false
    /// Opens the iCloud Drive settings after the tour closes.
    var onBackup: (() -> Void)?
    var onFinish: (() -> Void)?

    @State private var page = 0

    private struct Step {
        let title: String
        let text: String
        let art: AnyView
    }

    private var steps: [Step] {
        [
            Step(title: "Benvenuto in Appunti",
                 text: "Quaderni da scrivere a mano, PDF da annotare e la ricerca nella tua scrittura. Tutto resta sul tuo iPhone o iPad.",
                 art: AnyView(WelcomeArt())),
            Step(title: "Scrivi come su carta",
                 text: "Scegli penna, matita, evidenziatore o gomma dalla barra in alto, con spessore e colore. Due dita per scorrere e ingrandire. Su iPad puoi scrivere solo con la Pencil e scorrere col dito: lo trovi nel menu ⋯.",
                 art: AnyView(WriteArt())),
            Step(title: "PDF, testi e foto",
                 text: "Importa un PDF e scrivici sopra: l'evidenziatore colora senza coprire il testo. Aggiungi riquadri di testo e foto; con la mano li sposti e li ridimensioni.",
                 art: AnyView(PDFArt())),
            Step(title: "Ritrova tutto",
                 text: "La lente cerca nei titoli, nei testi, nei PDF e anche nella tua scrittura a mano, riconosciuta sul dispositivo qualche secondo dopo che hai scritto.",
                 art: AnyView(SearchArt())),
            Step(title: "Al sicuro su iCloud Drive",
                 text: "Nelle Impostazioni scegli una cartella di iCloud Drive: l'app ci copia i quaderni da sola e da lì li ripristini su un altro iPhone o iPad.",
                 art: AnyView(CloudArt())),
        ]
    }

    private var last: Int { steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Salta") { finish() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.sub)
                    .opacity(page < last ? 1 : 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { i in
                    VStack(spacing: 26) {
                        Spacer(minLength: 0)
                        steps[i].art
                            .frame(height: 230)
                        VStack(spacing: 12) {
                            Text(steps[i].title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            Text(steps[i].text)
                                .font(.callout)
                                .foregroundStyle(Theme.sub)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 28)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 520)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Theme.accent : Theme.line)
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: page)
            .padding(.bottom, 18)

            VStack(spacing: 10) {
                Button(page == last ? "Inizia a scrivere" : "Avanti") {
                    if page == last { finish() } else { withAnimation { page += 1 } }
                }
                .buttonStyle(PrimaryButtonStyle())
                if page == last, offerBackup {
                    Button("Imposta iCloud Drive adesso") {
                        finish()
                        onBackup?()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func finish() {
        onFinish?()
        dismiss()
    }
}

// MARK: Pictures

/// A sheet of paper with ruled lines, for the pictures of the tour.
private struct PaperCard<Content: View>: View {
    var lines = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: Paper.white.uiColor))
            if lines {
                VStack(spacing: 18) {
                    ForEach(0..<9, id: \.self) { _ in
                        Rectangle().fill(Color(uiColor: PageRenderer.lineColor)).frame(height: 1)
                    }
                }
                .padding(.top, 34)
            }
            content
        }
        .frame(width: 180, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
    }
}

/// A wavy line that looks like handwriting.
private struct Scribble: Shape {
    var loops = 9
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = loops * 12
        for i in 0...n {
            let t = CGFloat(i) / 12 * 2 * .pi
            let w = r.width / CGFloat(loops)
            let x = r.minX + w * t / (2 * .pi) - w * 0.4 * sin(t) + (1 + cos(t)) / 2 * r.height * 0.28
            let y = r.maxY - r.height * (1 + cos(t)) / 2
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

private struct WelcomeArt: View {
    var body: some View {
        ZStack {
            CoverArt(color: Covers.color(1), style: .elastic).frame(width: 120, height: 158)
                .rotationEffect(.degrees(-14)).offset(x: -78, y: 14)
            CoverArt(color: Covers.color(10), style: .label, title: "Appunti").frame(width: 120, height: 158)
                .rotationEffect(.degrees(12)).offset(x: 78, y: 14)
            CoverArt(color: Covers.color(0), style: .plain).frame(width: 132, height: 174)
                .overlay {
                    Image(systemName: "pencil.and.scribble").font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Theme.bg.opacity(0.75))
                }
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }
}

private struct WriteArt: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(["pencil.tip", "pencil", "highlighter", "eraser", "lasso"], id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: icon == "pencil.tip" ? .semibold : .regular))
                        .foregroundStyle(icon == "pencil.tip" ? Theme.accent : Theme.text)
                        .frame(width: 36, height: 32)
                        .background(icon == "pencil.tip" ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                Rectangle().fill(Theme.line).frame(width: 1, height: 22).padding(.horizontal, 4)
                ForEach(["1C1C20", "1D4ED8", "DC2626"], id: \.self) { hex in
                    Circle().fill(Color(uiColor: UIColor(hex: hex))).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(hex == "1C1C20" ? Theme.accent : Theme.line, lineWidth: hex == "1C1C20" ? 2 : 1).padding(-3))
                        .padding(.horizontal, 3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    Scribble(loops: 8).stroke(Color(uiColor: UIColor(hex: "1D4ED8")), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 120, height: 9)
                    ForEach(0..<3, id: \.self) { i in
                        Scribble(loops: i == 2 ? 6 : 10).stroke(Color(white: 0.12), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .frame(width: i == 2 ? 90 : 140, height: 8)
                    }
                }
                .padding(.leading, 16).padding(.top, 26)
            }
            .frame(height: 170, alignment: .top)
            .clipped()
        }
    }
}

private struct PDFArt: View {
    var body: some View {
        ZStack {
            PaperCard(lines: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(Color(white: 0.2)).frame(width: 110, height: 9)
                    ForEach(0..<8, id: \.self) { i in
                        Capsule().fill(Color(white: 0.45)).frame(width: i % 3 == 2 ? 90 : 145, height: 5)
                            .background(alignment: .leading) {
                                if i == 2 || i == 5 {
                                    Capsule().fill(Color(uiColor: UIColor(hex: "FDE047")).opacity(0.85))
                                        .frame(width: 120, height: 13)
                                        .blendMode(.multiply)
                                }
                            }
                    }
                    Scribble(loops: 6).stroke(Color(uiColor: UIColor(hex: "DC2626")), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 80, height: 8)
                        .padding(.leading, 50).padding(.top, 6)
                }
                .padding(18)
            }
            .overlay(alignment: .topLeading) {
                Text("PDF").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.bad, in: RoundedRectangle(cornerRadius: 4)).padding(8)
            }
            .offset(x: -30)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.42), Color(red: 0.42, green: 0.36, blue: 0.52)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 110, height: 80)
                .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(.white.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3])).padding(-4))
                .rotationEffect(.degrees(6))
                .offset(x: 80, y: 60)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        }
    }
}

private struct SearchArt: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
                Text("Newton").foregroundStyle(Theme.text)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 14).frame(width: 280, height: 42)
            .background(Theme.input, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            ForEach([("Fisica 1", "p. 1", "le leggi di Newton"), ("Analisi 2", "p. 1", "teorema (Newton–Leibniz)")], id: \.0) { nb, p, snippet in
                HStack(alignment: .top, spacing: 10) {
                    Text(p).font(.caption.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nb).font(.caption.weight(.semibold)).foregroundStyle(Theme.sub)
                        Text(snippet).font(.subheadline).foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 280)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            }
        }
    }
}

private struct CloudArt: View {
    var body: some View {
        ZStack {
            Image(systemName: "icloud.fill")
                .font(.system(size: 150))
                .foregroundStyle(Theme.panel)
                .overlay(Image(systemName: "icloud").font(.system(size: 150, weight: .thin)).foregroundStyle(Theme.line))
            HStack(spacing: -18) {
                CoverArt(color: Covers.color(1), style: .elastic).frame(width: 52, height: 68).rotationEffect(.degrees(-10))
                CoverArt(color: Covers.color(10), style: .label).frame(width: 52, height: 68).zIndex(1)
                CoverArt(color: Covers.color(2), style: .plain).frame(width: 52, height: 68).rotationEffect(.degrees(10))
            }
            .offset(y: 14)
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.bg, Theme.accent)
                .offset(x: 70, y: 52)
        }
    }
}
