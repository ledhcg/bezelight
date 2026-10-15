import SwiftUI
import BezelightCore

/// A stylised display with the LED strip drawn around its edge, lit with the live colours.
/// Reading the preview from here (not from `AppModel`) keeps 8 Hz updates local to this view.
struct MonitorPreview: View {
    @ObservedObject var live: LiveModel
    let layout: LedLayout
    let mode: LightMode
    let running: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Canvas { ctx, size in draw(&ctx, size: size) }
            VStack(spacing: 6) {
                Image(systemName: Self.symbol(for: mode))
                    .font(.system(size: 34, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                Text(Self.title(for: mode))
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(running ? 0.9 : 0.55))
            .shadow(color: .black.opacity(0.35), radius: 8)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("a11y.preview", layout.count))
    }

    static func symbol(for mode: LightMode) -> String {
        switch mode {
        case .staticColor: return "paintpalette.fill"
        case .screen: return "display"
        case .musicBass: return "hifispeaker.fill"
        case .musicMid: return "waveform"
        case .musicTreble: return "sparkles"
        case .musicSpectrum: return "rainbow"
        case .musicEqualizer: return "chart.bar.fill"
        case .rainbow: return "cloud.rainbow.half.fill"
        case .breathing: return "wind"
        case .comet: return "sparkle"
        case .spectrumCycling: return "circle.hexagongrid.fill"
        case .starryNight: return "moon.stars.fill"
        case .agents: return "bell.badge"
        }
    }

    static func title(for mode: LightMode) -> String {
        switch mode {
        case .staticColor: return tr("mode.static")
        case .screen: return tr("mode.screen")
        case .musicBass: return tr("mode.bass")
        case .musicMid: return tr("mode.mid")
        case .musicTreble: return tr("mode.treble")
        case .musicSpectrum: return tr("mode.spectrum")
        case .musicEqualizer: return tr("mode.equalizer")
        case .rainbow: return tr("mode.rainbow")
        case .breathing: return tr("mode.breathing")
        case .comet: return tr("mode.comet")
        case .spectrumCycling: return tr("mode.cycling")
        case .starryNight: return tr("mode.starry")
        case .agents: return tr("mode.agents")
        }
    }

    private var idleLED: Color { scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.22) }

    // MARK: drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let margin: CGFloat = 26
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let corner: CGFloat = 16
        let pts = layout.points
        let colors = live.colors.count == pts.count && running ? live.colors : []

        func color(_ i: Int) -> Color {
            guard i < colors.count else { return idleLED }
            let c = colors[i]
            return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }

        // Screen body with a soft wash of the nearest LED colours bleeding inward.
        let body = Path(roundedRect: screen, cornerRadius: corner, style: .continuous)
        ctx.fill(body, with: .color(Color(white: 0.09).opacity(scheme == .dark ? 0.45 : 0.62)))
        ctx.drawLayer { layer in
            layer.clip(to: body)
            layer.addFilter(.blur(radius: 22))
            for (i, p) in pts.enumerated() where i < colors.count {
                let center = CGPoint(x: screen.minX + p.u * screen.width, y: screen.minY + p.v * screen.height)
                let r = CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)
                layer.fill(Path(ellipseIn: r), with: .color(color(i).opacity(0.55)))
            }
        }
        ctx.stroke(body, with: .color(.white.opacity(scheme == .dark ? 0.22 : 0.45)), lineWidth: 1)

        // LEDs just outside the screen edge, glow first then crisp.
        let leds: [(CGRect, Color)] = pts.enumerated().map { i, p in
            (ledRect(p, in: screen, pitch: pitch(pts.count, screen)), color(i))
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            for (r, c) in leds { layer.fill(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 4), with: .color(c.opacity(0.9))) }
        }
        for (r, c) in leds { ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(c)) }
    }

    private func pitch(_ count: Int, _ screen: CGRect) -> CGFloat {
        let perimeter = 2 * (screen.width + screen.height)
        return perimeter / CGFloat(max(1, count))
    }

    /// Capsule sitting just outside the edge the LED belongs to, oriented along that edge.
    private func ledRect(_ p: LedLayout.Point, in s: CGRect, pitch: CGFloat) -> CGRect {
        let len = max(4, min(16, pitch * 0.62)), thick: CGFloat = 5, gap: CGFloat = 9
        let x = s.minX + p.u * s.width, y = s.minY + p.v * s.height
        let eps = 1e-6
        let onL = p.u <= eps, onR = p.u >= 1 - eps, onT = p.v <= eps, onB = p.v >= 1 - eps
        if (onL || onR) && !(onT || onB) {
            return CGRect(x: (onL ? s.minX - gap : s.maxX + gap) - thick / 2, y: y - len / 2, width: thick, height: len)
        }
        if (onT || onB) && !(onL || onR) {
            return CGRect(x: x - len / 2, y: (onT ? s.minY - gap : s.maxY + gap) - thick / 2, width: len, height: thick)
        }
        // corner LED
        return CGRect(x: (onL ? s.minX - gap : s.maxX + gap) - thick / 2,
                      y: (onT ? s.minY - gap : s.maxY + gap) - thick / 2, width: thick, height: thick)
    }
}
