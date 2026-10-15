import Foundation
import Testing
@testable import BezelightAgents

private func sample(_ kind: EventKind = .ask) -> AgentEvent {
    AgentEvent(agent: .claude, kind: kind, session: "abc-123", ts: 1_800_000_000_123,
               req: "r1", sub: "agent9", cwd: "/Users/me/work/app", pid: 4242, tp: "/Users/me/.claude/t.jsonl", src: "PermissionRequest")
}

@Test func wireRoundTrip() throws {
    let data = try #require(Wire.encode(sample()))
    #expect(data.count <= Wire.maxBytes)
    #expect(Wire.decode(data) == sample())
}

@Test func wireOmitsEmptyOptionalFields() throws {
    let e = AgentEvent(agent: .codex, kind: .done, session: "s", ts: 5)
    let text = String(decoding: try #require(Wire.encode(e)), as: UTF8.self)
    #expect(!text.contains("req") && !text.contains("tp") && !text.contains("cwd"))
}

@Test func wireShrinksBulkyFieldsToFit() throws {
    var e = sample()
    e.tp = "/" + String(repeating: "t", count: 600)
    e.cwd = "/" + String(repeating: "c", count: 600)
    let data = try #require(Wire.encode(e))
    #expect(data.count <= Wire.maxBytes)
    let back = try #require(Wire.decode(data))
    #expect(back.session == e.session && back.kind == e.kind && back.ts == e.ts)
}

@Test func wireRejectsGarbage() {
    #expect(Wire.decode(Data()) == nil)
    #expect(Wire.decode(Data("not json".utf8)) == nil)
    #expect(Wire.decode(Data(repeating: 0x7B, count: 3000)) == nil)                       // too large
    #expect(Wire.decode(Data(#"{"v":2,"agent":"claude","kind":"done","session":"s","ts":5}"#.utf8)) == nil)   // unknown version
    #expect(Wire.decode(Data(#"{"v":1,"agent":"gemini","kind":"done","session":"s","ts":5}"#.utf8)) == nil)   // unknown agent
    #expect(Wire.decode(Data(#"{"v":1,"agent":"claude","kind":"nope","session":"s","ts":5}"#.utf8)) == nil)   // unknown kind
    #expect(Wire.decode(Data(#"{"v":1,"agent":"claude","kind":"done","session":"","ts":5}"#.utf8)) == nil)    // empty session
    #expect(Wire.decode(Data(#"{"v":1,"agent":"claude","kind":"done","session":"s","ts":0}"#.utf8)) == nil)   // no time
}

@Test func wireCleansControlCharactersAndLength() throws {
    let raw = #"{"v":1,"agent":"claude","kind":"done","session":"a\u0000b\nc","ts":9,"cwd":"/x\u0007y"}"#
    let e = try #require(Wire.decode(Data(raw.utf8)))
    #expect(e.session == "abc" && e.cwd == "/xy")
    let long = String(repeating: "z", count: 400)
    let big = try #require(Wire.decode(Data(#"{"v":1,"agent":"codex","kind":"done","session":"\#(long)","ts":9}"#.utf8)))
    #expect(big.session.count == 128)
}

@Test func missingVersionDefaultsToCurrent() throws {
    let e = try #require(Wire.decode(Data(#"{"agent":"opencode","kind":"seen","session":"s","ts":3}"#.utf8)))
    #expect(e.v == Wire.version)
}
