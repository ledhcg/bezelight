import Foundation
import Testing
@testable import BezelightAgents

private let claudeSpecs = HookCatalog.specs(for: .claude)
private let codexSpecs = HookCatalog.specs(for: .codex)
private let claudeCmd = HookCatalog.command(for: .claude)
private let codexCmd = HookCatalog.command(for: .codex)

private func install(_ t: String?, _ agent: AgentKind = .claude) throws -> String {
    try HookConfigEditor.install(t, specs: HookCatalog.specs(for: agent), command: HookCatalog.command(for: agent))
}
private func inspect(_ t: String, _ agent: AgentKind = .claude) -> HookInspection {
    HookConfigEditor.inspect(t, specs: HookCatalog.specs(for: agent), command: HookCatalog.command(for: agent))
}
private func json(_ t: String) -> NSDictionary { try! JSONSerialization.jsonObject(with: Data(t.utf8)) as! NSDictionary }

// MARK: the catalog

@Test func theCommandIsStableAndSafeWhenTheHelperIsMissing() {
    #expect(claudeCmd == #"[ -x "$HOME/.bezelight/bin/bezelight-hook" ] && "$HOME/.bezelight/bin/bezelight-hook" claude || echo '{}'"#)
    #expect(codexCmd.hasSuffix(" codex || echo '{}'") && codexCmd.contains(HookCatalog.marker))
    // Codex ties its trust to this exact text: if this assertion ever needs changing, users have to re-approve.
}

@Test func theCommandReallyIsHarmlessWhenTheHelperIsMissing() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", claudeCmd]
    p.environment = ["HOME": "/nonexistent-home"]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "{}\n")
    #expect(err.fileHandleForReading.readDataToEndOfFile().isEmpty)
}

@Test func catalogsMatchTheDesign() {
    #expect(claudeSpecs.map(\.event) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "PostToolUse",
                                         "PostToolUseFailure", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"])
    #expect(claudeSpecs.allSatisfy { $0.async })
    #expect(claudeSpecs.first { $0.event == "Notification" }?.matcher == "elicitation_dialog|agent_needs_input")
    #expect(codexSpecs.map(\.event) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"])
    #expect(codexSpecs.allSatisfy { !$0.async })              // Codex wants JSON back from Stop
    #expect(HookCatalog.specs(for: .opencode).isEmpty)
}

// MARK: a file with another tool's hooks (modelled on the real Claude / Codex files)

@Test func installKeepsEveryOtherToolsHookAndSettingByteForByte() throws {
    for (name, agent) in [("claude-settings-orca", AgentKind.claude), ("codex-hooks-orca", .codex)] {
        let original = Fixtures.text(name)
        let installed = try install(original, agent)
        #expect(installed != original)
        // Taking Bezelight back out gives the original file, exactly.
        #expect(try HookConfigEditor.uninstall(installed) == original, "\(name): install then uninstall must be the identity")
        // And the new file is still valid, with the other tool's entries still there.
        let hooks = json(installed)["hooks"] as! NSDictionary
        for (event, groups) in json(original)["hooks"] as! [String: Any] {
            let now = hooks[event] as! [NSDictionary]
            #expect(now.count >= (groups as! [Any]).count, "\(name) \(event) lost an entry")
            #expect(now.first == (groups as! [NSDictionary]).first)
        }
        #expect(HookConfigEditor.isSafeEdit(old: original, new: installed))
    }
}

@Test func installIsIdempotent() throws {
    for (name, agent) in [("claude-settings-orca", AgentKind.claude), ("codex-hooks-orca", .codex)] {
        let once = try install(Fixtures.text(name), agent)
        #expect(try install(once, agent) == once, "\(name): a second install must change nothing")
        #expect(inspect(once, agent).state == .installed)
    }
}

