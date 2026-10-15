import Foundation
import Darwin
import Testing
@testable import BezelightAgents

/// A throwaway "home" with the folders an installation would have.
private struct FakeHome {
    let root: URL
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var paths: BezelightPaths { BezelightPaths(home: root.appendingPathComponent("bz", isDirectory: true)) }

    init() {
        root = URL(fileURLWithPath: "/tmp/bz-h-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult func dir(_ path: String) -> URL {
        let url = home.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult func file(_ path: String, _ text: String, mode: Int = 0o644) -> URL {
        let url = home.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        return url
    }
    func installer(env: [String: String] = [:], at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> HookInstaller {
        var i = HookInstaller(paths: paths, home: home, environment: env, now: { at })
        i.systemBinaryDirs = []                              // the real machine's tools must not leak into a test
        return i
    }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }
}

private let orca = Fixtures.text("claude-settings-orca")

// MARK: finding configurations

@Test func claudeConfigurationsIncludeEveryAccountFolder() {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", "{}")
    h.file(".claude-accounts/work/settings.json", "{}")
    h.dir(".claude-accounts/psa/projects")
    h.dir(".claude-accounts/empty-and-unrelated")                    // not a Claude config: left out
    h.file(".claude-accounts/config.json", "{}")                     // a file, not a folder
    let work = h.home.appendingPathComponent(".claude-accounts/work").path
    let targets = h.installer(env: ["CLAUDE_CONFIG_DIR": work]).targets(for: .claude)
    #expect(targets.map(\.label) == ["~/.claude", "~/.claude-accounts/psa", "~/.claude-accounts/work"] ||
            targets.map(\.label) == ["~/.claude", "~/.claude-accounts/work", "~/.claude-accounts/psa"])
    #expect(targets.filter(\.isActive).map(\.label) == ["~/.claude-accounts/work"], "only the folder CLAUDE_CONFIG_DIR points at is active")
    #expect(targets.first { $0.label == "~/.claude" }?.exists == true)
    #expect(targets.first { $0.label == "~/.claude-accounts/psa" }?.exists == false)       // folder yes, settings.json not yet
}

@Test func theDefaultFolderIsActiveWhenNothingOverridesIt() {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", "{}")
    h.dir(".claude-accounts/work/projects")
    let t = h.installer().targets(for: .claude)
    #expect(t.filter(\.isActive).map(\.label) == ["~/.claude"])
}

@Test func theSameFolderIsNotListedTwice() {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", "{}")
    let own = h.home.appendingPathComponent(".claude").path
    let t = h.installer(env: ["CLAUDE_CONFIG_DIR": own]).targets(for: .claude)
    #expect(t.count == 1 && t[0].isActive)
    // A symlinked account folder pointing at the same place is the same configuration.
    try? FileManager.default.createSymbolicLink(atPath: h.home.appendingPathComponent(".claude-accounts/alias").path, withDestinationPath: own)
    h.dir(".claude-accounts")
    try? FileManager.default.createSymbolicLink(atPath: h.home.appendingPathComponent(".claude-accounts/alias").path, withDestinationPath: own)
    #expect(h.installer().targets(for: .claude).count == 1)
}

@Test func noFolderMeansNoTarget() {
    let h = FakeHome(); defer { h.remove() }
    #expect(h.installer().targets(for: .claude).isEmpty)
    #expect(h.installer().targets(for: .codex).isEmpty)
    #expect(h.installer().targets(for: .opencode).isEmpty)
}

@Test func codexUsesItsHomeVariableToo() {
    let h = FakeHome(); defer { h.remove() }
    h.dir(".codex")
    let other = h.dir("elsewhere/codex-home")
    let t = h.installer(env: ["CODEX_HOME": other.path]).targets(for: .codex)
    #expect(t.count == 2 && t.filter(\.isActive).count == 1 && t.first { $0.isActive }?.file.path == other.appendingPathComponent("hooks.json").path)
    #expect(t.allSatisfy { $0.file.lastPathComponent == "hooks.json" })
}

@Test func agentsAreDetectedFromTheirBinariesOrFolders() {
    let h = FakeHome(); defer { h.remove() }
    let i = h.installer(env: ["PATH": "/nonexistent"])
    #expect(!i.isAgentInstalled(.claude) && !i.isAgentInstalled(.codex) && !i.isAgentInstalled(.opencode))
    let bin = h.dir(".local/bin")
    for name in ["claude", "codex"] {
        FileManager.default.createFile(atPath: bin.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }
    #expect(i.isAgentInstalled(.claude) && i.isAgentInstalled(.codex) && !i.isAgentInstalled(.opencode))
    h.file(".local/state/opencode/service.json", "{}")
    #expect(i.isAgentInstalled(.opencode))
    let j = FakeHome(); defer { j.remove() }
    j.dir(".codex")
    #expect(j.installer(env: ["PATH": ""]).isAgentInstalled(.codex))               // a configuration folder is enough
}

// MARK: installing

@Test func installWritesBacksUpAndIsIdempotent() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", orca)
    let inst = h.installer()
    let t = try #require(inst.targets(for: .claude).first)
    #expect(inst.inspect(t).state != .installed)

    let r = try inst.install(t)
    #expect(r.changed && r.backup != nil)
    #expect(inst.inspect(t).state == .installed)
    #expect(h.text(try #require(r.backup)) == orca, "the backup is the file as it was")
    #expect(h.mode(try #require(r.backup)) == 0o600)

    let again = try inst.install(t)
    #expect(!again.changed && again.backup == nil, "nothing to do, so nothing is rewritten or backed up")
    #expect(inst.backups(for: t).count == 1)

    let removed = try inst.uninstall(t)
    #expect(removed.changed && h.text(file) == orca, "uninstalling restores the original file exactly")
    #expect(inst.inspect(t).state == .notInstalled)
    #expect(!(try inst.uninstall(t).changed))
}

@Test func installKeepsPermissionsOfTheFile() throws {
    let h = FakeHome(); defer { h.remove() }
    for mode in [0o600, 0o644, 0o640] {
        let file = h.file(".codex/hooks.json", Fixtures.text("codex-hooks-orca"), mode: mode)
        let inst = h.installer()
        try inst.install(try #require(inst.targets(for: .codex).first))
        #expect(h.mode(file) == mode)
        try? FileManager.default.removeItem(at: file)
    }
}

@Test func aMissingFileIsCreatedPrivately() throws {
    let h = FakeHome(); defer { h.remove() }
    h.dir(".codex")
    let inst = h.installer()
    let t = try #require(inst.targets(for: .codex).first)
    #expect(!t.exists)
    let r = try inst.install(t)
    #expect(r.changed && r.backup == nil)
    #expect(h.mode(t.file) == 0o600 && inst.inspect(t).state == .installed)
    #expect(h.text(t.file).hasSuffix("}\n"))
}

@Test func aMissingFolderIsReportedNotCreated() {
    let h = FakeHome(); defer { h.remove() }
    let target = InstallTarget(agent: .claude, file: h.home.appendingPathComponent("no/such/settings.json"), label: "x", isActive: true, exists: false)
    #expect(throws: InstallError.self) { try h.installer().install(target) }
    #expect(!FileManager.default.fileExists(atPath: h.home.appendingPathComponent("no").path))
}

@Test func aSymlinkedFileKeepsItsLinkAndUpdatesTheTarget() throws {
    let h = FakeHome(); defer { h.remove() }
    let real = h.file("dotfiles/claude-settings.json", orca)
    h.dir(".claude")
    let link = h.home.appendingPathComponent(".claude/settings.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let inst = h.installer()
    let t = try #require(inst.targets(for: .claude).first)
    try inst.install(t)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path, "the link must survive")
    #expect(inst.inspect(t).state == .installed && h.text(real).contains(HookCatalog.marker))
    try inst.uninstall(t)
    #expect(h.text(real) == orca)
}

// MARK: refusing to damage anything

@Test func aBrokenFileIsLeftExactlyAsItWas() throws {
    let h = FakeHome(); defer { h.remove() }
    for broken in ["", "not json at all", "{\"hooks\": [", "{\"a\": 1,}", "[1,2,3]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": 5}}"] {
        let file = h.file(".claude/settings.json", broken)
        let inst = h.installer()
        let t = try #require(inst.targets(for: .claude).first)
        #expect(throws: InstallError.self, "\(broken)") { try inst.install(t) }
        #expect(h.text(file) == broken, "\(broken) must not be touched")
        #expect(inst.backups(for: t).isEmpty, "and no backup is made for a change that did not happen")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: h.dir(".claude").path))?.filter { $0.hasSuffix(".tmp") }.isEmpty == true)
    }
}

