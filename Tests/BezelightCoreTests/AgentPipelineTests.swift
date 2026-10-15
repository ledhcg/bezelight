import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

/// Alerts through the real pipeline and the real wire encoding (no serial port attached).

private final class SpecBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: OverlaySpec?
    var spec: OverlaySpec? { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

private func steadySpec(_ color: LEDColor, kind: AlertKind = .needsInput, since: Date = Date(),
                        lightsOff: Bool = false, floor: Double = 0.4, coverage: Coverage = .full, percent: Int = 100) -> OverlaySpec {
    var style = AgentAlertSettings().style(for: kind)
    style.color = color; style.flourish.effect = .none
    style.hold = Hold(effect: .solid, intensity: 1, periodSec: 1.6)
    style.alertWhenLightsOff = lightsOff; style.coverage = coverage; style.coveragePercent = percent
    return OverlaySpec(display: DisplayState(kind: kind, since: since, waitingCount: 1, sessionCount: 1),
                       style: style, multiPattern: .none, overlayBrightness: 1, minBrightness: floor, reduceMotion: false, crossfadeMs: 0)
}

private func pipeline(base: LEDColor, brightness: Double = 0.8, leds: Int = 8) async -> (LightPipeline, DeviceManager) {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: leds, brightness: brightness)
    let p = LightPipeline(device: dev)
    var s = StreamSettings()
    s.mode = .staticColor; s.staticColor = base; s.saturation = 1; s.brightness = brightness; s.smoothing = 0
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [leds]))
    return (p, dev)
}

private func led(_ w: [UInt8], _ i: Int) -> (r: UInt8, g: UInt8, b: UInt8) { (w[6 + i * 3], w[7 + i * 3], w[8 + i * 3]) }
private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

@Test func withoutAlertsTheOutputIsExactlyWhatItWas() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 120, b: 255))
    try await settle()
    let before = await dev.currentPayload()
    await p.setAgentOverlay { nil }                 // a source that never has anything to say
    try await settle()
    #expect(await dev.currentPayload() == before)
    #expect(await p.snapshot().preview.allSatisfy { $0 == LEDColor(r: 0, g: 120, b: 255) })
    await p.stop()
}

@Test func anAlertIsDrawnOverTheModeAndGivesItBack() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 204))      // blue at brightness 0.8

    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    try await settle()
    var w = await dev.currentPayload()
    #expect(led(w, 0) == (204, 0, 0) && led(w, 7) == (204, 0, 0))
    #expect(await p.snapshot().preview.allSatisfy { $0 == LEDColor(r: 255, g: 0, b: 0) })

    box.spec = nil
    try await settle()
    w = await dev.currentPayload()
    #expect(led(w, 0) == (0, 0, 204) && led(w, 7) == (0, 0, 204), "the mode must come back, not stay black")
    await p.stop()
}

@Test func coverageOnlyReplacesPartOfTheStrip() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), kind: .working, coverage: .start, percent: 25)   // 2 of 8 LEDs
    try await settle()
    let w = await dev.currentPayload()
    #expect(led(w, 0) == (204, 0, 0) && led(w, 1) == (204, 0, 0))
    #expect(led(w, 2) == (0, 0, 204) && led(w, 7) == (0, 0, 204))
    await p.stop()
}

@Test func theBrightnessFloorIsAppliedThenRestored() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255), brightness: 0.2)
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 51))                    // 0.2 of 255

    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), floor: 0.6)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (153, 0, 0))                   // lifted to 0.6
    #expect(await dev.state.brightness == 0.6)

    box.spec = nil
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 51))                    // back to what the user chose
    #expect(await dev.state.brightness == 0.2)
    await p.stop()
}

@Test func changingBrightnessDuringAnAlertKeepsTheFloor() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255), brightness: 0.8)
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), floor: 0.5)
    try await settle()
    var s = StreamSettings()
    s.mode = .staticColor; s.staticColor = LEDColor(r: 0, g: 0, b: 255); s.saturation = 1; s.brightness = 0.1; s.smoothing = 0
    await p.apply(s)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (128, 0, 0))                   // 0.5 floor, not 0.1
    await p.stop()
}

