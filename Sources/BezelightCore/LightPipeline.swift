import Foundation

/// Everything the user can tune. Codable so the app can persist it.
public struct StreamSettings: Codable, Sendable, Equatable {
    public var mode: LightMode = .screen
    public var region: CaptureRegion = .full
    /// 0 = main display.
    public var displayID: UInt32 = 0
    public var autoLetterbox = true
    public var edgeDepth = 0.16          // sampling band depth, fraction of the screen
    public var staticColor = LEDColor(r: 0, g: 120, b: 255)
    /// What the strip shows in Agents mode while nothing needs attention (black = off).
    public var agentIdleColor = LEDColor.black
    public var brightness = 0.8
    public var saturation = 1.1
    public var gamma = 2.2
    public var smoothing = 0.35
    public var musicGain = 1.0
    public var gainR = 1.0, gainG = 1.0, gainB = 1.0 // white balance
    public var effect = EffectParams()
    public init() {}

    // Every key is optional so settings written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        mode = get(.mode, mode); region = get(.region, region); displayID = get(.displayID, displayID)
        autoLetterbox = get(.autoLetterbox, autoLetterbox); edgeDepth = get(.edgeDepth, edgeDepth)
        staticColor = get(.staticColor, staticColor); agentIdleColor = get(.agentIdleColor, agentIdleColor)
        brightness = get(.brightness, brightness)
        saturation = get(.saturation, saturation); gamma = get(.gamma, gamma)
        smoothing = get(.smoothing, smoothing); musicGain = get(.musicGain, musicGain)
        gainR = get(.gainR, gainR); gainG = get(.gainG, gainG); gainB = get(.gainB, gainB)
        effect = get(.effect, effect)
    }

    private enum Keys: String, CodingKey {
        case mode, region, displayID, autoLetterbox, edgeDepth, staticColor, agentIdleColor, brightness, saturation
        case gamma, smoothing, musicGain, gainR, gainG, gainB, effect
    }

    /// Values reset by "Reset color" (everything except mode, region, display, colour and brightness).
    public mutating func resetTuning() {
        let d = StreamSettings()
        saturation = d.saturation; gamma = d.gamma; smoothing = d.smoothing
        gainR = d.gainR; gainG = d.gainG; gainB = d.gainB
        edgeDepth = d.edgeDepth; musicGain = d.musicGain
    }
}

/// What the pipeline is doing right now. The UI turns this into a localised sentence.
public enum PipelineStatus: Sendable, Equatable {
    case stopped
    case off
    case staticColor
    case animation
    case screen(bars: CellInsets)
    case music
    /// Agents mode: the strip only reports on coding agents.
    case agents
    case needsPermission
    case captureError(String)
    case reconnecting(String)
}

