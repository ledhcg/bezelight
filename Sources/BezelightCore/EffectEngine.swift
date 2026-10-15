import Foundation

/// Everything the engine needs to turn input (colour, screen, sound, time) into LED colours.
public struct EffectSettings: Sendable {
    public var mode: LightMode = .screen
    public var staticColor: LEDColor = .init(r: 0, g: 120, b: 255)
    public var smoothing: Double = 0.35 // 0 = instant, 0.95 = very slow
    public var musicGain: Double = 1.0
    public var saturation: Double = 1.0 // 1 = unchanged
    public var effect = EffectParams()
    public init() {}
}

/// Small deterministic generator, so animated effects can be tested.
struct SplitMix64: Sendable {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Pure-Swift effect engine. Reactive modes (static, screen, music) are smoothed over time;
/// animated modes run on their own clock and are written straight to the output.
public struct EffectEngine: Sendable {
    public var settings = EffectSettings()
    /// Colour per LED as Float (0...255). Float state matters: with 8-bit state a slow fade
    /// stalls as soon as the per-frame step drops below 0.5.
    private var state: [Float] = []
    private var target: [Float] = []
    /// True once the output equals the target and nothing is animating; callers can skip work.
    public private(set) var isSettled = false

    private var phase = 0.0
    private var rng = SplitMix64(seed: 0x42E2_E116)
    private var stars: [Star] = []
    private var breathIndex = -1
    private var breathColor = LEDColor(r: 255, g: 255, b: 255)

    private struct Star { var led: Int; var age: Double; var fadeIn: Double; var hold: Double; var fadeOut: Double; var color: LEDColor }

    public init() {}
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    public mutating func render(
        ledCount: Int,
        screen: ScreenSample?,
        audio: AudioLevel,
        dt: Double = 1.0 / 30
    ) -> [LEDColor]? {
        // No fresh data (e.g. screen permission denied): keep the previous frame so the LEDs
        // never go black because of a missing permission.
        if settings.mode == .screen, screen == nil {
            return state.count == ledCount * 3 ? output() : nil
        }
        if settings.mode.isAnimation {
            let frame = animate(ledCount: ledCount, dt: dt)
            state = frame.flatMap { [Float($0.r), Float($0.g), Float($0.b)] }
            isSettled = false
            return frame
        }

        let colors: [LEDColor] = switch settings.mode {
        case .staticColor: Array(repeating: settings.staticColor, count: ledCount)
        case .screen: mapScreen(screen, ledCount: ledCount)
        case .musicBass: pulse(base: .init(r: 255, g: 40, b: 120), energy: audio.bass * settings.musicGain, count: ledCount)
        case .musicMid: pulse(base: .init(r: 40, g: 200, b: 255), energy: audio.mid * settings.musicGain, count: ledCount)
        case .musicTreble: pulse(base: .init(r: 120, g: 255, b: 80), energy: audio.treble * settings.musicGain, count: ledCount)
        case .musicSpectrum: rainbow(energy: audio.peak * settings.musicGain, count: ledCount)
        case .musicEqualizer: equalizer(audio.spectrum, gain: settings.musicGain, count: ledCount)
        default: Array(repeating: .black, count: ledCount)
        }
        fillTarget(colors)

        if state.count != target.count {
            state = target
            isSettled = true
            return output()
        }
        // Time-based exponential smoothing with fast attack: the larger the change, the
        // shorter the time constant, so scene cuts and beats appear instantly while small
        // fluctuations are still smoothed. Frame-rate independent via `dt`.
        let tau = max(0, min(0.95, settings.smoothing)) * 0.4
        var maxDelta: Float = 0
        for l in 0..<ledCount {
            let i = l * 3
            let d = max(abs(target[i] - state[i]), abs(target[i + 1] - state[i + 1]), abs(target[i + 2] - state[i + 2]))
            maxDelta = max(maxDelta, d)
            let alpha: Float
            if tau < 0.001 { alpha = 1 } else {
                let tauEff = Float(tau) / (1 + d / 24)
                alpha = 1 - expf(-Float(dt) / tauEff)
            }
            for c in 0..<3 { state[i + c] += (target[i + c] - state[i + c]) * alpha }
        }
        if maxDelta < 0.5 { state = target; isSettled = true } else { isSettled = false }
        return output()
    }

    /// Last good frame (for preview when capture stalls).
    public var lastFrame: [LEDColor] { state.isEmpty ? [] : output() }

    private func output() -> [LEDColor] {
        var out = [LEDColor]()
        out.reserveCapacity(state.count / 3)
        var i = 0
        while i < state.count {
            out.append(LEDColor(r: Self.byte(state[i]), g: Self.byte(state[i + 1]), b: Self.byte(state[i + 2])))
            i += 3
        }
        return out
    }

