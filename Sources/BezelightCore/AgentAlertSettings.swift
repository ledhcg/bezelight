import Foundation
import BezelightAgents

// MARK: enums (raw values are persisted: do not rename)

public enum FlourishEffect: String, Codable, CaseIterable, Sendable { case none, blink, pulse, flash }
public enum HoldEffect: String, Codable, CaseIterable, Sendable { case none, solid, breathe, blink, comet }
public enum Persistence: String, Codable, CaseIterable, Sendable { case untilResolved, untilReturn, timed, untilDismissed, once }
public enum Coverage: String, Codable, CaseIterable, Sendable { case full, start, end }
public enum MultiPattern: String, Codable, CaseIterable, Sendable { case none, doubleBeat, faster }

/// The four things the strip can announce.
public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case needsInput, error, done, working

    /// Higher wins when several sessions want the strip at once.
    public var priority: Int {
        switch self {
        case .needsInput: return 3
        case .error: return 2
        case .done: return 1
        case .working: return 0
        }
    }
}

/// Reads a key and falls back to a default when it is missing or no longer valid.
private struct Lenient<K: CodingKey> {
    let c: KeyedDecodingContainer<K>
    func get<T: Decodable>(_ k: K, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
}

// MARK: building blocks

public struct Flourish: Codable, Sendable, Equatable {
    public var effect: FlourishEffect
    public var count: Int
    /// One full cycle (on + off), seconds.
    public var periodSec: Double
    public init(effect: FlourishEffect, count: Int, periodSec: Double) {
        self.effect = effect; self.count = count; self.periodSec = periodSec
    }

    /// How long the opening lasts.
    public var duration: Double {
        switch effect {
        case .none: return 0
        case .flash: return 0.3
        case .blink, .pulse: return Double(count) * periodSec
        }
    }

    private enum Keys: String, CodingKey { case effect, count, periodSec }
    /// Keys missing from the file take the values of `base` (that alert's shipped opening).
    public init(from decoder: Decoder, base: Flourish) throws {
        let l = Lenient(c: try decoder.container(keyedBy: Keys.self))
        effect = l.get(.effect, base.effect); count = l.get(.count, base.count); periodSec = l.get(.periodSec, base.periodSec)
    }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, base: Flourish(effect: .none, count: 2, periodSec: 0.5)) }
}

public struct Hold: Codable, Sendable, Equatable {
    public var effect: HoldEffect
    /// Peak brightness of the hold phase, relative to the strip brightness (0...1).
    public var intensity: Double
    public var periodSec: Double
    public init(effect: HoldEffect, intensity: Double, periodSec: Double) {
        self.effect = effect; self.intensity = intensity; self.periodSec = periodSec
    }

    private enum Keys: String, CodingKey { case effect, intensity, periodSec }
    public init(from decoder: Decoder, base: Hold) throws {
        let l = Lenient(c: try decoder.container(keyedBy: Keys.self))
        effect = l.get(.effect, base.effect); intensity = l.get(.intensity, base.intensity); periodSec = l.get(.periodSec, base.periodSec)
    }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, base: Hold(effect: .solid, intensity: 0.5, periodSec: 1.6)) }
}

