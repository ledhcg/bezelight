import SwiftUI
import AppKit
import BezelightCore

extension LEDColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: b(ns.redComponent), g: b(ns.greenComponent), b: b(ns.blueComponent))
    }

    var swiftUIColor: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            LiveBackdrop(live: model.live, layout: model.profile.layout, running: model.running)
            VStack(spacing: 16) {
                header
                HStack(alignment: .top, spacing: 18) {
                    leftColumn
                    rightColumn
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .padding(.top, 14)
        }
        .frame(minWidth: 940, minHeight: 700)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bezelight").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(tr("app.tagline")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(live: model.live, running: model.running)
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill").frame(width: 18, height: 18)
            }
            .actionStyle()
            .controlSize(.large)
            .help(tr("action.settings"))
            .accessibilityLabel(tr("action.settings"))
        }
        .padding(.leading, 74) // clear the window buttons
    }

    // MARK: left: preview, modes, start

    private var leftColumn: some View {
        VStack(spacing: 16) {
            MonitorPreview(live: model.live, layout: model.profile.layout, mode: model.settings.mode, running: model.running)
                .frame(maxWidth: .infinity, maxHeight: 280)
            ModePicker(mode: $model.settings.mode)
            Text(modeHint).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            if model.settings.mode == .agents { AgentsSummary(agents: model.agents) }
            Spacer(minLength: 0)
            if let message = model.message { MessageBanner(text: message) { model.message = nil } }
            PermissionBanner(live: model.live) { model.openPrivacySettings() }
            startButton
            StatusText(live: model.live, running: model.running)
        }
        .frame(maxWidth: .infinity)
    }

    private var modeHint: String {
        switch model.settings.mode {
        case .staticColor: return tr("hint.mode.static")
        case .screen: return tr("hint.mode.screen")
        case .agents: return tr("hint.mode.agents")
        case .rainbow: return tr("hint.mode.rainbow")
        case .breathing: return tr("hint.mode.breathing")
        case .comet: return tr("hint.mode.comet")
        case .spectrumCycling: return tr("hint.mode.cycling")
        case .starryNight: return tr("hint.mode.starry")
        case .musicEqualizer: return tr("hint.mode.equalizer")
        default: return tr("hint.mode.music")
        }
    }

    private var startButton: some View {
        Button { Task { await model.toggle() } } label: {
            Label(model.running ? tr("action.stop") : tr("action.start"),
                  systemImage: model.running ? "stop.fill" : "play.fill")
        }
        .buttonStyle(PrimaryActionStyle(prominent: !model.running))
        .keyboardShortcut(.space, modifiers: [])
    }

    // MARK: right: contextual controls

    /// The scroll view is wider/taller than the cards by `bleed` on every side and does not clip:
    /// a surface's edge highlight and shadow extend past its frame and would be cut off flat
    /// otherwise. Negative padding hands the extra space back to the layout.
    private var rightColumn: some View {
        let bleed: CGFloat = 16
        return ScrollView {
            SurfaceGroup(spacing: 14) {
                VStack(spacing: 14) {
                    switch model.settings.mode {
                    case .staticColor: StaticColorCard(settings: $model.settings)
                    case .screen: ScreenCard(settings: $model.settings, displays: model.displays)
                    case .agents: AgentsPanel().environmentObject(model.agents)
                    case _ where model.settings.mode.isAnimation: AnimationCard(settings: $model.settings)
                    default: MusicCard(settings: $model.settings)
                    }
                    ColorCard(settings: $model.settings)
                }
            }
            .padding(bleed)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .frame(width: 340 + 2 * bleed)
        .padding(.horizontal, -bleed)
        .padding(.vertical, -bleed)
    }
}

// MARK: - live-observing pieces (each redraws on its own, not the whole window)

/// Backdrop that glows in the colours the LEDs are showing.
struct LiveBackdrop: View {
    @ObservedObject var live: LiveModel
    let layout: LedLayout
    let running: Bool

    var body: some View {
        StageBackdrop(tints: tints)
    }

