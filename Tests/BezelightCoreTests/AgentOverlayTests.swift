import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func spec(_ kind: AlertKind = .needsInput, waiting: Int = 1, style: EventStyle? = nil,
                  multi: MultiPattern = .none, reduce: Bool = false, brightness: Double = 1) -> OverlaySpec {
    OverlaySpec(display: DisplayState(kind: kind, since: t0, waitingCount: waiting, sessionCount: max(1, waiting)),
                style: style ?? AgentAlertSettings().style(for: kind), multiPattern: multi,
                overlayBrightness: brightness, minBrightness: 0.4, reduceMotion: reduce, crossfadeMs: 250)
}

private func render(_ s: OverlaySpec, at seconds: Double, leds: Int = 8, base: [LEDColor]? = nil) -> [LEDColor]? {
    AgentOverlay.render(s, now: t0.addingTimeInterval(seconds), ledCount: leds,
                        base: base ?? [LEDColor](repeating: .black, count: leds))?.frame
}

private let amber = LEDColor(r: 255, g: 170, b: 0)
private func solid(_ style: EventStyle, color: LEDColor, intensity: Double = 1) -> EventStyle {
    var s = style
    s.color = color; s.flourish.effect = .none; s.hold = Hold(effect: .solid, intensity: intensity, periodSec: 1.6)
    return s
}

// MARK: golden frames

@Test func needsInputOpeningBlinksTwiceThenBreathes() {
    let s = spec()      // amber, blink x2 with a 0.5 s cycle, then breathe (1.6 s)
    func first(_ t: Double) -> LEDColor? { render(s, at: t)?.first }
    #expect(first(0.0) == amber)                           // on
    #expect(first(0.24) == amber)
    #expect(first(0.26) == .black)                         // off half of the cycle
    #expect(first(0.5) == amber)                           // second blink
    #expect(first(0.76) == .black)
    #expect(first(1.0) == LEDColor(r: 26, g: 17, b: 0))    // hold starts at the bottom of the breath (10 %)
    #expect(first(1.0 + 0.8) == amber)                     // top of the breath
    #expect(first(1.0 + 1.6) == LEDColor(r: 26, g: 17, b: 0))
}

@Test func doneIsADimSteadyGlowAfterItsOpening() {
    let s = spec(.done)    // green, blink x2, then solid at 25 %
    let color = EventStyle.defaultDone.color
    #expect(render(s, at: 0.1)?.first == color)
    let hold = render(s, at: 5)?.first
    #expect(hold == LEDColor(r: UInt8((Double(color.r) * 0.25).rounded()), g: UInt8((Double(color.g) * 0.25).rounded()), b: UInt8((Double(color.b) * 0.25).rounded())))
    #expect(render(s, at: 600)?.first == hold)             // it never fades by itself
}

@Test func flourishShapes() {
    var style = solid(EventStyle.defaultDone, color: LEDColor(r: 200, g: 200, b: 200))
    style.hold.effect = .none
    style.flourish = Flourish(effect: .pulse, count: 1, periodSec: 1)
    let s = spec(.done, style: style)
    #expect(render(s, at: 0)?.first == .black)                                   // swells up from nothing
    #expect(render(s, at: 0.5)?.first == LEDColor(r: 200, g: 200, b: 200))       // peak
    #expect(render(s, at: 1.01) == nil)                                          // opening over, nothing to hold
    style.flourish = Flourish(effect: .flash, count: 1, periodSec: 1)
    let f = spec(.done, style: style)
    #expect(render(f, at: 0)?.first == LEDColor(r: 200, g: 200, b: 200))
    #expect((render(f, at: 0.15)?.first?.r ?? 0) < 120)                          // decays
    #expect(render(f, at: 0.31) == nil)
}

@Test func nothingToDrawWhenBothPhasesAreOff() {
    var style = EventStyle.defaultDone
    style.flourish.effect = .none; style.hold.effect = .none
    #expect(render(spec(.done, style: style), at: 0) == nil)
}

// MARK: where it draws

@Test func coverageLeavesTheRestOfTheStrip() {
    let base = [LEDColor](repeating: LEDColor(r: 1, g: 2, b: 3), count: 10)
    var style = solid(EventStyle.defaultWorking, color: LEDColor(r: 255, g: 0, b: 0))
    style.coverage = .start; style.coveragePercent = 30
    let start = render(spec(.working, style: style), at: 1, leds: 10, base: base)!
    #expect(start.prefix(3).allSatisfy { $0.r == 255 } && start.dropFirst(3).allSatisfy { $0 == base[0] })
    style.coverage = .end
    let end = render(spec(.working, style: style), at: 1, leds: 10, base: base)!
    #expect(end.suffix(3).allSatisfy { $0.r == 255 } && end.dropLast(3).allSatisfy { $0 == base[0] })
    style.coverage = .full
    #expect(render(spec(.working, style: style), at: 1, leds: 10, base: base)!.allSatisfy { $0.r == 255 })
}

