import SwiftUI
import BezelightAgents
import BezelightCore

/// Everything configurable about one kind of alert, each choice explained under the control.
struct AgentEventEditor: View {
    @EnvironmentObject private var agents: AgentsModel
    @EnvironmentObject private var app: AppModel
    let kind: AlertKind
    @State private var expanded: Bool

    init(kind: AlertKind, expanded: Bool = false) {
        self.kind = kind
        _expanded = State(initialValue: expanded)
    }

    private var style: Binding<EventStyle> {
        Binding(get: { agents.settings.style(for: kind) }, set: { agents.settings.setStyle($0, for: kind) })
    }

    var body: some View {
        let s = style.wrappedValue
        VStack(alignment: .leading, spacing: 12) {
            header(s)
            if expanded {
                Text(tr("agents.event.\(kind.rawValue).help")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if s.isInvisible {
                    Label(tr("agents.event.invisible"), systemImage: "eye.slash").font(.caption).foregroundStyle(.orange)
                }
                colorRow
                Divider().opacity(0.4)
                openingSection(s)
                Divider().opacity(0.4)
                holdSection(s)
                Divider().opacity(0.4)
                staysSection(s)
                Divider().opacity(0.4)
                whereSection(s)
                Divider().opacity(0.4)
                lightsOffAndAgents(s)
                actions
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 22)
        .animation(nil, value: expanded)
    }

    // MARK: header

    private func header(_ s: EventStyle) -> some View {
        HStack(spacing: 12) {
            Circle().fill(s.color.swiftUIColor).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.5)))
                .opacity(s.enabled ? 1 : 0.35)
                .accessibilityHidden(true)
            Button { expanded.toggle() } label: {
                HStack {
                    Text(tr("agents.event.\(kind.rawValue)")).font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("agents.event.\(kind.rawValue)"))
            .accessibilityHint(expanded ? "" : tr("agents.event.expand"))
            Toggle(tr("agents.event.enabled"), isOn: style.enabled).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("\(tr("agents.event.\(kind.rawValue)")): \(tr("agents.event.enabled"))")
        }
    }

