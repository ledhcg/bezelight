import Foundation
import BezelightAgents

// MARK: public model

public struct SessionKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var agent: AgentKind
    public var session: String
    public init(agent: AgentKind, session: String) { self.agent = agent; self.session = session }
    public var description: String { "\(agent.rawValue):\(session)" }
}

public enum SessionState: String, Sendable, Equatable {
    case idle, working, needsInput, done, error
}

/// What the user is doing right now, as far as the keyboard and mouse tell.
public struct PresenceSample: Sendable, Equatable {
    /// Seconds since the last keyboard / mouse event.
    public var idleSeconds: Double
    /// Wall-clock time of that event.
    public var lastInputAt: Date
    public init(idleSeconds: Double, lastInputAt: Date) { self.idleSeconds = idleSeconds; self.lastInputAt = lastInputAt }
    /// A user who has not touched the machine for a very long time.
    public static func away(now: Date) -> PresenceSample { PresenceSample(idleSeconds: 86_400, lastInputAt: now.addingTimeInterval(-86_400)) }
}

public protocol PresenceProvider: Sendable {
    func sample(now: Date) -> PresenceSample
}

public enum TrackerEffect: Sendable, Equatable {
    /// Start noticing when the transcript grows (Claude refusals produce no hook).
    case watchTranscript(SessionKey, path: String)
    case unwatchTranscript(SessionKey)
    case sessionRemoved(SessionKey)
}

public struct AgentSession: Sendable, Equatable, Identifiable {
    public var id: SessionKey
    public var project = ""
    public var cwd: String?
    public var state = SessionState.idle
    /// True for a short while after a refusal was only inferred from the transcript.
    public var unconfirmed = false
    /// When the session entered its current state.
    public var since: Date
    /// The last time something asked for the user's attention.
    public var attentionAt: Date
    public var lastEventAt: Date
    public var pendingCount: Int { pending.count }
    public var activeSubagents: Int { activeSubs.count }

    // Internal bookkeeping, exposed read-only to tests through @testable.
    var pending: [String: String] = [:]     // request key -> origin ("" = main agent)
    var activeSubs: Set<String> = []
    var mainStopped = false
    var holdSince: Date?
    var endedAt: Date?
    var acked = true
    var presentAtEnd = false
    var dismissedAt: Date?
    var lastTs: Int64 = 0
    var lastWasTerminal = false
    var pid: Int32?
    var unconfirmedSince: Date?

    init(id: SessionKey, now: Date) {
        self.id = id; since = now; attentionAt = now; lastEventAt = now
    }

    /// Everything a person can see about a session. Two sessions that differ only in bookkeeping
    /// (the time of the last event, ordering stamps) look the same, so they compare equal: otherwise
    /// every "still working" event would count as a change and redraw the whole interface.
    struct Visible: Equatable {
        var id: SessionKey, project: String, state: SessionState, unconfirmed: Bool
        var since: Date, attentionAt: Date, pending: Int, subagents: Int
    }

    var visible: Visible {
        Visible(id: id, project: project, state: state, unconfirmed: unconfirmed, since: since,
                attentionAt: attentionAt, pending: pending.count, subagents: activeSubs.count)
    }

    public static func == (a: AgentSession, b: AgentSession) -> Bool { a.visible == b.visible }

    /// Who comes first in a list: what needs the user, then what failed, then what finished.
    var rank: Int {
        switch state {
        case .needsInput: return 4
        case .error: return 3
        case .done: return 2
        case .working: return 1
        case .idle: return 0
        }
    }
}

/// What the strip should show right now.
public struct DisplayState: Sendable, Equatable {
    public var kind: AlertKind
    /// Latest start among the sessions behind `kind`, so the opening replays when one more arrives.
    public var since: Date
    /// Sessions that currently need the user (drives the "several waiting" pattern).
    public var waitingCount: Int
    /// Sessions contributing to `kind`.
    public var sessionCount: Int
}

// MARK: tracker

/// Turns a stream of `AgentEvent`s into per-session state and decides what the strip shows.
///
/// Pure: no clock, no I/O. `now` and the user's presence are passed in, so behaviour can be
/// replayed exactly in tests (see `Tests/Fixtures/timelines`).
public struct AgentTracker: Sendable {
    public private(set) var settings: AgentAlertSettings
    private var table: [SessionKey: AgentSession] = [:]