@Test func aFileThatIsNotTextIsRefused() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", "")
    try Data([0xFF, 0xFE, 0x00, 0x7B]).write(to: file)
    let inst = h.installer()
    #expect(throws: InstallError.self) { try inst.install(try #require(inst.targets(for: .claude).first)) }
    #expect(try Data(contentsOf: file) == Data([0xFF, 0xFE, 0x00, 0x7B]))
}

@Test func aReadOnlyFileIsReportedAndKept() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", orca, mode: 0o444)
    let inst = h.installer()
    let t = try #require(inst.targets(for: .claude).first)
    #expect(throws: InstallError.self) { try inst.install(t) }
    #expect(h.text(file) == orca)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
}

@Test func anEditMadeByAnotherProgramMidwayIsNotLost() throws {
    // Another tool rewrites the file after we read it and before we replace it. We must start
    // again from its new content, so its change survives next to ours.
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", "{\n  \"model\": \"opus\"\n}\n")
    var inst = h.installer()
    let hit = Box(0)
    inst.beforeCommit = { attempt in
        hit.value = attempt
        if attempt == 1 { try? Data("{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n".utf8).write(to: file) }
    }
    let t = try #require(inst.targets(for: .claude).first)
    try inst.install(t)
    #expect(hit.value == 2, "a second attempt was needed")
    let result = h.text(file)
    #expect(result.contains("\"theme\": \"dark\"") && inst.inspect(t).state == .installed, "both the other tool's edit and ours")
}