    // MARK: colour

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("agents.event.color")).font(.callout)
                Spacer()
                ColorPicker("", selection: Binding(get: { style.wrappedValue.color.swiftUIColor },
                                                   set: { style.wrappedValue.color = LEDColor($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(tr("agents.event.color"))
            }
            HStack(spacing: 8) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, c in
                    Button { style.wrappedValue.color = c } label: {
                        Circle().fill(c.swiftUIColor).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(style.wrappedValue.color == c ? Color.primary : Color.white.opacity(0.4), lineWidth: style.wrappedValue.color == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("agents.event.color"))
                    .accessibilityValue("R \(c.r) G \(c.g) B \(c.b)")
                }
                Spacer()
            }
        }
    }

    /// Amber, red, green, cyan, blue, violet, pink, white: readable on a dark wall, distinct by hue and brightness.
    private static let swatches: [LEDColor] = [
        LEDColor(r: 255, g: 170, b: 0), LEDColor(r: 255, g: 40, b: 40), LEDColor(r: 40, g: 220, b: 100), LEDColor(r: 0, g: 200, b: 255),
        LEDColor(r: 60, g: 90, b: 255), LEDColor(r: 160, g: 80, b: 255), LEDColor(r: 255, g: 80, b: 180), LEDColor(r: 255, g: 255, b: 255),
    ]

    // MARK: opening and hold

    private func openingSection(_ s: EventStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EffectPicker(title: tr("agents.event.opening"), value: style.flourish.effect, options: FlourishEffect.allCases, keyPrefix: "agents.flourish")
            Text(tr("agents.event.opening.help")).font(.caption).foregroundStyle(.secondary)
            if s.flourish.effect == .blink || s.flourish.effect == .pulse {
                Stepper(value: style.flourish.count, in: 1...10) {
                    HStack { Text(tr("agents.event.count")); Spacer(); Text("\(s.flourish.count)").monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                }
                PeriodSlider(title: tr("agents.event.period"), value: style.flourish.periodSec, range: Sanitize.minBlinkPeriod...3, flashes: true)
            }
        }
    }

    private func holdSection(_ s: EventStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EffectPicker(title: tr("agents.event.hold"), value: style.hold.effect, options: HoldEffect.allCases, keyPrefix: "agents.hold")
            Text(tr("agents.event.hold.help")).font(.caption).foregroundStyle(.secondary)
            if s.hold.effect != .none {
                ValueSlider(title: tr("agents.event.intensity"), value: style.hold.intensity, range: 0...1)
            }
            if [.breathe, .blink, .comet].contains(s.hold.effect) {
                PeriodSlider(title: tr("agents.event.period"), value: style.hold.periodSec, range: Sanitize.minBlinkPeriod...10, flashes: s.hold.effect == .blink)
            }
        }
    }

    // MARK: how long, where

    private func staysSection(_ s: EventStyle) -> some View {
        let options = Persistence.allCases.filter { $0 != .untilResolved || kind == .needsInput }
        return VStack(alignment: .leading, spacing: 8) {
            EffectPicker(title: tr("agents.event.stays"), value: style.persistence, options: options, keyPrefix: "agents.persist")
            if s.persistence == .timed {
                Stepper(value: style.timeoutSec, in: 1...3600, step: s.timeoutSec >= 60 ? 10 : 1) {
                    HStack { Text(tr("agents.event.timeout")); Spacer(); Text(tr("agents.event.timeout.value", s.timeoutSec)).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                }
            }
        }
    }

    private func whereSection(_ s: EventStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EffectPicker(title: tr("agents.event.coverage"), value: style.coverage, options: Coverage.allCases, keyPrefix: "agents.coverage")
            if s.coverage != .full {
                ValueSlider(title: tr("agents.event.coveragePercent"),
                            value: Binding(get: { Double(style.wrappedValue.coveragePercent) / 100 }, set: { style.wrappedValue.coveragePercent = Int(($0 * 100).rounded()) }),
                            range: 0.05...1)
            }
        }
    }

    private func lightsOffAndAgents(_ s: EventStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("agents.event.lightsOff"), isOn: style.alertWhenLightsOff).toggleStyle(.switch)
            Text(tr("agents.event.lightsOff.help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(tr("agents.event.forAgents")).font(.callout)
                Spacer()
                ForEach(AgentKind.allCases, id: \.self) { a in
                    Toggle(AgentNames.name(a), isOn: Binding(
                        get: { style.wrappedValue.allows(a) },
                        set: { style.wrappedValue.perAgent[a.rawValue] = $0 ? nil : false }))
                        .toggleStyle(.button).controlSize(.small)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button { agents.preview(kind) } label: { Label(tr("agents.event.preview"), systemImage: "play.fill") }
                .actionStyle()
            if kind == .needsInput {
                Button { agents.preview(kind, several: true) } label: { Label(tr("agents.event.previewMany"), systemImage: "play.rectangle.on.rectangle") }
                    .actionStyle()
            }
            Spacer()
            Button { agents.reset(kind) } label: { Label(tr("agents.event.reset"), systemImage: "arrow.uturn.backward") }
                .actionStyle()
        }
        .padding(.top, 2)
        .overlay(alignment: .bottomLeading) {
            if !app.running {
                Text(tr("agents.preview.needsRunning")).font(.caption2).foregroundStyle(.orange).offset(y: 18)
            }
        }
        .padding(.bottom, app.running ? 0 : 18)
    }
}

/// Names of the agents as products (not translated).
enum AgentNames {
    static func name(_ a: AgentKind) -> String {
        switch a {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

/// A menu of choices with the explanation of the chosen one underneath.
struct EffectPicker<Value: Hashable & RawRepresentable>: View where Value.RawValue == String {
    let title: String
    @Binding var value: Value
    let options: [Value]
    let keyPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: $value) {
                ForEach(options, id: \.self) { Text(tr("\(keyPrefix).\($0.rawValue)")).tag($0) }
            }
            Text(tr("\(keyPrefix).\(value.rawValue).help")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A cycle length in seconds, shown together with how often it repeats: the number that matters
/// to anyone sensitive to flashing.
struct PeriodSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var flashes = false

    var body: some View {
        let loc = Locale(identifier: Localizer.resolved.rawValue)
        return ValueSlider(title: title, value: $value, range: range, format: { v in
            tr("agents.event.period.value", v.formatted(.number.precision(.fractionLength(2)).locale(loc)), (1 / max(v, 0.01)).formatted(.number.precision(.fractionLength(1)).locale(loc)))
        }, hint: flashes ? tr("agents.event.safety") : nil)
    }
}
