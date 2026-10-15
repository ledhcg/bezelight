import Foundation
import BezelightAgents

/// Everything the renderer needs to draw one alert. Built from the tracker's `DisplayState` and
/// the user's settings; pure data, so rendering is a deterministic function of time.
public struct OverlaySpec: Sendable, Equatable {
    public var display: DisplayState
    public var style: EventStyle
    public var multiPattern: MultiPattern
    /// Global multiplier on every alert's brightness.
    public var overlayBrightness: Double
    /// Strip brightness floor while the alert shows.
    public var minBrightness: Double
    /// Replace flashing with slow swells (macOS "Reduce motion" or the user's own switch).
    public var reduceMotion: Bool
    public var crossfadeMs: Int
    /// A preview from the settings window: drawn in any mode, even when alerts are off.
    public var isPreview: Bool

    public init(display: DisplayState, style: EventStyle, multiPattern: MultiPattern = .none,
                overlayBrightness: Double = 1, minBrightness: Double = 0, reduceMotion: Bool = false, crossfadeMs: Int = 0,
                isPreview: Bool = false) {
        self.display = display; self.style = style; self.multiPattern = multiPattern
        self.overlayBrightness = overlayBrightness; self.minBrightness = minBrightness
        self.reduceMotion = reduceMotion; self.crossfadeMs = crossfadeMs; self.isPreview = isPreview
    }
}

public struct OverlayResult: Sendable, Equatable {
    public var frame: [LEDColor]
    public var minBrightness: Double
    public var kind: AlertKind
}

/// Draws an alert over a base frame. An alert *replaces* the lights it covers (it does not tint
/// the ambient picture), then everything outside its coverage keeps the base colours.
///
/// Time line of an alert, measured from `display.since`:
///   opening (`flourish`)  ->  hold (`hold`)  ->  ends only when the tracker stops reporting it.
public enum AgentOverlay {
    /// Longest cycle of the double-beat is never shorter than this, so it cannot flicker.
    static let minBeatPeriod = 1.2

    /// Returns nil when there is nothing to draw (no hold effect and the opening is over).
    public static func render(_ spec: OverlaySpec, now: Date, ledCount n: Int, base: [LEDColor]) -> OverlayResult? {
        guard n > 0 else { return nil }
        let t = max(0, now.timeIntervalSince(spec.display.since))
        let (flourish, hold, multi) = effective(spec)
        let opening = flourish.duration

        let amount: Double          // 0...1, uniform over the covered LEDs (unless it is a comet)
        var comet = false
        if t < opening {
            amount = flourishAmount(flourish, t)
        } else {
            guard hold.effect != .none else { return nil }
            let th = t - opening
            let waiting = spec.display.kind == .needsInput ? spec.display.waitingCount : 1
            if hold.effect == .comet {
                comet = true
                amount = hold.intensity
            } else {
                amount = holdShape(hold, th, multi, waiting: waiting) * hold.intensity
            }
        }
        let level = clamp(amount * clamp(spec.overlayBrightness))

        let range = coverage(spec.style, n)
        var frame = base.count == n ? base : [LEDColor](repeating: .black, count: n)
        let color = spec.style.color
        if comet {
            let m = range.count
            let lap = max(Sanitize.minBlinkPeriod, hold.periodSec)
            let head = fract((t - opening) / lap) * Double(m)
            let tail = max(1.0, 0.25 * Double(m))
            for i in 0..<m {
                var d = head - Double(i)
                if d < 0 { d += Double(m) }
                frame[range.lowerBound + i] = scaled(color, level * exp(-4 * d / tail))
            }
        } else {
            let c = scaled(color, level)
            for i in range { frame[i] = c }
        }
        return OverlayResult(frame: frame, minBrightness: clamp(spec.minBrightness), kind: spec.display.kind)
    }

    // MARK: effects

    /// The opening and hold actually used: with reduced motion every flash becomes a slow swell.
    static func effective(_ spec: OverlaySpec) -> (Flourish, Hold, MultiPattern) {
        var f = spec.style.flourish, h = spec.style.hold, m = spec.multiPattern
        if spec.reduceMotion {
            if f.effect != .none { f = Flourish(effect: .pulse, count: 1, periodSec: 2) }
            if h.effect == .blink || h.effect == .comet { h.effect = .breathe }
            if h.effect == .breathe { h.periodSec = max(h.periodSec, 2) }
            m = .none
        }
        return (f, h, m)
    }