@Test func aFileThatKeepsChangingGivesUpWithoutWritingAnything() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", "{\"a\": 1}\n")
    var inst = h.installer()
    let n = Box(0)
    inst.beforeCommit = { _ in n.value += 1; try? Data("{\"a\": \(n.value + 1)}\n".utf8).write(to: file) }
    let t = try #require(inst.targets(for: .claude).first)
    #expect(throws: InstallError.changedUnderneath) { try inst.install(t) }
    #expect(!h.text(file).contains(HookCatalog.marker))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: h.dir(".claude").path))?.filter { $0.hasSuffix(".tmp") }.isEmpty == true, "no stray temp files")
}

@Test func manyThreadsInstallingAtOnceLeaveOneGoodResult() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", orca)
    let inst = h.installer()
    let t = try #require(inst.targets(for: .claude).first)
    let errors = Box<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 12) { i in
        do { if i % 3 == 0 { try inst.uninstall(t) } else { try inst.install(t) } }
        catch { errors.mutate { $0.append("\(error)") } }
    }
    #expect(errors.value.isEmpty, "\(errors.value)")
    let state = inst.inspect(t).state
    #expect(state == .installed || state == .notInstalled)
    let entries = inst.inspect(t).entries
    #expect(entries == 0 || entries == HookCatalog.specs(for: .claude).count, "never a half-written or doubled result")
    #expect((try? JSONSerialization.jsonObject(with: Data(h.text(file).utf8))) != nil)
}

// MARK: backups

@Test func onlyTheNewestFewBackupsAreKept() throws {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", orca)
    var tick = 0
    var inst = h.installer()
    inst.now = { tick += 1; return Date(timeIntervalSince1970: 1_800_000_000 + Double(tick)) }
    let t = try #require(inst.targets(for: .claude).first)
    for _ in 0..<8 { try inst.install(t); try inst.uninstall(t) }
    let backups = inst.backups(for: t)
    #expect(backups.count == HookInstaller.backupsKept)
    #expect(backups == backups.sorted { $0.lastPathComponent < $1.lastPathComponent })
}

@Test func theLatestBackupCanBeRestored() throws {
    let h = FakeHome(); defer { h.remove() }
    let file = h.file(".claude/settings.json", orca)
    let inst = h.installer()
    let t = try #require(inst.targets(for: .claude).first)
    try inst.install(t)
    try Data("{\"model\": \"changed by hand\"}\n".utf8).write(to: file)          // the user edits it afterwards
    try inst.restoreLatestBackup(for: t)
    #expect(h.text(file) == orca, "restores what the file was before Bezelight first changed it")
    #expect(throws: InstallError.self) { try h.installer().restoreLatestBackup(for: InstallTarget(agent: .claude, file: h.home.appendingPathComponent(".claude/none.json"), label: "", isActive: false, exists: false)) }
}

@Test func backupsOfDifferentFilesDoNotMix() throws {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", orca)
    h.file(".claude-accounts/work/settings.json", "{\"model\": \"x\"}\n")
    let inst = h.installer()
    let all = inst.targets(for: .claude)
    #expect(all.count == 2)
    for t in all { try inst.install(t) }
    #expect(all.allSatisfy { inst.backups(for: $0).count == 1 })
    #expect(Set(all.flatMap { inst.backups(for: $0) }.map(\.lastPathComponent)).count == 2)
}

// MARK: the helper binary

private func fakeBinary(_ h: FakeHome, _ content: String) -> URL {
    let url = h.root.appendingPathComponent("app-helper")
    FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o755])
    return url
}