@Test func coverageAlwaysLightsAtLeastOneLed() {
    var style = solid(EventStyle.defaultWorking, color: LEDColor(r: 9, g: 9, b: 9))
    style.coverage = .start; style.coveragePercent = 5
    #expect(render(spec(.working, style: style), at: 1, leds: 3)?.filter { $0 == LEDColor(r: 9, g: 9, b: 9) }.count == 1)
}

@Test func alertReplacesTheAmbientPictureItCovers() {
    let ambient = [LEDColor](repeating: LEDColor(r: 90, g: 90, b: 90), count: 4)
    let style = solid(EventStyle.defaultNeedsInput, color: LEDColor(r: 255, g: 0, b: 0), intensity: 0.5)
    #expect(render(spec(style: style), at: 1, leds: 4, base: ambient)?.first == LEDColor(r: 128, g: 0, b: 0))
}

@Test func cometTravelsAlongTheCoveredLeds() {
    var style = EventStyle.defaultWorking
    style.flourish.effect = .none; style.hold = Hold(effect: .comet, intensity: 1, periodSec: 2)
    style.coverage = .full; style.color = LEDColor(r: 255, g: 255, b: 255)
    let s = spec(.working, style: style)
    func brightest(_ t: Double) -> Int {
        let f = render(s, at: t, leds: 20)!
        return f.indices.max { f[$0].r < f[$1].r }!
    }
    let a = brightest(0.2), b = brightest(0.6), c = brightest(1.0)
    #expect(a < b && b < c)                                  // moves forward along the strip
}

@Test func globalBrightnessScalesEveryAlert() {
    let style = solid(EventStyle.defaultNeedsInput, color: LEDColor(r: 200, g: 100, b: 0))
    #expect(render(spec(style: style, brightness: 0.5), at: 1)?.first == LEDColor(r: 100, g: 50, b: 0))
    #expect(render(spec(style: style, brightness: 0), at: 1)?.first == .black)
}

// MARK: several waiting

@Test func severalWaitingChangeTheRhythm() {
    var style = EventStyle.defaultNeedsInput
    style.flourish.effect = .none; style.hold = Hold(effect: .breathe, intensity: 1, periodSec: 1.6)
    func samples(_ s: OverlaySpec) -> [UInt8] { stride(from: 0.0, to: 3.0, by: 0.05).map { render(s, at: $0)!.first!.r } }
    let one = samples(spec(waiting: 1, style: style, multi: .doubleBeat))
    let many = samples(spec(waiting: 3, style: style, multi: .doubleBeat))
    #expect(one != many)
    #expect(many.contains(0))                                // the rest between the two beats is dark
    let plain = samples(spec(waiting: 3, style: style, multi: .none))
    #expect(plain == one)                                    // "none" ignores the count
    let fast = samples(spec(waiting: 3, style: style, multi: .faster))
    #expect(fast != one)
}

@Test func theCountOnlyMattersForQuestions() {
    let d = spec(.done, waiting: 5, multi: .doubleBeat)
    let e = spec(.done, waiting: 1, multi: .doubleBeat)
    #expect(render(d, at: 2) == render(e, at: 2))
}

// MARK: reduced motion

@Test func reducedMotionReplacesFlashesWithASlowSwell() {
    let s = spec(reduce: true)
    var peak: UInt8 = 0, changes = 0
    var prev: UInt8 = 0
    for t in stride(from: 0.0, to: 2.0, by: 0.02) {
        let r = render(s, at: t)!.first!.r
        peak = max(peak, r)
        if abs(Int(r) - Int(prev)) > 40 { changes += 1 }     // no hard on/off steps
        prev = r
    }
    #expect(peak == 255 && changes == 0)
}

// MARK: photosensitivity (the hard limit)

