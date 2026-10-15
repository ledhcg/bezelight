import SwiftUI
import BezelightCore

/// Mode picker in two levels: a group (Screen / Music / Colors), then the modes inside it.
struct ModePicker: View {
    @Binding var mode: LightMode
    @State private var remembered: [LightMode.Group: LightMode] = [:]

    static func modes(in group: LightMode.Group) -> [LightMode] {
        switch group {
        case .screen: return [.screen]
        case .agents: return [.agents]
        case .music: return [.musicBass, .musicMid, .musicTreble, .musicSpectrum, .musicEqualizer]
        case .color, .animation: return [.staticColor, .rainbow, .breathing, .comet, .spectrumCycling, .starryNight]
        }
    }

    private static let tabs: [(LightMode.Group, String, String)] = [
        (.screen, "group.screen", "display"), (.music, "group.music", "waveform"), (.color, "group.colors", "paintpalette.fill"),
        (.agents, "group.agents", "bell.badge"),
    ]

    private var current: LightMode.Group { mode.group == .animation ? .color : mode.group }

    var body: some View {
        VStack(spacing: 10) {
            SurfaceGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.tabs, id: \.0) { group, key, symbol in
                        let selected = group == current
                        Button {
                            remembered[current] = mode
                            mode = remembered[group] ?? Self.modes(in: group)[0]
                        } label: {
                            Label(tr(key), systemImage: symbol)
                                .font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .surface(cornerRadius: 16, tint: selected ? Brand.accent.opacity(0.75) : nil, interactive: true)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if current != .screen && current != .agents {
                ModeChips(modes: Self.modes(in: current), mode: $mode, columns: 3)
            }
        }
    }
}

/// Selectable chips for a list of modes.
struct ModeChips: View {
    let modes: [LightMode]
    @Binding var mode: LightMode
    var columns = 3

    var body: some View {
        SurfaceGroup(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(modes, id: \.self) { m in
                    let selected = m == mode
                    Button { mode = m } label: {
                        VStack(spacing: 4) {
                            Image(systemName: MonitorPreview.symbol(for: m)).font(.system(size: 16, weight: .medium))
                            Text(MonitorPreview.title(for: m)).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .surface(cornerRadius: 14, tint: selected ? Brand.accent.opacity(0.75) : nil, interactive: true)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

/// A few colours in a grid of colour wells, with add and remove buttons.
struct ColorListEditor: View {
    @Binding var colors: [LEDColor]
    var minCount = 1
    var maxCount = 8

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
            ForEach(colors.indices, id: \.self) { i in
                ColorPicker("", selection: Binding(
                    get: { colors.indices.contains(i) ? colors[i].swiftUIColor : .white },
                    set: { if colors.indices.contains(i) { colors[i] = LEDColor($0) } }), supportsOpacity: false)
                    .labelsHidden()
            }
            if colors.count < maxCount {
                Button { colors.append(colors.last ?? LEDColor(r: 255, g: 255, b: 255)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).frame(width: 28, height: 28).capsuleSurface(interactive: true)
                    .accessibilityLabel(tr("action.addColor"))
            }
            if colors.count > minCount {
                Button { colors.removeLast() } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).frame(width: 28, height: 28).capsuleSurface(interactive: true)
                    .accessibilityLabel(tr("action.removeColor"))
            }
        }
    }
}

/// Parameters of the animated modes.
struct AnimationCard: View {
    @Binding var settings: StreamSettings

    var body: some View {
        Card(title: MonitorPreview.title(for: settings.mode), systemImage: MonitorPreview.symbol(for: settings.mode)) {
            ValueSlider(title: tr("label.speed"), value: $settings.effect.speed, range: 0...1)
            switch settings.mode {
            case .rainbow:
                Picker(tr("label.palette"), selection: $settings.effect.palette) {
                    ForEach(PalettePreset.allCases, id: \.self) { Text(tr("palette.\($0.rawValue)")).tag($0) }
                }
                if settings.effect.palette == .custom {
                    ColorListEditor(colors: $settings.effect.colors, minCount: 2)
                }
            case .breathing:
                Toggle(tr("label.random"), isOn: $settings.effect.randomColors)
                if !settings.effect.randomColors { ColorListEditor(colors: $settings.effect.colors) }
            case .comet:
                ValueSlider(title: tr("label.size"), value: $settings.effect.cometSize, range: 0...1)
                Toggle(tr("label.rainbowComet"), isOn: $settings.effect.cometRainbow)
                if !settings.effect.cometRainbow {
                    ColorPicker(tr("label.color"), selection: Binding(
                        get: { settings.effect.cometColor.swiftUIColor },
                        set: { settings.effect.cometColor = LEDColor($0) }), supportsOpacity: false)
                }
            case .spectrumCycling:
                ValueSlider(title: tr("label.saturation"), value: $settings.effect.cyclingSaturation, range: 0...1)
            case .starryNight:
                ValueSlider(title: tr("label.density"), value: $settings.effect.starDensity, range: 0...1)
                ColorPicker(tr("label.background"), selection: Binding(
                    get: { settings.effect.starBackground.swiftUIColor },
                    set: { settings.effect.starBackground = LEDColor($0) }), supportsOpacity: false)
                Text(tr("label.colors")).font(.callout)
                ColorListEditor(colors: $settings.effect.colors)
            default:
                EmptyView()
            }
        }
    }
}