    /// Average LED colour of the four quadrants, so the window glows like the room does.
    private var tints: [Color] {
        let idle = StageBackdrop.idle
        guard running, live.colors.count == layout.count, !live.colors.isEmpty else { return idle }
        var sum = [[Double]](repeating: [0, 0, 0, 0], count: 4) // r g b n
        for (i, p) in layout.points.enumerated() {
            let q = (p.v < 0.5 ? 0 : 2) + (p.u < 0.5 ? 0 : 1)
            let c = live.colors[i]
            sum[q][0] += Double(c.r); sum[q][1] += Double(c.g); sum[q][2] += Double(c.b); sum[q][3] += 1
        }
        // Quantised to 1/10 steps: small colour drifts leave the backdrop untouched (nothing to
        // redraw), only a clear change repaints it.
        func q(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return sum.enumerated().map { i, s in
            guard s[3] > 0 else { return idle[i] }
            return Color(red: q(s[0] / s[3] / 255), green: q(s[1] / s[3] / 255), blue: q(s[2] / s[3] / 255))
        }
    }
}

private struct StatusPill: View {
    @ObservedObject var live: LiveModel
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(live.connected && running ? tr("status.connected") : tr("status.disconnected")).font(.callout.weight(.medium))
            if live.connected && running {
                Text(tr("status.fps", Int(live.fps.rounded()))).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .capsuleSurface()
        .accessibilityElement(children: .combine)
    }

    private var dot: Color { live.connected && running ? .green : (running ? .orange : .gray) }
}

private struct StatusText: View {
    @ObservedObject var live: LiveModel
    let running: Bool

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 18)
    }

    private var text: String {
        guard running else { return tr("status.stopped") }
        switch live.status {
        case .stopped: return tr("status.stopped")
        case .off: return tr("status.off")
        case .animation: return tr("status.animation")
        case .staticColor: return tr("status.static")
        case .screen(let bars): return bars == .zero ? tr("status.screen") : tr("status.screen.bars")
        case .music: return tr("status.music")
        case .agents: return tr("status.agents")
        case .needsPermission: return tr("status.permission")
        case .captureError(let m): return tr("status.captureError", m)
        case .reconnecting: return tr("status.reconnecting")
        }
    }
}

private struct PermissionBanner: View {
    @ObservedObject var live: LiveModel
    let open: () -> Void

    var body: some View {
        if case .needsPermission = live.status {
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("perm.title"), systemImage: "lock.shield.fill").font(.headline)
                Text(tr("perm.body")).font(.callout).foregroundStyle(.secondary)
                Button(tr("action.openSettings"), action: open).actionStyle(prominent: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(cornerRadius: 18, tint: .orange)
        }
    }
}

private struct MessageBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel(tr("action.done"))
        }
        .padding(12)
        .surface(cornerRadius: 16, tint: .yellow)
    }
}

// MARK: - mode bar

// MARK: - control cards

private struct StaticColorCard: View {
    @Binding var settings: StreamSettings

    private static let swatches: [LEDColor] = [
        .init(r: 255, g: 59, b: 48), .init(r: 255, g: 149, b: 0), .init(r: 255, g: 204, b: 0),
        .init(r: 52, g: 199, b: 89), .init(r: 0, g: 199, b: 190), .init(r: 50, g: 173, b: 230),
        .init(r: 0, g: 122, b: 255), .init(r: 88, g: 86, b: 214), .init(r: 175, g: 82, b: 222),
        .init(r: 255, g: 45, b: 85), .init(r: 255, g: 214, b: 170), .init(r: 255, g: 255, b: 255),
    ]

    var body: some View {
        Card(title: tr("label.color"), systemImage: "paintpalette.fill") {
            ColorPicker(tr("label.color"), selection: Binding(
                get: { settings.staticColor.swiftUIColor },
                set: { settings.staticColor = LEDColor($0) }), supportsOpacity: false)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, c in
                    Button { settings.staticColor = c } label: {
                        Circle().fill(c.swiftUIColor)
                            .overlay(Circle().strokeBorder(.white.opacity(settings.staticColor == c ? 0.95 : 0.25), lineWidth: settings.staticColor == c ? 2.5 : 1))
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("RGB \(c.r), \(c.g), \(c.b)")
                }
            }
        }
    }
}

