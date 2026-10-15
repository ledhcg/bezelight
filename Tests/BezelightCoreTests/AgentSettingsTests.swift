import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private func load(_ json: String) throws -> AgentAlertSettings {
    try JSONDecoder().decode(AgentAlertSettings.self, from: Data(json.utf8))
}

@Test func emptyFileGivesTheDefaults() throws {
    #expect(try load("{}") == AgentAlertSettings())
}

@Test func defaultsMatchTheDesign() {
    let s = AgentAlertSettings()
    #expect(s.enabled && s.presence.enabled && s.minBrightness == 0.4)
    #expect(s.needsInput.persistence == .untilResolved && s.needsInput.alertWhenLightsOff)
    #expect(s.error.alertWhenLightsOff && !s.done.alertWhenLightsOff)
    #expect(s.done.persistence == .untilReturn && s.error.persistence == .untilReturn)
    #expect(s.working.enabled == false)                           // working is off by default
    #expect(s.working.coverage == .start && s.working.coveragePercent == 10)
}

@Test func defaultsAreAlreadySafe() {
    var s = AgentAlertSettings()
    Sanitize.clamp(&s)
    #expect(s == AgentAlertSettings())
}

@Test func roundTrip() throws {
    var s = AgentAlertSettings()
    s.done.color = LEDColor(r: 1, g: 2, b: 3)
    s.error.flourish.count = 7
    s.agents["codex"] = false
    s.working.perAgent = ["claude": true, "opencode": false]
    let back = try JSONDecoder().decode(AgentAlertSettings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}

@Test func missingKeysTakeThatAlertsOwnDefault() throws {
    // Only the colour is stored: the rest must be the shipped needsInput style, not the done style.
    let s = try load(#"{"needsInput":{"color":{"r":9,"g":8,"b":7}}}"#)
    #expect(s.needsInput.color == LEDColor(r: 9, g: 8, b: 7))
    #expect(s.needsInput.persistence == .untilResolved)
    #expect(s.needsInput.hold.effect == .breathe)
    #expect(s.error == .defaultError && s.done == .defaultDone)
}

@Test func partialNestedSettingsKeepTheAlertsOwnDefaults() throws {
    // Only the intensity is stored: the effect and period must stay needsInput's own (breathe, 1.6 s).
    let s = try load(#"{"needsInput":{"hold":{"intensity":0.2},"flourish":{"count":5}}}"#)
    #expect(s.needsInput.hold.intensity == 0.2)
    #expect(s.needsInput.hold.effect == .breathe && s.needsInput.hold.periodSec == 1.6)
    #expect(s.needsInput.flourish.count == 5 && s.needsInput.flourish.effect == .blink)
    #expect(s.done.hold == EventStyle.defaultDone.hold)
}

@Test func unknownValuesFallBackInsteadOfFailing() throws {
    let s = try load(#"{"done":{"persistence":"forever","hold":{"effect":"sparkle"}},"needsInput":{"flourish":"oops"},"multiPattern":"nope","extra":1}"#)
    #expect(s.done.persistence == EventStyle.defaultDone.persistence)
    #expect(s.done.hold.effect == EventStyle.defaultDone.hold.effect)
    #expect(s.needsInput.flourish == EventStyle.defaultNeedsInput.flourish)
    #expect(s.multiPattern == .doubleBeat)
}

@Test func corruptValuesAreClamped() throws {
    let s = try load(#"""
    {"crossfadeMs":99999,"overlayBrightness":7,"minBrightness":-3,"confirmSec":1,"subagentHoldSec":99999999,
     "presence":{"activeGraceSec":0,"presentFadeSec":9999},
     "stale":{"workingSec":1,"needsInputSec":1},
     "error":{"flourish":{"effect":"blink","count":99,"periodSec":0.01},"hold":{"effect":"blink","intensity":5,"periodSec":0.05},
              "timeoutSec":0,"coveragePercent":1}}
    """#)
    #expect(s.crossfadeMs == 1000 && s.overlayBrightness == 1 && s.minBrightness == 0)
    #expect(s.confirmSec == 10 && s.subagentHoldSec == 3600)
    #expect(s.presence.activeGraceSec == 1 && s.presence.presentFadeSec == 60)
    #expect(s.stale.workingSec == 60 && s.stale.needsInputSec == 120)
    #expect(s.error.flourish.count == 10 && s.error.hold.intensity == 1)
    #expect(s.error.timeoutSec == 1 && s.error.coveragePercent == 5)
}

@Test func nothingMayFlashMoreThanThreeTimesASecond() throws {
    let s = try load(#"{"error":{"flourish":{"effect":"blink","count":3,"periodSec":0.05},"hold":{"effect":"blink","periodSec":0.05}}}"#)
    #expect(s.error.flourish.periodSec >= Sanitize.minBlinkPeriod)
    #expect(s.error.hold.periodSec >= Sanitize.minBlinkPeriod)
    #expect(1.0 / s.error.flourish.periodSec <= 3.0 + 1e-9)
}

@Test func untilResolvedIsOnlyForQuestions() throws {
    let s = try load(#"{"done":{"persistence":"untilResolved"},"working":{"persistence":"untilResolved"},"needsInput":{"persistence":"untilResolved"}}"#)
    #expect(s.done.persistence == .untilReturn && s.working.persistence == .untilReturn)
    #expect(s.needsInput.persistence == .untilResolved)
}

@Test func nonFiniteNumbersDoNotSurvive() {
    var s = AgentAlertSettings()
    s.minBrightness = .nan; s.done.hold.intensity = .infinity; s.done.flourish.periodSec = .nan
    Sanitize.clamp(&s)
    #expect(s.minBrightness == 0 && s.done.hold.intensity == 0 && s.done.flourish.periodSec == Sanitize.minBlinkPeriod)
}

@Test func invisibleAlertsAreDetected() {
    var style = EventStyle.defaultDone
    #expect(!style.isInvisible)
    style.flourish.effect = .none; style.hold.effect = .none
    #expect(style.isInvisible)
}

@Test func flourishDurations() {
    #expect(Flourish(effect: .none, count: 3, periodSec: 1).duration == 0)
    #expect(Flourish(effect: .blink, count: 3, periodSec: 0.4).duration == 1.2000000000000002 || abs(Flourish(effect: .blink, count: 3, periodSec: 0.4).duration - 1.2) < 1e-9)
    #expect(Flourish(effect: .flash, count: 3, periodSec: 1).duration == 0.3)
}

@Test func alertPrioritiesAreStrictlyOrdered() {
    let order = AlertKind.allCases.sorted { $0.priority > $1.priority }
    #expect(order == [.needsInput, .error, .done, .working])
}