@Test func theInstalledFileHasOneBezelightEntryPerEventAndNoDuplicates() throws {
    let installed = try install(Fixtures.text("claude-settings-orca"))
    let hooks = json(installed)["hooks"] as! [String: [NSDictionary]]
    for spec in claudeSpecs {
        let groups = hooks[spec.event]!
        let mine = groups.filter { (($0["hooks"] as! [NSDictionary]).first?["command"] as? String)?.contains(HookCatalog.marker) == true }
        #expect(mine.count == 1, "\(spec.event)")
        #expect(mine[0]["matcher"] as? String == spec.matcher)
        let entry = (mine[0]["hooks"] as! [NSDictionary])[0]
        #expect(entry["type"] as? String == "command" && entry["command"] as? String == claudeCmd)
        #expect(entry["timeout"] as? Int == spec.timeout && (entry["async"] as? Bool) == (spec.async ? true : nil))
    }
    // Events that are not ours were not touched.
    #expect((hooks["TeammateIdle"]!).count == 1 && (hooks["PreToolUse"]!).count == 1)
}

@Test func newEventsAreAddedAndExistingOnesAppended() throws {
    let installed = try install(Fixtures.text("claude-settings-orca"))
    let hooks = json(installed)["hooks"] as! [String: [Any]]
    #expect(hooks["Notification"]!.count == 1)                  // Orca has none: a new event
    #expect(hooks["Stop"]!.count == 2)                          // Orca has one: ours is added after it
    #expect(hooks["PermissionRequest"]!.count == 2)
}

@Test func theRestOfTheFileIsUntouched() throws {
    let original = Fixtures.text("claude-settings-orca")
    let installed = try install(original)
    for key in ["env", "attribution", "permissions", "model", "statusLine", "enabledPlugins", "language", "theme"] {
        #expect(json(installed)[key] as AnyObject === json(installed)[key] as AnyObject || true)
        #expect((json(installed)[key] as AnyObject).isEqual(json(original)[key]), "\(key)")
    }
    // Key order is preserved too: the order of top-level keys is unchanged.
    func order(_ t: String) -> [String] { t.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { String($0.split(separator: "\"")[1]) } }
    #expect(order(installed) == order(original))
}

// MARK: layouts

private func compact(_ t: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(t.utf8)), options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}
private func reindented(_ t: String, _ unit: String, newline: String = "\n") -> String {
    // Re-render with another indentation: build from the pretty text by replacing each 2-space level.
    t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let lead = line.prefix { $0 == " " }
        return String(repeating: unit, count: lead.count / 2) + line.dropFirst(lead.count)
    }.joined(separator: newline)
}

@Test func everyLayoutRoundTripsToTheIdentity() throws {
    let base = Fixtures.text("codex-hooks-orca")
    let layouts: [(String, String)] = [
        ("four spaces", reindented(base, "    ")),
        ("tabs", reindented(base, "\t")),
        ("crlf", reindented(base, "  ", newline: "\r\n")),
        ("no trailing newline", String(base.dropLast())),
        ("compact one line", compact(base)),
        ("compact with newline", compact(base) + "\n"),
    ]
    for (name, text) in layouts {
        let installed = try install(text, .codex)
        #expect(inspect(installed, .codex).state == .installed, "\(name)")
        #expect(try HookConfigEditor.uninstall(installed) == text, "\(name): install then uninstall must be the identity")
        #expect(try install(installed, .codex) == installed, "\(name): idempotent")
        #expect(HookConfigEditor.isSafeEdit(old: text, new: installed), "\(name)")
    }
}

@Test func newMembersMatchTheFilesOwnStyle() throws {
    let tabbed = reindented(Fixtures.text("codex-hooks-orca"), "\t")
    let installed = try install(tabbed, .codex)
    let added = installed.split(separator: "\n").filter { $0.contains("\"Interrupt\"") }
    #expect(added.count == 1 && added[0].hasPrefix("\t\t\""), "new keys should be indented with tabs like their neighbours")
    let crlf = try install(reindented(Fixtures.text("codex-hooks-orca"), "  ", newline: "\r\n"), .codex)
    #expect(!crlf.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF may be mixed into a CRLF file")
}

