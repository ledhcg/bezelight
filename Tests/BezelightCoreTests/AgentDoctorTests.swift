import Foundation
import Darwin
import Testing
import BezelightAgents
@testable import BezelightCore

private struct Env {
    let root = URL(fileURLWithPath: "/tmp/bz-d-\(UUID().uuidString.prefix(8))", isDirectory: true)
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var paths: BezelightPaths { BezelightPaths(home: root.appendingPathComponent("bz", isDirectory: true)) }
    init() { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func dir(_ p: String) { try? FileManager.default.createDirectory(at: home.appendingPathComponent(p), withIntermediateDirectories: true) }
    func file(_ p: String, _ text: String, mode: Int = 0o644) {
        let url = home.appendingPathComponent(p)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }
    func installer() -> HookInstaller {
        var i = HookInstaller(paths: paths, home: home, environment: ["PATH": "/nonexistent"])
        i.systemBinaryDirs = []
        return i
    }
    func doctor(source: URL? = nil, status: RuntimeStatus = RuntimeStatus(), last: [AgentKind: Date] = [:], now: Date = Date()) -> AgentDoctor {
        AgentDoctor(installer: installer(), deployer: HelperDeployer(paths: paths), helperSource: source,
                    runtime: { status }, lastEvents: { last }, now: { now })
    }
}

private func listening() -> RuntimeStatus { var s = RuntimeStatus(); s.listener = .listening; return s }
private func find(_ checks: [DoctorCheck], _ id: String) -> DoctorCheck? { checks.first { $0.id == id } }

@Test func doctorReportsTheHelperState() async throws {
    let e = Env(); defer { e.remove() }
    let source = e.root.appendingPathComponent("helper-in-app")
    try? FileManager.default.createDirectory(at: e.root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: source.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

    #expect(find(await e.doctor(source: nil).run(), "helper")?.key == "doctor.helper.noSource")
    #expect(find(await e.doctor(source: source).run(), "helper") == .init("helper", .failed, "doctor.helper.missing"))
    try HelperDeployer(paths: e.paths).deploy(source: source)
    #expect(find(await e.doctor(source: source).run(), "helper") == .init("helper", .ok, "doctor.helper.ok"))
    FileManager.default.createFile(atPath: source.path, contents: Data("#!/bin/sh\necho new\n".utf8), attributes: [.posixPermissions: 0o755])
    #expect(find(await e.doctor(source: source).run(), "helper")?.status == .warning)
    chmod(e.paths.helper.path, 0o644)
    FileManager.default.createFile(atPath: source.path, contents: try Data(contentsOf: e.paths.helper), attributes: [.posixPermissions: 0o755])
    #expect(find(await e.doctor(source: source).run(), "helper")?.key == "doctor.helper.notExecutable")
}

@Test func doctorReportsTheListener() async {
    let e = Env(); defer { e.remove() }
    func socket(_ l: RuntimeStatus.Listener) async -> DoctorCheck? {
        var s = RuntimeStatus(); s.listener = l
        return find(await e.doctor(status: s).run(), "socket")
    }
    #expect(await socket(.listening)?.status == .ok)
    #expect(await socket(.stopped)?.key == "doctor.socket.stopped")
    #expect(await socket(.alreadyRunning)?.key == "doctor.socket.otherInstance")
    #expect(await socket(.failed("bind: nope")) == .init("socket", .failed, "doctor.socket.failed", ["bind: nope"]))
}

@Test func doctorRunsARealRoundTripThroughTheInstalledHelper() async throws {
    let helper = try #require(builtHelper())
    let e = Env(); defer { e.remove() }
    try HelperDeployer(paths: e.paths).deploy(source: helper)

    // Nobody listening although the app claims to be: the round trip must fail loudly.
    let missing = find(await e.doctor(source: helper, status: listening()).run(), "roundtrip")
    #expect(missing?.status == .failed)

    let got = Box<[AgentEvent]>([])
    let server = AgentHookServer(paths: e.paths) { ev in got.mutate { $0.append(ev) } }
    try server.start(); defer { server.stop() }
    #expect(find(await e.doctor(source: helper, status: listening()).run(), "roundtrip") == .init("roundtrip", .ok, "doctor.roundtrip.ok"))
    #expect(await eventually { got.value.first?.src == "selftest" })
}

@Test func doctorChecksEachClaudeFolder() async throws {
    let e = Env(); defer { e.remove() }
    e.file(".claude/settings.json", Fixtures.text("claude-settings-orca"))
    e.file(".claude-accounts/work/settings.json", "{ not json")
    let inst = e.installer()
    for t in inst.targets(for: .claude) where t.label == "~/.claude" { try inst.install(t) }

    let checks = await e.doctor(status: listening()).run()
    #expect(find(checks, "claude:~/.claude")?.key == "doctor.hooks.installed")
    #expect(find(checks, "claude:~/.claude")?.status == .ok)
    #expect(find(checks, "claude:~/.claude-accounts/work")?.status == .failed)
    #expect(find(checks, "claude:~/.claude-accounts/work")?.key == "doctor.hooks.unreadable")
}

@Test func doctorWarnsWhenTheActiveFolderHasNoHooks() async {
    let e = Env(); defer { e.remove() }
    e.file(".claude/settings.json", "{}")
    let checks = await e.doctor().run()
    #expect(find(checks, "claude:~/.claude") == .init("claude:~/.claude", .warning, "doctor.hooks.notInstalled", ["Claude Code", "~/.claude"]))
}

@Test func doctorSpotsDisabledHooksPartialInstallsAndReadOnlyFiles() async throws {
    let e = Env(); defer { e.remove() }
    e.file(".codex/hooks.json", "{\"disableAllHooks\": true, \"hooks\": {}}", mode: 0o444)
    var checks = await e.doctor().run()
    #expect(find(checks, "codex:~/.codex:disabled")?.status == .warning)
    #expect(find(checks, "codex:~/.codex:readonly")?.status == .warning)

    chmod(e.home.appendingPathComponent(".codex/hooks.json").path, 0o644)
    let inst = e.installer()
    let t = try #require(inst.targets(for: .codex).first)
    try inst.install(t)
    let stale = (try String(contentsOf: t.file, encoding: .utf8)).replacingOccurrences(of: "\"timeout\": 5", with: "\"timeout\": 77")
    try stale.write(to: t.file, atomically: true, encoding: .utf8)
    checks = await e.doctor().run()
    let partial = find(checks, "codex:~/.codex")
    #expect(partial?.key == "doctor.hooks.partial" && partial?.args.last?.contains("Stop") == true)
}

@Test func doctorExplainsASilentAgentAndCelebratesALiveOne() async throws {
    let e = Env(); defer { e.remove() }
    e.file(".codex/hooks.json", "{}")
    e.file(".claude/settings.json", "{}")
    let inst = e.installer()
    for agent in [AgentKind.claude, .codex] { for t in inst.targets(for: agent) { try inst.install(t) } }

    var checks = await e.doctor().run()
    #expect(find(checks, "codex:last")?.key == "doctor.codex.noEventTrust")      // installed but unproven: remind about /hooks
    #expect(find(checks, "claude:last")?.key == "doctor.claude.noEventRestart")  // and to restart the session

    let now = Date()
    checks = await e.doctor(last: [.claude: now.addingTimeInterval(-300), .codex: now.addingTimeInterval(-7200)], now: now).run()
    #expect(find(checks, "claude:last") == .init("claude:last", .ok, "doctor.agent.lastEvent", ["Claude Code", "5 min"]))
    #expect(find(checks, "codex:last")?.args == ["Codex", "2 h"])
}

@Test func doctorHandlesAgentsThatAreNotThere() async {
    let e = Env(); defer { e.remove() }
    let checks = await e.doctor().run()
    #expect(find(checks, "claude")?.key == "doctor.agent.notFound" && find(checks, "codex")?.status == .info)
    #expect(find(checks, "opencode")?.key == "doctor.agent.notFound")
}

@Test func doctorReportsOpenCodesConnection() async {
    let e = Env(); defer { e.remove() }
    e.file(".local/state/opencode/service.json", "{}")
    func check(_ s: OpenCodeStreamClient.State) async -> DoctorCheck? {
        var st = listening(); st.openCode = s
        return find(await e.doctor(status: st).run(), "opencode")
    }
    #expect(await check(.connected(version: "2.0.28")) == .init("opencode", .ok, "doctor.opencode.connected", ["2.0.28"]))
    #expect(await check(.waitingForOpenCode)?.status == .info)
    #expect(await check(.failed("OpenCode refused the password")) == .init("opencode", .failed, "doctor.opencode.failed", ["OpenCode refused the password"]))
    #expect(await check(.stopped)?.status == .warning)
    #expect(await check(.connecting)?.key == "doctor.opencode.connecting")
}

@Test func theReportHidesTheHomeFolderAndNeverNamesASession() async throws {
    let e = Env(); defer { e.remove() }
    e.file(".claude/settings.json", "{}")
    let d = e.doctor()
    let checks = await d.run()
    let text = d.report(checks) { key, args in "\(key) \(args.joined(separator: " | "))" + " \(e.home.path)/secret" }
    #expect(!text.contains(e.home.path) && text.contains("~/secret"))
    #expect(text.contains("[warn]") && text.contains("[info]"))
    #expect(text.split(separator: "\n").count == checks.count)
}

@Test func agoIsReadable() {
    #expect(AgentDoctor.ago(5) == "5s" && AgentDoctor.ago(89) == "89s" && AgentDoctor.ago(120) == "2 min")
    #expect(AgentDoctor.ago(3600) == "60 min" && AgentDoctor.ago(7200) == "2 h" && AgentDoctor.ago(86_400 * 3) == "3 d")
    #expect(AgentDoctor.ago(-10) == "0s")
}

@Test func theCenterRemembersWhenEachAgentLastSpoke() async {
    struct Away: PresenceProvider { func sample(now: Date) -> PresenceSample { .away(now: now) } }
    let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
    let center = AgentCenter(presence: Away(), clock: { clock.value })
    await center.ingest(AgentEvent(agent: .claude, kind: .working, session: "a", ts: 1_800_000_000_000))
    clock.value = clock.value.addingTimeInterval(10)
    await center.ingest(AgentEvent(agent: .codex, kind: .ask, session: "b", ts: 1_800_000_010_000))
    clock.value = clock.value.addingTimeInterval(10)
    await center.ingest(AgentEvent(agent: .opencode, kind: .seen, session: "selftest", ts: 1_800_000_020_000, src: "selftest"))
    let seen = await center.lastEventTimes()
    #expect(seen[.claude] == Date(timeIntervalSince1970: 1_800_000_000) && seen[.codex] == Date(timeIntervalSince1970: 1_800_000_010))
    #expect(seen[.opencode] == nil, "the self-test must not count as the agent being alive")
}