@Test func theHelperIsDeployedUpdatedAndNotRewrittenNeedlessly() throws {
    let h = FakeHome(); defer { h.remove() }
    let d = HelperDeployer(paths: h.paths)
    let v1 = fakeBinary(h, "#!/bin/sh\necho v1\n")
    #expect(d.status(source: v1) == .missing)
    #expect(try d.deploy(source: v1))
    #expect(d.status(source: v1) == .current)
    #expect(h.mode(h.paths.helper) == 0o755 && h.mode(h.paths.home) == 0o700 && h.mode(h.paths.bin) == 0o700)
    #expect(!(try d.deploy(source: v1)), "unchanged: not rewritten")

    let v2 = fakeBinary(h, "#!/bin/sh\necho v2\n")
    #expect(d.status(source: v2) == .outdated)
    #expect(try d.deploy(source: v2) && d.status(source: v2) == .current)
    #expect(h.text(h.paths.helper).contains("v2"))
    d.remove()
    #expect(d.status(source: v2) == .missing)
}

@Test func aBrokenHelperIsRepaired() throws {
    let h = FakeHome(); defer { h.remove() }
    let d = HelperDeployer(paths: h.paths)
    let src = fakeBinary(h, "#!/bin/sh\necho ok\n")
    try d.deploy(source: src)
    chmod(h.paths.helper.path, 0o644)
    #expect(d.status(source: src) == .notExecutable)
    #expect(try d.deploy(source: src) == false || d.status(source: src) == .current)
    try? FileManager.default.removeItem(at: h.paths.helper)
    FileManager.default.createFile(atPath: h.paths.helper.path, contents: Data("tampered".utf8))
    #expect(d.status(source: src) == .outdated)
    #expect(try d.deploy(source: src) && d.status(source: src) == .current)
}

@Test func theDeployedHelperHasNoQuarantineFlag() throws {
    let h = FakeHome(); defer { h.remove() }
    let src = fakeBinary(h, "#!/bin/sh\n")
    setxattr(src.path, "com.apple.quarantine", "0081;00000000;x;", 16, 0, 0)
    try HelperDeployer(paths: h.paths).deploy(source: src)
    #expect(getxattr(h.paths.helper.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
}

@Test func missingSourceIsAnErrorNotACrash() {
    let h = FakeHome(); defer { h.remove() }
    #expect(throws: InstallError.self) { try HelperDeployer(paths: h.paths).deploy(source: h.root.appendingPathComponent("nope")) }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

// MARK: which folders to set up by default

private func touch(_ url: URL, daysAgo: Double) {
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
}

@Test func onlyRecentlyUsedClaudeFoldersAreRecommended() {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", "{}"); touch(h.dir(".claude/projects"), daysAgo: 200)             // old
    h.file(".claude-accounts/work/settings.json", "{}"); touch(h.dir(".claude-accounts/work/projects"), daysAgo: 1)
    h.file(".claude-accounts/psa/settings.json", "{}"); touch(h.dir(".claude-accounts/psa/projects"), daysAgo: 90)
    h.file(".claude-accounts/gemini/settings.json", "{}"); touch(h.dir(".claude-accounts/gemini/sessions"), daysAgo: 5)
    let inst = h.installer(at: Date())
    let labels = inst.recommended(for: .claude).map(\.label).sorted()
    #expect(labels == ["~/.claude-accounts/gemini", "~/.claude-accounts/work"], "\(labels)")
    #expect(inst.targets(for: .claude).count == 4)
}

@Test func theSettingsFileDoesNotMakeAFolderLookBusy() {
    let h = FakeHome(); defer { h.remove() }
    let f = h.file(".claude/settings.json", "{}")                                                    // just written: fresh mtime
    let inst = h.installer(at: Date())
    let t = inst.targets(for: .claude)[0]
    #expect(inst.lastActivity(of: t) == nil && FileManager.default.fileExists(atPath: f.path))
}

@Test func withNothingRecentTheDefaultFolderIsRecommended() {
    let h = FakeHome(); defer { h.remove() }
    h.file(".claude/settings.json", "{}"); touch(h.dir(".claude/projects"), daysAgo: 400)
    h.file(".claude-accounts/old/settings.json", "{}"); touch(h.dir(".claude-accounts/old/projects"), daysAgo: 400)
    #expect(h.installer(at: Date()).recommended(for: .claude).map(\.label) == ["~/.claude"])
    // Without a default folder, everything found is offered.
    let g = FakeHome(); defer { g.remove() }
    g.file(".claude-accounts/a/settings.json", "{}"); g.file(".claude-accounts/b/settings.json", "{}")
    #expect(g.installer(at: Date()).recommended(for: .claude).count == 2)
}

@Test func codexIsAlwaysRecommendedAsItIs() {
    let h = FakeHome(); defer { h.remove() }
    h.dir(".codex")
    #expect(h.installer(at: Date()).recommended(for: .codex).map(\.label) == ["~/.codex"])
    #expect(h.installer(at: Date()).recommended(for: .opencode).isEmpty)
}