/// Capture -> LED colours -> device, running off the main thread at ~30 Hz.
///
/// CPU policy: nothing runs that is not needed. Static mode stops capture entirely; Screen mode
/// skips all processing while no new frame arrived and the colours have converged; Music mode
/// only runs the FFT while audio is flowing.
public actor LightPipeline {
    public struct Snapshot: Sendable {
        public var preview: [LEDColor]
        public var status: PipelineStatus
        public var fps: Double
        public var txBytes: Int
        public var connected: Bool
        public var identity: DeviceIdentity?
    }

    private struct CaptureNeed: Equatable { var video: Bool; var audio: Bool; var display: UInt32 }

    private let device: DeviceManager
    private let capture = ScreenCaptureService()
    private var settings = StreamSettings()
    private var engine = EffectEngine()
    private var layout = LedLayout(points: [])
    private var rects: [CellRect] = []
    private var grid = [UInt8](repeating: 0, count: ScreenCaptureService.gridW * ScreenCaptureService.gridH * 4)
    private var colors: [LEDColor] = []
    private var lastGen: UInt64 = 0
    private var dirty = true
    private var task: Task<Void, Never>?
    private var activeCapture: CaptureNeed?
    private var syncing = false
    private var captureError: CaptureError?
    private var retryAt = ContinuousClock.now
    private var bars = CellInsets.zero
    private var barCandidate = CellInsets.zero
    private var barHits = 0
    private var tickCount = 0
    private var preview: [LEDColor] = []
    private var powered = true
    private var blackSent = false
    private var testFrame: [LEDColor]?
    private var testUntil = ContinuousClock.now
    // Agent alerts (see AgentOverlay): drawn over the mode's frame, only while one is active.
    private var overlaySource: (@Sendable () -> OverlaySpec?)?
    /// Alerts are drawn only in Agents mode unless this is on (or the alert is a preview).
    private var overlayInAllModes = false
    private var overlayShown = false
    private var overlayKind: AlertKind?
    private var overlayFloor = 0.0
    private var overlayFadeMs = 0
    private var lastBase: [LEDColor] = []
    private var fader = FrameCrossfade()
    private var limiter = FlashLimiter()
    /// Brightness the device was last given, so the alert's floor is only pushed when it changes.
    private var outputBrightness: Double?

    public init(device: DeviceManager) { self.device = device }

    /// Lights on/off without stopping the pipeline. Off sends black and stops capturing, so it
    /// costs next to nothing; on resumes from the current mode.
    public func setPowered(_ on: Bool) async {
        guard powered != on else { return }
        powered = on
        blackSent = false
        dirty = true
        if task != nil { await syncCapture() }
    }

    public var isPowered: Bool { powered }

    /// Shows `colors` (one per LED) for `seconds`, then returns to the current mode. Used to
    /// check how a strip is wired.
    public func showTestPattern(_ colors: [LEDColor], seconds: Double) {
        testFrame = colors
        testUntil = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        dirty = true
    }

    public func clearTestPattern() { testFrame = nil; testUntil = ContinuousClock.now; dirty = true }

    /// Where the pipeline asks, every frame, whether an agent alert should be drawn.
    /// The source must be cheap: it is called 30 times a second.
    ///
    /// By default alerts are drawn **only in Agents mode**, so Screen, Music and the colour modes are
    /// never interrupted. `inAllModes` also draws them over those modes. A preview is always drawn.
    public func setAgentOverlay(_ source: (@Sendable () -> OverlaySpec?)?, inAllModes: Bool = false) {
        overlaySource = source
        overlayInAllModes = inAllModes
        dirty = true
    }

    // MARK: control

    public func apply(_ s: StreamSettings) async {
        let old = settings
        settings = s
        pushEngineSettings()
        let level = overlayShown ? max(s.brightness, overlayFloor) : s.brightness
        await device.setOutput(brightness: level, gamma: s.gamma, gains: (s.gainR, s.gainG, s.gainB))
        outputBrightness = level
        if old.region != s.region || old.edgeDepth != s.edgeDepth || old.autoLetterbox != s.autoLetterbox {
            if !s.autoLetterbox { bars = .zero; barCandidate = .zero }
            rebuildRects()
        }
        dirty = true
        if task != nil { await syncCapture() }
    }

    public func start(layout: LedLayout) async {
        task?.cancel()
        self.layout = layout
        engine = EffectEngine()
        pushEngineSettings()
        bars = .zero; barCandidate = .zero; barHits = 0
        lastGen = 0; dirty = true; colors = []; preview = []
        resetOverlayState()
        captureError = nil; retryAt = .now
        rebuildRects()
        task = Task { [weak self] in await self?.run() }
        await syncCapture()
    }

    public func stop() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value // let an in-flight tick finish so it cannot light the LEDs after blackout
        await capture.stop()
        activeCapture = nil
        resetOverlayState()
        await device.blackout()
        await device.disconnect()
    }

    public func snapshot() async -> Snapshot {
        let st = await device.state
        let status: PipelineStatus
        if task == nil {
            status = .stopped
        } else if !powered {
            status = .off
        } else if let captureError {
            if case .permissionDenied = captureError { status = .needsPermission }
            else { status = .captureError(captureError.localizedDescription) }
        } else if !st.connected {
            status = .reconnecting(st.lastError ?? "")
        } else {
            switch settings.mode {
            case .staticColor: status = .staticColor
            case .screen: status = .screen(bars: bars)
            case .agents: status = .agents
            case _ where settings.mode.isAnimation: status = .animation
            default: status = .music
            }
        }
        return Snapshot(preview: preview, status: status, fps: st.fps, txBytes: st.txBytes, connected: st.connected, identity: st.identity)
    }

    private func pushEngineSettings() {
        // Agents mode draws its calm background like a static colour; the alerts come on top.
        engine.settings.mode = settings.mode == .agents ? .staticColor : settings.mode
        engine.settings.staticColor = settings.mode == .agents ? settings.agentIdleColor : settings.staticColor
        engine.settings.smoothing = settings.smoothing
        engine.settings.musicGain = settings.musicGain
        engine.settings.saturation = settings.saturation
        engine.settings.effect = settings.effect
    }

    // MARK: capture lifecycle

    private func desiredCapture() -> CaptureNeed? {
        guard powered else { return nil }
        switch settings.mode {
        case .screen: return CaptureNeed(video: true, audio: false, display: settings.displayID)
        case _ where settings.mode.isMusic: return CaptureNeed(video: false, audio: true, display: settings.displayID)
        default: return nil // static colour and animations need neither screen nor audio
        }
    }

    private func syncCapture() async {
        if syncing { return }
        syncing = true; defer { syncing = false }
        while true {
            // A stopped pipeline wants no capture, even if a start was in flight when it stopped.
            let want = task == nil ? nil : desiredCapture()
            if want == activeCapture { return }
            activeCapture = want
            captureError = nil
            guard let want else { await capture.stop(); continue }
            do {
                try await capture.start(video: want.video, audio: want.audio, displayID: want.display)
                if task == nil { await capture.stop() } // stopped while starting
            } catch {
                captureError = CaptureError.wrap(error)
                activeCapture = nil
                retryAt = ContinuousClock.now.advanced(by: .seconds(2))
                return
            }
        }
    }

    // MARK: loop

    private func run() async {
        let clock = ContinuousClock()
        var next = clock.now
        var last = clock.now
        while !Task.isCancelled {
            let now = clock.now
            let elapsed = now - last
            let dt = min(0.1, max(0.005, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            last = now
            await tick(dt: dt)
            next = next.advanced(by: .milliseconds(33))
            if clock.now > next.advanced(by: .milliseconds(100)) { next = clock.now } // fell behind: resync
            try? await clock.sleep(until: next, tolerance: .milliseconds(2))
        }
    }

    private func tick(dt: Double) async {
        tickCount += 1
        let n = layout.count
        guard n > 0 else { return }

        // Recover from a stopped stream (display sleep, permission re-grant, error).
        // Not while a start is in flight: the actor is re-entrant and isRunning is still false.
        if !syncing, activeCapture != nil, !capture.isRunning {
            if let msg = capture.lastError { captureError = .other(msg) }
            activeCapture = nil
            retryAt = ContinuousClock.now.advanced(by: .seconds(1))
        }
        if !syncing, activeCapture == nil, desiredCapture() != nil, ContinuousClock.now >= retryAt {
            await syncCapture()
        }

        // A layout test owns the strip until it expires.
        if let test = testFrame {
            if ContinuousClock.now < testUntil {
                if dirty { dirty = false; preview = test; await device.submit(test) }
                return
            }
            testFrame = nil; dirty = true
        }
        // Agent alerts are drawn over the mode, and (if the alert says so) even with the lights off.
        var spec = overlaySource?()
        if let s = spec, !(overlayInAllModes || settings.mode == .agents || s.isPreview) { spec = nil }
        let now = Date()
        if fader.isActive(at: now) { dirty = true } // a fade is finishing: keep the base path running

        if !powered {
            let black = [LEDColor](repeating: .black, count: n)
            if let spec, spec.style.alertWhenLightsOff,
               let r = AgentOverlay.render(spec, now: now, ledCount: n, base: black) {
                await present(r, spec, now: now)
                blackSent = false
                return
            }
            if overlayShown { await endOverlay(now: now, fade: false); blackSent = false }
            if !blackSent {
                blackSent = true
                preview = black
                await device.submit(black)
            }
            return
        }

        var frame: [LEDColor]?
        var skip = false          // nothing new to compute this tick (the original early returns)
        switch settings.mode {
        case .staticColor, .agents:
            if engine.isSettled && !dirty { skip = true }
            else { frame = engine.render(ledCount: n, screen: nil, audio: .silence, dt: dt) }
        case _ where settings.mode.isAnimation:
            frame = engine.render(ledCount: n, screen: nil, audio: .silence, dt: dt)
        case .screen:
            if let gen = capture.copyGrid(into: &grid) {
                let fresh = gen != lastGen
                if !fresh && engine.isSettled && !dirty {
                    skip = true
                } else {
                    if fresh {
                        lastGen = gen
                        if tickCount % 10 == 0 { updateBars() }
                        colors = grid.withUnsafeBufferPointer {
                            GridSampler.average(grid: $0.baseAddress!, rowBytes: ScreenCaptureService.rowBytes, rects: rects)
                        }
                    }
                    if colors.isEmpty { skip = true }
                    else { frame = engine.render(ledCount: n, screen: ScreenSample(zones: colors), audio: .silence, dt: dt) }
                }
            } else {
                skip = true
            }
        default:
            frame = engine.render(ledCount: n, screen: nil, audio: capture.audioLevel, dt: dt)
        }
        if !skip { dirty = false }
        if let frame { lastBase = frame }

        if let spec,
           let r = AgentOverlay.render(spec, now: now, ledCount: n, base: frame ?? (lastBase.count == n ? lastBase : [LEDColor](repeating: .black, count: n))) {
            await present(r, spec, now: now)
            return
        }
        if overlayShown {
            // The alert just ended: fade back to the mode on the next frames.
            await endOverlay(now: now, fade: true)
            dirty = true
            return
        }
        if skip { return }
        guard let frame else { return }
        let shown = fader.apply(frame, at: now)
        preview = shown
        await device.submit(shown)
    }

    // MARK: agent alerts

    private func present(_ r: OverlayResult, _ spec: OverlaySpec, now: Date) async {
        if overlayShown, overlayKind != r.kind { fader.begin(at: now, milliseconds: spec.crossfadeMs) }
        if !overlayShown { limiter.begin(previous: fader.last) }
        overlayKind = r.kind
        overlayFloor = r.minBrightness
        overlayFadeMs = spec.crossfadeMs
        overlayShown = true
        await setDeviceBrightness(max(settings.brightness, r.minBrightness))
        let frame = fader.apply(limiter.filter(r.frame, at: now), at: now)
        preview = frame
        await device.submit(frame)
    }

    private func endOverlay(now: Date, fade: Bool) async {
        overlayShown = false
        overlayKind = nil
        overlayFloor = 0
        if fade { fader.begin(at: now, milliseconds: overlayFadeMs) } else { fader.reset() }
        await setDeviceBrightness(settings.brightness)
    }

    private func setDeviceBrightness(_ value: Double) async {
        let v = max(0, min(1, value))
        guard outputBrightness != v else { return }
        outputBrightness = v
        await device.setOutput(brightness: v, gamma: settings.gamma, gains: (settings.gainR, settings.gainG, settings.gainB))
    }

    private func resetOverlayState() {
        overlayShown = false; overlayKind = nil; overlayFloor = 0
        fader.reset(); lastBase = []; outputBrightness = nil
    }

    // MARK: layout

    private func baseRect() -> CellRect {
        let w = ScreenCaptureService.gridW, h = ScreenCaptureService.gridH
        switch settings.region {
        case .full: return CellRect(x0: 0, y0: 0, x1: w, y1: h)
        case .left: return CellRect(x0: 0, y0: 0, x1: w / 2, y1: h)
        case .right: return CellRect(x0: w / 2, y0: 0, x1: w, y1: h)
        case .top: return CellRect(x0: 0, y0: 0, x1: w, y1: h / 2)
        case .bottom: return CellRect(x0: 0, y0: h / 2, x1: w, y1: h)
        case .cinema:
            let c = Int((Double(h) * 0.12).rounded())
            return CellRect(x0: 0, y0: c, x1: w, y1: h - c)
        }
    }

    private func rebuildRects() {
        let w = ScreenCaptureService.gridW, h = ScreenCaptureService.gridH
        var active = baseRect()
        if settings.autoLetterbox, settings.region != .cinema {
            let barsRect = CellRect(x0: bars.left, y0: bars.top, x1: w - bars.right, y1: h - bars.bottom)
            let inter = active.intersection(barsRect)
            if inter.width >= 4, inter.height >= 4 { active = inter }
        }
        rects = layout.cellRects(gridW: w, gridH: h, depth: settings.edgeDepth, active: active)
        dirty = true
    }

    /// Letterbox/pillarbox tracking with hysteresis: bars must persist (~1.7 s) before the
    /// sampling window shrinks, but are released quickly (~0.7 s) when content reappears.
    private func updateBars() {
        guard settings.autoLetterbox, settings.region != .cinema else { return }
        let cand = grid.withUnsafeBufferPointer {
            GridSampler.blackBars(grid: $0.baseAddress!, rowBytes: ScreenCaptureService.rowBytes,
                                  width: ScreenCaptureService.gridW, height: ScreenCaptureService.gridH)
        }
        if cand == barCandidate { barHits += 1 } else { barCandidate = cand; barHits = 0 }
        guard cand != bars else { return }
        let needed = cand.isNoLargerThan(bars) ? 1 : 5
        if barHits >= needed { bars = cand; rebuildRects() }
    }
}
