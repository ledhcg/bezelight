import Foundation
import Darwin
import Testing
import BezelightAgents
@testable import BezelightCore

private func event(_ kind: EventKind, session: String = "s1", ts: Int64 = 1_800_000_000_000) -> AgentEvent {
    AgentEvent(agent: .claude, kind: kind, session: session, ts: ts)
}

private func send(_ e: AgentEvent, to server: AgentHookServer) -> Bool {
    DatagramSender.send(Wire.encode(e)!, toSocketAt: server.socketPath)
}

@Test func serverDeliversEventsInOrder() async throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([])
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { e in got.mutate { $0.append(e) } }
    try server.start(); defer { server.stop() }
    #expect(server.isRunning)
    for (i, kind) in [EventKind.ask, .answered, .done].enumerated() {
        #expect(send(event(kind, session: "s\(i)", ts: 1_800_000_000_000 + Int64(i)), to: server))
    }
    #expect(await eventually { got.value.count == 3 })
    #expect(got.value.map(\.kind) == [.ask, .answered, .done])
}

@Test func serverIsPrivate() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let home = dir.appendingPathComponent("home")
    let server = AgentHookServer(paths: BezelightPaths(home: home)) { _ in }
    try server.start(); defer { server.stop() }
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }
    #expect(mode(home) == 0o700)
    #expect(mode(BezelightPaths(home: home).socket) == 0o600)
}

@Test func onlyOneServerMayOwnTheSocket() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = BezelightPaths(home: dir)
    let first = AgentHookServer(paths: paths) { _ in }
    try first.start()
    let second = AgentHookServer(paths: paths) { _ in }
    #expect(throws: AgentHookServer.StartError.alreadyRunning) { try second.start() }
    #expect(!second.isRunning)
    first.stop()
    try second.start()                                       // free again once the first one is gone
    second.stop()
}

@Test func stopRemovesTheSocketAndIsRepeatable() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = BezelightPaths(home: dir)
    let server = AgentHookServer(paths: paths) { _ in }
    try server.start()
    #expect(FileManager.default.fileExists(atPath: paths.socket.path))
    server.stop(); server.stop()
    #expect(!FileManager.default.fileExists(atPath: paths.socket.path) && !server.isRunning)
    #expect(!DatagramSender.send(Data("x".utf8), toSocketAt: paths.socket.path))
}

@Test func aSocketLeftByACrashIsReplaced() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let paths = BezelightPaths(home: dir)
    FileManager.default.createFile(atPath: paths.socket.path, contents: Data("stale".utf8))
    let server = AgentHookServer(paths: paths) { _ in }
    try server.start(); defer { server.stop() }
    #expect(DatagramSender.send(Wire.encode(event(.done))!, toSocketAt: paths.socket.path))
}

@Test func tooLongAPathIsRefusedNotTruncated() {
    let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120))
    let server = AgentHookServer(paths: BezelightPaths(home: long)) { _ in }
    #expect(throws: (any Error).self) { try server.start() }
}

@Test func garbageIsDroppedAndCounted() async throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<Int>(0)
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { _ in got.mutate { $0 += 1 } }
    try server.start(); defer { server.stop() }
    for junk in ["", "not json", "{}", #"{"v":9,"agent":"claude","kind":"done","session":"s","ts":1}"#, String(repeating: "x", count: 1900)] {
        _ = DatagramSender.send(Data(junk.utf8), toSocketAt: server.socketPath)
    }
    _ = send(event(.done), to: server)                       // a good one after the bad ones still arrives
    #expect(await eventually { got.value == 1 })
    #expect(server.dropped >= 3)
}

@Test func burstsOfWorkingAreCoalescedButNothingElseIs() async throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let working = Box<Int>(0), other = Box<Int>(0)
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { e in
        if e.kind == .working { working.mutate { $0 += 1 } } else { other.mutate { $0 += 1 } }
    }
    try server.start(); defer { server.stop() }
    for i in 0..<60 {
        _ = send(event(.working, ts: 1_800_000_000_000 + Int64(i)), to: server)    // a tool-heavy turn
        if i % 20 == 0 { _ = send(event(.ask, session: "q\(i)", ts: 1_800_000_000_000 + Int64(i)), to: server) }
    }
    #expect(await eventually(timeout: 3) { other.value == 3 })
    #expect(working.value >= 1 && working.value < 60)
    #expect(other.value == 3)
}

@Test func differentSessionsAreNotCoalescedTogether() async throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<Set<String>>([])
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { e in got.mutate { $0.insert(e.session) } }
    try server.start(); defer { server.stop() }
    for i in 0..<5 { _ = send(event(.working, session: "s\(i)"), to: server) }
    #expect(await eventually { got.value.count == 5 })
}

@Test func aWorkingEventThatFollowsAQuestionIsNeverCoalescedAway() async throws {
    // working -> ask -> working within a few milliseconds: the last one is the answer to the
    // question (Claude sends no separate "answered" event), so dropping it would leave the
    // light on for something nobody is waiting for any more.
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[EventKind]>([])
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { e in got.mutate { $0.append(e.kind) } }
    try server.start(); defer { server.stop() }
    let t = Int64(1_800_000_000_000)
    _ = send(event(.working, ts: t), to: server)
    _ = send(event(.ask, ts: t + 1), to: server)
    _ = send(event(.working, ts: t + 2), to: server)
    _ = send(event(.working, ts: t + 3), to: server)        // a true duplicate: this one may go
    #expect(await eventually { got.value.count >= 3 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(got.value == [.working, .ask, .working])
}
