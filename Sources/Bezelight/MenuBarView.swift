import SwiftUI
import BezelightCore

/// Compact controls in the menu bar, so lighting can be driven without opening the window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Bezelight").font(.headline)
                Spacer()
                MenuStatus(live: model.live, running: model.running)
            }

            Button {
                Task { await model.toggle() }
            } label: {
                Label(model.running ? tr("action.stop") : tr("action.start"),
                      systemImage: model.running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PrimaryActionStyle(prominent: !model.running))

            SurfaceGroup(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("", selection: $model.settings.mode) {
                            ForEach([LightMode.Group.screen, .music, .color, .agents], id: \.self) { group in
                                Section(groupTitle(group)) {
                                    ForEach(ModePicker.modes(in: group), id: \.self) { m in
                                        Label(MonitorPreview.title(for: m), systemImage: MonitorPreview.symbol(for: m)).tag(m)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)

                        Button { model.toggleLights() } label: {
                            Image(systemName: model.lightsOn && model.running ? "lightbulb.max.fill" : "lightbulb.slash")
                                .frame(width: 22, height: 22)
                        }
                        .actionStyle()
                        .help(model.lightsOn ? tr("action.lightsOff") : tr("action.lightsOn"))
                        .accessibilityLabel(model.lightsOn ? tr("action.lightsOff") : tr("action.lightsOn"))
                    }
                    ValueSlider(title: tr("label.brightness"), value: $model.settings.brightness, range: 0...1)
                }
                .padding(14)
                .surface(cornerRadius: 18)
            }

            MenuAgents(agents: model.agents)

            HStack(spacing: 8) {
                footerButton(tr("action.open"), "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                footerButton(tr("action.settings"), "gearshape") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                footerButton(tr("action.quitShort"), "power") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(LiveBackdrop(live: model.live, layout: model.profile.layout, running: model.running))
        .background(WindowStyler(draggable: false, transparentPanel: true))
    }

    private func groupTitle(_ g: LightMode.Group) -> String {
        switch g {
        case .screen: return tr("group.screen")
        case .music: return tr("group.music")
        case .agents: return tr("group.agents")
        default: return tr("group.colors")
        }
    }

    private func footerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface(cornerRadius: 14, interactive: true)
        .accessibilityLabel(title)
    }
}

private struct MenuStatus: View {
    @ObservedObject var live: LiveModel
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live.connected && running ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(live.connected && running ? tr("status.connected") : tr("status.disconnected"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Sessions that need attention, with a one-tap way to dismiss the alerts.
private struct MenuAgents: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        let sessions = agents.snapshot.sessions.filter { $0.state != .idle }
        if agents.settings.enabled, !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(agents.snapshot.waiting > 0 ? tr("agents.menu.waiting", agents.snapshot.waiting) : tr("agents.section.sessions"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if agents.snapshot.display != nil {
                        Button { agents.dismissAll() } label: { Image(systemName: "bell.slash") }
                            .buttonStyle(.plain)
                            .help(tr("agents.dismissAll")).accessibilityLabel(tr("agents.dismissAll"))
                    }
                }
                ForEach(sessions.prefix(5)) { s in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(s.state)).frame(width: 16).foregroundStyle(color(s.state))
                        Text(s.project.isEmpty ? String(s.id.session.prefix(8)) : s.project).lineLimit(1)
                        Spacer()
                        Text(AgentNames.name(s.id.agent)).font(.caption).foregroundStyle(.secondary)
                        Text(tr("agents.state.\(s.state.rawValue)")).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
                if sessions.count > 5 { Text("+\(sessions.count - 5)").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(cornerRadius: 18)
        }
    }

    private func symbol(_ s: SessionState) -> String {
        switch s {
        case .needsInput: return "bell.badge.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle.fill"
        case .idle: return "moon.zzz"
        }
    }

    private func color(_ s: SessionState) -> Color {
        switch s {
        case .needsInput: return .orange
        case .error: return .red
        case .done: return .green
        case .working: return .cyan
        case .idle: return .secondary
        }
    }
}
