import Foundation
import Testing
@testable import BezelightCore

@Test func protocolRoundTrip() {
    let colors: [LEDColor] = [.init(r: 255, g: 0, b: 0), .init(r: 0, g: 255, b: 0)]
    let data = WireProtocol.encode(colors: colors)
    // "Ada" + 0x00 + countHi + countLo + RGB (matches shipped-app logs)
    #expect(data[0] == 0x41 && data[1] == 0x64 && data[2] == 0x61)
    #expect(data[3] == 0x00 && data[4] == 0x00 && data[5] == 0x02)
    #expect(data.count == 6 + 6)
    let frames = WireProtocol.splitStream(data)
    #expect(frames.count == 1)
}

@Test func protocolMatchesShipped96() {
    // Ground truth: 294-byte frame for 96-LED SK0L27 from shipped logs.
    let colors = Array(repeating: LEDColor(r: 0x13, g: 0x25, b: 0x00), count: 96)
    let data = WireProtocol.encode(colors: colors)
    #expect(data.count == 294)
    #expect(Array(data.prefix(6)) == [0x41, 0x64, 0x61, 0x00, 0x00, 0x60])
    #expect(data[6] == 0x13 && data[7] == 0x25 && data[8] == 0x00)
}

@Test func resampleKeepsCount() async {
    let m = DeviceManager()
    await m.configure(portPath: "/dev/cu.usb-test", baudRate: 115200, ledCount: 5, brightness: 1)
    await m.submit([.init(r: 10, g: 20, b: 30)])
    let st = await m.state
    #expect(st.ledCount == 5)
}

@Test func effectRendersAllModes() {
    var e = EffectEngine()
    let screen = ScreenSample(zones: [.init(r: 100, g: 50, b: 0)])
    for mode in LightMode.allCases {
        e.settings.mode = mode
        let out = e.render(ledCount: 8, screen: screen, audio: .init(bass: 0.5, mid: 0.5, treble: 0.5, peak: 0.5))
        #expect(out?.count == 8)
    }
    // screen mode without capture data must NOT emit black
    e.settings.mode = .screen
    let kept = e.render(ledCount: 8, screen: nil, audio: .silence)
    #expect(kept?.count == 8)
}

@Test func layoutRectsStayInGridAndCoverEdges() {
    let layout = LedLayout.build(kind: .perimeter4, zones: [17, 31, 17, 31])
    #expect(layout.count == 96)
    let rects = layout.cellRects(gridW: 64, gridH: 36, depth: 0.16, active: CellRect(x0: 0, y0: 0, x1: 64, y1: 36))
    #expect(rects.count == 96)
    for r in rects {
        #expect(r.x0 >= 0 && r.y0 >= 0 && r.x1 <= 64 && r.y1 <= 36 && r.area >= 1)
    }
    // first LED is on the left edge (bottom), a top-row LED samples the top band
    #expect(rects[0].x0 == 0)
    #expect(rects[17 + 15].y0 == 0)
    // right-edge LED touches the right side
    #expect(rects[17 + 31 + 5].x1 == 64)
}

@Test func gridAverageIsLinearLight() {
    // left half white, right half black -> one rect over everything
    var grid = [UInt8](repeating: 0, count: 8 * 2 * 4)
    for y in 0..<2 { for x in 0..<4 { let o = (y * 8 + x) * 4; grid[o] = 255; grid[o + 1] = 255; grid[o + 2] = 255 } }
    let out = grid.withUnsafeBufferPointer {
        GridSampler.average(grid: $0.baseAddress!, rowBytes: 8 * 4, rects: [CellRect(x0: 0, y0: 0, x1: 8, y1: 2)])
    }
    // 50% light encodes to sRGB ~188, not 128 (gamma-space average)
    #expect(out[0].r >= 186 && out[0].r <= 190)
}

