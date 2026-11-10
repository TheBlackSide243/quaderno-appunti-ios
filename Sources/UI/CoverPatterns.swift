import SwiftUI
import UIKit

/// The illustrated covers: a pattern drawn over the board in tints of the cover colour.
/// Everything is drawn from a fixed seed, so a cover always looks the same.
struct CoverPattern: View {
    let style: CoverStyle
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let p = Palette(UIColor(color))
            var rng = SeededRandom(seed: style.seed)
            let w = size.width, h = size.height
            switch style {
            case .plain, .elastic, .label: break
            case .waves: waves(&ctx, w, h, p)
            case .mosaic: mosaic(&ctx, w, h, p, &rng)
            case .dots: dots(&ctx, w, h, p)
            case .marble: marble(&ctx, w, h, p, &rng)
            case .leaves: leaves(&ctx, w, h, p, &rng)
            case .mountains: mountains(&ctx, w, h, p)
            case .stars: stars(&ctx, w, h, p, &rng)
            case .terrazzo: terrazzo(&ctx, w, h, p, &rng)
            case .aurora: aurora(&ctx, w, h, p)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Patterns

    /// Layered waves, darker towards the bottom.
    private func waves(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(p.light(0.12)))
        for i in 0..<6 {
            let top = h * (0.3 + CGFloat(i) * 0.12)
            let amp = h * 0.035
            var path = Path()
            path.move(to: CGPoint(x: 0, y: top))
            let steps = 40
            for s in 0...steps {
                let x = w * CGFloat(s) / CGFloat(steps)
                let y = top + sin(CGFloat(s) / CGFloat(steps) * .pi * 3 + CGFloat(i) * 0.9) * amp
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
            ctx.fill(path, with: .color(p.dark(0.04 + CGFloat(i) * 0.07)))
            ctx.stroke(path, with: .color(p.light(0.45).opacity(0.35)), lineWidth: max(0.5, w * 0.006))
        }
    }

    /// Triangles in five tints.
    private func mosaic(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette, _ rng: inout SeededRandom) {
        let tints = [p.light(0.32), p.light(0.16), p.base, p.dark(0.14), p.dark(0.28)]
        let cols = 5
        let cell = w / CGFloat(cols)
        let rows = Int((h / cell).rounded(.up))
        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * cell, y = CGFloat(r) * cell
                let a = CGPoint(x: x, y: y), b = CGPoint(x: x + cell, y: y)
                let d = CGPoint(x: x, y: y + cell), e = CGPoint(x: x + cell, y: y + cell)
                let flip = rng.next() > 0.5
                let t1 = flip ? [a, b, e] : [a, b, d]
                let t2 = flip ? [a, e, d] : [b, e, d]
                for tri in [t1, t2] {
                    var path = Path()
                    path.addLines(tri)
                    path.closeSubpath()
                    ctx.fill(path, with: .color(tints[Int(rng.next() * CGFloat(tints.count)) % tints.count]))
                }
            }
        }
    }

    /// Polka dots on a staggered grid.
    private func dots(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette) {
        let step = w * 0.15
        let r = w * 0.032
        var row = 0
        var y = step * 0.4
        while y < h + step {
            var x = (row % 2 == 0 ? step * 0.5 : step) + w * 0.04
            while x < w + step {
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(p.light(0.55).opacity(0.85)))
                x += step
            }
            y += step * 0.87
            row += 1
        }
    }

    /// Light stone with veins of the colour.
    private func marble(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette, _ rng: inout SeededRandom) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .linearGradient(
            Gradient(colors: [p.light(0.82), p.light(0.68)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
        for i in 0..<11 {
            var path = Path()
            let y0 = h * rng.next()
            path.move(to: CGPoint(x: -w * 0.1, y: y0))
            var x = -w * 0.1, y = y0
            while x < w * 1.1 {
                let nx = x + w * (0.2 + rng.next() * 0.25)
                let ny = y + h * (rng.next() - 0.45) * 0.22
                path.addQuadCurve(to: CGPoint(x: nx, y: ny), control: CGPoint(x: (x + nx) / 2, y: y + h * (rng.next() - 0.5) * 0.2))
                x = nx; y = ny
            }
            let wide = i < 3
            ctx.stroke(path, with: .color(wide ? p.base.opacity(0.22) : p.dark(0.15).opacity(0.35 + rng.next() * 0.45)),
                       lineWidth: wide ? w * 0.06 : max(0.5, w * (0.004 + rng.next() * 0.012)))
        }
    }

    /// Scattered leaves with their midrib.
    private func leaves(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette, _ rng: inout SeededRandom) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(p.dark(0.08)))
        let tints = [p.light(0.22), p.light(0.4), p.dark(0.22), p.base, p.light(0.08)]
        for i in 0..<16 {
            let len = w * (0.16 + rng.next() * 0.12)
            let c = CGPoint(x: w * (rng.next() * 1.1 - 0.05), y: h * (rng.next() * 1.05 - 0.02))
            let angle = Angle.radians(Double(rng.next()) * .pi * 2)
            var leaf = Path()
            leaf.move(to: CGPoint(x: 0, y: -len / 2))
            leaf.addQuadCurve(to: CGPoint(x: 0, y: len / 2), control: CGPoint(x: len * 0.42, y: 0))
            leaf.addQuadCurve(to: CGPoint(x: 0, y: -len / 2), control: CGPoint(x: -len * 0.42, y: 0))
            var rib = Path()
            rib.move(to: CGPoint(x: 0, y: -len / 2))
            rib.addLine(to: CGPoint(x: 0, y: len * 0.62))
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(angle.radians))
            ctx.fill(leaf.applying(t), with: .color(tints[i % tints.count]))
            ctx.stroke(rib.applying(t), with: .color(p.dark(0.35).opacity(0.55)), lineWidth: max(0.5, w * 0.008))
        }
    }

    /// Sun and three ranges of mountains.
    private func mountains(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .linearGradient(
            Gradient(colors: [p.light(0.5), p.light(0.18)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.7)))
        let r = w * 0.13
        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.62 - r, y: h * 0.27 - r, width: r * 2, height: r * 2)), with: .color(p.light(0.78)))
        let ranges: [(CGFloat, [CGFloat], CGFloat)] = [
            (0.52, [0.62, 0.38, 0.55, 0.33, 0.5, 0.42], 0.08),
            (0.62, [0.7, 0.5, 0.64, 0.46, 0.68], 0.22),
            (0.74, [0.82, 0.62, 0.78, 0.6], 0.38),
        ]
        for (base, peaks, darkness) in ranges {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: h * base))
            let n = CGFloat(peaks.count)
            for (i, py) in peaks.enumerated() {
                let x = w * (CGFloat(i) + 0.5) / n
                path.addLine(to: CGPoint(x: x, y: h * py * 0.9))
                path.addLine(to: CGPoint(x: x + w / n / 2, y: h * (base + 0.04)))
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            ctx.fill(path, with: .color(p.dark(darkness)))
        }
    }

    /// A night sky: stars, a few sparkles and the moon.
    private func stars(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette, _ rng: inout SeededRandom) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .linearGradient(
            Gradient(colors: [p.dark(0.62), p.dark(0.32)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        for _ in 0..<55 {
            let s = w * (0.006 + rng.next() * 0.012)
            let x = w * rng.next(), y = h * rng.next()
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.35 + rng.next() * 0.6)))
        }
        for _ in 0..<5 {
            let x = w * (0.1 + rng.next() * 0.8), y = h * (0.15 + rng.next() * 0.75)
            let s = w * (0.03 + rng.next() * 0.03)
            var star = Path()
            star.move(to: CGPoint(x: x, y: y - s))
            star.addQuadCurve(to: CGPoint(x: x + s, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y + s), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x - s, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y - s), control: CGPoint(x: x, y: y))
            ctx.fill(star, with: .color(p.light(0.75)))
        }
        let r = w * 0.15
        let moon = CGRect(x: w * 0.7 - r, y: h * 0.2 - r, width: r * 2, height: r * 2)
        var crescent = Path(ellipseIn: moon)
        crescent.addEllipse(in: moon.offsetBy(dx: r * 0.55, dy: -r * 0.2))
        ctx.fill(crescent, with: .color(Color(white: 0.97)), style: FillStyle(eoFill: true))
    }

    /// Stone chips on a light ground.
    private func terrazzo(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette, _ rng: inout SeededRandom) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(p.light(0.84)))
        let tints = [p.base, p.dark(0.25), p.light(0.35), Color(white: 0.3), Color(white: 0.62)]
        for i in 0..<70 {
            let c = CGPoint(x: w * rng.next(), y: h * rng.next())
            let r = w * (0.015 + rng.next() * (i < 12 ? 0.05 : 0.025))
            let n = 4 + Int(rng.next() * 3)
            var chip = Path()
            for k in 0..<n {
                let a = CGFloat(k) / CGFloat(n) * .pi * 2 + rng.next() * 0.6
                let rr = r * (0.6 + rng.next() * 0.5)
                let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                if k == 0 { chip.move(to: pt) } else { chip.addLine(to: pt) }
            }
            chip.closeSubpath()
            ctx.fill(chip, with: .color(tints[i % tints.count]))
        }
    }

    /// Soft blurred glows in neighbouring hues.
    private func aurora(_ ctx: inout GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ p: Palette) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(p.dark(0.45)))
        var glow = ctx
        glow.addFilter(.blur(radius: w * 0.14))
        let blobs: [(CGFloat, CGFloat, CGFloat, Color)] = [
            (0.25, 0.25, 0.55, p.hue(0.09)),
            (0.8, 0.4, 0.5, p.light(0.3)),
            (0.3, 0.75, 0.6, p.hue(-0.1)),
            (0.85, 0.9, 0.45, p.base),
        ]
        for (x, y, r, c) in blobs {
            let rr = w * r
            glow.fill(Path(ellipseIn: CGRect(x: w * x - rr, y: h * y - rr, width: rr * 2, height: rr * 2)), with: .color(c.opacity(0.9)))
        }
    }
}

/// Tints of a cover colour.
private struct Palette {
    let r: CGFloat, g: CGFloat, b: CGFloat
    let hueValue: CGFloat, sat: CGFloat, bri: CGFloat

    init(_ c: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.r = r; self.g = g; self.b = b
        var hh: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        c.getHue(&hh, saturation: &s, brightness: &v, alpha: &a)
        hueValue = hh; sat = s; bri = v
    }

    var base: Color { Color(red: r, green: g, blue: b) }
    func light(_ t: CGFloat) -> Color { Color(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t) }
    func dark(_ t: CGFloat) -> Color { Color(red: r * (1 - t), green: g * (1 - t), blue: b * (1 - t)) }
    /// The colour with its hue turned a little (for colourful glows).
    func hue(_ d: CGFloat) -> Color {
        var hh = (hueValue + d).truncatingRemainder(dividingBy: 1)
        if hh < 0 { hh += 1 }
        return Color(hue: hh, saturation: max(0.35, sat), brightness: max(0.55, bri))
    }
}

/// A small fixed-seed generator, so the patterns do not change between draws.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z % 10_000) / 10_000
    }
}