// MARK: starting points

@Test func aMissingFileIsCreated() throws {
    let created = try install(nil)
    #expect(created.hasSuffix("}\n") && inspect(created).state == .installed)
    #expect(created.hasPrefix("{\n  \"hooks\": {\n    \"SessionStart\": [\n"))
    #expect((json(created)["hooks"] as! [String: Any]).count == claudeSpecs.count)
    #expect(try install(created) == created)
    #expect(try HookConfigEditor.uninstall(created) == "{}\n")        // nothing of ours is left; the file is a valid empty object
}

@Test func fileWithoutHooksGetsOneAndGivesItBack() throws {
    let text = "{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n"
    let installed = try install(text)
    #expect(json(installed)["model"] as? String == "opus" && (json(installed)["hooks"] as? NSDictionary) != nil)
    #expect(try HookConfigEditor.uninstall(installed) == text)
}

@Test func emptyObjectsAndEmptyHooks() throws {
    for text in ["{}", "{}\n", "{\n}\n", "{ }", "{\n  \"hooks\": {}\n}\n", "{\"hooks\":{}}", "{\n  \"hooks\": {\n  }\n}\n"] {
        let installed = try install(text)
        #expect(inspect(installed).state == .installed, "\(text)")
        #expect(HookConfigEditor.isSafeEdit(old: text, new: installed), "\(text)")
        #expect(try install(installed) == installed, "\(text)")
        let removed = try HookConfigEditor.uninstall(installed)
        #expect(inspect(removed).state == .notInstalled && json(removed).count == 0 || (json(removed)["hooks"] as? NSDictionary)?.count == 0, "\(text)")
    }
}

@Test func someEventsAlreadyThere() throws {
    // Only Stop is registered by Bezelight (an older release): the rest are added, Stop is kept in place.
    let old = try install(nil)
    let partial = try partialFile(keeping: ["Stop"], from: old)
    #expect(inspect(partial).state != .installed)
    let fixed = try install(partial)
    #expect(inspect(fixed).state == .installed)
    #expect(fixed.components(separatedBy: HookCatalog.marker).count - 1 == claudeSpecs.count * 2, "one command per event, two mentions of the helper each")
}

private func partialFile(keeping events: [String], from full: String) throws -> String {
    var o = json(full) as! [String: Any]
    var hooks = o["hooks"] as! [String: Any]
    hooks = hooks.filter { events.contains($0.key) }
    o["hooks"] = hooks
    return String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n"
}

// MARK: repair

@Test func anOutOfDateEntryIsRepairedInPlace() throws {
    let current = try install(Fixtures.text("claude-settings-orca"))
    let stale = current.replacingOccurrences(of: "\"timeout\": 5", with: "\"timeout\": 99")
    #expect(stale != current && inspect(stale).state != .installed)
    let repaired = try install(stale)
    #expect(inspect(repaired).state == .installed)
    #expect(repaired.components(separatedBy: HookCatalog.marker).count == current.components(separatedBy: HookCatalog.marker).count)
    #expect(try HookConfigEditor.uninstall(repaired) == Fixtures.text("claude-settings-orca"))
}

@Test func aChangedCommandOrMatcherCountsAsOutOfDate() throws {
    let current = try install(nil)
    let oldCommand = current.replacingOccurrences(of: "|| echo '{}'", with: "|| true")
    #expect(inspect(oldCommand).state != .installed)
    let fixedCommand = try install(oldCommand)
    #expect(inspect(fixedCommand).state == .installed)
    let oldMatcher = current.replacingOccurrences(of: "elicitation_dialog|agent_needs_input", with: "permission_prompt")
    guard case .partial(let missing) = inspect(oldMatcher).state else { Issue.record("expected partial"); return }
    #expect(missing == ["Notification"])
    #expect(try install(oldMatcher) == current)
}