    private static func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.isFinite ? v + 0.5 : 0))) }

    private mutating func fillTarget(_ colors: [LEDColor]) {
        if target.count != colors.count * 3 { target = [Float](repeating: 0, count: colors.count * 3) }
        let sat = Float(settings.saturation)
        // A colour the user picked explicitly (Static) must come out as picked: saturation is
        // an ambient/music enhancement, not a correction.
        let adjust = abs(sat - 1) > 0.01 && settings.mode != .staticColor
        for (k, c) in colors.enumerated() {
            var r = Float(c.r), g = Float(c.g), b = Float(c.b)
            if adjust {
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b // Rec.709 luma
                r = max(0, min(255, y + (r - y) * sat))
                g = max(0, min(255, y + (g - y) * sat))
                b = max(0, min(255, y + (b - y) * sat))
            }
            target[k * 3] = r; target[k * 3 + 1] = g; target[k * 3 + 2] = b
        }
    }

    // MARK: reactive modes

    private func mapScreen(_ s: ScreenSample?, ledCount: Int) -> [LEDColor] {
        guard let s, !s.zones.isEmpty else { return Array(repeating: .black, count: ledCount) }
        if s.zones.count == ledCount { return s.zones }
        return (0..<ledCount).map { i in
            let pos = Double(i) * Double(s.zones.count - 1) / Double(max(1, ledCount - 1))
            return s.zones[Int(pos.rounded())]
        }
    }

    private func pulse(base: LEDColor, energy: Double, count: Int) -> [LEDColor] {
        let e = max(0, min(1, energy))
        let dim = LEDColor(r: UInt8(Double(base.r) * 0.08), g: UInt8(Double(base.g) * 0.08), b: UInt8(Double(base.b) * 0.08))
        return (0..<count).map { i in
            let wave = 0.5 + 0.5 * sin(Double(i) * 0.4)
            let k = min(1, e * (0.4 + 0.6 * wave))
            return dim.lerped(to: base, t: k)
        }
    }

    private func rainbow(energy: Double, count: Int) -> [LEDColor] {
        let e = max(0, min(1, energy))
        return (0..<count).map { i in
            let h = (Double(i) / Double(max(1, count)) + e * 0.3).truncatingRemainder(dividingBy: 1)
            return Self.hsv(h: h, s: 1, v: 0.15 + 0.85 * e)
        }
    }

    /// Spectrum along the strip: each LED shows the level of "its" frequency band, hue running from
    /// blue (lows) to red (highs).
    private func equalizer(_ bands: [Float], gain: Double, count: Int) -> [LEDColor] {
        guard !bands.isEmpty else { return (0..<count).map { _ in LEDColor(r: 4, g: 4, b: 10) } }
        return (0..<count).map { i in
            let pos = Double(i) / Double(max(1, count)) * Double(bands.count)
            let b0 = min(bands.count - 1, Int(pos)), b1 = min(bands.count - 1, b0 + 1)
            let f = Float(pos - Double(b0))
            let level = max(0, min(1, Double((bands[b0] * (1 - f) + bands[b1] * f)) * gain))
            let hue = 0.66 - 0.66 * Double(i) / Double(max(1, count - 1))
            return Self.hsv(h: hue, s: 0.9, v: 0.05 + 0.95 * level)
        }
    }

    // MARK: animated modes

    private mutating func animate(ledCount n: Int, dt: Double) -> [LEDColor] {
        let p = settings.effect
        let speed = max(0, min(1, p.speed))
        switch settings.mode {
        case .spectrumCycling:
            phase = (phase + dt * (0.02 + speed * 0.4)).truncatingRemainder(dividingBy: 1)
            let c = Self.hsv(h: phase, s: max(0, min(1, p.cyclingSaturation)), v: 1)
            return Array(repeating: c, count: n)

        case .rainbow:
            phase = (phase + dt * (0.03 + speed * 0.6)).truncatingRemainder(dividingBy: 1)
            let stops = Self.palette(p.palette, custom: p.colors)
            return (0..<n).map { i in
                Self.sample(stops, at: (Double(i) / Double(max(1, n)) + phase).truncatingRemainder(dividingBy: 1))
            }

        case .breathing:
            let colors = p.colors.isEmpty ? [LEDColor(r: 255, g: 255, b: 255)] : p.colors
            phase += dt / (7 - 6 * speed) // seconds per colour: 7 (slow) ... 1 (fast)
            let idx = Int(phase)
            if idx != breathIndex {
                breathIndex = idx
                breathColor = p.randomColors ? Self.hsv(h: rng.unit(), s: 1, v: 1) : colors[idx % colors.count]
            }
            let t = phase - Double(idx)
            let env = pow(sin(.pi * t), 2) // 0 -> 1 -> 0 smoothly
            let c = LEDColor(r: UInt8(Double(breathColor.r) * env), g: UInt8(Double(breathColor.g) * env), b: UInt8(Double(breathColor.b) * env))
            return Array(repeating: c, count: n)

        case .comet:
            let lap = 9 - 8 * speed // seconds for one lap of the strip
            phase = (phase + dt / lap).truncatingRemainder(dividingBy: 1)
            let head = phase * Double(n)
            let tail = 1 + max(0, min(1, p.cometSize)) * Double(n) * 0.35
            let base = p.cometRainbow ? Self.hsv(h: phase, s: 1, v: 1) : p.cometColor
            return (0..<n).map { i in
                var d = head - Double(i)               // distance behind the head, wrapping around
                if d < 0 { d += Double(n) }
                let k = exp(-4 * d / tail)
                return LEDColor(r: UInt8(Double(base.r) * k), g: UInt8(Double(base.g) * k), b: UInt8(Double(base.b) * k))
            }

        case .starryNight:
            return starry(count: n, dt: dt, params: p)

        default:
            return Array(repeating: .black, count: n)
        }
    }

    private mutating func starry(count n: Int, dt: Double, params p: EffectParams) -> [LEDColor] {
        let pace = 0.4 + max(0, min(1, p.speed)) * 1.2 // higher = quicker twinkle
        // Spawn rate scales with strip length and density.
        var expected = max(0, min(1, p.starDensity)) * Double(n) * 0.35 * pace * dt
        while expected > 0 {
            if rng.unit() < min(1, expected) {
                let led = Int(rng.next() % UInt64(max(1, n)))
                if !stars.contains(where: { $0.led == led }) {
                    let palette = p.colors.isEmpty ? [LEDColor(r: 255, g: 255, b: 255)] : p.colors
                    stars.append(Star(led: led, age: 0, fadeIn: 0.5 / pace, hold: 0.6 / pace, fadeOut: 0.9 / pace,
                                      color: palette[Int(rng.next() % UInt64(palette.count))]))
                }
            }
            expected -= 1
        }
        var frame = Array(repeating: p.starBackground, count: n)
        stars = stars.compactMap { s0 in
            var s = s0
            s.age += dt
            let total = s.fadeIn + s.hold + s.fadeOut
            guard s.age < total, s.led < n else { return nil }
            let env: Double
            if s.age < s.fadeIn { env = s.age / s.fadeIn }
            else if s.age < s.fadeIn + s.hold { env = 1 }
            else { env = 1 - (s.age - s.fadeIn - s.hold) / s.fadeOut }
            frame[s.led] = p.starBackground.lerped(to: s.color, t: env)
            return s
        }
        return frame
    }

    // MARK: colour helpers

    static func hsv(h: Double, s: Double, v: Double) -> LEDColor {
        let hh = h - floor(h)
        let i = Int(hh * 6) % 6
        let f = hh * 6 - Double(Int(hh * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p); case 1: (q, v, p); case 2: (p, v, t)
        case 3: (p, q, v); case 4: (t, p, v); default: (v, p, q)
        }
        return LEDColor(r: UInt8(max(0, min(255, r * 255))), g: UInt8(max(0, min(255, g * 255))), b: UInt8(max(0, min(255, b * 255))))
    }

    static func palette(_ preset: PalettePreset, custom: [LEDColor]) -> [LEDColor] {
        func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> LEDColor { LEDColor(r: r, g: g, b: b) }
        switch preset {
        case .rainbow: return (0..<7).map { hsv(h: Double($0) / 6, s: 1, v: 1) }
        case .sunset: return [c(255, 94, 77), c(255, 154, 0), c(255, 206, 84), c(237, 117, 150), c(127, 76, 170), c(255, 94, 77)]
        case .ocean: return [c(0, 119, 182), c(0, 180, 216), c(144, 224, 239), c(72, 202, 228), c(2, 62, 138), c(0, 119, 182)]
        case .synthwave: return [c(255, 0, 153), c(122, 0, 255), c(0, 229, 255), c(255, 0, 153)]
        case .custom: return custom.count >= 2 ? custom + [custom[0]] : [c(255, 255, 255), c(255, 255, 255)]
        }
    }

    /// Colour at position `t` (0...1) of a gradient whose last stop equals its first.
    static func sample(_ stops: [LEDColor], at t: Double) -> LEDColor {
        guard stops.count > 1 else { return stops.first ?? .black }
        let x = t * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        return stops[i].lerped(to: stops[i + 1], t: x - Double(i))
    }
}
