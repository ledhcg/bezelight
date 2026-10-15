import Foundation
import Darwin
import Testing
import BezelightAgents
@testable import BezelightCore

private struct Away: PresenceProvider { func sample(now: Date) -> PresenceSample { .away(now: now) } }

private struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

private func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

private func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

/// Three agents, twenty sessions each, behaving badly: they start, ask, get answered or refused,
/// finish, are interrupted, spawn subagents, vanish. The checks are the invariants that must hold
/// at every moment, and that nothing is left behind at the end.
///
/// `BEZELIGHT_SOAK_SECONDS=600 swift test --filter soak` runs it for ten minutes (scripts/soak.sh).
@Test func soak() async throws {
    let seconds = Double(ProcessInfo.processInfo.environment["BEZELIGHT_SOAK_SECONDS"] ?? "") ?? 2
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = BezelightPaths(home: dir)
    let center = AgentCenter(presence: Away())
    let runtime = AgentRuntime(center: center, paths: paths, openCodeServiceFile: dir.appendingPathComponent("none.json"))
    await runtime.start()

    let fdsBefore = openDescriptors()
    var rng = Rng(s: 0x50AC)
    var ts = Int64(Date().timeIntervalSince1970 * 1000)
    var generation = 0
    var live: [(AgentKind, String)] = (0..<60).map { i in (AgentKind.allCases[i % 3], "soak-\(i)-0") }
    var sent = 0

    func send(_ kind: EventKind, _ s: (AgentKind, String), sub: String? = nil, req: String? = nil) {
        ts += 1 + Int64(rng.int(3))
        let e = AgentEvent(agent: s.0, kind: kind, session: s.1, ts: ts, req: req, sub: sub, cwd: "/w/project-\(s.1.count % 7)", pid: nil)
        _ = DatagramSender.send(Wire.encode(e)!, toSocketAt: paths.socket.path)
        sent += 1
    }

    var violations: [String] = []
    func check() async {
        let snap = await center.snapshot()
        #expect(snap.sessions.count <= AgentTracker.maxSessions)
        for s in snap.sessions {
            if s.state == .needsInput && s.pendingCount == 0 { violations.append("\(s.id) needsInput with nothing pending") }
            if s.pendingCount > 0 && s.state != .needsInput { violations.append("\(s.id) \(s.state) with \(s.pendingCount) pending") }
        }
        if snap.sessions.contains(where: { $0.state == .needsInput }) {
            if snap.display?.kind != .needsInput { violations.append("a session needs the user but the strip shows \(String(describing: snap.display?.kind))") }
        }
        #expect(snap.waiting == snap.sessions.filter { $0.state == .needsInput }.count)
    }

    let end = Date().addingTimeInterval(seconds)
    var lastCheck = Date()
    var midMemory: Double?
    let start = Date()
    while Date() < end {
        let i = rng.int(live.count)
        let s = live[i]
        switch rng.int(14) {
        case 0, 1: send(.working, s)
        case 2: send(.ask, s, req: s.0 == .opencode ? "r\(rng.int(3))" : nil)
        case 3: send(.answered, s, req: s.0 == .opencode ? "r\(rng.int(3))" : nil)
        case 4: send(.working, s)                                            // the answer, for hook-based agents
        case 5: send(.done, s)
        case 6: send(.error, s)
        case 7: send(.interrupt, s)
        case 8: send(.substart, s, sub: "a\(rng.int(3))")
        case 9: send(.substop, s, sub: "a\(rng.int(3))")
        case 10: send(.seen, s)
        case 11: send(.ask, s, sub: "a\(rng.int(3))")
        case 12:                                                             // the session ends and another begins
            send(.end, s)
            generation += 1
            live[i] = (s.0, "soak-\(i)-\(generation)")
            send(.start, live[i])
        default: send(.start, s)
        }
        // ~400 events a second across 60 sessions: far busier than real agents, below the server's flood limit.
        if sent % 2 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        if Date().timeIntervalSince(lastCheck) > 0.4 { await check(); lastCheck = Date() }
        if midMemory == nil, Date().timeIntervalSince(start) > seconds / 2 { midMemory = residentMB() }
    }
    await check()
    #expect(violations.isEmpty, "\(violations.prefix(5))")
    #expect(sent > 100)

    // Everybody leaves: nothing may be left behind.
    try await Task.sleep(for: .milliseconds(1200))                          // let the server's one-second window reset
    for s in live { send(.end, s); try await Task.sleep(for: .milliseconds(2)) }
    #expect(await eventually(timeout: 10) { await center.snapshot().sessions.isEmpty })
    await center.tick()
    #expect(await center.isTicking == false, "the one-second timer must stop when there is nothing to watch")
    #expect(await center.display() == nil)

    await runtime.stop()
    try await Task.sleep(for: .milliseconds(200))
    let fdsAfter = openDescriptors()
    // Run alone (scripts/soak.sh) the count must come back exactly. Inside the full test run other tests
    // open and close files at the same moment, so allow noise: a real leak grows with the hundreds of events and sessions sent here.
    let alone = ProcessInfo.processInfo.environment["BEZELIGHT_SOAK_SECONDS"] != nil
    #expect(abs(fdsAfter - fdsBefore) <= (alone ? 3 : 150), "file descriptors leaked: \(fdsBefore) -> \(fdsAfter)")
    if let mid = midMemory, seconds >= 60 {
        #expect(residentMB() - mid < 30, "memory kept growing: \(mid) MB -> \(residentMB()) MB")
    }
    print("soak: \(Int(seconds)) s, \(sent) events, \(fdsBefore)->\(fdsAfter) fds, \(Int(residentMB())) MB")
}