/// Counts how many times per second the light climbs by at least 10 % of full scale after having
/// fallen: the WCAG 2.3.1 notion of a flash, which must stay at three or fewer per second.
private func worstFlashesPerSecond(_ luminance: [Double], rate: Double) -> Int {
    let threshold = 0.1
    var rises: [Int] = []
    var dir = 0, extreme = luminance[0]
    for (i, v) in luminance.enumerated() {
        switch dir {
        case 0:
            if v - extreme >= threshold { dir = 1; extreme = v; rises.append(i) }
            else if extreme - v >= threshold { dir = -1; extreme = v }
        case 1:
            if v > extreme { extreme = v } else if extreme - v >= threshold { dir = -1; extreme = v }
        default:
            if v < extreme { extreme = v } else if v - extreme >= threshold { dir = 1; extreme = v; rises.append(i) }
        }
    }
    let window = Int(rate)
    var worst = 0, lo = 0
    for hi in rises.indices {
        while rises[hi] - rises[lo] >= window { lo += 1 }
        worst = max(worst, hi - lo + 1)
    }
    return worst
}

/// Luminance of an alert rendered on one LED over `seconds`, optionally through the limiter.
private func series(_ s: OverlaySpec, seconds: Double, rate: Double, limited: Bool) -> [Double] {
    var limiter = FlashLimiter()
    limiter.begin(previous: nil)
    return (0..<Int(rate * seconds)).map { i in
        let now = t0.addingTimeInterval(Double(i) / rate)
        var frame = AgentOverlay.render(s, now: now, ledCount: 1, base: [.black])?.frame ?? [.black]
        if limited { frame = limiter.filter(frame, at: now) }
        return FlashLimiter.luminance(frame)
    }
}

/// Every combination of effect, count, period (including absurdly fast ones that the clamp must fix).
private func everySetting(_ body: (EventStyle, MultiPattern, Int, Bool, String) -> Void) {
    for fe in [FlourishEffect.none, .blink, .pulse, .flash] {
        for count in [1, 3, 10] {
            for fp in [0.01, 0.34, 1.0] {
                for he in [HoldEffect.none, .solid, .breathe, .blink, .comet] {
                    for hp in [0.01, 0.34, 1.6] {
                        for multi in [MultiPattern.none, .doubleBeat, .faster] {
                            for (waiting, reduce) in [(1, false), (3, false), (3, true)] {
                                var style = EventStyle.defaultNeedsInput
                                style.flourish = Flourish(effect: fe, count: count, periodSec: fp)
                                style.hold = Hold(effect: he, intensity: 1, periodSec: hp)
                                Sanitize.clamp(&style, for: .needsInput)
                                body(style, multi, waiting, reduce, "\(fe) x\(count)@\(fp) + \(he)@\(hp) \(multi) waiting=\(waiting) reduce=\(reduce)")
                            }
                        }
                    }
                }
            }
        }
    }
}

@Test func eachPhaseOnItsOwnNeverFlashesMoreThanThreeTimesASecond() {
    var checked = 0
    everySetting { style, multi, waiting, reduce, label in
        // Opening alone, and hold alone: no seams, so the renderer itself must be within the limit.
        var opening = style; opening.hold.effect = .none
        var hold = style; hold.flourish.effect = .none
        for (name, st) in [("opening", opening), ("hold", hold)] {
            let worst = worstFlashesPerSecond(series(spec(waiting: waiting, style: st, multi: multi, reduce: reduce), seconds: 6, rate: 100, limited: false), rate: 100)
            #expect(worst <= 3, "\(name) of \(label): \(worst)/s")
            checked += 1
        }
    }
    #expect(checked > 3000)
}

@Test func noSettingAndNoSequenceCanFlashMoreThanThreeTimesASecond() {
    // Opening followed by hold, through the limiter that guards the strip.
    var checked = 0
    everySetting { style, multi, waiting, reduce, label in
        let worst = worstFlashesPerSecond(series(spec(waiting: waiting, style: style, multi: multi, reduce: reduce), seconds: 8, rate: 100, limited: true), rate: 100)
        #expect(worst <= 3, "\(label): \(worst)/s")
        checked += 1
    }
    #expect(checked > 3000)
}

@Test func theShippedDefaultsNeverNeedTheLimiter() {
    // Out of the box the limiter must be invisible: it is a safety net, not part of the look.
    for kind in AlertKind.allCases {
        for (waiting, multi) in [(1, MultiPattern.none), (3, .doubleBeat), (3, .faster)] {
            let s = spec(kind, waiting: waiting, multi: multi)
            let raw = series(s, seconds: 10, rate: 100, limited: false)
            #expect(worstFlashesPerSecond(raw, rate: 100) <= 3, "\(kind)")
            #expect(raw == series(s, seconds: 10, rate: 100, limited: true), "limiter changed the default \(kind) alert")
        }
    }
}

