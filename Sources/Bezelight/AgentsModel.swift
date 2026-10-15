import SwiftUI
import AppKit
import BezelightAgents
import BezelightCore

/// What the settings screen knows about one agent.
struct AgentSetup: Equatable {
    var detected = false
    var targets: [TargetStatus] = []
}

struct TargetStatus: Identifiable, Equatable {
    var target: InstallTarget
    var inspection: HookInspection
    var hasBackup: Bool
    /// Worth setting up by default: the agent was used from this folder lately.
    var recommended: Bool
    var id: String { target.id }
}

/// What was just set up, so the screen can say so, remind what to do next and offer to undo it.
struct SetupNotice: Equatable {
    var targets: [InstallTarget]
    var agents: Set<AgentKind>
}

/// Everything about agent alerts that is not drawing: the settings, the live state, installing
/// hooks, the check-up. Kept apart from `AppModel` so a session changing state redraws only the
/// views that show agents.
@MainActor
final class AgentsModel: ObservableObject {
    static let settingsKey = "agents.v1"
    static let lastEventsKey = "agents.lastEvents.v1"
    static let logLimit = 500

    @Published var settings: AgentAlertSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var snapshot = AgentSnapshot(sessions: [], display: nil, waiting: 0)
    @Published private(set) var runtime = RuntimeStatus()
    @Published private(set) var setup: [AgentKind: AgentSetup] = [:]
    @Published private(set) var checks: [DoctorCheck] = []
    @Published private(set) var checking = false
    @Published private(set) var lastEvents: [AgentKind: Date] = [:]
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var previewing: AlertKind?
    @Published private(set) var systemReduceMotion = false
    @Published private(set) var busy = false
    /// Folders waiting for the user's confirmation before anything is written.
    @Published var pendingSetup: [InstallTarget]?
    @Published private(set) var notice: SetupNotice?
    @Published var message: String?

    /// The pipeline reads alerts from here, 30 times a second, without waiting for the main actor.
    let store = OverlayStore()

    private let center: AgentCenter
    private let engine: AgentRuntime
    private let installer: HookInstaller
    private let deployer: HelperDeployer
    private let pipeline: LightPipeline
    private var consumer: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let logging = LockedFlag()
    private var started = false

