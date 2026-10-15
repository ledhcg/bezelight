import Foundation
import Testing
@testable import BezelightAgents

/// Deterministic noise. The point of these tests is simple: whatever arrives, nothing crashes and
/// the hook contract (exit 0, `{}`) holds.
private struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: next()) }) }
}

/// Flips, inserts, deletes and duplicates bytes of a valid payload: the realistic kind of damage.
private func mutate(_ base: Data, _ r: inout Rng) -> Data {
    var d = Array(base)
    for _ in 0..<(1 + r.int(6)) {
        guard !d.isEmpty else { break }
        let i = r.int(d.count)
        switch r.int(5) {
        case 0: d[i] = UInt8(truncatingIfNeeded: r.next())
        case 1: d.remove(at: i)
        case 2: d.insert(UInt8(truncatingIfNeeded: r.next()), at: i)
        case 3: d.replaceSubrange(i..<min(d.count, i + r.int(20)), with: [])
        default: d.insert(contentsOf: d[i..<min(d.count, i + r.int(40))], at: i)
        }
    }
    return Data(d)
}

private let claudeFixtures = Fixtures.all("claude").map(\.data)
private let codexFixtures = Fixtures.all("codex").map(\.data)
private let openCodeFixtures = Fixtures.all("opencode").map(\.data)

@Test func theHookContractHoldsForAnyInput() {
    var rng = Rng(s: 0xC0FFEE)
    let sent = Box(0)
    for i in 0..<6000 {
        let agent = i % 2 == 0 ? "claude" : "codex"
        let pool = agent == "claude" ? claudeFixtures : codexFixtures
        let input: Data
        switch rng.int(4) {
        case 0: input = rng.bytes(rng.int(3000))
        case 1: input = mutate(pool[rng.int(pool.count)], &rng)
        case 2: input = Data(repeating: UInt8(ascii: "{"), count: rng.int(500))
        default: input = pool[rng.int(pool.count)]
        }
        let cli = HookCLI(arguments: ["bezelight-hook", agent], readInput: { input }, now: { 1_800_000_000_000 },
                          agentPID: { 42 }, send: { _ in sent.mutate { $0 += 1 }; return true })
        #expect(cli.run() == "{}\n")
    }
    #expect(sent.value > 1000, "mutated payloads are often still valid; the unmodified ones must always go through")
}

@Test func everythingSentIsAlwaysDecodableAndSmall() {
    var rng = Rng(s: 0xBADF00D)
    let ok = Box(0)
    for _ in 0..<4000 {
        let pool = rng.int(2) == 0 ? claudeFixtures : codexFixtures
        let input = rng.int(3) == 0 ? mutate(pool[rng.int(pool.count)], &rng) : pool[rng.int(pool.count)]
        let cli = HookCLI(arguments: ["bezelight-hook", pool.count == claudeFixtures.count ? "claude" : "codex"], readInput: { input },
                          now: { 1_800_000_000_000 }, agentPID: { nil },
                          send: { data in
                              #expect(data.count <= Wire.maxBytes)
                              #expect(Wire.decode(data) != nil, "what the helper sends must be accepted by the app")
                              ok.mutate { $0 += 1 }
                              return true
                          })
        _ = cli.run()
    }
    #expect(ok.value > 500)
}

@Test func theWireDecoderSurvivesAnything() {
    var rng = Rng(s: 0x5EED)
    let valid = Wire.encode(AgentEvent(agent: .claude, kind: .ask, session: "s", ts: 5, req: "r", sub: "a", cwd: "/x", pid: 1, tp: "/t", src: "p"))!
    var decoded = 0
    for _ in 0..<30_000 {
        let data = rng.int(3) == 0 ? rng.bytes(rng.int(2500)) : mutate(valid, &rng)
        if let e = Wire.decode(data) {
            decoded += 1
            #expect(!e.session.isEmpty && e.session.count <= 128 && e.ts > 0)
            #expect(Wire.encode(e) != nil, "whatever decodes must encode again")
        }
    }
    #expect(decoded > 0)
}

@Test func theOpenCodeNormalizerSurvivesAnything() {
    var rng = Rng(s: 0x0FFEE)
    var n = OpenCodeNormalizer(capacity: 64)
    var produced = 0
    for _ in 0..<12_000 {
        let frame = rng.int(4) == 0 ? rng.bytes(rng.int(1500)) : mutate(openCodeFixtures[rng.int(openCodeFixtures.count)], &rng)
        for e in n.events(from: frame, now: 1_800_000_000_000) {
            produced += 1
            #expect(!e.session.isEmpty && e.agent == .opencode)
        }
    }
    #expect(produced > 500)
}

@Test func theJSONEditorNeverWritesAnythingInvalid() throws {
    // Damaged settings files: either the installer refuses, or what it produces is valid and means
    // the same as before. It must never hand back broken JSON.
    var rng = Rng(s: 0xFACADE)
    let base = Data(Fixtures.text("claude-settings-orca").utf8)
    var accepted = 0, refused = 0
    for _ in 0..<500 {
        let damaged = String(decoding: mutate(base, &rng), as: UTF8.self)
        do {
            let installed = try HookConfigEditor.install(damaged, specs: HookCatalog.specs(for: .claude), command: HookCatalog.command(for: .claude))
            #expect((try? JSONSerialization.jsonObject(with: Data(installed.utf8))) != nil, "invalid output from a damaged input")
            #expect(HookConfigEditor.isSafeEdit(old: damaged, new: installed))
            accepted += 1
        } catch { refused += 1 }
    }
    #expect(accepted + refused == 500 && refused > 30)
}

@Test func theJSONParserSurvivesAnything() {
    var rng = Rng(s: 0xDEADBEEF)
    let seeds = [Fixtures.text("claude-settings-orca"), Fixtures.text("codex-hooks-orca"), "{}", "[]", "{\"a\":[1,2,{\"b\":null}]}"]
    for _ in 0..<3000 {
        let seed = Data(seeds[rng.int(seeds.count)].utf8)
        let text = rng.int(5) == 0 ? String(decoding: rng.bytes(rng.int(400)), as: UTF8.self) : String(decoding: mutate(seed, &rng), as: UTF8.self)
        _ = try? JSONDocument(text)                          // may throw; must not crash or hang
        _ = HookConfigEditor.inspect(text, specs: HookCatalog.specs(for: .codex), command: HookCatalog.command(for: .codex))
    }
}

