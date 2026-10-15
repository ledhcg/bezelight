import SwiftUI
import AppKit

// Translucent surfaces used by every screen.
//
// On macOS 26 these use the system's dynamic material (`glassEffect`). The `#if compiler` guard
// keeps the project buildable with older Xcode toolchains, and the `#available` check keeps it
// running on macOS 14/15, where the same shapes are drawn with ordinary materials.

extension View {
    /// A translucent rounded surface. `tint` colours it; `interactive` adds hover/press response.
    @ViewBuilder
    func surface(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(Self.material(tint: tint, interactive: interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            fallbackSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        }
        #else
        fallbackSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        #endif
    }

    @ViewBuilder
    func capsuleSurface(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(Self.material(tint: tint, interactive: interactive), in: .capsule)
        } else {
            fallbackSurface(Capsule(), tint: tint)
        }
        #else
        fallbackSurface(Capsule(), tint: tint)
        #endif
    }

    /// Button style that matches the surfaces above.
    @ViewBuilder
    func actionStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }

    private func fallbackSurface<S: InsettableShape>(_ shape: S, tint: Color?) -> some View {
        self.background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.22), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14)))
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private static func material(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif
}

/// Groups surfaces so neighbouring ones blend and are rendered in a single pass.
struct SurfaceGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Titled surface that holds one group of controls.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 22)
    }
}

/// Label, live value and slider in one row.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            SoftSlider(value: $value, range: range)
                .accessibilityLabel(title)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Slider with a light track instead of the system's dark one, which turns into a black stripe
/// on a translucent card. Drag anywhere on the track; VoiceOver can adjust it in 5% steps.
struct SoftSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private let knob: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let span = max(1, geo.size.width - knob)
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16)).frame(height: 6)
                Capsule().fill(Brand.accent).frame(width: knob / 2 + t * span, height: 6)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .offset(x: t * span)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = min(max(0, (g.location.x - knob / 2) / span), 1)
                value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: knob)
        .accessibilityElement()
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// The main call-to-action: a tinted surface rather than a solid slab of colour.
struct PrimaryActionStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.headline)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
        if #available(macOS 26, *) {
            label
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .surface(cornerRadius: 20, tint: prominent ? Brand.accent.opacity(0.9) : nil, interactive: true)
        } else {
            label
                .foregroundStyle(Color.primary)
                .surface(cornerRadius: 20, tint: prominent ? Brand.accent : nil)
        }
    }
}

/// Colour field behind the surfaces, tinted by what the LEDs are showing.
///
/// Translucent surfaces only read as translucent over a backdrop that is lit and coloured: over
/// near-black they collapse into flat grey plates whose edge shadow looks like a black outline.
/// So every tint is lifted into a comfortable brightness band for the current appearance, even
/// when the screen (and therefore the LEDs) is black.
///
/// A mesh gradient (macOS 15+) interpolates smoothly between the four corner tints; older
/// systems get blended linear gradients. No blurred layers, so nothing can be clipped into a seam.
struct StageBackdrop: View {
    /// Top-left, top-right, bottom-left, bottom-right.
    let tints: [Color]
    @Environment(\.colorScheme) private var scheme

    static let idle: [Color] = [
        Color(red: 0.36, green: 0.34, blue: 0.95), Color(red: 0.74, green: 0.33, blue: 0.93),
        Color(red: 0.20, green: 0.78, blue: 0.80), Color(red: 0.25, green: 0.55, blue: 1.00),
    ]

    var body: some View {
        // No implicit animation: a running animation re-renders the mesh at the display rate for as
        // long as the LED colours keep moving, which cost more than all the rest of the app.
        field
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var field: some View {
        let t = (tints.count == 4 ? tints : Self.idle).map { $0.lifted(for: scheme) }
        if #available(macOS 15, *) {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                colors: [t[0], t[0].blended(t[1]), t[1],
                         t[0].blended(t[2]), t[0].blended(t[1]).blended(t[2].blended(t[3])), t[1].blended(t[3]),
                         t[2], t[2].blended(t[3]), t[3]])
        } else {
            ZStack {
                LinearGradient(colors: [t[0], t[2]], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [t[1], t[3]], startPoint: .top, endPoint: .bottom).opacity(0.5)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

extension Color {
    /// Keeps the hue but moves brightness and saturation into a band that suits surfaces drawn
    /// on top: mid-bright and softly saturated in dark mode, light pastel in light mode.
    func lifted(for scheme: ColorScheme) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &br, alpha: &al)
        let s2: CGFloat, b2: CGFloat
        if scheme == .dark {
            s2 = 0.35 + 0.40 * sat      // never grey, never neon
            b2 = 0.38 + 0.34 * br       // black lifts to 0.38, white tops out at 0.72
        } else {
            s2 = 0.16 + 0.30 * sat
            b2 = 0.90 + 0.08 * br
        }
        return Color(hue: Double(h), saturation: Double(s2), brightness: Double(b2))
    }

    /// Even mix of two colours in sRGB.
    func blended(_ other: Color) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(red: (a.redComponent + b.redComponent) / 2,
                     green: (a.greenComponent + b.greenComponent) / 2,
                     blue: (a.blueComponent + b.blueComponent) / 2)
    }
}

/// Makes the hosting window transparent so the backdrop is the window's own surface: no title
/// bar band, no seam. Title bar buttons stay; content may extend under them.
struct WindowStyler: NSViewRepresentable {
    var draggable = true
    var transparentPanel = false

    /// Applies the style the moment the view joins its window (a deferred closure can run
    /// before that, e.g. for the Settings window, and would silently do nothing).
    private final class StyleView: NSView {
        var draggable = true
        var transparentPanel = false

        override func viewDidMoveToWindow() {
            apply()
            // SwiftUI configures scene windows (Settings especially) after attaching the content;
            // apply once more when that is done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = draggable
            w.styleMask.insert(.fullSizeContentView)
            w.backgroundColor = .clear
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = transparentPanel
            }
            // With full-size content some windows (Settings) stack the content above the title bar,
            // which hides the window buttons. Put the title bar container back on top.
            if let bar = w.standardWindowButton(.closeButton)?.superview?.superview,
               let frame = w.contentView?.superview, bar.superview === frame {
                frame.addSubview(bar, positioned: .above, relativeTo: nil)
            }
            if transparentPanel { w.isOpaque = false; w.hasShadow = true }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let v = StyleView()
        v.draggable = draggable
        v.transparentPanel = transparentPanel
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