    public static let maxSessions = 256
    /// Finished and idle sessions are forgotten after this long.
    static let historySeconds: TimeInterval = 3600

    public init(settings: AgentAlertSettings = AgentAlertSettings()) { self.settings = settings }

    /// Counts changes a person could see (a session appearing, going away, changing state...).
    /// Consumers can skip all work while it stays the same, however many events arrive.
    public private(set) var version: UInt64 = 0

    /// Most important first (needs you, failed, finished, working), then newest first.
    public var sessions: [AgentSession] {
        table.values.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.since != $1.since { return $0.since > $1.since }
            return $0.id.description < $1.id.description
        }
    }

    /// Whether the one-second timer has real work: anything waiting on time or on the user's return.
    /// Otherwise only old history needs sweeping, which is not urgent.
    public var wantsFastTick: Bool {
        table.values.contains { s in
            s.mainStopped || s.unconfirmed || {
                switch s.state {
                case .working, .needsInput: return true
                case .done, .error: return !s.acked
                case .idle: return false
                }
            }()
        }
    }

    public var nextTickInterval: TimeInterval { wantsFastTick ? 1 : 30 }

    public func session(_ key: SessionKey) -> AgentSession? { table[key] }
    public var isEmpty: Bool { table.isEmpty }

    public mutating func updateSettings(_ new: AgentAlertSettings) {
        settings = new
        version &+= 1
        for key in table.keys where !new.isEnabled(key.agent) { table.removeValue(forKey: key) }
    }

    // MARK: events

    @discardableResult
    public mutating func apply(_ e: AgentEvent, now: Date, presence: PresenceSample) -> [TrackerEffect] {
        guard settings.enabled, settings.isEnabled(e.agent) else { return [] }
        let key = SessionKey(agent: e.agent, session: e.session)
        var fx: [TrackerEffect] = []

        if e.kind == .end {
            if table.removeValue(forKey: key) != nil { fx += [.unwatchTranscript(key), .sessionRemoved(key)]; version &+= 1 }
            return fx
        }
        // These only make sense for a session we already know.
        if [.answered, .seen, .substop, .interrupt].contains(e.kind), table[key] == nil { return [] }

        var s = table[key] ?? AgentSession(id: key, now: now)
        // Order by the time the hook started, not by arrival. At equal times a turn's end wins.
        if e.ts < s.lastTs { return [] }
        if e.ts == s.lastTs, s.lastWasTerminal, e.kind == .working { return [] }
        s.lastTs = e.ts
        s.lastWasTerminal = e.kind.isTerminal
        s.lastEventAt = now
        if let cwd = e.cwd, !cwd.isEmpty {
            s.cwd = cwd
            s.project = (cwd as NSString).lastPathComponent
        }
        if let pid = e.pid { s.pid = pid }
        let origin = e.sub ?? ""
        let hadPending = !s.pending.isEmpty

        switch e.kind {
        case .start:
            s.reset(now: now)

        case .working:
            // Activity from the same source that asked is the answer (Claude/Codex have no
            // "answered" event). A subagent's activity never answers the main agent's question.
            s.pending = s.pending.filter { $0.value != origin }
            if e.sub != nil, s.state == .done || s.state == .error { break }   // stray subagent event
            if e.sub == nil { s.mainStopped = false; s.holdSince = nil }
            s.unconfirmed = false; s.unconfirmedSince = nil
            switch s.state {
            case .needsInput: if s.pending.isEmpty { s.enter(.working, now) }
            case .working: break
            default: s.enter(.working, now); s.endedAt = nil; s.acked = true
            }

        case .ask:
            let k = e.req ?? "ask:" + origin
            s.pending[k] = origin
            if s.state != .needsInput { s.enter(.needsInput, now) }
            s.attentionAt = now
            s.unconfirmed = false; s.unconfirmedSince = nil
            s.acked = false
            if let tp = e.tp, e.agent == .claude, !hadPending { fx.append(.watchTranscript(key, path: tp)) }

        case .answered:
            if e.src == "transcript" {
                s.pending.removeAll()
            } else if let r = e.req {
                s.pending.removeValue(forKey: r)
            } else {
                s.pending = s.pending.filter { $0.value != origin }
            }
            if s.pending.isEmpty, s.state == .needsInput {
                if s.mainStopped, s.activeSubs.isEmpty {
                    s.finish(.done, now: now, presence: presence, settings: settings)
                } else {
                    s.enter(.working, now)
                    if e.src == "transcript" { s.unconfirmed = true; s.unconfirmedSince = now }
                }
            }

        case .done:
            s.pending = s.pending.filter { $0.value != "" }          // the main agent's own questions are over
            if s.activeSubs.isEmpty {
                s.finish(.done, now: now, presence: presence, settings: settings)
            } else {
                // Claude reports the main turn's end while background subagents still run (and
                // they may ask for permission afterwards): hold the "done" until they finish.
                s.mainStopped = true
                s.holdSince = s.holdSince ?? now
                if s.pending.isEmpty { s.enter(.working, now) }
            }

        case .error:
            s.finish(.error, now: now, presence: presence, settings: settings)

        case .interrupt:
            s.reset(now: now)

        case .substart:
            if let sub = e.sub {
                s.activeSubs.insert(sub)
                if s.state == .idle { s.enter(.working, now) }
            }

        case .substop:
            // An id we never saw start is one of Claude's internal helpers: ignore it.
            guard let sub = e.sub, s.activeSubs.contains(sub) else { break }
            s.activeSubs.remove(sub)
            s.pending = s.pending.filter { $0.value != sub }
            if s.pending.isEmpty {
                if s.mainStopped, s.activeSubs.isEmpty {
                    s.finish(.done, now: now, presence: presence, settings: settings)
                } else if s.state == .needsInput {
                    s.enter(.working, now)
                }
            }

        case .seen:
            if settings.presence.useAgentSeen, s.state == .done || s.state == .error { s.acked = true }

        case .end:
            break
        }

        if hadPending, s.pending.isEmpty { fx.append(.unwatchTranscript(key)) }
        if table[key]?.visible != s.visible { version &+= 1 }
        table[key] = s
        trim()
        return fx
    }

    // MARK: time

    /// Call about once a second while any session exists.
    @discardableResult
    public mutating func tick(now: Date, presence: PresenceSample, alive: (Int32) -> Bool = { _ in true }) -> [TrackerEffect] {
        var fx: [TrackerEffect] = []
        for key in Array(table.keys) {
            guard var s = table[key] else { continue }
            let hadPending = !s.pending.isEmpty
            let before = s.visible

            if let pid = s.pid, !alive(pid) {
                version &+= 1
                table.removeValue(forKey: key)
                fx += [.unwatchTranscript(key), .sessionRemoved(key)]
                continue
            }

            switch s.state {
            case .working:
                if s.mainStopped, let h = s.holdSince, now.timeIntervalSince(h) >= Double(settings.subagentHoldSec) {
                    s.finish(.done, now: now, presence: presence, settings: settings)
                } else if s.unconfirmed, let u = s.unconfirmedSince, now.timeIntervalSince(u) >= Double(settings.confirmSec) {
                    s.reset(now: now)      // refused and Claude stopped: nothing more will come
                } else if now.timeIntervalSince(s.lastEventAt) >= Double(settings.stale.workingSec) {
                    s.reset(now: now)
                }
            case .needsInput:
                if now.timeIntervalSince(s.attentionAt) >= Double(settings.stale.needsInputSec) { s.reset(now: now) }
                else if settings.presence.enabled, presence.lastInputAt > s.attentionAt { s.acked = true }
            case .done, .error:
                if settings.presence.enabled, let ended = s.endedAt, presence.lastInputAt > ended { s.acked = true }
                if let ended = s.endedAt, now.timeIntervalSince(ended) >= Self.historySeconds {
                    version &+= 1; table.removeValue(forKey: key); fx.append(.sessionRemoved(key)); continue
                }
            case .idle:
                if now.timeIntervalSince(s.lastEventAt) >= Self.historySeconds {
                    version &+= 1; table.removeValue(forKey: key); fx.append(.sessionRemoved(key)); continue
                }
            }

            if hadPending, s.pending.isEmpty { fx.append(.unwatchTranscript(key)) }
            if s.visible != before { version &+= 1 }
            table[key] = s
        }
        return fx
    }

    /// "Dismiss all": hides every current alert. A new event shows again.
    public mutating func dismissAll(now: Date) {
        version &+= 1
        for key in table.keys {
            table[key]?.dismissedAt = now
            table[key]?.acked = true
        }
    }

    // MARK: display

    public func display(now: Date) -> DisplayState? {
        var groups: [AlertKind: (latest: Date, count: Int)] = [:]
        var waiting = 0
        for s in table.values {
            guard settings.isEnabled(s.id.agent), let kind = alertKind(of: s.state) else { continue }
            let style = settings.style(for: kind)
            guard style.enabled, style.allows(s.id.agent), isVisible(s, kind, style, now) else { continue }
            let at = kind == .needsInput ? s.attentionAt : s.since
            let g = groups[kind] ?? (latest: at, count: 0)
            groups[kind] = (latest: max(g.latest, at), count: g.count + 1)
            if kind == .needsInput { waiting += 1 }
        }
        guard let best = groups.max(by: { $0.key.priority < $1.key.priority }) else { return nil }
        return DisplayState(kind: best.key, since: best.value.latest, waitingCount: waiting, sessionCount: best.value.count)
    }

    private func alertKind(of state: SessionState) -> AlertKind? {
        switch state {
        case .needsInput: return .needsInput
        case .error: return .error
        case .done: return .done
        case .working: return .working
        case .idle: return nil
        }
    }

    private func isVisible(_ s: AgentSession, _ kind: AlertKind, _ style: EventStyle, _ now: Date) -> Bool {
        let at = kind == .needsInput ? s.attentionAt : s.since
        if let d = s.dismissedAt, at <= d { return false }
        switch style.persistence {
        case .untilResolved:
            return kind == .needsInput || returnRule(s, kind, now)
        case .untilReturn:
            return returnRule(s, kind, now)
        case .timed:
            return now.timeIntervalSince(at) < Double(style.timeoutSec)
        case .untilDismissed:
            return true
        case .once:
            return now.timeIntervalSince(at) < style.flourish.duration
        }
    }

    /// "Until the user is back": ends with the first keyboard / mouse input after the alert,
    /// or after a short fade when the user was already at the machine.
    private func returnRule(_ s: AgentSession, _ kind: AlertKind, _ now: Date) -> Bool {
        if kind == .working { return true }
        if s.acked { return false }
        if (kind == .done || kind == .error), s.presentAtEnd, let ended = s.endedAt {
            return now.timeIntervalSince(ended) < settings.presence.presentFadeSec
        }
        return true
    }

    private mutating func trim() {
        guard table.count > Self.maxSessions else { return }
        // Drop the quietest sessions first, never one that is waiting for the user.
        let victims = table.values
            .filter { $0.state != .needsInput }
            .sorted { $0.lastEventAt < $1.lastEventAt }
            .prefix(table.count - Self.maxSessions)
        for v in victims { table.removeValue(forKey: v.id) }
        if !victims.isEmpty { version &+= 1 }
    }
}

// MARK: session transitions

extension AgentSession {
    mutating func enter(_ new: SessionState, _ now: Date) {
        state = new
        since = now
    }

    /// Back to a clean idle session (a new session, `/clear`, an interrupt, a stale timeout).
    mutating func reset(now: Date) {
        pending = [:]; activeSubs = []; mainStopped = false; holdSince = nil
        unconfirmed = false; unconfirmedSince = nil; endedAt = nil; acked = true; presentAtEnd = false
        enter(.idle, now)
    }

    /// A turn ended (`done`) or failed (`error`).
    mutating func finish(_ kind: SessionState, now: Date, presence: PresenceSample, settings: AgentAlertSettings) {
        pending = [:]; activeSubs = []; mainStopped = false; holdSince = nil
        unconfirmed = false; unconfirmedSince = nil
        enter(kind, now)
        endedAt = now
        acked = false
        presentAtEnd = settings.presence.enabled && presence.idleSeconds < settings.presence.activeGraceSec
    }
}