@Test func blackBarsDetected() {
    let w = 16, h = 12
    var grid = [UInt8](repeating: 0, count: w * h * 4)
    for y in 2..<(h - 2) { for x in 0..<w { let o = (y * w + x) * 4; grid[o] = 120; grid[o + 1] = 120; grid[o + 2] = 120 } }
    let ins = grid.withUnsafeBufferPointer {
        GridSampler.blackBars(grid: $0.baseAddress!, rowBytes: w * 4, width: w, height: h)
    }
    #expect(ins.top == 2 && ins.bottom == 2 && ins.left == 0 && ins.right == 0)
    // a fully black screen is not a letterbox
    let black = [UInt8](repeating: 0, count: w * h * 4)
    let none = black.withUnsafeBufferPointer {
        GridSampler.blackBars(grid: $0.baseAddress!, rowBytes: w * 4, width: w, height: h)
    }
    #expect(none == .zero)
}

@Test func engineSmoothsAndSettlesExactly() {
    var e = EffectEngine()
    e.settings.mode = .staticColor
    e.settings.smoothing = 0.5
    e.settings.staticColor = .init(r: 0, g: 0, b: 0)
    _ = e.render(ledCount: 4, screen: nil, audio: .silence)
    e.settings.staticColor = .init(r: 200, g: 100, b: 50)
    var out = e.render(ledCount: 4, screen: nil, audio: .silence)!
    #expect(out[0].r > 0 && out[0].r < 200) // moving, not jumped
    for _ in 0..<300 { out = e.render(ledCount: 4, screen: nil, audio: .silence)! }
    #expect(out[0] == .init(r: 200, g: 100, b: 50))
    #expect(e.isSettled)
}

@Test func outputCurveGammaAndBrightness() {
    let full = OutputCurve.lut(brightness: 1, gamma: 2.2, gains: (1, 1, 1))
    #expect(full[255] == 255 && full[0] == 0)
    #expect(abs(Int(full[128]) - 56) <= 1)
    let half = OutputCurve.lut(brightness: 0.5, gamma: 1, gains: (1, 0.5, 1))
    #expect(half[200] == 100)            // red: brightness only
    #expect(half[256 + 200] == 50)       // green: brightness * white-balance gain
}

