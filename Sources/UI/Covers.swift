import SwiftUI

/// A notebook cover: coloured board with a darker spine, the page edges peeking out on the right,
/// and depending on the style an elastic band or a white label with the title.
struct CoverArt: View {
    let color: Color
    let style: CoverStyle
    var title: String = ""

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let r = max(4, w * 0.05)
            ZStack(alignment: .topLeading) {
                // page block behind the board
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: r, topTrailingRadius: r)
                    .fill(Color(white: 0.94))
                    .frame(width: w, height: h * 0.985)
                    .offset(y: h * 0.0075)
                // the board
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: r, topTrailingRadius: r)
                    .fill(color.gradient)
                    .frame(width: w * 0.965, height: h)
                    .overlay {
                        if style.isIllustrated { CoverPattern(style: style, color: color) }
                    }
                    .overlay(alignment: .leading) {
                        // spine
                        Rectangle().fill(.black.opacity(0.28)).frame(width: w * 0.075)
                            .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.12)).frame(width: 1) }
                    }
                    .overlay { details(w: w * 0.965, h: h) }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: r, topTrailingRadius: r))
            }
        }
    }

    @ViewBuilder
    private func details(w: CGFloat, h: CGFloat) -> some View {
        switch style {
        case .plain:
            // a few faint lines to write a name on, bottom right
            VStack(alignment: .trailing, spacing: h * 0.035) {
                ForEach(0..<3, id: \.self) { i in
                    Rectangle().fill(.black.opacity(0.22)).frame(width: w * (i == 2 ? 0.28 : 0.36), height: max(0.8, h * 0.004))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, w * 0.1)
            .padding(.bottom, h * 0.1)
        case .elastic:
            Rectangle().fill(.black.opacity(0.42))
                .frame(width: max(3, w * 0.05))
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.15)).frame(width: 1) }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, w * 0.11)
        case .label:
            VStack(spacing: h * 0.02) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: max(7, w * 0.085), weight: .semibold, design: .serif))
                        .foregroundStyle(Color(white: 0.15))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                } else {
                    ForEach(0..<2, id: \.self) { _ in Rectangle().fill(.black.opacity(0.18)).frame(height: max(0.8, h * 0.004)) }
                }
            }
            .padding(.horizontal, w * 0.06)
            .frame(width: w * 0.6, height: h * 0.17)
            .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: max(2, w * 0.025)))
            .overlay(RoundedRectangle(cornerRadius: max(2, w * 0.025)).stroke(.black.opacity(0.15), lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, h * 0.18)
            .padding(.leading, w * 0.07)
        default:
            // illustrated: a soft sheen, like a printed board
            LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The cover of a notebook on the shelf: its own art, or the first page for PDFs and notebooks
/// without a cover.
struct NotebookCover: View {
    let notebook: Notebook
    var version = 0
    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let c = notebook.cover {
                CoverArt(color: Covers.color(c), style: notebook.coverStyle ?? .plain, title: notebook.title)
            } else {
                ZStack {
                    Color(uiColor: notebook.paper.uiColor)
                    if let thumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if notebook.hasPDF {
                        Text("PDF").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.bad, in: RoundedRectangle(cornerRadius: 3))
                            .padding(6)
                    }
                }
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
        .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
        .overlay(alignment: .topTrailing) {
            if notebook.favorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(7)
            }
        }
        .task(id: version) {
            guard notebook.cover == nil else { return }
            let nb = notebook
            // the saved picture, or the first page drawn now if it is not there yet
            thumb = await Task.detached { () -> UIImage? in
                if let img = UIImage(contentsOfFile: Store.thumb(nb.id).path) { return img }
                guard let first = nb.pages.first else { return nil }
                return PageRenderer.render(nb, first, width: 360)
            }.value
        }
    }
}

/// A folder drawn as a folder.
struct FolderArt: View {
    var count: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let bh = h * 0.62
            ZStack(alignment: .bottom) {
                // back with the tab
                UnevenRoundedRectangle(topLeadingRadius: w * 0.05, bottomLeadingRadius: w * 0.05,
                                       bottomTrailingRadius: w * 0.05, topTrailingRadius: w * 0.05)
                    .fill(Color(red: 0.38, green: 0.47, blue: 0.60))
                    .frame(height: bh)
                    .overlay(alignment: .topLeading) {
                        UnevenRoundedRectangle(topLeadingRadius: w * 0.04, topTrailingRadius: w * 0.04)
                            .fill(Color(red: 0.38, green: 0.47, blue: 0.60))
                            .frame(width: w * 0.38, height: h * 0.08)
                            .offset(y: -h * 0.07)
                    }
                    .offset(y: -h * 0.05)
                // a sheet of paper sticking out
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.93))
                    .frame(width: w * 0.8, height: bh * 0.7)
                    .offset(y: -bh * 0.32)
                // front
                RoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.52, green: 0.62, blue: 0.76), Color(red: 0.45, green: 0.55, blue: 0.69)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: bh * 0.86)
                    .overlay {
                        Text("\(count)").font(.system(size: max(10, w * 0.12), weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
        .aspectRatio(0.76, contentMode: .fit)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}