    private static func flourishAmount(_ f: Flourish, _ t: Double) -> Double {
        let phase = fract(t / f.periodSec)
        switch f.effect {
        case .none: return 0
        case .blink: return phase < 0.5 ? 1 : 0
        case .pulse: return smoothBump(phase)
        case .flash: return max(0, 1 - t / 0.3)
        }
    }

    /// Shape of the hold phase in 0...1 (the intensity is applied by the caller).
    private static func holdShape(_ h: Hold, _ th: Double, _ multi: MultiPattern, waiting: Int) -> Double {
        let several = waiting >= 2
        if several && multi == .doubleBeat && h.effect != .none {
            // Two quick beats then a rest, so "more than one is waiting" feels different.
            // Start in the rest part of the cycle so the first beat never lands right on top of
            // the opening flashes (that is what keeps the total under three flashes a second).
            let p = fract(th / max(h.periodSec, minBeatPeriod) + 0.5)
            return min(1, window(p, 0.0, 0.14) + window(p, 0.22, 0.36))
        }
        var period = h.periodSec
        if several && multi == .faster { period = max(Sanitize.minBlinkPeriod, period / 2) }
        switch h.effect {
        case .none, .comet: return 0
        case .solid: return 1
        case .breathe: return 0.1 + 0.9 * (0.5 - 0.5 * cos(2 * .pi * th / period))
        case .blink: return fract(th / period) < 0.5 ? 1 : 0
        }
    }

    // MARK: helpers

    private static func coverage(_ s: EventStyle, _ n: Int) -> Range<Int> {
        let m = max(1, min(n, Int((Double(n) * Double(s.coveragePercent) / 100).rounded())))
        switch s.coverage {
        case .full: return 0..<n
        case .start: return 0..<m
        case .end: return (n - m)..<n
        }
    }

    private static func scaled(_ c: LEDColor, _ k: Double) -> LEDColor {
        func ch(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * k).rounded()))) }
        return LEDColor(r: ch(c.r), g: ch(c.g), b: ch(c.b))
    }

    private static func fract(_ x: Double) -> Double { x - floor(x) }
    private static func clamp(_ v: Double) -> Double { v.isFinite ? max(0, min(1, v)) : 0 }
    private static func smoothBump(_ p: Double) -> Double { let s = sin(.pi * p); return s * s }
    private static func window(_ p: Double, _ a: Double, _ b: Double) -> Double {
        p >= a && p < b ? smoothBump((p - a) / (b - a)) : 0
    }
}

/// Blends from the last frame shown to the next one over a short time, so a change of alert
/// (or the end of one) is not a hard cut. Starting a fresh alert is deliberately *not* faded:
/// attention should arrive at once.
public struct FrameCrossfade: Sendable {
    private var from: [LEDColor] = []
    private var start = Date.distantPast
    private var duration = 0.0
    /// The last frame handed out, i.e. what the strip shows.
    public private(set) var last: [LEDColor] = []

    public init() {}

    public mutating func begin(at now: Date, milliseconds: Int) {
        guard milliseconds > 0, !last.isEmpty else { return }
        from = last; start = now; duration = Double(milliseconds) / 1000
    }

    public func isActive(at now: Date) -> Bool { duration > 0 && now.timeIntervalSince(start) < duration }

    /// Returns `frame` blended with the frame we are fading from, and remembers the result.
    public mutating func apply(_ frame: [LEDColor], at now: Date) -> [LEDColor] {
        var out = frame
        if isActive(at: now), from.count == frame.count {
            let k = now.timeIntervalSince(start) / duration
            out = zip(from, frame).map { $0.lerped(to: $1, t: k) }
        } else if duration > 0 {
            from = []; duration = 0
        }
        last = out
        return out
    }

    public mutating func reset() { from = []; duration = 0; last = [] }
}

/// Last line of defence for photosensitive viewers: whatever the settings or the sequence of
/// alerts, the strip never brightens by 10 % or more, after having dimmed, more than three times
/// in any second (WCAG 2.3.1). A rise that would be the fourth is held back just under the
/// threshold until the second has passed.
///
/// The renderer already respects this for one alert on its own; this catches the seams between
/// alerts (an opening replayed on top of a breathing hold, one kind replacing another).
public struct FlashLimiter: Sendable {
    public static let maxPerSecond = 3
    public static let threshold = 0.1