@Test func theFlashCounterReallyCountsFlashes() {
    // Guard the guard: a 5 Hz square wave must be reported as more than three flashes a second.
    let wave = (0..<400).map { Int(Double($0) / 100 * 10) % 2 == 0 ? 1.0 : 0.0 }
    #expect(worstFlashesPerSecond(wave, rate: 100) >= 5)
    let calm = (0..<400).map { Int(Double($0) / 100 * 2) % 2 == 0 ? 1.0 : 0.0 }     // 1 Hz
    #expect(worstFlashesPerSecond(calm, rate: 100) <= 1)
}

// MARK: the limiter (seams between alerts)

private func filteredLuminance(_ series: [[LEDColor]], rate: Double, limit: Bool) -> [Double] {
    var limiter = FlashLimiter()
    limiter.begin(previous: nil)
    return series.enumerated().map { i, frame in
        let out = limit ? limiter.filter(frame, at: t0.addingTimeInterval(Double(i) / rate)) : frame
        return FlashLimiter.luminance(out)
    }
}

@Test func limiterHoldsBackTheFourthRiseInASecond() {
    let rate = 100.0
    let fast: [[LEDColor]] = (0..<500).map { Int(Double($0) / rate * 10) % 2 == 0 ? [LEDColor(r: 255, g: 255, b: 255)] : [.black] }
    #expect(worstFlashesPerSecond(filteredLuminance(fast, rate: rate, limit: false), rate: rate) >= 5)
    #expect(worstFlashesPerSecond(filteredLuminance(fast, rate: rate, limit: true), rate: rate) <= 3)
}

@Test func limiterLeavesCalmSequencesUntouched() {
    var limiter = FlashLimiter(); limiter.begin(previous: nil)
    for i in 0..<400 {
        let frame = [LEDColor](repeating: Int(Double(i) / 100) % 2 == 0 ? LEDColor(r: 200, g: 100, b: 50) : .black, count: 4)
        #expect(limiter.filter(frame, at: t0.addingTimeInterval(Double(i) / 100)) == frame)      // 0.5 Hz
    }
}

@Test func limiterCoversReplayedOpeningsAndKindChanges() {
    // A busy sequence of alerts: each new arrival replays its opening on top of what is showing,
    // and the kind alternates. Each alert alone is within limits; the seams are not.
    let rate = 100.0
    var white = EventStyle.defaultNeedsInput
    white.color = LEDColor(r: 255, g: 255, b: 255)
    white.flourish = Flourish(effect: .blink, count: 3, periodSec: 0.34)
    white.hold = Hold(effect: .breathe, intensity: 1, periodSec: 0.34)
    var blinker = white; blinker.hold.effect = .blink
    var unsafeSeams = 0
    for restart in [0.37, 0.5, 0.9, 1.3, 1.7] {
        var frames: [[LEDColor]] = []
        for i in 0..<Int(rate * 20) {
            let t = Double(i) / rate
            let index = Int(t / restart)
            let since = t0.addingTimeInterval(Double(index) * restart)
            let alternate = index % 2 == 0
            let spec = OverlaySpec(display: DisplayState(kind: alternate ? .needsInput : .error, since: since, waitingCount: 1, sessionCount: 1),
                                   style: alternate ? white : blinker, multiPattern: .none, overlayBrightness: 1, minBrightness: 0, reduceMotion: false, crossfadeMs: 0)
            frames.append(AgentOverlay.render(spec, now: t0.addingTimeInterval(t), ledCount: 1, base: [.black])?.frame ?? [.black])
        }
        if worstFlashesPerSecond(filteredLuminance(frames, rate: rate, limit: false), rate: rate) > 3 { unsafeSeams += 1 }
        let safe = worstFlashesPerSecond(filteredLuminance(frames, rate: rate, limit: true), rate: rate)
        #expect(safe <= 3, "restart every \(restart) s: \(safe) flashes/s even with the limiter")
    }
    #expect(unsafeSeams > 0, "the scenario must really be unsafe without the limiter, or this test proves nothing")
}

// MARK: crossfade

@Test func crossfadeBlendsThenSettles() {
    var fader = FrameCrossfade()
    let red = [LEDColor(r: 200, g: 0, b: 0)], blue = [LEDColor(r: 0, g: 0, b: 200)]
    _ = fader.apply(red, at: t0)
    fader.begin(at: t0, milliseconds: 200)
    #expect(fader.apply(blue, at: t0.addingTimeInterval(0.1)) == [LEDColor(r: 100, g: 0, b: 100)])
    #expect(fader.apply(blue, at: t0.addingTimeInterval(0.25)) == blue)
    #expect(!fader.isActive(at: t0.addingTimeInterval(0.25)))
}