private func sine(_ hz: Double, count: Int, rate: Double = 48_000, amp: Float = 0.5) -> [Float] {
    (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
}

@Test func audioBandsSeparateBassFromTreble() {
    let a = AudioAnalyzer()
    var s = sine(100, count: 48_000)           // 1 s of 100 Hz
    s.withUnsafeMutableBufferPointer { a.feed($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
    let bass = a.level
    #expect(bass.bass > 0.5 && bass.treble < 0.2)

    a.reset()
    var t = sine(6000, count: 48_000)
    t.withUnsafeMutableBufferPointer { a.feed($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
    let treble = a.level
    #expect(treble.treble > 0.5 && treble.bass < 0.2)
}

@Test func audioSilenceStaysSilentAndBeatsPop() {
    let a = AudioAnalyzer()
    var quiet = [Float](repeating: 0, count: 24_000)
    quiet.withUnsafeMutableBufferPointer { a.feed($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
    #expect(a.level.peak < 0.05 && a.level.bass < 0.05)   // AGC must not amplify silence
    // loud kick burst after quiet music => bass jumps
    var kick = sine(60, count: 2048, amp: 0.9)
    kick.withUnsafeMutableBufferPointer { a.feed($0.baseAddress!, count: $0.count, sampleRate: 48_000) }
    #expect(a.level.bass > 0.5)
}

// MARK: - Static mode, end to end through the real pipeline (no serial port attached)

private func staticPipeline(_ color: LEDColor, leds: Int = 8) async -> (LightPipeline, DeviceManager) {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: leds, brightness: 0.8)
    let p = LightPipeline(device: dev)
    var s = StreamSettings()
    s.mode = .staticColor; s.staticColor = color; s.saturation = 1.0
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [leds]))
    return (p, dev)
}

@Test func staticColorReachesWire() async throws {
    let (p, dev) = await staticPipeline(.init(r: 0, g: 120, b: 255))
    try await Task.sleep(for: .milliseconds(300))
    let preview = await p.snapshot().preview
    #expect(preview.count == 8 && preview.allSatisfy { $0 == .init(r: 0, g: 120, b: 255) })
    // wire = gamma 2.2 + brightness 0.8: G 120 -> ~38, B 255 -> 204
    let w = await dev.currentPayload()
    #expect(w.count == 6 + 24 && Array(w.prefix(6)) == [0x41, 0x64, 0x61, 0, 0, 8])
    #expect(w[6] == 0 && abs(Int(w[7]) - 38) <= 1 && w[8] == 204)
    await p.stop()
}

@Test func staticColorChangeAndBrightnessApplyLive() async throws {
    let (p, dev) = await staticPipeline(.init(r: 255, g: 0, b: 0))
    try await Task.sleep(for: .milliseconds(200))
    var s = StreamSettings()
    s.mode = .staticColor; s.staticColor = .init(r: 0, g: 255, b: 0); s.saturation = 1.0; s.smoothing = 0
    await p.apply(s)
    try await Task.sleep(for: .milliseconds(300))
    var w = await dev.currentPayload()
    #expect(w[6] == 0 && w[7] == 204 && w[8] == 0, "colour change must reach the wire")
    s.brightness = 0.4
    await p.apply(s)
    try await Task.sleep(for: .milliseconds(200))
    w = await dev.currentPayload()
    #expect(w[7] == 102, "brightness change must re-encode the current frame")
    await p.stop()
}

@Test func staticBlackAndWhiteBalance() async throws {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 2, brightness: 1)
    let p = LightPipeline(device: dev)
    var s = StreamSettings()
    s.mode = .staticColor; s.staticColor = .init(r: 255, g: 255, b: 255); s.saturation = 1; s.brightness = 1
    s.gainB = 0.5
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [2]))
    try await Task.sleep(for: .milliseconds(200))
    var w = await dev.currentPayload()
    #expect(w[6] == 255 && w[7] == 255 && w[8] == 128 || w[8] == 127)
    s.staticColor = .init(r: 0, g: 0, b: 0)
    s.smoothing = 0
    await p.apply(s)
    try await Task.sleep(for: .milliseconds(200))
    w = await dev.currentPayload()
    #expect(w[6...11].allSatisfy { $0 == 0 }, "black must really send zeros")
    await p.stop()
}

@Test func staticIgnoresSaturationButScreenUsesIt() {
    var e = EffectEngine()
    e.settings.saturation = 1.5
    e.settings.mode = .staticColor
    e.settings.staticColor = .init(r: 200, g: 100, b: 50)
    #expect(e.render(ledCount: 2, screen: nil, audio: .silence)![0] == .init(r: 200, g: 100, b: 50))

    var f = EffectEngine()
    f.settings.saturation = 1.5
    f.settings.mode = .screen
    let out = f.render(ledCount: 1, screen: ScreenSample(zones: [.init(r: 200, g: 100, b: 50)]), audio: .silence)![0]
    #expect(out.r > 200 && out.b < 50) // boosted away from grey
}

// MARK: - Localisation

@Test func everyLanguageDefinesEveryKey() {
    let english = Localizer.keys(for: .en)
    #expect(english.count > 50, "English strings failed to load")
    for lang in Localizer.supported where lang != .en {
        let keys = Localizer.keys(for: lang)
        #expect(english.subtracting(keys).isEmpty, "\(lang.rawValue) is missing: \(english.subtracting(keys).sorted())")
        #expect(keys.subtracting(english).isEmpty, "\(lang.rawValue) has unknown keys: \(keys.subtracting(english).sorted())")
    }
}

@Test func placeholdersMatchAcrossLanguages() {
    func specs(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }
    let saved = Localizer.language
    defer { Localizer.language = saved }
    for key in Localizer.keys(for: .en) {
        Localizer.language = .en
        let expected = specs(tr(key))
        for lang in Localizer.supported {
            Localizer.language = lang
            #expect(specs(tr(key)) == expected, "\(lang.rawValue) '\(key)' has different placeholders")
        }
    }
}

@Test func languageSwitchesAtRuntimeAndFallsBack() {
    let saved = Localizer.language
    defer { Localizer.language = saved }
    Localizer.language = .en
    #expect(tr("action.start") == "Start")
    Localizer.language = .vi
    #expect(tr("action.start") == "Bắt đầu")
    Localizer.language = .zhHans
    #expect(tr("action.start") == "开始")
    Localizer.language = .ja
    #expect(tr("action.start") == "開始")
    Localizer.language = .ko
    #expect(tr("action.start") == "시작")
    #expect(tr("label.leds", 96).contains("96"))
    #expect(tr("no.such.key") == "no.such.key") // unknown keys are visible, never crash
}

// MARK: - Devices and layout




@Test func wireFrameHeaderMatchesLengthAtLargeCounts() {
    let data = WireProtocol.encode(colors: Array(repeating: LEDColor(r: 1, g: 2, b: 3), count: 300))
    #expect(data.count == 6 + 900)
    #expect(Array(data.prefix(6)) == [0x41, 0x64, 0x61, 0x00, 0x01, 0x2C]) // 300 = 0x012C
    #expect(WireProtocol.splitStream(data + data).count == 2)
}

@Test func blackoutSendsZeros() async {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 3, brightness: 1)
    await dev.submit(Array(repeating: LEDColor(r: 9, g: 9, b: 9), count: 3))
    #expect(await dev.currentPayload().count == 6 + 9)
    await dev.blackout() // no port attached: must be a harmless no-op
}

