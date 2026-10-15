import SwiftUI
import AppKit
import ServiceManagement
import BezelightCore

/// Live values refreshed ~8x/s. Kept apart from `AppModel` so a preview update redraws only the
/// views that read it, not every control in the window.
@MainActor
final class LiveModel: ObservableObject {
    @Published var colors: [LEDColor] = []
    @Published var status: PipelineStatus = .stopped
    @Published var fps = 0.0
    @Published var connected = false
    @Published var identity: DeviceIdentity?
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: persisted
    @Published var settings = StreamSettings() {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            scheduleApply()
        }
    }
    @Published var profile = DeviceProfile() {
        didSet {
            guard profile != oldValue else { return }
            scheduleSave()
            if running { scheduleLayoutRestart() }
        }
    }
    @Published var selectedPort = "" {
        didSet {
            UserDefaults.standard.set(selectedPort, forKey: "port")
            if running, oldValue != selectedPort, !oldValue.isEmpty { Task { await reconnect() } }
        }
    }
    @Published var baudRate = 115_200 {
        didSet {
            UserDefaults.standard.set(baudRate, forKey: "baud")
            if running, oldValue != baudRate { Task { await reconnect() } }
        }
    }
    @Published var autoStart = false { didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") } }
    @Published var quitOnClose = false { didSet { UserDefaults.standard.set(quitOnClose, forKey: "quitOnClose") } }
    @Published var hotkeysEnabled = true {
        didSet {
            UserDefaults.standard.set(hotkeysEnabled, forKey: "hotkeys")
            if hotkeysEnabled { hotKeys.register() } else { hotKeys.unregister() }
        }
    }
    @Published var language = AppLanguage.system {
        didSet {
            Localizer.language = language
            UserDefaults.standard.set(language.rawValue, forKey: "language")
        }
    }

    // MARK: runtime
    @Published private(set) var ports: [String] = []
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var running = false
    @Published private(set) var lightsOn = true
    @Published private(set) var launchAtLogin = false
    @Published var message: String?
    @Published private(set) var diagnostics: [String] = []
    let live = LiveModel()
    /// Alerts from Claude Code, Codex and OpenCode.
    let agents: AgentsModel

    private let device: DeviceManager
    private let pipeline: LightPipeline
    private let frameLog = FrameLog()
    private let hotKeys = HotKeys()
    private var loop: Task<Void, Never>?
    private var chain: Task<Void, Never> = Task {}
    private var activity: NSObjectProtocol?
    private var resumeAfterWake = false
    private var saveTask: Task<Void, Never>?
    private var applyPending = false, applying = false
    private var layoutPending = false, layoutQueued = false

    init() {
        let dev = DeviceManager()
        device = dev
        pipeline = LightPipeline(device: dev)
        agents = AgentsModel(pipeline: pipeline)
        let d = UserDefaults.standard
        if let s: StreamSettings = Store.load(key: Store.settingsKey) { settings = s }
        if let p: DeviceProfile = Store.load(key: Store.profileKey) { profile = p }
        selectedPort = d.string(forKey: "port") ?? ""
        baudRate = d.object(forKey: "baud") as? Int ?? 115_200
        autoStart = d.bool(forKey: "autoStart")
        quitOnClose = d.bool(forKey: "quitOnClose")
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        Localizer.language = language
        launchAtLogin = SMAppService.mainApp.status == .enabled
        observeSleepAndWake()
        hotKeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeysEnabled = d.object(forKey: "hotkeys") as? Bool ?? true
        if hotkeysEnabled { hotKeys.register() }

        Task {
            await dev.setLog(frameLog)
            await dev.setButtonHandler { [weak self] in Task { @MainActor in self?.toggleLights() } }
            await agents.start()
            rescanPorts()
            await refreshDisplays()
            if autoStart, !selectedPort.isEmpty, ports.contains(selectedPort) { await start() }
        }
        startLoop()
    }

    // MARK: start / stop (serialised)

    /// Runs `work` after every earlier start/stop/restart has finished, so two requests (button,
    /// Space key, menu bar, wake-up) can never interleave.
    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = chain
        let t = Task { @MainActor in
            await previous.value
            await work()
        }
        chain = t
        await t.value
    }

    func toggle() async {
        await serialized { [self] in
            resumeAfterWake = false
            running ? await stopNow() : await startNow()
        }
    }

    func start() async {
        await serialized { [self] in if !running { await startNow() } }
    }

    func stop() async {
        await serialized { [self] in
            resumeAfterWake = false
            if running { await stopNow() }
        }
    }

    /// Always stops the pipeline (even mid-start) and flushes settings. Used when the app quits.
    func shutdown() async {
        await serialized { [self] in
            resumeAfterWake = false
            saveNow()
            await agents.shutdown()
            await stopNow()
        }
    }

    private func startNow() async {
        message = nil
        guard !selectedPort.isEmpty else { message = tr("msg.noPort"); return }
        var p = profile
        await device.configure(portPath: selectedPort, baudRate: baudRate, ledCount: p.ledCount, brightness: settings.brightness)
        await device.connect()
        let st = await device.state
        guard st.connected else {
            var text = tr("msg.connectFailed", st.lastError ?? "?")
            if (st.lastError ?? "").localizedCaseInsensitiveContains("busy") { text += "\n" + tr("hint.busy") }
            message = text
            return
        }
        // The controller said what it is: use its layout unless the user built a custom one.
        live.identity = st.identity
        if let model = st.identity?.model, DeviceCatalog.preset(id: model) != nil, profile.presetID != model,
           profile.presetID != DeviceCatalog.customID {
            profile.presetID = model
            p = profile
            await device.configure(portPath: selectedPort, baudRate: baudRate, ledCount: p.ledCount, brightness: settings.brightness)
        }
        await pipeline.apply(settings)
        await pipeline.setPowered(lightsOn)
        await pipeline.start(layout: p.layout)
        running = true
        // Keep timers precise even with the window closed (App Nap would coalesce them).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Streaming LED colors")
        await pollOnce()
    }

    private func stopNow() async {
        running = false
        lightsOn = true
        await pipeline.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        live.status = .stopped
        live.identity = nil
        live.connected = false
        live.fps = 0
        live.colors = []
    }

    /// Port or baud rate changed while running.
    private func reconnect() async {
        await serialized { [self] in
            guard running else { return }
            await stopNow()
            await startNow()
        }
    }

    // MARK: coalesced work

    /// Many slider ticks collapse into one apply of the newest settings.
    private func scheduleApply() {
        applyPending = true
        guard !applying else { return }
        applying = true
        Task { [self] in
            while applyPending {
                applyPending = false
                await pipeline.apply(settings)
            }
            applying = false
        }
    }

    private func scheduleLayoutRestart() {
        layoutPending = true
        guard !layoutQueued else { return }
        layoutQueued = true
        Task { [self] in
            await serialized { [self] in
                layoutQueued = false
                guard running, layoutPending else { return }
                layoutPending = false
                let p = profile
                await device.configure(portPath: selectedPort, baudRate: baudRate, ledCount: p.ledCount, brightness: settings.brightness)
                await pipeline.apply(settings)
                await pipeline.start(layout: p.layout)
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        Store.save(settings, key: Store.settingsKey)
        Store.save(profile, key: Store.profileKey)
    }

    // MARK: sleep / wake

    /// USB ports vanish and displays stop when the Mac sleeps: light off on the way down, then
    /// reconnect (with retries, the port takes a moment to come back) on the way up.
    private func observeSleepAndWake() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleSleep() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleWake() }
            }
        }
    }

    private func handleSleep() async {
        await serialized { [self] in
            guard running else { return }
            resumeAfterWake = true
            await stopNow()
        }
    }

    private func handleWake() async {
        guard resumeAfterWake else { return }
        for attempt in 0..<8 {
            try? await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 2))
            guard resumeAfterWake else { return } // the user took over
            await serialized { [self] in if resumeAfterWake, !running { await startNow() } }
            if running { resumeAfterWake = false; message = nil; return }
        }
    }

    // MARK: lights

    /// Lights on/off without disconnecting; also what the hot keys and the device button do.
    func setLights(_ on: Bool) {
        lightsOn = on
        Task { await pipeline.setPowered(on) }
    }

    func toggleLights() {
        if !running { Task { await start() } ; return }
        setLights(!lightsOn)
    }

    private func handle(_ action: HotKeys.Action) {
        switch action {
        case .toggle: toggleLights()
        case .on:
            if running { setLights(true) } else { lightsOn = true; Task { await start() } }
        case .off: setLights(false)
        case .brightnessUp: settings.brightness = min(1, settings.brightness + 0.1)
        case .brightnessDown: settings.brightness = max(0, settings.brightness - 0.1)
        case .dismissAlerts: if agents.settings.dismissHotkeyEnabled { agents.dismissAll() }
        }
    }

    /// Colours each wired segment differently, brightening along the wiring, so the user can check
    /// that the layout matches the strip (first segment red; the glow should travel the way it runs).
    func testLayout() async {
        await serialized { [self] in
            if !running { await startNow() }
            guard running else { return }
            let palette: [LEDColor] = [.init(r: 255, g: 0, b: 0), .init(r: 0, g: 255, b: 0), .init(r: 0, g: 0, b: 255), .init(r: 255, g: 220, b: 0)]
            var colors: [LEDColor] = []
            for (z, n) in profile.zones.enumerated() {
                for i in 0..<n {
                    let k = 0.12 + 0.88 * Double(i) / Double(max(1, n - 1))
                    let c = palette[z % palette.count]
                    colors.append(LEDColor(r: UInt8(Double(c.r) * k), g: UInt8(Double(c.g) * k), b: UInt8(Double(c.b) * k)))
                }
            }
            if profile.reversed { colors.reverse() }
            await pipeline.setPowered(true)
            await pipeline.showTestPattern(colors, seconds: 20)
        }
    }

    // MARK: misc actions

    func rescanPorts() {
        let found = SerialPort.listPorts()
        if found != ports { ports = found }
        if selectedPort.isEmpty || (!found.contains(selectedPort) && !running), let first = found.first {
            selectedPort = first
        }
    }

    func refreshDisplays() async { displays = ScreenCaptureService.availableDisplays() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshDiagnostics() async {
        let entries = await frameLog.all()
        diagnostics = entries.suffix(12).map { "\($0.direction) \($0.bytes.count)B  \(FrameLog.hex($0.bytes, maxBytes: 24))" }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: refresh loop

    private var windowVisible: Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// `colors` are only worth publishing while someone can see them: a changing preview restarts
    /// the backdrop animation every time, which keeps SwiftUI busy even for a hidden window.
    private func pollOnce(colors: Bool = true) async {
        let s = await pipeline.snapshot()
        if colors { live.colors = s.preview }
        if live.status != s.status { live.status = s.status }
        if live.fps.rounded() != s.fps.rounded() { live.fps = s.fps }
        if live.connected != s.connected { live.connected = s.connected }
        if live.identity != s.identity { live.identity = s.identity }
    }

    /// One light loop: ~8 Hz while the window is visible, 1 Hz otherwise, so status in the menu
    /// bar stays current. Hot-plug detection only runs while idle and visible.
    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                let visible = self.windowVisible
                if self.running {
                    await self.pollOnce(colors: visible)
                } else if visible, n % 16 == 0 {
                    self.rescanPorts()
                }
                n += 1
                try? await Task.sleep(for: .milliseconds(visible ? 125 : 1000))
            }
        }
    }
}

/// Small JSON-in-UserDefaults helper.
enum Store {
    static let settingsKey = "settings.v1"
    static let profileKey = "profile.v1"

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