    private var falling = true
    private var extreme = 0.0
    private var rises: [Date] = []

    public init() {}

    /// Call when an alert starts; `previous` is what the strip showed just before.
    public mutating func begin(previous: [LEDColor]?) {
        extreme = previous.map(Self.luminance) ?? 0
        falling = true
        rises.removeAll()
    }

    public mutating func filter(_ frame: [LEDColor], at now: Date) -> [LEDColor] {
        let l = Self.luminance(frame)
        rises.removeAll { now.timeIntervalSince($0) >= 1 }
        var shown = l
        if falling {
            if l < extreme { extreme = l }
            else if l - extreme >= Self.threshold {
                if rises.count >= Self.maxPerSecond {
                    shown = extreme + Self.threshold * 0.9           // held back: not a rise yet
                } else {
                    falling = false; extreme = l; rises.append(now)
                }
            }
        } else {
            if l > extreme { extreme = l }
            else if extreme - l >= Self.threshold { falling = true; extreme = l }
        }
        guard shown < l, l > 0 else { return frame }
        let k = shown / l
        return frame.map { LEDColor(r: UInt8(Double($0.r) * k), g: UInt8(Double($0.g) * k), b: UInt8(Double($0.b) * k)) }
    }

    /// Mean brightness of a frame, 0...1.
    public static func luminance(_ frame: [LEDColor]) -> Double {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(0) { $0 + Int($1.r) + Int($1.g) + Int($1.b) }
        return Double(sum) / Double(frame.count * 765)
    }
}

/// The hand-over point between the main actor (which knows the alerts) and the lighting pipeline
/// (which needs them 30 times a second). A lock-protected value, so reading it never waits.
public final class OverlayStore: @unchecked Sendable {
    private let lock = NSLock()
    private var display: DisplayState?
    private var settings = AgentAlertSettings()
    private var systemReduceMotion = false
    /// The alert for the real state, built once when something changes rather than 30 times a second.
    private var current: OverlaySpec?
    private var preview: (kind: AlertKind, waiting: Int, since: Date, until: Date)?

    public init() {}

    public func update(display: DisplayState?, settings: AgentAlertSettings) {
        lock.withLock { self.display = display; self.settings = settings; rebuild() }
    }

    public func setSystemReduceMotion(_ on: Bool) { lock.withLock { systemReduceMotion = on; rebuild() } }

    private func rebuild() {
        guard settings.enabled, let d = display else { current = nil; return }
        current = OverlaySpec(display: d, style: settings.style(for: d.kind), multiPattern: settings.multiPattern,
                              overlayBrightness: settings.overlayBrightness, minBrightness: settings.minBrightness,
                              reduceMotion: systemReduceMotion || settings.reduceFlashing, crossfadeMs: settings.crossfadeMs)
    }

    /// Plays one kind of alert on the strip for a few seconds, with the settings as they are now,
    /// so a change can be judged before it matters. Ignores "also when the lights are off".
    public func setPreview(_ kind: AlertKind?, waiting: Int = 1, seconds: TimeInterval = 5, now: Date = Date()) {
        lock.withLock { preview = kind.map { ($0, waiting, now, now.addingTimeInterval(seconds)) } }
    }

    /// The preview currently playing, if any.
    public func activePreview(now: Date = Date()) -> AlertKind? {
        lock.withLock { preview.flatMap { now < $0.until ? $0.kind : nil } }
    }

    /// What to draw right now, or nil. Called by the pipeline on every frame.
    public func spec(now: Date = Date()) -> OverlaySpec? {
        lock.withLock {
            let reduce = systemReduceMotion || settings.reduceFlashing
            if let p = preview {
                if now < p.until {
                    var style = settings.style(for: p.kind)
                    style.alertWhenLightsOff = true
                    return OverlaySpec(display: DisplayState(kind: p.kind, since: p.since, waitingCount: p.waiting, sessionCount: p.waiting),
                                       style: style, multiPattern: settings.multiPattern, overlayBrightness: settings.overlayBrightness,
                                       minBrightness: settings.minBrightness, reduceMotion: reduce, crossfadeMs: settings.crossfadeMs, isPreview: true)
                }
                preview = nil
            }
            return current
        }
    }
}
