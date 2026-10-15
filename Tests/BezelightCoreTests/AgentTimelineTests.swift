import Foundation
import Testing
@testable import BezelightCore

/// Behaviour measured on real Claude Code, Codex and OpenCode sessions, replayed exactly.
private let timelines = [
    "01-claude-allow", "02-claude-deny", "03-claude-askuserquestion", "04-claude-subagent-background",
    "05-claude-internal-subagent-stop", "06-codex-allow", "07-codex-deny-interrupt", "08-opencode-allow",
    "09-opencode-reject", "10-opencode-esc", "11-opencode-provider-failure", "12-opencode-subagent-and-form",
]

@Test(arguments: timelines) func timelineReplay(_ name: String) throws {
    var replay = Replay(name)
    try replay.run()
}

@Test func everyTimelineOnDiskIsCovered() throws {
    let dir = Fixtures.root.appendingPathComponent("timelines")
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".jsonl") }.map { $0.replacingOccurrences(of: ".jsonl", with: "") }.sorted()
    #expect(onDisk == timelines.sorted())
}

/// The same recordings with the user sitting at the machine: nothing waits for them to "come back".
@Test func doneFadesWhenTheUserWasAlreadyThere() throws {
    var rig = Rig()
    rig.send(.working)
    rig.advance(5)
    rig.input()                       // typing right up to the end of the turn
    rig.advance(1)
    rig.send(.done)
    #expect(rig.display?.kind == .done)
    rig.advance(7); rig.tick()
    #expect(rig.display?.kind == .done)
    rig.advance(2); rig.tick()        // past presentFadeSec (8 s)
    #expect(rig.display == nil)
}
