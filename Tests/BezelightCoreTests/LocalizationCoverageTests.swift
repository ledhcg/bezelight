import Foundation
import Testing
@testable import BezelightCore

/// Typos in a key are invisible until someone reads the screen: the UI would show the raw key.
private func swiftSources() -> [URL] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
}

@Test func everyAgentKeyUsedInTheCodeIsDefined() throws {
    let defined = Localizer.keys(for: .en)
    let pattern = try NSRegularExpression(pattern: #""((?:agents|doctor)\.[A-Za-z0-9_.]+)""#)
    // Storage keys and key prefixes that are not strings on screen.
    let notStrings: Set<String> = ["agents.v1", "agents.lastEvents.v1", "agents.flourish", "agents.hold", "agents.persist", "agents.coverage", "agents.multi"]
    var used = Set<String>()
    for file in swiftSources() {
        let text = try String(contentsOf: file, encoding: .utf8)
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let key = String(text[Range(m.range(at: 1), in: text)!])
            if !notStrings.contains(key) && !key.hasSuffix(".") { used.insert(key) }
        }
    }
    #expect(used.count > 100, "the scan found suspiciously few keys: \(used.count)")
    #expect(used.subtracting(defined).isEmpty, "keys used but not defined: \(used.subtracting(defined).sorted())")
}

@Test func keysBuiltFromEnumsAreAllDefined() {
    let defined = Localizer.keys(for: .en)
    var wanted: [String] = []
    for k in AlertKind.allCases { wanted += ["agents.event.\(k.rawValue)", "agents.event.\(k.rawValue).help"] }
    for v in FlourishEffect.allCases { wanted += ["agents.flourish.\(v.rawValue)", "agents.flourish.\(v.rawValue).help"] }
    for v in HoldEffect.allCases { wanted += ["agents.hold.\(v.rawValue)", "agents.hold.\(v.rawValue).help"] }
    for v in Persistence.allCases { wanted += ["agents.persist.\(v.rawValue)", "agents.persist.\(v.rawValue).help"] }
    for v in Coverage.allCases { wanted += ["agents.coverage.\(v.rawValue)", "agents.coverage.\(v.rawValue).help"] }
    for v in MultiPattern.allCases { wanted += ["agents.multi.\(v.rawValue)", "agents.multi.\(v.rawValue).help"] }
    for s in ["idle", "working", "needsInput", "done", "error"] { wanted.append("agents.state.\(s)") }
    #expect(Set(wanted).subtracting(defined).isEmpty, "\(Set(wanted).subtracting(defined).sorted())")
}

@Test func everyDoctorMessageHasAText() async {
    // Every key the doctor can produce must be translatable.
    let defined = Localizer.keys(for: .en)
    let text = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/BezelightCore/AgentDoctor.swift"), encoding: .utf8)) ?? ""
    let re = try! NSRegularExpression(pattern: #""(doctor\.[A-Za-z0-9_.]+)""#)
    let keys = Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) })
    #expect(keys.count >= 28)
    #expect(keys.subtracting(defined).isEmpty, "\(keys.subtracting(defined).sorted())")
}

@Test func theAgentTextsReadWellInEveryLanguage() {
    let saved = Localizer.language
    defer { Localizer.language = saved }
    for lang in Localizer.supported {
        Localizer.language = lang
        // The values that carry numbers must keep the numbers.
        #expect(tr("agents.sessions.subagents", 3).contains("3"), "\(lang.rawValue)")
        #expect(tr("agents.menu.waiting", 2).contains("2"), "\(lang.rawValue)")
        #expect(tr("agents.event.period.value", "0.34", "2.9").contains("0.34") && tr("agents.event.period.value", "0.34", "2.9").contains("2.9"), "\(lang.rawValue)")
        #expect(tr("doctor.hooks.partial", "Codex", "~/.codex", "Stop").contains("Stop"), "\(lang.rawValue)")
        #expect(tr("agents.title") != "agents.title" && !tr("agents.title").isEmpty)
    }
}