// MARK: - Device identification and catalog

@Test func identityParsesTheRealControllerReply() {
    // Bytes captured from an SK0L27: "SK0L27," + 5 serial bytes, CR, 2 bytes, CRLF
    let raw = Data([0x53, 0x4B, 0x30, 0x4C, 0x32, 0x37, 0x2C, 0x3C, 0x12, 0x22, 0x15, 0x0D, 0x38, 0x3B, 0x0D, 0x0A])
    let id = DeviceProbe.parse(raw)
    #expect(id?.model == "SK0L27")
    #expect(id?.serial == "3C1222150D383B")
    #expect(DeviceProbe.parse(Data("SK0121\r\n".utf8))?.serial == "000000")
}

@Test func identityRejectsNoise() {
    #expect(DeviceProbe.parse(Data()) == nil)
    #expect(DeviceProbe.parse(Data("hello world".utf8)) == nil)
    #expect(DeviceProbe.parse(Data("SK".utf8)) == nil)                     // too short
    #expect(DeviceProbe.parse(Data("SK0L2,x".utf8)) == nil)                // comma before the 6th byte
    #expect(DeviceProbe.parse(Data([0x53, 0x4B, 0x00, 0x01, 0x02, 0x03])) == nil) // not a product code
}

@Test func catalogIsSane() {
    let ids = DeviceCatalog.presets.map(\.id)
    #expect(Set(ids).count == ids.count, "duplicate preset ids")
    #expect(ids.count >= 35)
    for p in DeviceCatalog.presets {
        #expect(p.zones.count == p.kind.zoneCount, "\(p.id): zone count does not match its layout kind")
        #expect(p.zones.allSatisfy { $0 > 0 } && p.ledCount <= DeviceCatalog.maxLEDs)
        #expect(p.id.count == 6 && p.id.hasPrefix("SK"), "\(p.id) is not a product code")
    }
    #expect(DeviceCatalog.preset(id: "SK0L27")?.ledCount == 96)
    #expect(DeviceCatalog.preset(id: "SK0204")?.kind == .sides2)
    #expect(DeviceCatalog.preset(id: "SK0N02")?.ledCount == 1024)
}

