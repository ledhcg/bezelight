import Foundation
import BezelightAgents

/// A copy of what the UI and the strip need. Equatable so unchanged states are not republished.
public struct AgentSnapshot: Sendable, Equatable {
    public var sessions: [AgentSession]
    public var display: DisplayState?
    /// Sessions that need the user right now (menu bar badge).
    public var waiting: Int

    public init(sessions: [AgentSession] = [], display: DisplayState? = nil, waiting: Int = 0) {
        self.sessions = sessions; self.display = display; self.waiting = waiting
    }
}

/// Owns the tracker. Every source (hook socket, OpenCode stream, transcript watcher) feeds
/// `ingest`; consumers read `updates`. One actor serialises all changes.
///
/// A one-second timer runs only while at least one session exists, so an idle app costs nothing.
public actor AgentCenter {
    private var tracker: AgentTracker
    private let presence: PresenceProvider
    private let clock: @Sendable () -> Date
    private let alive: @Sendable (Int32) -> Bool
    private var effectHandler: (@Sendable (TrackerEffect) -> Void)?
    private var timer: Task<Void, Never>?
    private var last: AgentSnapshot?
    private var lastVersion: UInt64?
    private var timerInterval: TimeInterval = 0
    private var lastSeen: [AgentKind: Date] = [:]
    private let continuation: AsyncStream<AgentSnapshot>.Continuation

    /// Latest snapshot whenever it changes. Single consumer.
    public nonisolated let updates: AsyncStream<AgentSnapshot>

    public init(
        settings: AgentAlertSettings = AgentAlertSettings(),
        presence: PresenceProvider,
        clock: @escaping @Sendable () -> Date = { Date() },
        alive: @escaping @Sendable (Int32) -> Bool = AgentCenter.processIsAlive
    ) {
        tracker = AgentTracker(settings: settings)
        self.presence = presence
        self.clock = clock
        self.alive = alive
        var c: AsyncStream<AgentSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        continuation = c
    }

    deinit { timer?.cancel(); continuation.finish() }

    /// `kill(pid, 0)` succeeds (or fails with EPERM) for a live process.
    @Sendable public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public func setEffectHandler(_ handler: (@Sendable (TrackerEffect) -> Void)?) { effectHandler = handler }

    public func ingest(_ event: AgentEvent) {
        let now = clock()
        if event.src != "selftest" { lastSeen[event.agent] = now }
        let fx = tracker.apply(event, now: now, presence: presence.sample(now: now))
        fx.forEach { effectHandler?($0) }
        publish(now: now)
        startTimerIfNeeded()
    }

    public func updateSettings(_ settings: AgentAlertSettings) {
        tracker.updateSettings(settings)
        publish(now: clock())
    }

    public func dismissAll() {
        let now = clock()
        tracker.dismissAll(now: now)
        publish(now: now)
    }

    public func snapshot() -> AgentSnapshot { makeSnapshot(now: clock()) }

    /// What the strip should show at `now`. Cheap: the pipeline may call it every frame.
    public func display(at now: Date? = nil) -> DisplayState? { tracker.display(now: now ?? clock()) }

    /// When each agent last reported anything real (since the app started). The self-test does not count.
    public func lastEventTimes() -> [AgentKind: Date] { lastSeen }

    public var isTicking: Bool { timer != nil }

    /// Seconds between timer ticks right now (0 when the timer is not running).
    public var tickInterval: TimeInterval { timer == nil ? 0 : timerInterval }

    /// Advances time-based rules (expiry, acknowledgement, liveness). The timer calls this once a
    /// second; tests call it directly with a fake clock.
    public func tick() {
        let now = clock()
        let fx = tracker.tick(now: now, presence: presence.sample(now: now), alive: alive)
        fx.forEach { effectHandler?($0) }
        publish(now: now, timeDriven: true)
        if tracker.isEmpty { timer?.cancel(); timer = nil; timerInterval = 0 } else { startTimerIfNeeded() }
    }

    // MARK: private

    /// One second while something is waiting on time or on the user; 30 s when only old history is
    /// left to sweep (a timer that wakes the Mac every second for an hour for nothing costs battery).
    private func startTimerIfNeeded() {
        guard !tracker.isEmpty else { return }
        let want = tracker.nextTickInterval
        if timer != nil, timerInterval == want { return }
        timer?.cancel()
        timerInterval = want
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(want))
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func makeSnapshot(now: Date) -> AgentSnapshot {
        let sessions = tracker.sessions
        return AgentSnapshot(sessions: sessions, display: tracker.display(now: now),
                             waiting: sessions.filter { $0.state == .needsInput }.count)
    }

    /// Events that change nothing a person can see (the many "still working" ones) end here, before
    /// any sorting or comparing: the tracker's version only moves for visible changes. The clock can
    /// change what is shown too (an alert that expires), so a timer tick looks again regardless.
    private func publish(now: Date, timeDriven: Bool = false) {
        let v = tracker.version
        if v == lastVersion, !timeDriven { return }
        lastVersion = v
        let snap = makeSnapshot(now: now)
        guard snap != last else { return }
        last = snap
        continuation.yield(snap)
    }
}
