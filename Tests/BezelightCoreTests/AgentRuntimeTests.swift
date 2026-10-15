import Foundation
import Darwin
import Testing
import BezelightAgents
@testable import BezelightCore

private struct Away: PresenceProvider { func sample(now: Date) -> PresenceSample { .away(now: now) } }

/// A fixture with the session and transcript replaced, as the real agent would send it.
private func hookInput(_ fixture: String, session: String, transcript: String? = nil, agentID: String? = nil) -> Data {
    var o = try! JSONSerialization.jsonObject(with: Fixtures.data(fixture)) as! [String: Any]
    o["session_id"] = session
    if let transcript { o["transcript_path"] = transcript }
    if let agentID { o["agent_id"] = agentID }
    return try! JSONSerialization.data(withJSONObject: o)
}

private struct RuntimeRig {
    let dir: URL
    let paths: BezelightPaths
    let center: AgentCenter
    let runtime: AgentRuntime
    let helper: URL

    static func make(openCodeFile: URL? = nil) async throws -> RuntimeRig {
        let helper = try #require(builtHelper(), "bezelight-hook is not built next to the tests")
        let dir = makeShortTempDir()
        let paths = BezelightPaths(home: dir)
        let center = AgentCenter(presence: Away())
        let runtime = AgentRuntime(center: center, paths: paths, openCodeServiceFile: openCodeFile ?? dir.appendingPathComponent("no-opencode.json"))
        await runtime.start()
        return RuntimeRig(dir: dir, paths: paths, center: center, runtime: runtime, helper: helper)
    }

    func hook(_ agent: String, _ fixture: String, session: String, transcript: String? = nil, agentID: String? = nil) throws {
        let r = try runHelper(helper, [agent], input: hookInput(fixture, session: session, transcript: transcript, agentID: agentID), home: dir)
        #expect(r.out == "{}\n" && r.status == 0)
    }

    func state(_ session: String) async -> SessionState? {
        await center.snapshot().sessions.first { $0.id.session == session }?.state
    }

    func finish() async { await runtime.stop(); try? FileManager.default.removeItem(at: dir) }
}

@Test func aRealHelperDrivesTheAppThroughAClaudeTurn() async throws {
    let rig = try await RuntimeRig.make(); 
    let transcript = rig.dir.appendingPathComponent("t.jsonl"); FileManager.default.createFile(atPath: transcript.path, contents: Data())
    let s = "claude-turn"

    try rig.hook("claude", "claude/UserPromptSubmit", session: s)
    #expect(await eventually { await rig.state(s) == .working })

    try rig.hook("claude", "claude/PermissionRequest.bash", session: s, transcript: transcript.path)
    #expect(await eventually { await rig.center.display()?.kind == .needsInput })

    try rig.hook("claude", "claude/PostToolUse.bash", session: s)
    #expect(await eventually { await rig.state(s) == .working })

    try rig.hook("claude", "claude/Stop", session: s)
    #expect(await eventually { await rig.center.display()?.kind == .done })

    try rig.hook("claude", "claude/SessionEnd", session: s)
    #expect(await eventually { await rig.center.snapshot().sessions.isEmpty })
    await rig.finish()
}

