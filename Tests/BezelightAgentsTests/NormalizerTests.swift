import Foundation
import Testing
@testable import BezelightAgents

private let T: Int64 = 1_800_000_000_000
private let claudeSession = "c1fba868-a541-42ab-8008-60a7d82a753d"
private let subagent = "ad828c66f3500209c"
private let root = "ses_ec9491f56ffex9TnVTY0kxh7p4"
private let child = "ses_ec94789adffeMigXP3HDlrxao3"

private func claude(_ name: String) -> [AgentEvent] { ClaudeNormalizer.events(from: Fixtures.data("claude/\(name)"), now: T, pid: 77) }
private func codex(_ name: String) -> [AgentEvent] { CodexNormalizer.events(from: Fixtures.data("codex/\(name)"), now: T, pid: 88) }

private func one(_ events: [AgentEvent], sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentEvent {
    try #require(events.count == 1 ? events.first : nil, "expected exactly one event", sourceLocation: sourceLocation)
}

// MARK: Claude

@Test func claudeLifecycle() throws {
    #expect(try one(claude("SessionStart")).kind == .start)
    #expect(try one(claude("UserPromptSubmit")).kind == .working)
    #expect(try one(claude("PostToolUse.bash")).kind == .working)
    #expect(try one(claude("Stop")).kind == .done)
    #expect(try one(claude("SessionEnd")).kind == .end)
    let e = try one(claude("Stop"))
    #expect(e.session == claudeSession && e.agent == .claude && e.ts == T && e.pid == 77 && e.src == "Stop")
    #expect(e.cwd == "/Users/me/work/app")
}

@Test func claudePermissionRequestIsAsk() throws {
    let e = try one(claude("PermissionRequest.bash"))
    #expect(e.kind == .ask && e.sub == nil)
    #expect(e.tp == "/Users/me/.claude/projects/p/SESSION.jsonl")
    // AskUserQuestion arrives as a PermissionRequest too (Phase 0).
    #expect(try one(claude("PermissionRequest.askuserquestion")).kind == .ask)
}

@Test func claudeSubagentEvents() throws {
    let ask = try one(claude("PermissionRequest.bash.subagent"))
    #expect(ask.kind == .ask && ask.sub == subagent)
    #expect(try one(claude("SubagentStart.subagent")).sub == subagent)
    #expect(try one(claude("SubagentStart.subagent")).kind == .substart)
    #expect(try one(claude("SubagentStop.subagent")).kind == .substop)
    // The internal helper has an id but no SubagentStart; the tracker ignores it, the normalizer still reports it.
    #expect(try one(claude("SubagentStop.subagent.internal")).sub == "a7c4039df9cffea00")
}

@Test func claudeIgnoresRedundantPermissionNotification() {
    // Arrives ~6 s after the PermissionRequest that already reported it.
    #expect(claude("Notification.permission_prompt").isEmpty)
}

@Test func claudeElicitationNotificationIsAsk() throws {
    let json = Data(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"private text","cwd":"/a/b"}"#.utf8)
    let e = try one(ClaudeNormalizer.events(from: json, now: T))
    #expect(e.kind == .ask && e.tp == nil)
    let idle = Data(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"idle_prompt"}"#.utf8)
    #expect(ClaudeNormalizer.events(from: idle, now: T).isEmpty)
}

@Test func claudeFailureMapsToError() throws {
    let json = Data(#"{"session_id":"s1","hook_event_name":"StopFailure","error":"rate_limit"}"#.utf8)
    #expect(try one(ClaudeNormalizer.events(from: json, now: T)).kind == .error)
}

@Test func claudeBadInputYieldsNothing() {
    for raw in ["", "{", "[]", #"{"hook_event_name":"Stop"}"#, #"{"session_id":"s"}"#, #"{"session_id":"s","hook_event_name":"Weird"}"#] {
        #expect(ClaudeNormalizer.events(from: Data(raw.utf8), now: T).isEmpty, "\(raw)")
    }
}

// MARK: Codex

@Test func codexLifecycle() throws {
    #expect(try one(codex("SessionStart")).kind == .start)
    #expect(try one(codex("UserPromptSubmit")).kind == .working)
    #expect(try one(codex("PermissionRequest.bash")).kind == .ask)
    #expect(try one(codex("PostToolUse.bash")).kind == .working)
    #expect(try one(codex("Stop")).kind == .done)
    #expect(try one(codex("Interrupt")).kind == .interrupt)
    #expect(try one(codex("SessionEnd")).kind == .end)
    #expect(try one(codex("Stop")).agent == .codex && (try one(codex("Stop")).pid == 88))
}

// MARK: OpenCode

private func opencode(_ names: [String], _ n: inout OpenCodeNormalizer) -> [AgentEvent] {
    names.flatMap { n.events(from: Fixtures.data("opencode/\($0)"), now: T) }
}

@Test func openCodeRootLifecycle() throws {
    var n = OpenCodeNormalizer()
    let e = opencode(["session.created.root", "session.execution.started", "session.execution.succeeded",
                      "session.execution.failed", "session.execution.interrupted.user", "session.viewed"], &n)
    #expect(e.map(\.kind) == [.start, .working, .done, .error, .interrupt, .seen])
    #expect(e.allSatisfy { $0.session == root && $0.sub == nil && $0.agent == .opencode })
    #expect(e[0].cwd == "/Users/me/work/app")
}

@Test func openCodePermissionAndForm() throws {
    var n = OpenCodeNormalizer()
    let e = opencode(["permission.asked", "permission.replied.once", "form.created", "form.replied"], &n)
    #expect(e.map(\.kind) == [.ask, .answered, .ask, .answered])
    #expect(e[0].req == "per_136b6ee940015UD5UPaWH8pdbF" && e[1].req == e[0].req)
    #expect(e[2].req == "frm_136b810330011lcguofgVhaBzM" && e[3].req == e[2].req)
}

@Test func openCodeChildSessionFoldsIntoRoot() throws {
    var n = OpenCodeNormalizer()
    _ = opencode(["session.created.root"], &n)
    let created = opencode(["session.created.child"], &n)
    #expect(created.count == 1 && created[0].kind == .substart && created[0].session == root && created[0].sub == child)

    func frame(_ type: String, _ data: String) -> Data { Data(#"{"id":"e","created":5,"type":"\#(type)","data":\#(data)}"#.utf8) }
    let ask = n.events(from: frame("permission.asked", #"{"id":"per_1","sessionID":"\#(child)"}"#), now: T)
    #expect(ask.count == 1 && ask[0].kind == .ask && ask[0].session == root && ask[0].sub == child)

    // A child finishing is not the root finishing, whatever way it ends.
    for (type, expected) in [("session.execution.succeeded", EventKind.substop), ("session.execution.failed", .substop),
                             ("session.execution.interrupted", .substop)] {
        let ev = n.events(from: frame(type, #"{"sessionID":"\#(child)"}"#), now: T)
        #expect(ev.count == 1 && ev[0].kind == expected && ev[0].session == root && ev[0].sub == child, "\(type)")
    }
    // The child's own start was reported by session.created, and "viewed" only matters for the root.
    #expect(n.events(from: frame("session.execution.started", #"{"sessionID":"\#(child)"}"#), now: T).isEmpty)
    #expect(n.events(from: frame("session.viewed", #"{"sessionID":"\#(child)"}"#), now: T).isEmpty)
}

@Test func openCodeUsesServerTimeAndIgnoresNoise() {
    var n = OpenCodeNormalizer()
    let e = n.events(from: Fixtures.data("opencode/session.execution.started"), now: 1)
    #expect(e.first?.ts != 1)    // the stream's own timestamp wins
    for noise in ["session.text.delta", "shell.created", "project.updated", "session.usage.updated"] {
        let f = Data(#"{"id":"e","created":5,"type":"\#(noise)","data":{"sessionID":"x","delta":"secret"}}"#.utf8)
        #expect(n.events(from: f, now: T).isEmpty, "\(noise)")
    }
    for bad in ["", "{", "[]", #"{"type":"permission.asked"}"#, #"{"type":"permission.asked","data":{"sessionID":"s"}}"#] {
        #expect(n.events(from: Data(bad.utf8), now: T).isEmpty, "\(bad)")
    }
}

@Test func openCodeParentTableIsBounded() {
    var n = OpenCodeNormalizer(capacity: 4)
    for i in 0..<20 {
        _ = n.events(from: Data(#"{"type":"session.created","data":{"sessionID":"c\#(i)","parentID":"p"}}"#.utf8), now: T)
    }
    // Old children were forgotten: they would now look like roots. New ones are still known.
    let old = n.events(from: Data(#"{"type":"session.execution.succeeded","data":{"sessionID":"c0"}}"#.utf8), now: T)
    let new = n.events(from: Data(#"{"type":"session.execution.succeeded","data":{"sessionID":"c19"}}"#.utf8), now: T)
    #expect(old.first?.kind == .done)
    #expect(new.first?.kind == .substop)
}

// MARK: privacy

@Test func noContentEverReachesTheWire() throws {
    // Every fixture, normalised and encoded, may only carry the wire's own fields, and none of the
    // fixtures' redacted content (prompts, answers, commands, tool output) may appear anywhere.
    let allowedKeys: Set<String> = ["v", "agent", "kind", "session", "req", "sub", "cwd", "pid", "tp", "ts", "src"]
    var checked = 0
    var oc = OpenCodeNormalizer()
    for agent in ["claude", "codex", "opencode"] {
        for (name, data) in Fixtures.all(agent) {
            let events: [AgentEvent]
            switch agent {
            case "claude": events = ClaudeNormalizer.events(from: data, now: T)
            case "codex": events = CodexNormalizer.events(from: data, now: T)
            default: events = oc.events(from: data, now: T)
            }
            for e in events {
                let wire = try #require(Wire.encode(e))
                let keys = Set(try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any]).keys)
                #expect(keys.isSubset(of: allowedKeys), "\(agent)/\(name) has extra keys \(keys.subtracting(allowedKeys))")
                #expect(!String(decoding: wire, as: UTF8.self).contains("<redacted>"), "\(agent)/\(name) leaks redacted content")
                checked += 1
            }
        }
    }
    #expect(checked >= 25)
}