@Test func lightsOffHidesAlertsUnlessTheyOptOut() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    await p.setPowered(false)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), lightsOff: false)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 0), "silent while the lights are off")

    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), lightsOff: true)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (204, 0, 0), "an error or question must still get through")

    box.spec = nil
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 0), "and the strip goes dark again afterwards")
    await p.stop()
}

@Test func theLayoutTestStillWins() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    let pattern = [LEDColor](repeating: LEDColor(r: 0, g: 255, b: 0), count: 8)
    await p.showTestPattern(pattern, seconds: 5)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 204, 0))
    await p.clearTestPattern()
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (204, 0, 0))
    await p.stop()
}

@Test func anAlertWorksOnAnAnimatedMode() async throws {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 8, brightness: 0.8)
    let p = LightPipeline(device: dev)
    var s = StreamSettings(); s.mode = .rainbow
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [8]))
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    try await settle()
    let w = await dev.currentPayload()
    #expect((0..<8).allSatisfy { led(w, $0) == (204, 0, 0) })
    await p.stop()
}

@Test func stoppingThePipelineForgetsTheAlert() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255), brightness: 0.2)
    let box = SpecBox()
    await p.setAgentOverlay({ box.spec }, inAllModes: true)
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), floor: 0.9)
    try await settle()
    await p.stop()
    #expect(await p.snapshot().status == .stopped)
    _ = dev
}


// MARK: Agents is its own mode

private func agentsPipeline(idle: LEDColor = .black, brightness: Double = 0.8, leds: Int = 8) async -> (LightPipeline, DeviceManager) {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: leds, brightness: brightness)
    let p = LightPipeline(device: dev)
    var s = StreamSettings()
    s.mode = .agents; s.agentIdleColor = idle; s.brightness = brightness; s.smoothing = 0
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [leds]))
    return (p, dev)
}

@Test func byDefaultAlertsDoNotTouchTheOtherModes() async throws {
    // The independent-mode promise: with the default setting, Screen / Music / Colors are left alone,
    // even while an agent is shouting for attention.
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }                      // default: only in Agents mode
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), lightsOff: true)
    try await settle()
    let w = await dev.currentPayload()
    let brightness = await dev.state.brightness
    #expect((0..<8).allSatisfy { led(w, $0) == (0, 0, 204) }, "the colour mode must be untouched")
    #expect(brightness == 0.8, "and so must the brightness")
    await p.stop()
}

@Test func theOtherModesStayUntouchedForAnimationsToo() async throws {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 8, brightness: 0.8)
    let p = LightPipeline(device: dev)
    var s = StreamSettings(); s.mode = .rainbow
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [8]))
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    try await settle()
    let w = await dev.currentPayload()
    #expect(!(0..<8).allSatisfy { led(w, $0) == (204, 0, 0) })
    await p.stop()
}

@Test func agentsModeIsDarkUntilSomethingHappens() async throws {
    let (p, dev) = await agentsPipeline()
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }
    try await settle()
    var w = await dev.currentPayload()
    #expect((0..<8).allSatisfy { led(w, $0) == (0, 0, 0) })

    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    try await settle()
    w = await dev.currentPayload()
    #expect((0..<8).allSatisfy { led(w, $0) == (204, 0, 0) })

    box.spec = nil
    try await settle()
    w = await dev.currentPayload()
    #expect((0..<8).allSatisfy { led(w, $0) == (0, 0, 0) }, "back to dark, not stuck on the alert")
    await p.stop()
}

@Test func agentsModeCanKeepACalmBackground() async throws {
    let (p, dev) = await agentsPipeline(idle: LEDColor(r: 0, g: 255, b: 0))
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 204, 0))

    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), kind: .working, coverage: .start, percent: 25)
    try await settle()
    let w = await dev.currentPayload()
    #expect(led(w, 0) == (204, 0, 0) && led(w, 4) == (0, 204, 0), "the alert sits on the background")

    var s = StreamSettings(); s.mode = .agents; s.agentIdleColor = LEDColor(r: 0, g: 0, b: 255); s.brightness = 0.8; s.smoothing = 0
    box.spec = nil
    await p.apply(s)
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 204), "changing the background applies live")
    await p.stop()
}