/// Everything configurable about one kind of alert.
public struct EventStyle: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var color: LEDColor
    public var flourish: Flourish
    public var hold: Hold
    public var persistence: Persistence
    /// Used by `.timed`.
    public var timeoutSec: Int
    public var coverage: Coverage
    public var coveragePercent: Int
    public var alertWhenLightsOff: Bool
    /// Per-agent overrides (`AgentKind.rawValue` -> on/off). Missing = follow the agent switch.
    public var perAgent: [String: Bool]

    public init(enabled: Bool, color: LEDColor, flourish: Flourish, hold: Hold, persistence: Persistence,
                timeoutSec: Int = 8, coverage: Coverage = .full, coveragePercent: Int = 100,
                alertWhenLightsOff: Bool, perAgent: [String: Bool] = [:]) {
        self.enabled = enabled; self.color = color; self.flourish = flourish; self.hold = hold
        self.persistence = persistence; self.timeoutSec = timeoutSec; self.coverage = coverage
        self.coveragePercent = coveragePercent; self.alertWhenLightsOff = alertWhenLightsOff
        self.perAgent = perAgent
    }

    /// An alert with neither an opening nor a hold would be invisible: the UI warns about it.
    public var isInvisible: Bool { flourish.effect == .none && hold.effect == .none }

    public func allows(_ agent: AgentKind) -> Bool { perAgent[agent.rawValue] ?? true }

    private enum Keys: String, CodingKey {
        case enabled, color, flourish, hold, persistence, timeoutSec, coverage, coveragePercent
        case alertWhenLightsOff, perAgent
    }

    /// Keys missing from older files take the values of `base` (the shipped default for that alert).
    public init(from decoder: Decoder, base: EventStyle) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let l = Lenient(c: c)
        func nested<T>(_ k: Keys, _ make: (Decoder) throws -> T, _ fallback: T) -> T {
            guard c.contains(k), let sub = try? c.superDecoder(forKey: k), let v = try? make(sub) else { return fallback }
            return v
        }
        enabled = l.get(.enabled, base.enabled); color = l.get(.color, base.color)
        flourish = nested(.flourish, { try Flourish(from: $0, base: base.flourish) }, base.flourish)
        hold = nested(.hold, { try Hold(from: $0, base: base.hold) }, base.hold)
        persistence = l.get(.persistence, base.persistence); timeoutSec = l.get(.timeoutSec, base.timeoutSec)
        coverage = l.get(.coverage, base.coverage); coveragePercent = l.get(.coveragePercent, base.coveragePercent)
        alertWhenLightsOff = l.get(.alertWhenLightsOff, base.alertWhenLightsOff)
        perAgent = l.get(.perAgent, base.perAgent)
    }

    public init(from decoder: Decoder) throws { try self.init(from: decoder, base: .defaultDone) }

    // MARK: shipped defaults

    public static let defaultNeedsInput = EventStyle(
        enabled: true, color: LEDColor(r: 255, g: 170, b: 0),
        flourish: Flourish(effect: .blink, count: 2, periodSec: 0.5),
        hold: Hold(effect: .breathe, intensity: 1.0, periodSec: 1.6),
        persistence: .untilResolved, alertWhenLightsOff: true)

    public static let defaultError = EventStyle(
        enabled: true, color: LEDColor(r: 255, g: 40, b: 40),
        flourish: Flourish(effect: .blink, count: 3, periodSec: 0.4),
        hold: Hold(effect: .solid, intensity: 0.30, periodSec: 1.6),
        persistence: .untilReturn, alertWhenLightsOff: true)

    public static let defaultDone = EventStyle(
        enabled: true, color: LEDColor(r: 40, g: 220, b: 100),
        flourish: Flourish(effect: .blink, count: 2, periodSec: 0.5),
        hold: Hold(effect: .solid, intensity: 0.25, periodSec: 1.6),
        persistence: .untilReturn, alertWhenLightsOff: false)

    public static let defaultWorking = EventStyle(
        enabled: false, color: LEDColor(r: 0, g: 200, b: 255),
        flourish: Flourish(effect: .none, count: 1, periodSec: 0.5),
        hold: Hold(effect: .breathe, intensity: 0.40, periodSec: 2.4),
        persistence: .untilReturn, coverage: .start, coveragePercent: 10, alertWhenLightsOff: false)
}

public struct PresenceSettings: Codable, Sendable, Equatable {
    /// Use keyboard / mouse activity to know the user is back.
    public var enabled = true
    /// Input within this many seconds of the end of a turn means the user is already here.
    public var activeGraceSec = 5.0
    /// How long the "done" glow lasts when the user was already here.
    public var presentFadeSec = 8.0
    /// Let OpenCode's own "session viewed" signal acknowledge an alert.
    public var useAgentSeen = true
    public init() {}

    private enum Keys: String, CodingKey { case enabled, activeGraceSec, presentFadeSec, useAgentSeen }
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: Keys.self))
        enabled = l.get(.enabled, true); activeGraceSec = l.get(.activeGraceSec, 5)
        presentFadeSec = l.get(.presentFadeSec, 8); useAgentSeen = l.get(.useAgentSeen, true)
    }
}

public struct StaleSettings: Codable, Sendable, Equatable {
    public var workingSec = 600
    public var needsInputSec = 1800
    public init() {}

    private enum Keys: String, CodingKey { case workingSec, needsInputSec }
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: Keys.self))
        workingSec = l.get(.workingSec, 600); needsInputSec = l.get(.needsInputSec, 1800)
    }
}

// MARK: top level

/// Persisted under its own key (`agents.v1`), apart from `StreamSettings`, so changing an alert
/// never re-applies the lighting pipeline.
public struct AgentAlertSettings: Codable, Sendable, Equatable {
    public var enabled = true
    /// Draw alerts over Screen, Music and the colour modes as well. Off by default: Agents mode is
    /// the independent place for alerts, and the other modes are never interrupted.
    public var alertsInOtherModes = false
    public var agents: [String: Bool] = ["claude": true, "codex": true, "opencode": true]
    public var presence = PresenceSettings()
    public var multiPattern = MultiPattern.doubleBeat
    public var crossfadeMs = 250
    public var overlayBrightness = 1.0
    /// Strip brightness floor while an alert shows, so a dimmed strip cannot hide it.
    public var minBrightness = 0.4
    public var reduceFlashing = false
    public var dismissHotkeyEnabled = true
    public var stale = StaleSettings()
    public var livenessIntervalSec = 5
    /// Longest a "done" waits for a still-running subagent.
    public var subagentHoldSec = 300
    /// How long a guessed refusal stays unconfirmed before the session is treated as stopped.
    public var confirmSec = 45
    public var diagnosticsLog = false
    public var needsInput = EventStyle.defaultNeedsInput
    public var error = EventStyle.defaultError
    public var done = EventStyle.defaultDone
    public var working = EventStyle.defaultWorking