@Test func crossfadeIsOptionalAndSafeWithChangingLength() {
    var fader = FrameCrossfade()
    _ = fader.apply([.black], at: t0)
    fader.begin(at: t0, milliseconds: 0)
    #expect(fader.apply([LEDColor(r: 9, g: 9, b: 9)], at: t0) == [LEDColor(r: 9, g: 9, b: 9)])
    fader.begin(at: t0, milliseconds: 300)
    let two = [LEDColor(r: 5, g: 5, b: 5), LEDColor(r: 5, g: 5, b: 5)]
    #expect(fader.apply(two, at: t0.addingTimeInterval(0.1)) == two)      // layout changed: no blend
}

// MARK: store

@Test func storeBuildsTheSpecFromSettings() {
    let store = OverlayStore()
    #expect(store.spec() == nil)
    var settings = AgentAlertSettings(); settings.reduceFlashing = true
    let d = DisplayState(kind: .error, since: t0, waitingCount: 0, sessionCount: 1)
    store.update(display: d, settings: settings)
    let s = store.spec()
    #expect(s?.style == settings.error && s?.reduceMotion == true && s?.minBrightness == 0.4)
    store.update(display: d, settings: AgentAlertSettings())
    #expect(store.spec()?.reduceMotion == false)
    store.setSystemReduceMotion(true)
    #expect(store.spec()?.reduceMotion == true)
    var off = AgentAlertSettings(); off.enabled = false
    store.update(display: d, settings: off)
    #expect(store.spec() == nil)
    store.update(display: nil, settings: AgentAlertSettings())
    #expect(store.spec() == nil)
}

// MARK: preview

@Test func aPreviewPlaysOverTheRealStateAndEndsByItself() {
    let store = OverlayStore()
    let settings = AgentAlertSettings()
    store.update(display: nil, settings: settings)
    #expect(store.spec(now: t0) == nil)

    store.setPreview(.error, seconds: 5, now: t0)
    #expect(store.activePreview(now: t0.addingTimeInterval(1)) == .error)
    let s = store.spec(now: t0.addingTimeInterval(1))
    #expect(s?.display.kind == .error && s?.display.since == t0 && s?.style.alertWhenLightsOff == true)
    #expect(store.spec(now: t0.addingTimeInterval(5.1)) == nil && store.activePreview(now: t0.addingTimeInterval(5.1)) == nil)

    // It wins over a real alert while it plays, and the real one comes back afterwards.
    let real = DisplayState(kind: .done, since: t0, waitingCount: 0, sessionCount: 1)
    store.update(display: real, settings: settings)
    store.setPreview(.needsInput, waiting: 3, seconds: 2, now: t0)
    #expect(store.spec(now: t0.addingTimeInterval(1))?.display.kind == .needsInput)
    #expect(store.spec(now: t0.addingTimeInterval(1))?.display.waitingCount == 3)
    #expect(store.spec(now: t0.addingTimeInterval(3))?.display.kind == .done)
}

@Test func aPreviewUsesTheSettingsAsTheyAreEdited() {
    let store = OverlayStore()
    var settings = AgentAlertSettings()
    store.setPreview(.done, seconds: 60, now: t0)
    store.update(display: nil, settings: settings)
    #expect(store.spec(now: t0)?.style.color == EventStyle.defaultDone.color)
    settings.done.color = LEDColor(r: 1, g: 2, b: 3)
    store.update(display: nil, settings: settings)
    #expect(store.spec(now: t0)?.style.color == LEDColor(r: 1, g: 2, b: 3))
}

@Test func aPreviewCanBeCancelled() {
    let store = OverlayStore()
    store.setPreview(.error, seconds: 60, now: t0)
    store.setPreview(nil)
    #expect(store.spec(now: t0) == nil)
}

@Test func aPreviewStillShowsWhenAgentAlertsAreSwitchedOff() {
    // Editing a style while the master switch is off must still let you see the result.
    let store = OverlayStore()
    var settings = AgentAlertSettings(); settings.enabled = false
    store.update(display: nil, settings: settings)
    store.setPreview(.done, seconds: 5, now: t0)
    #expect(store.spec(now: t0) != nil)
}

@Test func onlyAPreviewIsMarkedAsOne() {
    let store = OverlayStore()
    let real = DisplayState(kind: .done, since: t0, waitingCount: 0, sessionCount: 1)
    store.update(display: real, settings: AgentAlertSettings())
    #expect(store.spec(now: t0)?.isPreview == false)
    store.setPreview(.error, seconds: 5, now: t0)
    #expect(store.spec(now: t0)?.isPreview == true)
}
