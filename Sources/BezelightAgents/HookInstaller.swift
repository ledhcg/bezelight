import Foundation
import Darwin

/// A configuration file Bezelight can add its hooks to.
public struct InstallTarget: Identifiable, Equatable, Sendable {
    public var id: String { file.path }
    public var agent: AgentKind
    public var file: URL
    /// Short, human-readable place (`~/.claude`, `~/.claude-accounts/work`).
    public var label: String
    /// The configuration the agent would read in a normal shell (`CLAUDE_CONFIG_DIR`, else the default).
    public var isActive: Bool
    public var exists: Bool
}

public struct InstallResult: Equatable, Sendable {
    public var changed: Bool
    /// Copy of the file as it was, kept before the first change.
    public var backup: URL?
}

/// Finds the agents on this Mac and their configuration files, and edits those files safely.
///
/// Safety rules, all of them tested: never write a file that is not valid JSON; take a backup
/// before changing anything; replace the file atomically (a crash cannot leave half a file);
/// follow a symlinked file to its target and keep the link; keep permissions; notice if another
/// program changed the file while we were editing and start over; one edit at a time.
public struct HookInstaller: @unchecked Sendable {
    public var paths: BezelightPaths
    public var home: URL
    public var environment: [String: String]
    public var now: @Sendable () -> Date
    /// Where Homebrew and friends put command-line tools, besides `PATH` and `~/.local/bin`.
    public var systemBinaryDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// Test seam: called after a new version is written but before it replaces the old one.
    public var beforeCommit: (@Sendable (_ attempt: Int) -> Void)?

    public static let backupsKept = 5