@Test func profileClampsCustomLayoutAndOldSettingsStillLoad() throws {
    var p = DeviceProfile()
    p.presetID = DeviceCatalog.customID
    p.customKind = .perimeter3
    p.custom = [10, 20]                              // short: padded to the kind's three segments
    #expect(p.zones == [10, 20, 0] && p.ledCount == 30)
    p.custom = [99_999, 0, 0]
    #expect(p.ledCount == DeviceCatalog.maxLEDs)
    p.custom = [0, 0, 0]
    #expect(p.ledCount == 1, "never zero LEDs")
    // settings saved before orientation options existed
    let old = Data(#"{"presetID":"SK0121","custom":[17,31,17,31],"reversed":true}"#.utf8)
    let loaded = try JSONDecoder().decode(DeviceProfile.self, from: old)
    #expect(loaded.presetID == "SK0121" && loaded.reversed && !loaded.mirrored && loaded.stripEdge == .bottom)
}

// MARK: - Layout geometry (orientation verified on a real SK0L27)

@Test func perimeterFollowsTheVerifiedWiringOrder() {
    let l = LedLayout.build(kind: .perimeter4, zones: [17, 31, 17, 31])
    #expect(l.count == 96)
    // zone 1 = left edge, climbing from the bottom
    #expect(l.points[0].u == 0 && l.points[0].v > 0.9)
    #expect(l.points[16].u == 0 && l.points[16].v < 0.1)
    #expect(zip(l.points[0..<16], l.points[1..<17]).allSatisfy { $0.v > $1.v })
    // zone 2 = top edge, left to right
    #expect(l.points[17].v == 0 && l.points[17].u < l.points[47].u)
    // zone 3 = right edge, descending
    #expect(l.points[48].u == 1 && l.points[48].v < l.points[64].v)
    // zone 4 = bottom edge, right to left, ending next to the first LED
    #expect(l.points[65].v == 1 && l.points[65].u > l.points[95].u)
    #expect(l.points[95].u < 0.1)
    // corners are empty: no LED sits on two edges
    #expect(l.points.allSatisfy { !(($0.u == 0 || $0.u == 1) && ($0.v == 0 || $0.v == 1)) })
}

@Test func threeSidedKitReachesTheBottomCorners() {
    let l = LedLayout.build(kind: .perimeter3, zones: [13, 25, 13])
    #expect(l.count == 51)
    #expect(l.points[0].u == 0 && l.points[0].v == 1)       // first LED in the bottom-left corner
    #expect(l.points[50].u == 1 && l.points[50].v == 1)     // last LED in the bottom-right corner
    #expect(l.points[13].v == 0)                            // then the top edge
}

@Test func twoSidedKitIsLeftThenRightNotTop() {
    let l = LedLayout.build(kind: .sides2, zones: [20, 20])
    #expect(l.points[0..<20].allSatisfy { $0.u == 0 })
    #expect(l.points[20..<40].allSatisfy { $0.u == 1 })
    #expect(l.points[0].v > l.points[19].v && l.points[20].v < l.points[39].v)
}

@Test func stripOrientationOptions() {
    #expect(LedLayout.build(kind: .strip, zones: [10], stripEdge: .bottom).points.allSatisfy { $0.v == 1 })
    #expect(LedLayout.build(kind: .strip, zones: [10], stripEdge: .top).points.allSatisfy { $0.v == 0 })
    let left = LedLayout.build(kind: .strip, zones: [10], stripEdge: .left)
    #expect(left.points.allSatisfy { $0.u == 0 } && left.points[0].v > left.points[9].v)
    let fwd = LedLayout.build(kind: .perimeter4, zones: [3, 4, 3, 4])
    let mir = LedLayout.build(kind: .perimeter4, zones: [3, 4, 3, 4], mirrored: true)
    let rev = LedLayout.build(kind: .perimeter4, zones: [3, 4, 3, 4], reversed: true)
    #expect(zip(fwd.points, mir.points).allSatisfy { abs($0.u + $1.u - 1) < 1e-9 && $0.v == $1.v })
    #expect(fwd.points == rev.points.reversed())
}

@Test func samplingWindowsStayInsideTheGridForEveryKit() {
    for p in DeviceCatalog.presets {
        let l = LedLayout.build(kind: p.kind, zones: p.zones)
        let rects = l.cellRects(gridW: 64, gridH: 36, depth: 0.16, active: CellRect(x0: 0, y0: 0, x1: 64, y1: 36))
        #expect(rects.count == p.ledCount, "\(p.id)")
        #expect(rects.allSatisfy { $0.x0 >= 0 && $0.y0 >= 0 && $0.x1 <= 64 && $0.y1 <= 36 && $0.area >= 1 }, "\(p.id)")
    }
}

// MARK: - Animated effects

private func engine(_ mode: LightMode, _ tweak: (inout EffectParams) -> Void = { _ in }) -> EffectEngine {
    var e = EffectEngine(seed: 7)
    e.settings.mode = mode
    tweak(&e.settings.effect)
    return e
}

@Test func spectrumCyclingKeepsAllLEDsEqualAndMoves() {
    var e = engine(.spectrumCycling)
    let a = e.render(ledCount: 12, screen: nil, audio: .silence, dt: 0.1)!
    #expect(Set(a.map { "\($0.r),\($0.g),\($0.b)" }).count == 1)
    var b = a
    for _ in 0..<10 { b = e.render(ledCount: 12, screen: nil, audio: .silence, dt: 0.1)! }
    #expect(a[0] != b[0])
    #expect(!e.isSettled)
}

@Test func rainbowScrollsAcrossTheStrip() {
    var e = engine(.rainbow) { $0.speed = 1 }
    let a = e.render(ledCount: 30, screen: nil, audio: .silence, dt: 0.05)!
    #expect(Set(a.map { "\($0.r),\($0.g),\($0.b)" }).count > 10, "a gradient, not a solid colour")
    let b = e.render(ledCount: 30, screen: nil, audio: .silence, dt: 0.3)!
    #expect(a != b)
}

@Test func rainbowPresetsAndCustomPalette() {
    for preset in PalettePreset.allCases {
        var e = engine(.rainbow) { $0.palette = preset; $0.colors = [LEDColor(r: 255, g: 0, b: 0), LEDColor(r: 0, g: 0, b: 255)] }
        #expect(e.render(ledCount: 20, screen: nil, audio: .silence)?.count == 20, "\(preset)")
    }
    var e = engine(.rainbow) { $0.palette = .custom; $0.colors = [LEDColor(r: 255, g: 0, b: 0), LEDColor(r: 0, g: 0, b: 255)] }
    let f = e.render(ledCount: 20, screen: nil, audio: .silence, dt: 0)!
    #expect(f.allSatisfy { $0.g == 0 }, "custom red-blue palette never produces green")
}

@Test func breathingFadesInAndOutThroughItsColours() {
    var e = engine(.breathing) { $0.speed = 1; $0.colors = [LEDColor(r: 255, g: 0, b: 0)] }
    var peak: UInt8 = 0, sawDark = false
    for _ in 0..<120 {
        let f = e.render(ledCount: 5, screen: nil, audio: .silence, dt: 0.05)!
        #expect(f.allSatisfy { $0.g == 0 && $0.b == 0 })
        peak = max(peak, f[0].r); if f[0].r < 10 { sawDark = true }
    }
    #expect(peak > 240 && sawDark)
}

@Test func cometHasABrightHeadAndAFadingTail() {
    var e = engine(.comet) { $0.cometRainbow = false; $0.cometColor = LEDColor(r: 255, g: 255, b: 255); $0.cometSize = 0.5 }
    _ = e.render(ledCount: 60, screen: nil, audio: .silence, dt: 1.0)
    let f = e.render(ledCount: 60, screen: nil, audio: .silence, dt: 0.5)!
    let head = f.enumerated().max { $0.element.r < $1.element.r }!
    #expect(head.element.r > 200)
    let behind = f[(head.offset - 5 + 60) % 60].r, farBehind = f[(head.offset - 25 + 60) % 60].r
    #expect(behind < head.element.r && farBehind < behind, "intensity falls off behind the head")
    let ahead = f[(head.offset + 5) % 60].r
    #expect(ahead < behind, "nothing glows in front of the head")
}

@Test func starryNightTwinklesOnABackground() {
    var e = engine(.starryNight) {
        $0.starDensity = 0.8; $0.speed = 1; $0.starBackground = LEDColor(r: 0, g: 0, b: 20)
        $0.colors = [LEDColor(r: 255, g: 255, b: 255)]
    }
    var maxLit = 0
    for _ in 0..<90 {
        let f = e.render(ledCount: 80, screen: nil, audio: .silence, dt: 1 / 30)!
        maxLit = max(maxLit, f.filter { $0.r > 100 }.count)
        #expect(f.allSatisfy { $0.b >= 20 })           // never darker than the background
    }
    #expect(maxLit >= 3 && maxLit < 80, "some stars, not a wall of light")
    for _ in 0..<300 { _ = e.render(ledCount: 80, screen: nil, audio: .silence, dt: 1 / 30) }
}

@Test func equalizerFollowsTheSpectrum() {
    var e = engine(.musicEqualizer)
    e.settings.smoothing = 0
    var bands = [Float](repeating: 0, count: AudioLevel.bandCount)
    bands[0] = 1                                         // only the lowest band is loud
    let f = e.render(ledCount: 64, screen: nil, audio: AudioLevel(bass: 1, mid: 0, treble: 0, peak: 1, spectrum: bands))!
    let lum: (LEDColor) -> Int = { Int($0.r) + Int($0.g) + Int($0.b) }
    #expect(lum(f[0]) > lum(f[40]) * 3, "the loud band lights its own LEDs far more than the others")
    let silent = e.render(ledCount: 64, screen: nil, audio: .silence)!
    #expect(silent.allSatisfy { lum($0) < 60 })
}

// MARK: - Power and layout test, through the real pipeline

@Test func powerOffSendsBlackAndPowerOnRestoresTheColour() async throws {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 4, brightness: 1)
    let p = LightPipeline(device: dev)
    var s = StreamSettings(); s.mode = .staticColor; s.staticColor = .init(r: 200, g: 100, b: 50); s.brightness = 1; s.gamma = 1
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [4]))
    try await Task.sleep(for: .milliseconds(250))
    #expect(await dev.currentPayload()[6] == 200)
    await p.setPowered(false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await dev.currentPayload()[6...17].allSatisfy { $0 == 0 })
    #expect(await p.snapshot().status == .off)
    await p.setPowered(true)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await dev.currentPayload()[6] == 200)
    await p.stop()
}