    public init() {}

    public func isEnabled(_ agent: AgentKind) -> Bool { agents[agent.rawValue] ?? true }

    public func style(for kind: AlertKind) -> EventStyle {
        switch kind {
        case .needsInput: return needsInput
        case .error: return error
        case .done: return done
        case .working: return working
        }
    }

    public mutating func setStyle(_ style: EventStyle, for kind: AlertKind) {
        switch kind {
        case .needsInput: needsInput = style
        case .error: error = style
        case .done: done = style
        case .working: working = style
        }
    }

    private enum Keys: String, CodingKey {
        case enabled, alertsInOtherModes, agents, presence, multiPattern, crossfadeMs, overlayBrightness, minBrightness
        case reduceFlashing, dismissHotkeyEnabled, stale, livenessIntervalSec, subagentHoldSec, confirmSec
        case diagnosticsLog, needsInput, error, done, working
    }

    /// Every key is optional so files written by other versions keep loading, and every value is
    /// clamped to what the app can safely show.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let l = Lenient(c: c)
        enabled = l.get(.enabled, true)
        alertsInOtherModes = l.get(.alertsInOtherModes, false)
        agents = l.get(.agents, agents)
        presence = l.get(.presence, presence)
        multiPattern = l.get(.multiPattern, .doubleBeat)
        crossfadeMs = l.get(.crossfadeMs, 250)
        overlayBrightness = l.get(.overlayBrightness, 1.0)
        minBrightness = l.get(.minBrightness, 0.4)
        reduceFlashing = l.get(.reduceFlashing, false)
        dismissHotkeyEnabled = l.get(.dismissHotkeyEnabled, true)
        stale = l.get(.stale, stale)
        livenessIntervalSec = l.get(.livenessIntervalSec, 5)
        subagentHoldSec = l.get(.subagentHoldSec, 300)
        confirmSec = l.get(.confirmSec, 45)
        diagnosticsLog = l.get(.diagnosticsLog, false)
        func style(_ k: Keys, _ base: EventStyle) -> EventStyle {
            guard c.contains(k), let sub = try? c.superDecoder(forKey: k),
                  let s = try? EventStyle(from: sub, base: base) else { return base }
            return s
        }
        needsInput = style(.needsInput, .defaultNeedsInput)
        error = style(.error, .defaultError)
        done = style(.done, .defaultDone)
        working = style(.working, .defaultWorking)
        Sanitize.clamp(&self)
    }
}

// MARK: safety limits

/// Forces settings into ranges that are safe to display. Applied on load and before saving.
public enum Sanitize {
    /// At most three flashes per second (WCAG 2.3.1): the shortest allowed blink cycle.
    public static let minBlinkPeriod = 0.34

    public static func clamp(_ s: inout AgentAlertSettings) {
        s.crossfadeMs = max(0, min(1000, s.crossfadeMs))
        s.overlayBrightness = unit(s.overlayBrightness)
        s.minBrightness = unit(s.minBrightness)
        s.livenessIntervalSec = max(2, min(60, s.livenessIntervalSec))
        s.subagentHoldSec = max(10, min(3600, s.subagentHoldSec))
        s.confirmSec = max(10, min(300, s.confirmSec))
        s.presence.activeGraceSec = range(s.presence.activeGraceSec, 1, 60)
        s.presence.presentFadeSec = range(s.presence.presentFadeSec, 1, 60)
        s.stale.workingSec = max(60, min(7200, s.stale.workingSec))
        s.stale.needsInputSec = max(120, min(14400, s.stale.needsInputSec))
        for kind in AlertKind.allCases {
            var style = s.style(for: kind)
            clamp(&style, for: kind)
            s.setStyle(style, for: kind)
        }
    }

    public static func clamp(_ e: inout EventStyle, for kind: AlertKind) {
        e.flourish.count = max(1, min(10, e.flourish.count))
        e.flourish.periodSec = range(e.flourish.periodSec, minBlinkPeriod, 3)
        e.hold.intensity = unit(e.hold.intensity)
        // Anything that swings between bright and dark (blink, breathe, comet) is held to the
        // same limit as a flash; a solid colour has no cycle, so any value is harmless.
        switch e.hold.effect {
        case .blink, .breathe, .comet: e.hold.periodSec = range(e.hold.periodSec, minBlinkPeriod, 10)
        case .solid, .none: e.hold.periodSec = range(e.hold.periodSec, 0.3, 10)
        }
        e.timeoutSec = max(1, min(3600, e.timeoutSec))
        e.coveragePercent = max(5, min(100, e.coveragePercent))
        // "Until resolved" only makes sense for something the user must answer.
        if e.persistence == .untilResolved && kind != .needsInput { e.persistence = .untilReturn }
    }

    private static func unit(_ v: Double) -> Double { v.isFinite ? max(0, min(1, v)) : 0 }
    private static func range(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? max(lo, min(hi, v)) : lo }
}