    public init(paths: BezelightPaths = .current(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths; self.home = home; self.environment = environment; self.now = now
    }

    // MARK: finding things

    public func targets(for agent: AgentKind) -> [InstallTarget] {
        let fm = FileManager.default
        var out: [InstallTarget] = []
        var seen = Set<String>()
        func add(_ dir: URL, file: String, label: String, active: Bool) {
            let target = dir.appendingPathComponent(file)
            let key = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(key) else {
                if active, let i = out.firstIndex(where: { $0.id == key || $0.file.resolvingSymlinksInPath().path == key }) { out[i].isActive = true }
                return
            }
            seen.insert(key)
            out.append(InstallTarget(agent: agent, file: target, label: label, isActive: active, exists: fm.fileExists(atPath: target.path)))
        }
        switch agent {
        case .claude:
            let defaultDir = home.appendingPathComponent(".claude", isDirectory: true)
            let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            let activeDir = (custom ?? defaultDir).standardizedFileURL
            if isDirectory(defaultDir) { add(defaultDir, file: "settings.json", label: tilde(defaultDir), active: defaultDir.standardizedFileURL == activeDir) }
            if let custom, isDirectory(custom) { add(custom, file: "settings.json", label: tilde(custom), active: true) }
            let accounts = home.appendingPathComponent(".claude-accounts", isDirectory: true)
            let names = ((try? fm.contentsOfDirectory(atPath: accounts.path)) ?? []).sorted()
            for name in names {
                let dir = accounts.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(dir), looksLikeClaudeConfig(dir) else { continue }
                add(dir, file: "settings.json", label: tilde(dir), active: dir.standardizedFileURL == activeDir)
            }
        case .codex:
            let defaultDir = home.appendingPathComponent(".codex", isDirectory: true)
            let custom = environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            let activeDir = (custom ?? defaultDir).standardizedFileURL
            if isDirectory(defaultDir) { add(defaultDir, file: "hooks.json", label: tilde(defaultDir), active: defaultDir.standardizedFileURL == activeDir) }
            if let custom, isDirectory(custom) { add(custom, file: "hooks.json", label: tilde(custom), active: true) }
        case .opencode:
            break         // nothing to install: the app listens to OpenCode's own event stream
        }
        return out
    }

    private func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private func looksLikeClaudeConfig(_ dir: URL) -> Bool {
        ["settings.json", "projects", ".claude.json", "CLAUDE.md", "sessions"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private func tilde(_ url: URL) -> String {
        let p = url.standardizedFileURL.path, h = home.standardizedFileURL.path
        return p == h ? "~" : (p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p)
    }

    /// When the agent last did real work in this folder (its sessions, projects or history), or nil.
    /// The settings file itself does not count: installing would make every folder look busy.
    public func lastActivity(of target: InstallTarget) -> Date? {
        let dir = target.file.deletingLastPathComponent()
        let names = target.agent == .claude ? ["projects", "sessions", "history.jsonl", "todos"] : ["sessions", "history.jsonl"]
        let dates = names.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }
        return dates.max()
    }

    /// The folders worth setting up by default. The app cannot see which folder a Claude Code session
    /// uses (a GUI app does not inherit `CLAUDE_CONFIG_DIR` from a shell), so it picks the ones that were
    /// used lately rather than every account folder it finds. With none in use, the default folder.
    public func recommended(for agent: AgentKind, withinDays days: Double = 30) -> [InstallTarget] {
        let all = targets(for: agent)
        guard agent == .claude else { return all }
        let cutoff = now().addingTimeInterval(-days * 86_400)
        let recent = all.filter { (lastActivity(of: $0) ?? .distantPast) > cutoff }
        if !recent.isEmpty { return recent }
        if let main = all.first(where: { $0.file.deletingLastPathComponent().standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL }) {
            return [main]
        }
        return all
    }

    /// Is the agent itself on this Mac?
    public func isAgentInstalled(_ agent: AgentKind) -> Bool {
        let fm = FileManager.default
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [home.appendingPathComponent(".local/bin").path] + systemBinaryDirs
        let (binary, extra): (String, [String]) = {
            switch agent {
            case .claude: return ("claude", [home.appendingPathComponent(".claude/local/claude").path])
            case .codex: return ("codex", [])
            case .opencode: return ("opencode", [home.appendingPathComponent(".opencode/bin/opencode").path])
            }
        }()
        if (dirs.map { $0 + "/" + binary } + extra).contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        switch agent {
        case .claude: return isDirectory(home.appendingPathComponent(".claude"))
        case .codex: return isDirectory(home.appendingPathComponent(".codex"))
        case .opencode: return fm.fileExists(atPath: OpenCodeLocation.serviceFile(home: home, environment: environment).path)
        }
    }

    // MARK: status

    public func inspect(_ target: InstallTarget) -> HookInspection {
        let specs = HookCatalog.specs(for: target.agent), command = HookCatalog.command(for: target.agent)
        guard FileManager.default.fileExists(atPath: target.file.path) else {
            return HookInspection(state: .notInstalled, entries: 0, hooksDisabled: false)
        }
        guard let data = try? Data(contentsOf: target.file), let text = String(data: data, encoding: .utf8) else {
            return HookInspection(state: .unreadable("cannot read \(target.file.lastPathComponent)"), entries: 0, hooksDisabled: false)
        }
        return HookConfigEditor.inspect(text, specs: specs, command: command)
    }

    // MARK: changing

    @discardableResult
    public func install(_ target: InstallTarget) throws -> InstallResult {
        let specs = HookCatalog.specs(for: target.agent), command = HookCatalog.command(for: target.agent)
        return try apply(target.file, creating: true) { old in
            let new = try HookConfigEditor.install(old, specs: specs, command: command)
            guard HookConfigEditor.isSafeEdit(old: old, new: new) else { throw InstallError.invalidResult }
            return new
        }
    }

    @discardableResult
    public func uninstall(_ target: InstallTarget) throws -> InstallResult {
        guard FileManager.default.fileExists(atPath: target.file.path) else { return InstallResult(changed: false, backup: nil) }
        return try apply(target.file, creating: false) { old in
            guard let old else { return nil }
            let new = try HookConfigEditor.uninstall(old)
            guard HookConfigEditor.isSafeEdit(old: old, new: new) else { throw InstallError.invalidResult }
            return new
        }
    }

    // MARK: backups

    public func backups(for target: InstallTarget) -> [URL] {
        let prefix = Self.backupPrefix(for: resolved(target.file))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        return names.map { paths.backups.appendingPathComponent($0) }
    }

    /// Puts the file back as it was before the most recent change (itself backed up first).
    @discardableResult
    public func restoreLatestBackup(for target: InstallTarget) throws -> InstallResult {
        guard let latest = backups(for: target).last, let data = try? Data(contentsOf: latest),
              let text = String(data: data, encoding: .utf8) else { throw InstallError.io("no backup to restore") }
        return try apply(target.file, creating: true) { _ in text }
    }

    // MARK: the safe write

    func resolved(_ file: URL) -> URL { file.resolvingSymlinksInPath() }

    static func backupPrefix(for file: URL) -> String {
        file.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_") + "."
    }

    func apply(_ file: URL, creating: Bool, _ transform: (String?) throws -> String?) throws -> InstallResult {
        let fm = FileManager.default
        let target = resolved(file)
        let dir = target.deletingLastPathComponent()
        guard isDirectory(dir) else { throw InstallError.missingFolder(dir.path) }

        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try FileLock(url: paths.home.appendingPathComponent("install.lock"))
        defer { lock.unlock() }

        var backup: URL?
        for attempt in 1...3 {
            let exists = fm.fileExists(atPath: target.path)
            if !exists && !creating { return InstallResult(changed: false, backup: nil) }
            let baseData: Data? = exists ? try? Data(contentsOf: target) : nil
            if exists, baseData == nil { throw InstallError.notWritable(target.path) }
            let baseText: String?
            if let baseData {
                guard let t = String(data: baseData, encoding: .utf8) else { throw InstallError.notJSON("the file is not UTF-8 text") }
                baseText = t
            } else { baseText = nil }

            guard let new = try transform(baseText), new != baseText else { return InstallResult(changed: false, backup: backup) }
            guard exists ? fm.isWritableFile(atPath: target.path) && fm.isWritableFile(atPath: dir.path) : fm.isWritableFile(atPath: dir.path)
            else { throw InstallError.notWritable(target.path) }

            if backup == nil, let baseData { backup = try writeBackup(baseData, for: target) }

            let mode = ((try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber)?.int16Value ?? 0o600
            let temp = dir.appendingPathComponent(".bezelight-\(UUID().uuidString.prefix(8)).tmp")
            do {
                guard fm.createFile(atPath: temp.path, contents: Data(new.utf8), attributes: [.posixPermissions: mode]) else {
                    throw InstallError.notWritable(temp.path)
                }
                if let h = try? FileHandle(forWritingTo: temp) { try? h.synchronize(); try? h.close() }
                beforeCommit?(attempt)
                // Another program may have changed the file since we read it: then start again from its new content.
                let nowData: Data? = fm.fileExists(atPath: target.path) ? try? Data(contentsOf: target) : nil
                guard nowData == baseData else { try? fm.removeItem(at: temp); continue }
                guard rename(temp.path, target.path) == 0 else {
                    throw InstallError.io("could not replace \(target.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                return InstallResult(changed: true, backup: backup)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        throw InstallError.changedUnderneath
    }

    private func writeBackup(_ data: Data, for file: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter.backupStamp.string(from: now())
        var url = paths.backups.appendingPathComponent(Self.backupPrefix(for: file) + stamp + ".bak")
        var n = 1
        while fm.fileExists(atPath: url.path) { n += 1; url = paths.backups.appendingPathComponent(Self.backupPrefix(for: file) + stamp + "-\(n).bak") }
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw InstallError.io("could not write a backup")
        }
        // Keep only the newest few.
        let prefix = Self.backupPrefix(for: file)
        let old = ((try? fm.contentsOfDirectory(atPath: paths.backups.path)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        for name in old.dropLast(Self.backupsKept) { try? fm.removeItem(at: paths.backups.appendingPathComponent(name)) }
        return url
    }
}

extension DateFormatter {
    fileprivate static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// One edit at a time, across threads and processes.
final class FileLock {
    private var fd: Int32

    init(url: URL, timeout: TimeInterval = 5) throws {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw InstallError.io("cannot create the lock file") }
        let end = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < end else { close(fd); fd = -1; throw InstallError.changedUnderneath }
            usleep(20_000)
        }
    }

    func unlock() { if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 } }
    deinit { unlock() }
}

/// Where OpenCode 2.0 publishes how to reach its background service.
public enum OpenCodeLocation {
    public static func serviceFile(home: URL, environment: [String: String]) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/state")
        return base.appendingPathComponent("opencode/service.json")
    }
}

// MARK: the helper binary

/// Keeps `~/.bezelight/bin/bezelight-hook` equal to the copy inside the app. The hook entries
/// never change (Codex ties its trust to their text); only this binary is replaced on upgrade.
public struct HelperDeployer: Sendable {
    public enum Status: Equatable, Sendable { case missing, outdated, notExecutable, current }

    public var paths: BezelightPaths
    public init(paths: BezelightPaths = .current()) { self.paths = paths }

    public func status(source: URL) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.helper.path) else { return .missing }
        guard let installed = try? Data(contentsOf: paths.helper), let wanted = try? Data(contentsOf: source), installed == wanted else { return .outdated }
        return fm.isExecutableFile(atPath: paths.helper.path) ? .current : .notExecutable
    }

    /// Copies the helper into place atomically. Returns whether anything changed.
    @discardableResult
    public func deploy(source: URL) throws -> Bool {
        if status(source: source) == .current { return false }
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: source), !data.isEmpty else { throw InstallError.io("the helper is missing from the app") }
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = paths.bin.appendingPathComponent(".bezelight-hook.\(UUID().uuidString.prefix(8)).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o755]) else {
            throw InstallError.notWritable(temp.path)
        }
        removexattr(temp.path, "com.apple.quarantine", 0)       // a copy made by the app is trusted, but be sure
        guard rename(temp.path, paths.helper.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw InstallError.io("could not install the helper: \(String(cString: strerror(errno)))")
        }
        return true
    }

    public func remove() {
        try? FileManager.default.removeItem(at: paths.helper)
    }
}