@Test func agentsModeNeedsNoScreenOrAudioAccess() async throws {
    // The status reports a capture problem before anything else (a permission refusal, a capture error),
    // so if this mode ever tried to capture on a machine without the permission, it would show here.
    func problem(_ s: PipelineStatus) -> Bool {
        switch s { case .needsPermission, .captureError: return true; default: return false }
    }
    let (p, _) = await agentsPipeline()
    try await settle()
    #expect(!problem(await p.snapshot().status))
    try await Task.sleep(for: .milliseconds(2500))             // longer than the capture retry interval
    #expect(!problem(await p.snapshot().status))
    await p.stop()
}

@Test func aPreviewIsDrawnInAnyModeEvenWhenAlertsAreConfinedToAgentsMode() async throws {
    let (p, dev) = await pipeline(base: LEDColor(r: 0, g: 0, b: 255))
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }                      // default gating
    var preview = steadySpec(LEDColor(r: 255, g: 0, b: 0))
    preview.isPreview = true
    box.spec = preview
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (204, 0, 0))
    box.spec = nil
    try await settle()
    #expect(led(await dev.currentPayload(), 0) == (0, 0, 204))
    await p.stop()
}

@Test func leavingAgentsModeEndsTheAlertAndGivesBackTheBrightness() async throws {
    let (p, dev) = await agentsPipeline(brightness: 0.2)
    let box = SpecBox()
    await p.setAgentOverlay { box.spec }
    box.spec = steadySpec(LEDColor(r: 255, g: 0, b: 0), floor: 0.6)
    try await settle()
    let during = await dev.currentPayload()
    let brightnessDuring = await dev.state.brightness
    #expect(led(during, 0) == (153, 0, 0) && brightnessDuring == 0.6)

    var s = StreamSettings()                                  // the user picks the colour mode: the agent is still shouting
    s.mode = .staticColor; s.staticColor = LEDColor(r: 0, g: 0, b: 255); s.saturation = 1; s.brightness = 0.2; s.smoothing = 0
    await p.apply(s)
    try await settle()
    let after = await dev.currentPayload()
    let brightnessAfter = await dev.state.brightness
    #expect(led(after, 0) == (0, 0, 51), "the alert must not follow the user into another mode")
    #expect(brightnessAfter == 0.2, "and the brightness must be the user's again")
    await p.stop()
}

@Test func theModeIsStoredAndNothingElseThinksItIsMusic() {
    #expect(LightMode.agents.rawValue == "agents")
    #expect(LightMode.agents.group == .agents && !LightMode.agents.isMusic && !LightMode.agents.isAnimation)
    for other in LightMode.allCases where other != .agents { #expect(other.group != .agents, "\(other)") }
    let json = try! JSONEncoder().encode(StreamSettings())
    var s = StreamSettings(); s.mode = .agents; s.agentIdleColor = LEDColor(r: 1, g: 2, b: 3)
    let back = try! JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s))
    #expect(back.mode == .agents && back.agentIdleColor == LEDColor(r: 1, g: 2, b: 3))
    // Settings written before this mode existed still load, with the strip dark when idle.
    let old = try! JSONDecoder().decode(StreamSettings.self, from: Data(#"{"mode":"screen","brightness":0.5}"#.utf8))
    #expect(old.mode == .screen && old.agentIdleColor == .black)
    #expect(!json.isEmpty)
}

@Test func theSettingDefaultsToAnIndependentMode() throws {
    #expect(AgentAlertSettings().alertsInOtherModes == false)
    var s = AgentAlertSettings(); s.alertsInOtherModes = true
    #expect(try JSONDecoder().decode(AgentAlertSettings.self, from: JSONEncoder().encode(s)).alertsInOtherModes)
    #expect(try JSONDecoder().decode(AgentAlertSettings.self, from: Data("{}".utf8)).alertsInOtherModes == false)
}
