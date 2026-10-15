import SwiftUI
import BezelightCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            StageBackdrop(tints: StageBackdrop.idle)
            VStack(spacing: 0) {
                // Title bar zone: the window buttons live here, so nothing scrolls under them.
                Color.clear.frame(height: 40)
                ScrollView {
                    SurfaceGroup(spacing: 14) {
                        VStack(spacing: 14) {
                            deviceCard
                            layoutCard
                            captureCard
                            generalCard
                            diagnosticsCard
                            aboutCard
                        }
                    }
                    .padding(.horizontal, 26) // room for the surfaces' edge highlight and shadow
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                .mask(edgeFade)
            }
        }
        .background(WindowStyler())
        .frame(width: 560, height: 700)
    }

    /// Fades the scrolling content out at both ends instead of cutting it with a hard edge.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }

    // MARK: device

    private var deviceCard: some View {
        Card(title: tr("section.device"), systemImage: "cable.connector") {
            HStack {
                Picker(tr("label.port"), selection: $model.selectedPort) {
                    if model.ports.isEmpty { Text("—").tag("") }
                    ForEach(model.ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
                    if !model.selectedPort.isEmpty && !model.ports.contains(model.selectedPort) {
                        Text(model.selectedPort.replacingOccurrences(of: "/dev/", with: "")).tag(model.selectedPort)
                    }
                }
                Button(tr("action.rescan")) { model.rescanPorts() }.actionStyle()
            }
            if model.ports.isEmpty {
                Text(tr("hint.noPorts")).font(.caption).foregroundStyle(.orange)
            }
            Picker(tr("label.baud"), selection: $model.baudRate) {
                ForEach([9_600, 57_600, 115_200, 230_400, 460_800, 921_600], id: \.self) { Text("\($0)").tag($0) }
            }
            DetectedDevice(live: model.live, running: model.running)
        }
    }

    private var layoutCard: some View {
        Card(title: tr("section.layout"), systemImage: "rectangle.dashed") {
            Picker(tr("label.model"), selection: $model.profile.presetID) {
                ForEach(DeviceCatalog.presets) { p in
                    Text("\(p.id) · \(tr("label.leds", p.ledCount))").tag(p.id)
                }
                Divider()
                Text(tr("label.custom")).tag(DeviceCatalog.customID)
            }
            if model.profile.presetID == DeviceCatalog.customID {
                Picker(tr("label.layoutType"), selection: $model.profile.customKind) {
                    ForEach(LayoutKind.allCases, id: \.self) { Text(tr("kind.\($0.rawValue)")).tag($0) }
                }
                ForEach(0..<model.profile.customKind.zoneCount, id: \.self) { i in
                    Stepper(value: Binding(
                        get: { model.profile.custom.indices.contains(i) ? model.profile.custom[i] : 0 },
                        set: { v in
                            var c = model.profile.custom
                            while c.count < 4 { c.append(0) }
                            c[i] = v; model.profile.custom = c
                        }), in: 0...DeviceCatalog.maxLEDs) {
                        HStack {
                            Text(segmentName(i, kind: model.profile.customKind))
                            Spacer()
                            Text("\(model.profile.custom.indices.contains(i) ? model.profile.custom[i] : 0)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.profile.kind == .strip {
                Picker(tr("label.stripEdge"), selection: $model.profile.stripEdge) {
                    ForEach(ScreenEdge.allCases, id: \.self) { Text(tr("edge.\($0.rawValue)")).tag($0) }
                }
            }
            HStack {
                Text(tr("kind.\(model.profile.kind.rawValue)")).foregroundStyle(.secondary)
                Spacer()
                Text(tr("label.leds", model.profile.ledCount)).foregroundStyle(.secondary)
            }
            .font(.callout)
            Toggle(tr("label.mirror"), isOn: $model.profile.mirrored)
            Text(tr("hint.mirror")).font(.caption).foregroundStyle(.tertiary)
            Toggle(tr("label.reverse"), isOn: $model.profile.reversed)
            Text(tr("hint.reverse")).font(.caption).foregroundStyle(.tertiary)
            Button { Task { await model.testLayout() } } label: {
                Label(tr("action.testLayout"), systemImage: "light.max")
            }
            .actionStyle()
            Text(tr("hint.testLayout")).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func segmentName(_ i: Int, kind: LayoutKind) -> String {
        let edges: [String]
        switch kind {
        case .perimeter4: edges = ["edge.left", "edge.top", "edge.right", "edge.bottom"]
        case .perimeter3: edges = ["edge.left", "edge.top", "edge.right"]
        case .sides2: edges = ["edge.left", "edge.right"]
        case .strip: return tr("label.leds", model.profile.custom.first ?? 0)
        }
        return "\(tr("label.segment", i + 1)) · \(tr(edges[min(i, edges.count - 1)]))"
    }

    private var captureCard: some View {
        Card(title: tr("section.capture"), systemImage: "display.2") {
            Picker(tr("label.display"), selection: $model.settings.displayID) {
                Text(tr("label.mainDisplay")).tag(UInt32(0))
                ForEach(model.displays) { Text("\($0.name) · \($0.width)×\($0.height)").tag($0.id) }
            }
            Button(tr("action.refresh")) { Task { await model.refreshDisplays() } }.actionStyle()
        }
    }

    private var generalCard: some View {
        Card(title: tr("section.general"), systemImage: "gearshape") {
            Picker(tr("label.language"), selection: $model.language) {
                ForEach(AppLanguage.allCases) { l in
                    Text(l.nativeName ?? tr("label.systemLanguage")).tag(l)
                }
            }
            Toggle(tr("label.autoStart"), isOn: $model.autoStart)
            Toggle(tr("label.quitOnClose"), isOn: $model.quitOnClose)
            Text(tr("hint.quitOnClose")).font(.caption).foregroundStyle(.tertiary)
            Toggle(tr("label.shortcuts"), isOn: $model.hotkeysEnabled)
            Text(tr("hint.shortcuts")).font(.caption).foregroundStyle(.tertiary)
            Toggle(tr("label.launchAtLogin"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
    }

    private var diagnosticsCard: some View {
        Card(title: tr("section.diagnostics"), systemImage: "stethoscope") {
            if model.diagnostics.isEmpty {
                Text(tr("diag.empty")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button(tr("action.refresh")) { Task { await model.refreshDiagnostics() } }.actionStyle()
        }
    }

    private var aboutCard: some View {
        Card(title: tr("section.about"), systemImage: "info.circle") {
            HStack {
                Text("Bezelight").font(.headline)
                Spacer()
                Text("\(tr("label.version")) \(Self.version)").foregroundStyle(.secondary)
            }
            Text(tr("about.description")).font(.callout)
            Text(tr("about.independent")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Link(tr("about.source"), destination: URL(string: "https://github.com/ledhcg/bezelight")!)
                Spacer()
                Text(tr("about.license")).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}


/// "Detected: SK0L27" once the controller has answered the handshake.
private struct DetectedDevice: View {
    @ObservedObject var live: LiveModel
    let running: Bool

    var body: some View {
        if running, let id = live.identity {
            Label(tr("label.detected", id.model), systemImage: DeviceCatalog.preset(id: id.model) != nil ? "checkmark.seal.fill" : "questionmark.circle")
                .font(.callout)
                .foregroundStyle(DeviceCatalog.preset(id: id.model) != nil ? Color.green : Color.orange)
            if DeviceCatalog.preset(id: id.model) == nil {
                Text(tr("label.unknownModel", id.model)).font(.caption).foregroundStyle(.secondary)
            }
        } else if running {
            Text(tr("label.noReply")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