@Test func duplicateEntriesAreReducedToOne() throws {
    let current = try install(nil)
    var doc = json(current) as! [String: Any]
    var hooks = doc["hooks"] as! [String: [Any]]
    hooks["Stop"] = hooks["Stop"]! + hooks["Stop"]!
    hooks["SessionEnd"] = hooks["SessionEnd"]! + hooks["SessionEnd"]! + hooks["SessionEnd"]!
    doc["hooks"] = hooks
    let doubled = String(decoding: try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    #expect(inspect(doubled).entries == claudeSpecs.count + 1 + 2)
    let fixed = try install(doubled)
    #expect(inspect(fixed).entries == claudeSpecs.count && inspect(fixed).state == .installed)
}

@Test func anEntrySharingAGroupWithAnotherToolsHookIsSeparatedNotLost() throws {
    let text = """
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              { "type": "command", "command": "other-tool notify" },
              { "type": "command", "command": "old bezelight-hook claude", "timeout": 1 }
            ]
          }
        ]
      }
    }
    """
    let installed = try install(text)
    let stop = (json(installed)["hooks"] as! [String: [NSDictionary]])["Stop"]!
    let commands = stop.flatMap { ($0["hooks"] as! [NSDictionary]).map { $0["command"] as! String } }
    #expect(commands.contains("other-tool notify") && commands.filter { $0.contains(HookCatalog.marker) } == [claudeCmd])
    let removed = try HookConfigEditor.uninstall(installed)
    let left = ((json(removed)["hooks"] as! [String: [NSDictionary]])["Stop"]!).flatMap { ($0["hooks"] as! [NSDictionary]).map { $0["command"] as! String } }
    #expect(left == ["other-tool notify"])
}

// MARK: uninstall

@Test func uninstallLeavesAFileWithoutBezelightAlone() throws {
    let original = Fixtures.text("claude-settings-orca")
    #expect(try HookConfigEditor.uninstall(original) == original)
    #expect(try HookConfigEditor.uninstall("{}") == "{}")
    #expect(try HookConfigEditor.uninstall("{\"hooks\": {\"Stop\": []}}") == "{\"hooks\": {\"Stop\": []}}")
}

@Test func uninstallCleansUpWhatItEmptied() throws {
    let onlyUs = try install(nil)
    let removed = try HookConfigEditor.uninstall(onlyUs)
    #expect(!removed.contains("hooks") && !removed.contains(HookCatalog.marker))
    // The event Bezelight shared with another tool keeps the other tool.
    let shared = try HookConfigEditor.uninstall(try install(Fixtures.text("claude-settings-orca")))
    #expect(((json(shared)["hooks"] as! [String: [Any]])["Stop"])?.count == 1)
}

@Test func uninstallAlsoRemovesEntriesForEventsNoLongerInTheCatalog() throws {
    let text = #"{"hooks":{"SomeRetiredEvent":[{"hooks":[{"type":"command","command":"x/bezelight-hook y"}]}],"Stop":[{"hooks":[{"type":"command","command":"keep"}]}]}}"#
    let removed = try HookConfigEditor.uninstall(text)
    #expect(removed == #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep"}]}]}}"#)
}

// MARK: refusing to guess

@Test func filesItCannotUnderstandAreLeftAlone() {
    let bad: [(String, InstallError)] = [
        ("", .notJSON("unexpected end of file")),
        ("not json", .notJSON("unexpected character at byte 0")),
        ("[1,2]", .notAnObject),
        ("\"text\"", .notAnObject),
        (#"{"hooks": []}"#, .hooksNotObject),
        (#"{"hooks": {"Stop": {}}}"#, .eventNotArray("Stop")),
    ]
    for (text, _) in bad {
        #expect(throws: InstallError.self, "\(text)") { _ = try install(text) }
    }
    #expect(throws: InstallError.hooksNotObject) { _ = try install(#"{"hooks": []}"#) }
    #expect(throws: InstallError.notAnObject) { _ = try install("[1]") }
    if case .unreadable = inspect("not json").state {} else { Issue.record("inspect should report unreadable") }
}

@Test func trailingCommasAndCommentsAreNotGuessedAt() {
    for text in ["{\"a\":1,}", "{\"a\":1 // hi\n}", "{/* c */}", "{'a':1}", "\u{FEFF}{}"] {
        #expect(throws: InstallError.self, "\(text)") { _ = try install(text) }
    }
}

@Test func deepNestingCannotCrashTheParser() {
    let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
    #expect(throws: InstallError.self) { _ = try install("{\"x\":\(deep)}") }
}

@Test func disabledHooksAreReported() throws {
    let text = #"{"disableAllHooks": true, "hooks": {}}"#
    #expect(inspect(text).hooksDisabled)
    let reinstalled = try install(text)
    #expect(inspect(reinstalled).hooksDisabled)
    #expect(!inspect(Fixtures.text("claude-settings-orca")).hooksDisabled)
    #expect(!inspect(#"{"disableAllHooks": false}"#).hooksDisabled)
}

// MARK: strings with awkward content

@Test func awkwardCharactersInOtherEntriesSurvive() throws {
    let text = "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          { \"type\": \"command\", \"command\": \"echo \\\"a\\\\b\\\" \\u00e9 \\ud83d\\ude00 \\n\\t / } ] { [\" }\n        ]\n      }\n    ]\n  }\n}\n"
    let installed = try install(text)
    #expect(try HookConfigEditor.uninstall(installed) == text)
    #expect(HookConfigEditor.isSafeEdit(old: text, new: installed))
}

@Test func bracesAndQuotesInsideStringsDoNotConfuseTheParser() throws {
    let text = #"{"a": "}{][\"", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x \"}\" ]"}]}], "b": "{"}, "c": 1}"#
    let installed = try install(text)
    #expect(try HookConfigEditor.uninstall(installed) == text)
}

// MARK: a safety net

@Test func theSafetyNetRejectsAnEditThatChangesOtherContent() throws {
    let original = Fixtures.text("claude-settings-orca")
    let installed = try install(original)
    #expect(HookConfigEditor.isSafeEdit(old: original, new: installed))
    #expect(!HookConfigEditor.isSafeEdit(old: original, new: installed.replacingOccurrences(of: "\"opus\"", with: "\"haiku\"")))
    #expect(!HookConfigEditor.isSafeEdit(old: original, new: String(installed.dropLast(5))))
    #expect(!HookConfigEditor.isSafeEdit(old: original, new: "{}"))
    #expect(HookConfigEditor.isSafeEdit(old: nil, new: installed))
}

// MARK: property test: random files, random layouts

private struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bool() -> Bool { next() % 2 == 0 }
}

private func randomValue(_ r: inout Rng, depth: Int) -> Any {
    switch r.int(depth > 2 ? 4 : 7) {
    case 0: return r.int(1000)
    case 1: return ["plain", "with \"quotes\"", "slash\\back", "caf\u{e9}", "line\nbreak", "{brace}", "[bracket]"][r.int(7)]
    case 2: return r.bool()
    case 3: return NSNull()
    case 4: return (0..<r.int(4)).map { _ in randomValue(&r, depth: depth + 1) }
    default: return Dictionary(uniqueKeysWithValues: (0..<r.int(4)).map { ("k\($0)", randomValue(&r, depth: depth + 1)) })
    }
}

private func randomConfig(_ r: inout Rng) -> [String: Any] {
    var root: [String: Any] = [:]
    for i in 0..<(1 + r.int(4)) { root["setting\(i)"] = randomValue(&r, depth: 0) }   // a file with nothing in it has no style to restore
    if r.int(4) != 0 {
        var hooks: [String: Any] = [:]
        let names = ["SessionStart", "Stop", "PostToolUse", "Notification", "Elsewhere", "PermissionRequest", "SessionEnd"]
        for name in names where r.bool() {
            hooks[name] = (0..<(1 + r.int(2))).map { _ -> Any in
                var g: [String: Any] = ["hooks": (0..<(1 + r.int(2))).map { _ in ["type": "command", "command": "other-tool \(r.int(99))", "timeout": r.int(30)] as [String: Any] }]
                if r.bool() { g["matcher"] = "*" }
                return g
            }
        }
        if !hooks.isEmpty { root["hooks"] = hooks }       // an empty `hooks` is covered by its own test
    }
    return root
}

private func render(_ o: [String: Any], _ r: inout Rng) -> String {
    switch r.int(4) {
    case 0:
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    default:
        let pretty = String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let unit = ["  ", "    ", "\t"][r.int(3)]
        let text = reindented(pretty.replacingOccurrences(of: " : ", with: ": "), unit)
        return (r.bool() ? text + "\n" : text).replacingOccurrences(of: "\n", with: r.int(5) == 0 ? "\r\n" : "\n")
    }
}

@Test func randomFilesInRandomLayoutsAlwaysRoundTrip() throws {
    var rng = Rng(s: 0x9E3779B97F4A7C15)
    var checked = 0
    for agent in [AgentKind.claude, .codex] {
        for _ in 0..<150 {
            let text = render(randomConfig(&rng), &rng)
            let installed = try install(text, agent)
            #expect(inspect(installed, agent).state == .installed)
            #expect(try install(installed, agent) == installed, "idempotent:\n\(text)")
            #expect(try HookConfigEditor.uninstall(installed) == text, "identity:\n\(text)")
            #expect(HookConfigEditor.isSafeEdit(old: text, new: installed))
            checked += 1
        }
    }
    #expect(checked == 300)
}

@Test func anEventListThatWasAlreadyEmptyCannotBeRestoredByteForByte() throws {
    // `"Stop": []` and no Stop at all mean the same to an agent; after uninstall the empty list is
    // gone. Nothing else may change, and the file must still mean what it did.
    let text = "{\n  \"hooks\": {\n    \"Stop\": [],\n    \"Keep\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"x\" } ] }\n    ]\n  }\n}\n"
    let installed = try install(text)
    #expect(inspect(installed).state == .installed && HookConfigEditor.isSafeEdit(old: text, new: installed))
    let removed = try HookConfigEditor.uninstall(installed)
    #expect(json(removed) == json(text.replacingOccurrences(of: "    \"Stop\": [],\n", with: "")))
    #expect((json(removed)["hooks"] as! [String: Any]).keys.sorted() == ["Keep"])
}

@Test func repairKeepsThePositionOfAnEntryAmongItsNeighbours() throws {
    let current = try install(Fixtures.text("claude-settings-orca"))
    let stale = current.replacingOccurrences(of: "elicitation_dialog|agent_needs_input", with: "permission_prompt")
    #expect(try install(stale) == current, "the Notification entry must be fixed where it is, not moved to the end")
    let slow = current.replacingOccurrences(of: "\"timeout\": 5", with: "\"timeout\": 60")
    #expect(try install(slow) == current)
}

@Test func aFileWithTheSameKeyTwiceIsNotTouched() {
    // Most programs keep the last of two equal keys. Editing the first would silently do nothing.
    let texts = [
        #"{"hooks": {"Stop": [], "Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}}"#,
        #"{"hooks": {}, "hooks": {"Stop": []}}"#,
        #"{"model": "a", "model": "b", "hooks": {}}"#,
        #"{"env": {"A": "1", "A": "2"}, "hooks": {}}"#,
    ]
    for text in texts {
        #expect(throws: InstallError.self, "\(text)") { _ = try install(text) }
        #expect(throws: InstallError.self, "\(text)") { _ = try HookConfigEditor.uninstall(text) }
        if case .unreadable(let why) = inspect(text).state { #expect(why.contains("twice")) } else { Issue.record("inspect should say unreadable: \(text)") }
    }
    // The same key in two *different* objects is, of course, fine.
    #expect((try? install(#"{"a": {"k": 1}, "b": {"k": 2}, "hooks": {}}"#)) != nil)
}
