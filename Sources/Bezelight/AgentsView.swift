import SwiftUI
import BezelightAgents
import BezelightCore

/// The options of the Agents mode. It sits in the right-hand column of the main window, exactly where
/// Screen, Music and Colors show theirs: Agents is a mode, not a separate place.
struct AgentsPanel: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentsModel
    @State private var confirmReset = false
    @State private var confirmRemove = false
    @State private var checkOpen = false
    @State private var advancedOpen = false
    @State private var setupOpen = false

    var body: some View {
        VStack(spacing: 14) {
            headerCard
            bannersCard
            if agents.settings.enabled {
                sessionsCard
            }
            setupCard
            if agents.settings.enabled {
                eventsSection
                generalCard
            }
            checkCard
            if agents.settings.enabled { advancedCard }
        }
        .onAppear { agents.refreshSetup() }
    }

    // MARK: header

    private var headerCard: some View {
        Card(title: tr("agents.title"), systemImage: "bell.badge") {
            Text(tr("agents.mode.explain")).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !agents.settings.enabled {
                Toggle(tr("agents.enabled"), isOn: $agents.settings.enabled).toggleStyle(.switch)
                Text(tr("agents.enabled.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if agents.settings.enabled {
                HStack {
                    Text(tr("agents.mode.idle")).font(.callout)
                    Spacer()
                    ColorPicker("", selection: Binding(get: { app.settings.agentIdleColor.swiftUIColor },
                                                       set: { app.settings.agentIdleColor = LEDColor($0) }), supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityLabel(tr("agents.mode.idle"))
                    Button(tr("agents.mode.idleOff")) { app.settings.agentIdleColor = .black }
                        .actionStyle().controlSize(.small).disabled(app.settings.agentIdleColor == .black)
                }
                Text(tr("agents.mode.idle.help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(tr("agents.mode.noPermission"), systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            }
            if let message = agents.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    // MARK: what to do next (not running, nothing connected, just set up)

    private var anyAgentConnected: Bool {
        if case .connected = agents.runtime.openCode { return true }
        return agents.setup.values.contains { $0.targets.contains { $0.inspection.state == .installed } }
    }

    private var connectedNames: String {
        var names: [String] = []
        for a in [AgentKind.claude, .codex] where agents.setup[a]?.targets.contains(where: { $0.inspection.state == .installed }) == true { names.append(AgentNames.name(a)) }
        if case .connected = agents.runtime.openCode { names.append(AgentNames.name(.opencode)) }
        return names.joined(separator: ", ")
    }

    @ViewBuilder
    private var bannersCard: some View {
        let stopped = !app.running
        let nothing = !anyAgentConnected && !agents.setup.isEmpty
        if agents.settings.enabled, stopped || nothing || agents.notice != nil {
            Card(title: nil, systemImage: nil) {
                if stopped {
                    Label(tr("agents.banner.stopped"), systemImage: "play.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await app.toggle() } } label: { Label(tr("action.start"), systemImage: "play.fill") }
                        .actionStyle(prominent: true)
                }
                if nothing, agents.notice == nil {
                    Label(tr("agents.banner.noAgent"), systemImage: "link.badge.plus").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button { agents.requestSetup() } label: { Label(tr("agents.setup.installAll"), systemImage: "wand.and.stars") }
                        .actionStyle(prominent: !stopped).disabled(agents.busy)
                }
                if let n = agents.notice { noticeContent(n) }
            }
        }
    }

    @ViewBuilder
    private func noticeContent(_ n: SetupNotice) -> some View {
        Label(tr("agents.notice.done", n.targets.count), systemImage: "checkmark.circle.fill")
            .font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        if n.agents.contains(.claude) {
            Text(tr("agents.setup.claude.restart")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if n.agents.contains(.codex) {
            Text(tr("agents.setup.codex.trust")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !app.launchAtLogin {
            Label(tr("agents.notice.openAtLogin"), systemImage: "power").font(.callout).fixedSize(horizontal: false, vertical: true)
            Button { app.setLaunchAtLogin(true) } label: { Label(tr("agents.notice.openAtLoginButton"), systemImage: "power.circle") }
                .actionStyle()
        }
        HStack {
            Button(tr("agents.notice.undo")) { agents.undoSetup() }.actionStyle().disabled(agents.busy)
            Button(tr("agents.notice.dismiss")) { agents.dismissNotice() }.actionStyle()
        }
    }

    // MARK: sessions

    private var sessionsCard: some View {
        Card(title: tr("agents.section.sessions"), systemImage: "list.bullet.rectangle") {
            if agents.snapshot.sessions.isEmpty {
                Text(tr("agents.sessions.empty")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(agents.snapshot.sessions.prefix(12)) { s in SessionRow(session: s) }
                if agents.snapshot.sessions.count > 12 {
                    Text("+\(agents.snapshot.sessions.count - 12)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { agents.dismissAll() } label: { Label(tr("agents.dismissAll"), systemImage: "bell.slash") }
                    .actionStyle()
                    .disabled(agents.snapshot.display == nil)
                Spacer()
            }
            Text(tr("agents.dismissAll.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: connecting agents

    private var setupCard: some View {
        Card(title: tr("agents.section.setup"), systemImage: "link") {
            Text(tr("agents.setup.intro")).font(.callout).fixedSize(horizontal: false, vertical: true)
            ListenerLine(status: agents.runtime.listener)
            HStack {
                Button { agents.requestSetup() } label: { Label(tr("agents.setup.installAll"), systemImage: "wand.and.stars") }
                    .actionStyle(prominent: true)
                    .disabled(agents.busy)
                if agents.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !agents.pendingRecommendation.isEmpty {
                Text(tr("agents.setup.willSetUp", agents.pendingRecommendation.map(\.label).joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if anyAgentConnected {
                DisclosureGroup(isExpanded: $setupOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach([AgentKind.claude, .codex, .opencode], id: \.self) { AgentSetupRow(agent: $0) }
                    }.padding(.top, 6)
                } label: { Label(tr("agents.setup.summary", connectedNames), systemImage: "checkmark.circle.fill").font(.callout) }
            } else {
                ForEach([AgentKind.claude, .codex, .opencode], id: \.self) { AgentSetupRow(agent: $0) }
            }
            Button(role: .destructive) { confirmRemove = true } label: { Label(tr("agents.setup.removeAll"), systemImage: "trash") }
                .actionStyle()
                .disabled(agents.busy || agents.setup.values.flatMap(\.targets).allSatisfy { $0.inspection.entries == 0 })
                .confirmationDialog(tr("agents.setup.removeAll.confirm"), isPresented: $confirmRemove) {
                    Button(tr("agents.setup.removeAll"), role: .destructive) { agents.removeEverything() }
                    Button(tr("action.cancel"), role: .cancel) {}
                }
        }
        .confirmationDialog(tr("agents.setup.confirm"),
                            isPresented: Binding(get: { agents.pendingSetup != nil }, set: { if !$0 { agents.pendingSetup = nil } }),
                            titleVisibility: .visible) {
            Button(tr("agents.setup.confirm.button")) { agents.confirmSetup() }
            Button(tr("action.cancel"), role: .cancel) { agents.pendingSetup = nil }
        } message: {
            Text(tr("agents.setup.confirm.message", (agents.pendingSetup ?? []).map(\.label).joined(separator: ", ")))
        }
    }

    // MARK: events

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("agents.section.events"), systemImage: "lightbulb.led.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            AgentEventEditor(kind: .needsInput, expanded: true)
            AgentEventEditor(kind: .error)
            AgentEventEditor(kind: .done)
            AgentEventEditor(kind: .working)
        }
    }

    // MARK: general

    private var generalCard: some View {
        Card(title: tr("agents.section.general"), systemImage: "slider.horizontal.3") {
            Toggle(tr("agents.general.inOtherModes"), isOn: $agents.settings.alertsInOtherModes).toggleStyle(.switch)
            Text(tr("agents.general.inOtherModes.help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            Toggle(tr("agents.general.presence"), isOn: $agents.settings.presence.enabled).toggleStyle(.switch)
            Text(tr("agents.general.presence.help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if agents.settings.presence.enabled {
                ValueSlider(title: tr("agents.general.activeGrace"), value: $agents.settings.presence.activeGraceSec, range: 1...60,
                            format: { tr("agents.seconds", Int($0.rounded())) }, hint: tr("agents.general.activeGrace.help"))
                ValueSlider(title: tr("agents.general.fade"), value: $agents.settings.presence.presentFadeSec, range: 1...60,
                            format: { tr("agents.seconds", Int($0.rounded())) }, hint: tr("agents.general.fade.help"))
                Toggle(tr("agents.general.useSeen"), isOn: $agents.settings.presence.useAgentSeen).toggleStyle(.switch)
                Text(tr("agents.general.useSeen.help")).font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.4)
            EffectPicker(title: tr("agents.general.multi"), value: $agents.settings.multiPattern, options: MultiPattern.allCases, keyPrefix: "agents.multi")
            Text(tr("agents.general.multi.help")).font(.caption).foregroundStyle(.secondary)
            ValueSlider(title: tr("agents.general.crossfade"),
                        value: Binding(get: { Double(agents.settings.crossfadeMs) }, set: { agents.settings.crossfadeMs = Int($0.rounded()) }),
                        range: 0...1000, format: { tr("agents.ms", Int($0.rounded())) }, hint: tr("agents.general.crossfade.help"))
            ValueSlider(title: tr("agents.general.brightness"), value: $agents.settings.overlayBrightness, range: 0...1, hint: tr("agents.general.brightness.help"))
            ValueSlider(title: tr("agents.general.minBrightness"), value: $agents.settings.minBrightness, range: 0...1, hint: tr("agents.general.minBrightness.help"))
            Divider().opacity(0.4)
            Toggle(tr("agents.general.reduceFlashing"), isOn: $agents.settings.reduceFlashing).toggleStyle(.switch)
            Text(tr("agents.general.reduceFlashing.help")).font(.caption).foregroundStyle(.secondary)
            if agents.systemReduceMotion {
                Label(tr("agents.general.reduceFlashing.system"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(tr("agents.general.hotkey"), isOn: $agents.settings.dismissHotkeyEnabled).toggleStyle(.switch)
            Text(tr("agents.general.hotkey.help")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: check

    private var checkCard: some View {
        Card(title: nil, systemImage: nil) {
            DisclosureGroup(isExpanded: $checkOpen) {
                VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { agents.runCheck() } label: { Label(agents.checking ? tr("agents.check.running") : tr("agents.check.run"), systemImage: "checkmark.shield") }
                    .actionStyle().disabled(agents.checking)
                Button { agents.copyReport() } label: { Label(tr("agents.check.copy"), systemImage: "doc.on.doc") }
                    .actionStyle().disabled(agents.checks.isEmpty)
                Spacer()
            }
            ForEach(agents.checks) { c in
                Label {
                    Text(AgentsModel.format(c.key, c.args)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.symbol(c.status)).foregroundStyle(Self.color(c.status))
                }
                .accessibilityElement(children: .combine)
            }
                }
            } label: { Label(tr("agents.section.check"), systemImage: "stethoscope").font(.headline) }
        }
    }

    private static func symbol(_ s: DoctorCheck.Status) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private static func color(_ s: DoctorCheck.Status) -> Color {
        switch s {
        case .ok: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .failed: return .red
        }
    }

    // MARK: advanced

    private var advancedCard: some View {
        Card(title: nil, systemImage: nil) {
            DisclosureGroup(isExpanded: $advancedOpen) {
                VStack(alignment: .leading, spacing: 10) {
            ValueSlider(title: tr("agents.adv.staleWorking"),
                        value: Binding(get: { Double(agents.settings.stale.workingSec) / 60 }, set: { agents.settings.stale.workingSec = Int(($0 * 60).rounded()) }),
                        range: 1...120, format: { tr("agents.minutes", Int($0.rounded())) }, hint: tr("agents.adv.staleWorking.help"))
            ValueSlider(title: tr("agents.adv.staleNeedsInput"),
                        value: Binding(get: { Double(agents.settings.stale.needsInputSec) / 60 }, set: { agents.settings.stale.needsInputSec = Int(($0 * 60).rounded()) }),
                        range: 2...240, format: { tr("agents.minutes", Int($0.rounded())) }, hint: tr("agents.adv.staleNeedsInput.help"))
            ValueSlider(title: tr("agents.adv.liveness"),
                        value: Binding(get: { Double(agents.settings.livenessIntervalSec) }, set: { agents.settings.livenessIntervalSec = Int($0.rounded()) }),
                        range: 2...60, format: { tr("agents.seconds", Int($0.rounded())) }, hint: tr("agents.adv.liveness.help"))
            ValueSlider(title: tr("agents.adv.subHold"),
                        value: Binding(get: { Double(agents.settings.subagentHoldSec) }, set: { agents.settings.subagentHoldSec = Int($0.rounded()) }),
                        range: 10...3600, format: { tr("agents.seconds", Int($0.rounded())) }, hint: tr("agents.adv.subHold.help"))
            ValueSlider(title: tr("agents.adv.confirm"),
                        value: Binding(get: { Double(agents.settings.confirmSec) }, set: { agents.settings.confirmSec = Int($0.rounded()) }),
                        range: 10...300, format: { tr("agents.seconds", Int($0.rounded())) }, hint: tr("agents.adv.confirm.help"))
            Divider().opacity(0.4)
            Toggle(tr("agents.enabled"), isOn: $agents.settings.enabled).toggleStyle(.switch)
            Text(tr("agents.enabled.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            Toggle(tr("agents.adv.log"), isOn: $agents.settings.diagnosticsLog).toggleStyle(.switch)
            Text(tr("agents.adv.log.help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if agents.settings.diagnosticsLog {
                if agents.eventLog.isEmpty {
                    Text(tr("agents.adv.log.empty")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(agents.eventLog.suffix(12).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button(tr("agents.adv.log.copy")) { agents.copyLog() }.actionStyle().disabled(agents.eventLog.isEmpty)
                    Button(tr("agents.adv.log.clear")) { agents.clearLog() }.actionStyle().disabled(agents.eventLog.isEmpty)
                }
            }
            Divider().opacity(0.4)
            Button(role: .destructive) { confirmReset = true } label: { Label(tr("agents.adv.resetAll"), systemImage: "arrow.counterclockwise") }
                .actionStyle()
                .confirmationDialog(tr("agents.adv.resetAll.confirm"), isPresented: $confirmReset) {
                    Button(tr("agents.adv.resetAll"), role: .destructive) { agents.resetAll() }
                    Button(tr("action.cancel"), role: .cancel) {}
                }
                }
            } label: { Label(tr("agents.section.advanced"), systemImage: "gearshape.2").font(.headline) }
        }
    }
}

// MARK: pieces

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project.isEmpty ? String(session.id.session.prefix(8)) : session.project).font(.callout.weight(.medium))
                Text(AgentNames.name(session.id.agent)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(tr("agents.state.\(session.state.rawValue)")).font(.callout)
                HStack(spacing: 4) {
                    if session.activeSubagents > 0 { Text(tr("agents.sessions.subagents", session.activeSubagents)) }
                    Text(session.since, style: .relative)
                        .environment(\.locale, Locale(identifier: Localizer.resolved.rawValue))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch session.state {
        case .needsInput: return "bell.badge.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle.fill"
        case .idle: return "moon.zzz"
        }
    }

    private var color: Color {
        switch session.state {
        case .needsInput: return .orange
        case .error: return .red
        case .done: return .green
        case .working: return .cyan
        case .idle: return .secondary
        }
    }
}

private struct ListenerLine: View {
    let status: RuntimeStatus.Listener

    var body: some View {
        switch status {
        case .listening: Label(tr("agents.setup.listener.listening"), systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
        case .alreadyRunning: Label(tr("agents.setup.listener.other"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .failed(let why): Label(tr("agents.setup.listener.failed", why), systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        case .stopped: Label(tr("agents.setup.listener.stopped"), systemImage: "antenna.radiowaves.left.and.right.slash").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgentSetupRow: View {
    @EnvironmentObject private var agents: AgentsModel
    let agent: AgentKind

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    var body: some View {
        let setup = agents.setup[agent] ?? AgentSetup()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: agent == .opencode ? "network" : "terminal").frame(width: 20)
                Text(AgentNames.name(agent)).font(.headline)
                Spacer()
                if !setup.detected { Text(tr("agents.setup.notFound")).font(.caption).foregroundStyle(.secondary) }
            }
            if agent == .opencode { openCode(setup) } else { hooks(setup) }
            if let when = agents.lastEvents[agent] {
                let _ = Self.relative.locale = Locale(identifier: Localizer.resolved.rawValue)
                Label(tr("agents.setup.last", Self.relative.localizedString(for: when, relativeTo: Date())), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if setup.targets.contains(where: { $0.inspection.state == .installed }) {
                Label(tr("agents.setup.noEvent"), systemImage: "clock.badge.questionmark").font(.caption).foregroundStyle(.secondary)
                Text(tr(agent == .codex ? "agents.setup.codex.trust" : "agents.setup.claude.restart"))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .task {                                   // runs only while this row is on screen
            while !Task.isCancelled {
                await agents.refreshLastEvents()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func hooks(_ setup: AgentSetup) -> some View {
        if setup.targets.isEmpty {
            Text(tr("agents.setup.state.noFolder")).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(setup.targets) { t in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.target.label).font(.callout).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(stateText(t.inspection.state)).foregroundStyle(stateColor(t.inspection.state))
                            if t.recommended { Text("· " + tr("agents.setup.recent")).foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if t.inspection.state != .installed, !isUnreadable(t.inspection.state) {
                        Button(isPartial(t.inspection.state) ? tr("agents.setup.action.repair") : tr("agents.setup.action.install")) { agents.install(t.target) }
                            .actionStyle(prominent: !isPartial(t.inspection.state)).controlSize(.small).disabled(agents.busy)
                    }
                    if t.inspection.entries > 0 {
                        Button(tr("agents.setup.action.remove")) { agents.uninstall(t.target) }.actionStyle().controlSize(.small).disabled(agents.busy)
                    }
                    if t.hasBackup {
                        Button { agents.restoreBackup(t.target) } label: { Image(systemName: "clock.arrow.circlepath") }
                            .actionStyle().controlSize(.small).disabled(agents.busy)
                            .help(tr("agents.setup.action.restore")).accessibilityLabel(tr("agents.setup.action.restore"))
                    }
                }
                if t.inspection.hooksDisabled {
                    Label(tr("agents.setup.disabled"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func openCode(_ setup: AgentSetup) -> some View {
        Text(tr("agents.setup.opencode")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        switch agents.runtime.openCode {
        case .connected(let v): Label(tr("agents.setup.opencode.state.connected", v ?? "?"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .waitingForOpenCode: Label(tr("agents.setup.opencode.state.waiting"), systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .connecting: Label(tr("agents.setup.opencode.state.connecting"), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        case .failed(let why): Label(tr("agents.setup.opencode.state.failed", why), systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        case .stopped: Label(tr("agents.setup.opencode.state.stopped"), systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func isPartial(_ s: InstallState) -> Bool { if case .partial = s { return true } else { return false } }
    private func isUnreadable(_ s: InstallState) -> Bool { if case .unreadable = s { return true } else { return false } }

    private func stateText(_ s: InstallState) -> String {
        switch s {
        case .installed: return tr("agents.setup.state.installed")
        case .notInstalled: return tr("agents.setup.state.notInstalled")
        case .partial(let missing): return tr("agents.setup.state.partial", missing.count)
        case .unreadable: return tr("agents.setup.state.unreadable")
        }
    }

    private func stateColor(_ s: InstallState) -> Color {
        switch s {
        case .installed: return .green
        case .notInstalled: return .secondary
        case .partial: return .orange
        case .unreadable: return .red
        }
    }
}