private struct ScreenCard: View {
    @Binding var settings: StreamSettings
    let displays: [DisplayInfo]

    var body: some View {
        Card(title: tr("section.screen"), systemImage: "display") {
            if displays.count > 1 {
                Picker(tr("label.display"), selection: $settings.displayID) {
                    Text(tr("label.mainDisplay")).tag(UInt32(0))
                    ForEach(displays) { Text($0.name).tag($0.id) }
                }
            }
            Picker(tr("label.region"), selection: $settings.region) {
                ForEach(CaptureRegion.allCases, id: \.self) { Text(regionName($0)).tag($0) }
            }
            Toggle(tr("label.letterbox"), isOn: $settings.autoLetterbox)
                .disabled(settings.region == .cinema)
            Text(tr("hint.letterbox")).font(.caption).foregroundStyle(.tertiary)
            ValueSlider(title: tr("label.edgeDepth"), value: $settings.edgeDepth, range: 0.05...0.4)
        }
    }

    private func regionName(_ r: CaptureRegion) -> String {
        switch r {
        case .full: return tr("region.full")
        case .left: return tr("region.left")
        case .right: return tr("region.right")
        case .top: return tr("region.top")
        case .bottom: return tr("region.bottom")
        case .cinema: return tr("region.cinema")
        }
    }
}

private struct MusicCard: View {
    @Binding var settings: StreamSettings

    var body: some View {
        Card(title: tr("section.music"), systemImage: "waveform") {
            ValueSlider(title: tr("label.musicGain"), value: $settings.musicGain, range: 0.2...3) { String(format: "%.1f×", $0) }
        }
    }
}

private struct ColorCard: View {
    @Binding var settings: StreamSettings
    @State private var advanced = false

    var body: some View {
        Card(title: tr("section.color"), systemImage: "slider.horizontal.3") {
            ValueSlider(title: tr("label.brightness"), value: $settings.brightness, range: 0...1)
            if settings.mode == .screen || settings.mode.isMusic {
                ValueSlider(title: tr("label.saturation"), value: $settings.saturation, range: 0...2)
            }
            if !settings.mode.isAnimation && settings.mode != .agents {
                ValueSlider(title: tr("label.smoothing"), value: $settings.smoothing, range: 0...0.95, hint: tr("hint.smoothing"))
            }
            DisclosureGroup(tr("section.advanced"), isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    ValueSlider(title: tr("label.gamma"), value: $settings.gamma, range: 1...3, format: { String(format: "%.1f", $0) }, hint: tr("hint.gamma"))
                    ValueSlider(title: tr("label.red"), value: $settings.gainR, range: 0.3...1)
                    ValueSlider(title: tr("label.green"), value: $settings.gainG, range: 0.3...1)
                    ValueSlider(title: tr("label.blue"), value: $settings.gainB, range: 0.3...1)
                    Button(tr("action.reset")) { settings.resetTuning() }.actionStyle()
                }
                .padding(.top, 10)
            }
        }
    }
}




/// Under the preview in Agents mode: how many sessions are in each state, at a glance.
private struct AgentsSummary: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        let sessions = agents.snapshot.sessions
        let order: [(SessionState, String, Color)] = [
            (.needsInput, "bell.badge.fill", .orange), (.error, "exclamationmark.triangle.fill", .red),
            (.done, "checkmark.circle.fill", .green), (.working, "ellipsis.circle.fill", .cyan),
        ]
        VStack(spacing: 8) {
            if sessions.allSatisfy({ $0.state == .idle }) {
                Label(tr("agents.sessions.empty"), systemImage: "moon.zzz").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    ForEach(order, id: \.0) { state, symbol, color in
                        let n = sessions.filter { $0.state == state }.count
                        if n > 0 {
                            Label("\(n)", systemImage: symbol).foregroundStyle(color)
                                .accessibilityLabel("\(n) \(tr("agents.state.\(state.rawValue)"))")
                        }
                    }
                }
                .font(.title3.weight(.semibold))
                Text(order.compactMap { state, _, _ in
                    let n = sessions.filter { $0.state == state }.count
                    return n > 0 ? "\(n) \(tr("agents.state.\(state.rawValue)"))" : nil
                }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