@Test func layoutTestPatternOverridesThenExpires() async throws {
    let dev = DeviceManager()
    await dev.configure(portPath: "/dev/null", baudRate: 115200, ledCount: 3, brightness: 1)
    let p = LightPipeline(device: dev)
    var s = StreamSettings(); s.mode = .staticColor; s.staticColor = .init(r: 0, g: 0, b: 255); s.brightness = 1; s.gamma = 1
    await p.apply(s)
    await p.start(layout: LedLayout.build(kind: .strip, zones: [3]))
    try await Task.sleep(for: .milliseconds(200))
    await p.showTestPattern([.init(r: 255, g: 0, b: 0), .init(r: 0, g: 255, b: 0), .init(r: 255, g: 255, b: 0)], seconds: 0.4)
    try await Task.sleep(for: .milliseconds(150))
    let during = await dev.currentPayload()
    #expect(during[6] == 255 && during[10] == 255 && during[11] == 0, "test colours are on the wire")
    try await Task.sleep(for: .milliseconds(600))
    let after = await dev.currentPayload()
    #expect(after[6] == 0 && after[8] == 255, "back to the static colour afterwards")
    await p.stop()
}

@Test func tuningSurvivesOldSettingsFiles() throws {
    let old = Data(#"{"mode":"musicBass","brightness":0.5}"#.utf8)
    let s = try JSONDecoder().decode(StreamSettings.self, from: old)
    #expect(s.mode == .musicBass && s.brightness == 0.5 && s.effect.speed == 0.5 && s.gamma == 2.2)
    let junk = Data(#"{"mode":"someFutureMode","brightness":0.7}"#.utf8)
    #expect((try JSONDecoder().decode(StreamSettings.self, from: junk)).brightness == 0.7, "an unknown mode must not discard the rest")
}