    init(pipeline: LightPipeline, paths: BezelightPaths = .current(), installer: HookInstaller? = nil) {
        self.pipeline = pipeline
        let loaded = Self.loadSettings()
        settings = loaded
        center = AgentCenter(settings: loaded, presence: SystemPresence())
        engine = AgentRuntime(center: center, paths: paths)
        self.installer = installer ?? HookInstaller(paths: paths)
        deployer = HelperDeployer(paths: paths)
        lastEvents = Self.loadLastEvents()
        logging.value = loaded.diagnosticsLog
        store.update(display: nil, settings: loaded)
        applyReduceMotion()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyReduceMotion() } }
    }

    // MARK: lifecycle

    func start() async {
        guard !started else { return }
        started = true
        let store = self.store
        await pipeline.setAgentOverlay({ store.spec() }, inAllModes: settings.alertsInOtherModes)

        engine.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.runtime = status }
        }
        engine.onEvent = { [weak self] event in
            guard let self, self.logging.value else { return }
            DispatchQueue.main.async { self.record(event) }              // the main queue keeps events in order
        }
        consumer = Task { [weak self] in
            guard let updates = self?.center.updates else { return }
            for await snap in updates { await self?.apply(snap) }
        }
        if settings.enabled { await engine.start() }
        runtime = engine.currentStatus()
        refreshSetup()
        repairHelperIfNeeded()
    }

    func shutdown() async {
        previewTask?.cancel()
        store.setPreview(nil)
        consumer?.cancel()
        await refreshLastEvents()
        lastEventsSaveTask?.cancel()
        Self.saveLastEvents(lastEvents)
        await engine.stop()
        await pipeline.setAgentOverlay(nil)
        saveNow()
        started = false
    }

    // MARK: live state

    private func apply(_ snap: AgentSnapshot) async {
        snapshot = snap
        store.update(display: snap.display, settings: settings)
    }

    /// Pulls "when did each agent last speak" from the center. Events arrive far too often to follow
    /// one by one (and to write to disk), so the screen that shows it asks every few seconds.
    func refreshLastEvents() async {
        let times = await center.lastEventTimes()
        var merged = lastEvents
        for (agent, date) in times where date > (merged[agent] ?? .distantPast) { merged[agent] = date }
        guard merged != lastEvents else { return }
        lastEvents = merged
        lastEventsSaveTask?.cancel()
        lastEventsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            Self.saveLastEvents(self.lastEvents)
        }
    }
    private var lastEventsSaveTask: Task<Void, Never>?

    /// Hides the alerts showing now; the next event shows again.
    func dismissAll() {
        store.setPreview(nil)
        Task { await center.dismissAll() }
    }

    /// Plays one kind of alert on the strip for a few seconds, using the settings as they are now.
    func preview(_ kind: AlertKind, several: Bool = false) {
        store.setPreview(kind, waiting: several ? 3 : 1, seconds: 5)
        previewing = kind
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5.2))
            guard !Task.isCancelled else { return }
            self?.previewing = nil
        }
    }

    /// Symbol for the menu bar. Different shapes (not just colours) for different states.
    var menuSymbol: String? {
        guard settings.enabled, let kind = snapshot.display?.kind else { return nil }
        switch kind {
        case .needsInput: return "bell.badge.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle.fill"
        }
    }

    private func applyReduceMotion() {
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        store.setSystemReduceMotion(systemReduceMotion)
    }

    // MARK: settings

    private func settingsDidChange(from old: AgentAlertSettings) {
        guard settings != old else { return }
        var clamped = settings
        Sanitize.clamp(&clamped)
        if clamped != settings { settings = clamped; return }

        scheduleSave()
        store.update(display: snapshot.display, settings: settings)
        logging.value = settings.diagnosticsLog
        let now = settings
        Task { await center.updateSettings(now) }
        if now.alertsInOtherModes != old.alertsInOtherModes, started {
            let store = self.store
            Task { await pipeline.setAgentOverlay({ store.spec() }, inAllModes: now.alertsInOtherModes) }
        }
        if now.enabled != old.enabled {
            Task { [weak self] in
                guard let self else { return }
                if now.enabled { await engine.start(); runtime = engine.currentStatus() } else { await engine.stop(); runtime = RuntimeStatus() }
            }
        }
    }

    func reset(_ kind: AlertKind) {
        var s = settings
        s.setStyle(Self.defaultStyle(kind), for: kind)
        settings = s
    }

    func resetAll() { settings = AgentAlertSettings() }

    static func defaultStyle(_ kind: AlertKind) -> EventStyle {
        AgentAlertSettings().style(for: kind)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() { Store.save(settings, key: Self.settingsKey) }

    private static func loadSettings() -> AgentAlertSettings {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: settingsKey) else { return AgentAlertSettings() }
        if let s = try? JSONDecoder().decode(AgentAlertSettings.self, from: data) { return s }
        d.set(data, forKey: settingsKey + ".corrupt")             // keep what we could not read, then start fresh
        return AgentAlertSettings()
    }

    private static func loadLastEvents() -> [AgentKind: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastEventsKey) as? [String: Double] else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in AgentKind(rawValue: k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }

    private static func saveLastEvents(_ times: [AgentKind: Date]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: times.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }), forKey: lastEventsKey)
    }

    // MARK: installing

    /// The helper binary shipped inside the app (or next to the executable in a development build).
    nonisolated static var bundledHelper: URL? {
        let fm = FileManager.default
        let inApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bezelight-hook")
        if fm.isExecutableFile(atPath: inApp.path) { return inApp }
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bezelight-hook")
        if let beside, fm.isExecutableFile(atPath: beside.path) { return beside }
        return nil
    }

    /// Re-reads the agents' configuration. Reading and parsing several settings files is cheap but not
    /// free, so asking again within a few seconds is ignored unless something was just changed.
    func refreshSetup(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastSetupRefresh) < 5 { return }
        lastSetupRefresh = Date()
        let installer = self.installer
        Task {
            let result = await Task.detached(priority: .utility) { () -> [AgentKind: AgentSetup] in
                var out: [AgentKind: AgentSetup] = [:]
                for agent in AgentKind.allCases {
                    let recommended = Set(installer.recommended(for: agent).map(\.id))
                    let targets = installer.targets(for: agent).map {
                        TargetStatus(target: $0, inspection: installer.inspect($0), hasBackup: !installer.backups(for: $0).isEmpty,
                                     recommended: recommended.contains($0.id))
                    }
                    out[agent] = AgentSetup(detected: installer.isAgentInstalled(agent), targets: targets)
                }
                return out
            }.value
            self.setup = result
        }
    }

    /// Keeps the helper in `~/.bezelight/bin` equal to the app's copy once it has been installed.
    private func repairHelperIfNeeded() {
        guard let source = Self.bundledHelper else { return }
        let deployer = self.deployer
        Task.detached(priority: .utility) {
            let status = deployer.status(source: source)
            if status == .outdated || status == .notExecutable { _ = try? deployer.deploy(source: source) }
        }
    }

    private var lastSetupRefresh = Date.distantPast

    func install(_ target: InstallTarget) {
        run({ try self.perform(install: [target]) }, onSuccess: { self.didInstall([target]) })
    }
    func uninstall(_ target: InstallTarget) { notice = nil; run { try self.perform(uninstall: [target]) } }
    func restoreBackup(_ target: InstallTarget) { run { _ = try self.installer.restoreLatestBackup(for: target) } }

    /// The folders "Set up detected agents" would change: the recommended ones that are not set up yet.
    var pendingRecommendation: [InstallTarget] {
        [AgentKind.claude, .codex].flatMap { agent -> [InstallTarget] in
            guard setup[agent]?.detected == true else { return [] }
            return (setup[agent]?.targets ?? [])
                .filter { $0.recommended && $0.inspection.state != .installed && !isUnreadable($0.inspection.state) }.map(\.target)
        }
    }

    /// Step one of setting up: say what would change and ask. Nothing is written yet.
    func requestSetup() {
        let targets = pendingRecommendation
        if targets.isEmpty { message = tr("agents.setup.nothingToDo"); return }
        message = nil
        pendingSetup = targets
    }

    /// Step two, after the user agreed.
    func confirmSetup() {
        guard let targets = pendingSetup else { return }
        pendingSetup = nil
        run({ try self.perform(install: targets) }, onSuccess: { self.didInstall(targets) })
    }

    private func didInstall(_ targets: [InstallTarget]) {
        notice = SetupNotice(targets: targets, agents: Set(targets.map(\.agent)))
        runCheck()                                  // show at once whether it works
    }

    func dismissNotice() { notice = nil }

    /// Takes back what the last setup added (the files go back exactly as they were).
    func undoSetup() {
        guard let n = notice else { return }
        notice = nil
        run { try self.perform(uninstall: n.targets) }
    }

    func removeEverything() {
        let targets = setup.values.flatMap(\.targets).filter { $0.inspection.entries > 0 }.map(\.target)
        notice = nil
        run { try self.perform(uninstall: targets); self.deployer.remove() }
    }

    private func isUnreadable(_ s: InstallState) -> Bool { if case .unreadable = s { return true } else { return false } }

    private nonisolated func perform(install targets: [InstallTarget]) throws {
        guard let source = Self.bundledHelper else { throw InstallError.io(tr("agents.setup.noHelper")) }
        try deployer.deploy(source: source)
        for t in targets { try installer.install(t) }
    }

    private nonisolated func perform(uninstall targets: [InstallTarget]) throws {
        for t in targets { try installer.uninstall(t) }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try work(); return nil } catch { return "\(error)" }
            }.value
            self.busy = false
            if let outcome { self.message = tr("agents.setup.error", outcome) } else { onSuccess() }
            self.refreshSetup(force: true)
        }
    }

    // MARK: check-up

    func runCheck() {
        guard !checking else { return }
        checking = true
        let doctor = makeDoctor()
        Task {
            let result = await Task.detached(priority: .userInitiated) { await doctor.run() }.value
            self.checks = result
            self.checking = false
        }
    }

    private func makeDoctor() -> AgentDoctor {
        let engine = self.engine, center = self.center
        return AgentDoctor(installer: installer, deployer: deployer, helperSource: Self.bundledHelper,
                           runtime: { engine.currentStatus() }, lastEvents: { await center.lastEventTimes() })
    }

    func copyReport() {
        let report = makeDoctor().report(checks) { key, args in Self.format(key, args) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    static func format(_ key: String, _ args: [String]) -> String {
        String(format: tr(key), locale: Locale(identifier: Localizer.resolved.rawValue), arguments: args.map { $0 as CVarArg })
    }

    // MARK: event log

    private func record(_ e: AgentEvent) {
        let stamp = Self.logFormatter.string(from: Date())
        let project = e.cwd.map { ($0 as NSString).lastPathComponent } ?? "-"
        let line = "\(stamp) \(e.agent.rawValue) \(e.kind.rawValue) [\(e.src ?? "")] \(String(e.session.prefix(6))) \(project)\(e.sub != nil ? " (sub)" : "")"
        eventLog.append(line)
        if eventLog.count > Self.logLimit { eventLog.removeFirst(eventLog.count - Self.logLimit) }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(eventLog.joined(separator: "\n"), forType: .string)
    }

    func clearLog() { eventLog = [] }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
}

/// A flag that can be read from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
