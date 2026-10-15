import Foundation
import BezelightAgents

/// One line of the "Check" report. The message is a localisation key plus arguments, so the
/// settings screen can show it in any of the app's languages.
public struct DoctorCheck: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case ok, info, warning, failed }
    public var id: String
    public var status: Status
    public var key: String
    public var args: [String]
    public init(_ id: String, _ status: Status, _ key: String, _ args: [String] = []) {
        self.id = id; self.status = status; self.key = key; self.args = args
    }
}

/// Looks at everything that has to work for an alert to reach the strip and says what is wrong.
public struct AgentDoctor: Sendable {
    public var installer: HookInstaller
    public var deployer: HelperDeployer
    /// The helper inside the app bundle (nil when running from a build without one).
    public var helperSource: URL?
    public var runtime: @Sendable () -> RuntimeStatus
    public var lastEvents: @Sendable () async -> [AgentKind: Date]
    public var now: @Sendable () -> Date

    public init(installer: HookInstaller, deployer: HelperDeployer, helperSource: URL?,
                runtime: @escaping @Sendable () -> RuntimeStatus,
                lastEvents: @escaping @Sendable () async -> [AgentKind: Date],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.installer = installer; self.deployer = deployer; self.helperSource = helperSource
        self.runtime = runtime; self.lastEvents = lastEvents; self.now = now
    }

    public func run() async -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let status = runtime()
        let last = await lastEvents()

        // 1. the helper binary
        if let src = helperSource {
            switch deployer.status(source: src) {
            case .current: out.append(.init("helper", .ok, "doctor.helper.ok"))
            case .missing: out.append(.init("helper", .failed, "doctor.helper.missing"))
            case .outdated: out.append(.init("helper", .warning, "doctor.helper.outdated"))
            case .notExecutable: out.append(.init("helper", .failed, "doctor.helper.notExecutable"))
            }
        } else {
            out.append(.init("helper", .warning, "doctor.helper.noSource"))
        }

        // 2. the socket the hooks talk to, and a real round trip through the installed helper
        switch status.listener {
        case .listening:
            out.append(.init("socket", .ok, "doctor.socket.ok"))
            out.append(roundTrip())
        case .stopped: out.append(.init("socket", .warning, "doctor.socket.stopped"))
        case .alreadyRunning: out.append(.init("socket", .warning, "doctor.socket.otherInstance"))
        case .failed(let why): out.append(.init("socket", .failed, "doctor.socket.failed", [why]))
        }

        // 3. Claude Code and Codex: hooks in each configuration file
        for agent in [AgentKind.claude, .codex] {
            let name = agent == .claude ? "Claude Code" : "Codex"
            guard installer.isAgentInstalled(agent) else { out.append(.init("\(agent.rawValue)", .info, "doctor.agent.notFound", [name])); continue }
            let targets = installer.targets(for: agent)
            if targets.isEmpty { out.append(.init("\(agent.rawValue):folder", .info, "doctor.agent.noFolder", [name])); continue }
            var anyInstalled = false
            for t in targets {
                let id = "\(agent.rawValue):\(t.label)"
                let insp = installer.inspect(t)
                switch insp.state {
                case .installed:
                    anyInstalled = true
                    out.append(.init(id, .ok, "doctor.hooks.installed", [name, t.label]))
                case .notInstalled:
                    out.append(.init(id, t.isActive ? .warning : .info, "doctor.hooks.notInstalled", [name, t.label]))
                case .partial(let missing):
                    anyInstalled = true
                    out.append(.init(id, .warning, "doctor.hooks.partial", [name, t.label, missing.joined(separator: ", ")]))
                case .unreadable(let why):
                    out.append(.init(id, .failed, "doctor.hooks.unreadable", [name, t.label, why]))
                }
                if insp.hooksDisabled { out.append(.init("\(id):disabled", .warning, "doctor.hooks.disabled", [name, t.label])) }
                if t.exists, !FileManager.default.isWritableFile(atPath: t.file.resolvingSymlinksInPath().path) {
                    out.append(.init("\(id):readonly", .warning, "doctor.hooks.readOnly", [name, t.label]))
                }
            }
            if anyInstalled {
                if let when = last[agent] {
                    out.append(.init("\(agent.rawValue):last", .ok, "doctor.agent.lastEvent", [name, Self.ago(now().timeIntervalSince(when))]))
                } else {
                    out.append(.init("\(agent.rawValue):last", .info, agent == .codex ? "doctor.codex.noEventTrust" : "doctor.claude.noEventRestart", [name]))
                }
            }
        }

        // 4. OpenCode: nothing to install, only a connection
        if installer.isAgentInstalled(.opencode) {
            switch status.openCode {
            case .connected(let v): out.append(.init("opencode", .ok, "doctor.opencode.connected", [v ?? "?"]))
            case .waitingForOpenCode: out.append(.init("opencode", .info, "doctor.opencode.waiting"))
            case .connecting: out.append(.init("opencode", .info, "doctor.opencode.connecting"))
            case .failed(let why): out.append(.init("opencode", .failed, "doctor.opencode.failed", [why]))
            case .stopped: out.append(.init("opencode", .warning, "doctor.opencode.stopped"))
            }
            if let when = last[.opencode] {
                out.append(.init("opencode:last", .ok, "doctor.agent.lastEvent", ["OpenCode", Self.ago(now().timeIntervalSince(when))]))
            }
        } else {
            out.append(.init("opencode", .info, "doctor.agent.notFound", ["OpenCode"]))
        }
        return out
    }

    /// Runs the installed helper's self-test, which sends a harmless event to the socket.
    private func roundTrip() -> DoctorCheck {
        guard FileManager.default.isExecutableFile(atPath: deployer.paths.helper.path) else { return .init("roundtrip", .info, "doctor.roundtrip.skipped") }
        let p = Process()
        p.executableURL = deployer.paths.helper
        p.arguments = ["--selftest"]
        p.environment = ["BEZELIGHT_HOME": deployer.paths.home.path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe(); p.standardInput = Pipe()
        do { try p.run() } catch { return .init("roundtrip", .failed, "doctor.roundtrip.failed", ["\(error.localizedDescription)"]) }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return .init("roundtrip", .failed, "doctor.roundtrip.timeout") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.hasPrefix("ok") ? .init("roundtrip", .ok, "doctor.roundtrip.ok") : .init("roundtrip", .failed, "doctor.roundtrip.failed", [text.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 90 { return "\(s)s" }
        if s < 5400 { return "\(s / 60) min" }
        if s < 172_800 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }

    /// Plain text for "Copy report". Home folders are shortened to `~` and session ids never appear.
    public func report(_ checks: [DoctorCheck], translate: (String, [String]) -> String) -> String {
        let home = installer.home.path
        let mark: [DoctorCheck.Status: String] = [.ok: "[ok]  ", .info: "[info]", .warning: "[warn]", .failed: "[FAIL]"]
        return checks.map { c in
            let line = "\(mark[c.status] ?? "") \(translate(c.key, c.args))"
            return line.replacingOccurrences(of: home, with: "~")
        }.joined(separator: "\n")
    }
}