// MARK: speed

private struct Clock { static func measure(_ body: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; body(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9 } }

@Test func renderingAnAlertIsCheapEnoughForEveryFrame() {
    // 30 frames a second on the longest strip (1024 LEDs). Debug build, so the bar is generous.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let spec = OverlaySpec(display: DisplayState(kind: .needsInput, since: t0, waitingCount: 3, sessionCount: 3),
                           style: AgentAlertSettings().needsInput, multiPattern: .doubleBeat, overlayBrightness: 1, minBrightness: 0.4, reduceMotion: false, crossfadeMs: 250)
    let base = [LEDColor](repeating: LEDColor(r: 10, g: 20, b: 30), count: 1024)
    var sink = 0
    let seconds = Clock.measure {
        for i in 0..<1000 { sink &+= Int(AgentOverlay.render(spec, now: t0.addingTimeInterval(Double(i) / 30), ledCount: 1024, base: base)?.frame[0].r ?? 0) }
    }
    // Unoptimised code: a release build is 20-50x faster. The bar only has to catch an accident.
    #expect(seconds / 1000 < 0.003, "\(seconds) ms per frame")
    #expect(sink >= 0)
}

@Test func theTrackerKeepsUpWithAnyRealisticEventRate() {
    var rig = Rig()
    var rng = Rng(s: 7)
    let seconds = Clock.measure {
        for i in 0..<60_000 {
            rig.advance(0.0001)
            rig.send([EventKind.working, .ask, .answered, .done, .working][rng.int(5)], AgentKind.allCases[rng.int(3)], session: "s\(i % 60)", req: "r\(rng.int(3))")
        }
    }
    #expect(seconds < 3, "60,000 events took \(seconds) s")                              // real agents produce a few per second
    let showing = Clock.measure { for _ in 0..<2000 { _ = rig.tracker.display(now: rig.now) } }
    #expect(showing / 2000 < 0.0005, "display() took \(showing / 2000 * 1000) ms")
}

@Test func theSSEParserKeepsUpWithAStreamOfDeltas() {
    var parser = SSEParser()
    let line = Data((#"data: {"id":"e","created":1,"type":"session.text.delta","data":{"sessionID":"s","delta":"some streamed text"}}"# + "\n\n").utf8)
    var frames = 0
    let seconds = Clock.measure { for _ in 0..<50_000 { frames += parser.feed(line).count } }
    #expect(frames == 50_000 && seconds < 3, "\(seconds) s")
}
