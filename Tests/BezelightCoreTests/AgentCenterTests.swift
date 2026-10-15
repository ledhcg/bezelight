import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Rig.epoch
    var now: Date { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private struct Away: PresenceProvider {
    func sample(now: Date) -> PresenceSample { .away(now: now) }
}

private func event(_ kind: EventKind, _ clock: Clock, session: String = "s1") -> AgentEvent {
    AgentEvent(agent: .claude, kind: kind, session: session, ts: Int64(clock.now.timeIntervalSince1970 * 1000))
}

@Test func centerPublishesSnapshotsOnlyWhenSomethingChanges() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    var it = center.updates.makeAsyncIterator()

    await center.ingest(event(.ask, clock))
    let first = await it.next()
    #expect(first?.display?.kind == .needsInput && first?.waiting == 1)
    #expect(first?.sessions.count == 1)

    clock.advance(0.1)
    await center.ingest(event(.working, clock, session: "other"))
    let second = await it.next()
    #expect(second?.sessions.count == 2 && second?.waiting == 1)
}

@Test func centerTimerRunsOnlyWhileThereAreSessions() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    #expect(await center.isTicking == false)
    await center.ingest(event(.working, clock))
    #expect(await center.isTicking == true)
    clock.advance(1)
    await center.ingest(event(.end, clock))
    await center.tick()
    #expect(await center.isTicking == false)
}

@Test func centerAppliesTimeBasedRulesOnTick() async {
    let clock = Clock()
    var s = AgentAlertSettings(); s.stale.workingSec = 60
    let center = AgentCenter(settings: s, presence: Away(), clock: { clock.now })
    await center.ingest(event(.working, clock))
    clock.advance(61)
    await center.tick()
    let snap = await center.snapshot()
    #expect(snap.sessions.first?.state == .idle)
}

@Test func centerDropsSessionsWhoseProcessDied() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now }, alive: { _ in false })
    var e = event(.ask, clock); e.pid = 4242
    await center.ingest(e)
    clock.advance(1)
    await center.tick()
    #expect(await center.snapshot().sessions.isEmpty)
}

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
    var get: T { lock.withLock { value } }
}

@Test func centerForwardsTranscriptEffects() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    let seen = LockedBox<[TrackerEffect]>([])
    await center.setEffectHandler { fx in seen.mutate { $0.append(fx) } }

    var ask = event(.ask, clock); ask.tp = "/t.jsonl"
    await center.ingest(ask)
    let key = SessionKey(agent: .claude, session: "s1")
    #expect(seen.get == [.watchTranscript(key, path: "/t.jsonl")])

    clock.advance(1)
    var answered = event(.answered, clock); answered.src = "transcript"
    await center.ingest(answered)
    #expect(seen.get.last == .unwatchTranscript(key))
}

@Test func centerDismissAndDisable() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    await center.ingest(event(.done, clock))
    #expect(await center.display()?.kind == .done)
    clock.advance(1)
    await center.dismissAll()
    #expect(await center.display() == nil)
    var off = AgentAlertSettings(); off.agents["claude"] = false
    await center.updateSettings(off)
    #expect(await center.snapshot().sessions.isEmpty)
}

// MARK: not doing work nobody can see

@Test func eventsThatChangeNothingVisibleArePublishedAtMostOnce() async throws {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    let count = LockedBox<Int>(0)
    let reader = Task { for await _ in center.updates { count.mutate { $0 += 1 } } }
    defer { reader.cancel() }
    var e = event(.working, clock)
    e.cwd = "/w/app"
    await center.ingest(e)
    try await Task.sleep(for: .milliseconds(50))
    let before = count.get
    for i in 0..<200 {
        clock.advance(0.01)
        var again = event(.working, clock); again.ts += Int64(i + 1); again.cwd = "/w/app"
        await center.ingest(again)                      // a PostToolUse: the session is still just "working"
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(count.get - before == 0, "200 invisible events caused \(count.get - before) updates of the interface")

    // A real change still gets through at once.
    clock.advance(1)
    var ask = event(.ask, clock); ask.ts += 1000
    await center.ingest(ask)
    try await Task.sleep(for: .milliseconds(100))
    #expect(count.get - before == 1)
}

@Test func theTimerSlowsDownWhenOnlyHistoryIsLeft() async {
    let clock = Clock()
    let center = AgentCenter(presence: Away(), clock: { clock.now })
    await center.ingest(event(.working, clock))
    #expect(await center.tickInterval == 1)                       // something is happening
    clock.advance(1)
    var end = event(.end, clock); end.ts += 1000
    await center.ingest(end)
    await center.tick()
    let ticking = await center.isTicking
    let interval = await center.tickInterval
    #expect(ticking == false && interval == 0)

    // A finished session the user has not looked at still needs watching for their return;
    // once seen (or dismissed), only slow housekeeping remains.
    clock.advance(1)
    var done = event(.done, clock); done.ts += 5000
    await center.ingest(done)
    #expect(await center.tickInterval == 1)
    clock.advance(1)
    await center.dismissAll()
    await center.tick()
    #expect(await center.tickInterval == 30, "nothing is waiting on time any more")

    clock.advance(1)
    var again = event(.ask, clock); again.ts += 9000
    await center.ingest(again)
    #expect(await center.tickInterval == 1, "and back to one second as soon as something needs watching")
}