@Test func aRefusedPermissionIsNoticedThroughTheTranscript() async throws {
    let rig = try await RuntimeRig.make()
    let transcript = rig.dir.appendingPathComponent("t.jsonl"); FileManager.default.createFile(atPath: transcript.path, contents: Data())
    let s = "claude-refused"
    try rig.hook("claude", "claude/PermissionRequest.bash", session: s, transcript: transcript.path)
    #expect(await eventually { await rig.state(s) == .needsInput })
    try await Task.sleep(for: .milliseconds(300))
    #expect(await rig.state(s) == .needsInput, "nothing has happened yet, so it must still be waiting")

    // The user says no: Claude fires no hook, but writes the refusal into the transcript.
    let h = try FileHandle(forWritingTo: transcript)
    h.write(Data(#"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true}]}}"#.utf8 + [0x0A]))
    try h.synchronize()
    #expect(await eventually { await rig.state(s) == .working })
    let session = await rig.center.snapshot().sessions.first { $0.id.session == s }
    #expect(session?.unconfirmed == true && session?.pendingCount == 0)
    #expect(await rig.center.display() == nil)
    await rig.finish()
}

@Test func codexInterruptEndsTheQuestion() async throws {
    let rig = try await RuntimeRig.make()
    try rig.hook("codex", "codex/PermissionRequest.bash", session: "cx")
    #expect(await eventually { await rig.center.display()?.kind == .needsInput })
    try rig.hook("codex", "codex/Interrupt", session: "cx")
    #expect(await eventually { await rig.state("cx") == .idle })
    #expect(await rig.center.display() == nil)
    await rig.finish()
}

@Test func aSubagentsQuestionIsAttributedToItsSession() async throws {
    let rig = try await RuntimeRig.make()
    try rig.hook("claude", "claude/UserPromptSubmit", session: "sa")
    try rig.hook("claude", "claude/SubagentStart.subagent", session: "sa", agentID: "agent-1")
    try rig.hook("claude", "claude/Stop", session: "sa")                              // main turn ends, subagent runs on
    try rig.hook("claude", "claude/PermissionRequest.bash.subagent", session: "sa", agentID: "agent-1")
    #expect(await eventually { await rig.center.display()?.kind == .needsInput })
    try rig.hook("claude", "claude/SubagentStop.subagent", session: "sa", agentID: "agent-1")
    #expect(await eventually { await rig.center.display()?.kind == .done })
    await rig.finish()
}

@Test func openCodeEventsFlowThroughTheSameRuntime() async throws {
    func frame(_ type: String, _ data: String) -> String { #"data: {"id":"e","created":\#(Int(Date().timeIntervalSince1970 * 1000)),"type":"\#(type)","data":\#(data)}"# + "\n\n" }
    let sse = frame("session.created", #"{"sessionID":"oc1","location":{"directory":"/w/app"}}"#)
        + frame("session.execution.started", #"{"sessionID":"oc1"}"#)
        + frame("permission.asked", #"{"id":"per_1","sessionID":"oc1"}"#)
    let server = FakeSSEServer { _ in .init(chunks: [(0, sse)], close: false) }
    defer { server.stop() }
    let dir = makeShortTempDir()
    let file = dir.appendingPathComponent("service.json")
    try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:\(server.port)", "password": "pw"]).write(to: file)
    let rig = try await RuntimeRig.make(openCodeFile: file)
    #expect(await eventually { await rig.center.display()?.kind == .needsInput })
    #expect(rig.runtime.currentStatus().openCode == .connected(version: nil))
    #expect(rig.runtime.currentStatus().listener == .listening)
    await rig.finish(); try? FileManager.default.removeItem(at: dir)
}

@Test func eventsFromManySendersKeepTheirOrder() async throws {
    // If each event were handed to its own task they could overtake one another, and the tracker
    // drops an event older than one it has already seen. A question must never be lost that way.
    let rig = try await RuntimeRig.make()
    let base = Int64(Date().timeIntervalSince1970 * 1000)
    for i in 0..<300 {
        var e = AgentEvent(agent: .claude, kind: i == 299 ? .ask : (i % 2 == 0 ? .working : .substart), session: "ord", ts: base + Int64(i), sub: i % 2 == 0 ? nil : "a\(i)")
        if i == 299 { e.sub = nil }
        _ = DatagramSender.send(Wire.encode(e)!, toSocketAt: rig.paths.socket.path)
    }
    #expect(await eventually { await rig.state("ord") == .needsInput })
    await rig.finish()
}

@Test func theRuntimeReportsASecondInstance() async throws {
    let rig = try await RuntimeRig.make()
    let second = AgentRuntime(center: AgentCenter(presence: Away()), paths: rig.paths, openCodeServiceFile: rig.dir.appendingPathComponent("x.json"))
    await second.start()
    #expect(second.currentStatus().listener == .alreadyRunning)
    await second.stop()
    #expect(rig.runtime.currentStatus().listener == .listening)
    await rig.finish()
}

@Test func theRuntimeStopsCleanlyAndCanRestart() async throws {
    let rig = try await RuntimeRig.make()
    await rig.runtime.stop()
    #expect(rig.runtime.currentStatus() == RuntimeStatus())
    #expect(!FileManager.default.fileExists(atPath: rig.paths.socket.path))
    await rig.runtime.start()
    #expect(rig.runtime.currentStatus().listener == .listening)
    await rig.finish()
}

// MARK: the helper itself

@Test func theHelperIsHarmlessWhenTheAppIsNotRunning() throws {
    let helper = try #require(builtHelper())
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    for (args, input) in [(["claude"], Fixtures.data("claude/Stop")), (["codex"], Fixtures.data("codex/Stop")),
                          (["claude"], Data("garbage".utf8)), (["claude"], Data()), (["bogus"], Data("x".utf8)), ([String](), Data())] {
        let r = try runHelper(helper, args, input: input, home: dir)
        #expect(r.out == "{}\n" && r.status == 0, "args \(args)")
        #expect(r.seconds < 2)
    }
}

@Test func theHelperSelftestSeesTheApp() throws {
    let helper = try #require(builtHelper())
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try runHelper(helper, ["--selftest"], input: Data(), home: dir).out.hasPrefix("not delivered"))
    let got = Box<Int>(0)
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { _ in got.mutate { $0 += 1 } }
    try server.start(); defer { server.stop() }
    #expect(try runHelper(helper, ["--selftest"], input: Data(), home: dir).out.hasPrefix("ok"))
    #expect(try runHelper(helper, ["--version"], input: Data(), home: dir).out == HookCLI.version + "\n")
}

@Test func theHelperStartsFast() throws {
    // A debug build with no optimisation: the bar is generous, but an accidental heavy import
    // (AppKit, ScreenCaptureKit) would push it far past this.
    let helper = try #require(builtHelper())
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let server = AgentHookServer(paths: BezelightPaths(home: dir)) { _ in }
    try server.start(); defer { server.stop() }
    let input = Fixtures.data("claude/PostToolUse.bash")
    var times: [Double] = []
    for _ in 0..<20 { times.append(try runHelper(helper, ["claude"], input: input, home: dir).seconds) }
    times.sort()
    #expect(times[times.count / 2] < 0.15, "median \(times[times.count / 2] * 1000) ms")
}

// MARK: the exact command that gets written into the agents' settings

@Test func theInstalledCommandRunsTheDeployedHelperThroughAShell() async throws {
    let helper = try #require(builtHelper())
    let home = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: home) }
    // A pretend $HOME with the helper where the command expects it.
    let bin = home.appendingPathComponent(".bezelight/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: helper, to: bin.appendingPathComponent("bezelight-hook"))

    let got = Box<[AgentEvent]>([])
    let server = AgentHookServer(paths: BezelightPaths(home: home.appendingPathComponent(".bezelight"))) { e in got.mutate { $0.append(e) } }
    try server.start(); defer { server.stop() }

    for agent in [AgentKind.claude, .codex] {
        let command = HookCatalog.command(for: agent)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]                       // how Claude Code and Codex run a hook
        p.environment = ["HOME": home.path, "BEZELIGHT_HOME": home.appendingPathComponent(".bezelight").path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Fixtures.data(agent == .claude ? "claude/PermissionRequest.bash" : "codex/PermissionRequest.bash"))
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "{}\n", "exactly one {} - the fallback must not also print")
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
    #expect(await eventually { got.value.count == 2 })
    #expect(Set(got.value.map(\.agent)) == [.claude, .codex] && got.value.allSatisfy { $0.kind == .ask })
}
