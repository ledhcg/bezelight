import Foundation

/// The whole behaviour of `bezelight-hook`, with its side effects injected so it can be tested.
///
/// Contract (never to be broken, whatever happens): exit 0, nothing on stderr, and a JSON object
/// on stdout. Codex requires JSON from `Stop`, and `{}` is a no-op for every agent.
public struct HookCLI {
    public static let version = "0.3.0 protocol \(Wire.version)"

    public var arguments: [String]
    public var readInput: () -> Data
    public var now: () -> Int64
    public var agentPID: () -> Int32?
    public var send: (Data) -> Bool

    public init(arguments: [String], readInput: @escaping () -> Data, now: @escaping () -> Int64,
                agentPID: @escaping () -> Int32?, send: @escaping (Data) -> Bool) {
        self.arguments = arguments; self.readInput = readInput; self.now = now
        self.agentPID = agentPID; self.send = send
    }

    /// Returns what to print on stdout.
    public func run() -> String {
        let args = Array(arguments.dropFirst())
        switch args.first {
        case "--version", "-v":
            return Self.version + "\n"
        case "--selftest":
            return selftest() + "\n"
        case "claude", "codex":
            // Taken first: the timestamp must be when the hook *started*, to order events correctly.
            let start = now()
            let input = readInput()
            let pid = agentPID()
            let events = args.first == "claude"
                ? ClaudeNormalizer.events(from: input, now: start, pid: pid)
                : CodexNormalizer.events(from: input, now: start, pid: pid)
            for e in events { if let data = Wire.encode(e) { _ = send(data) } }
            return "{}\n"
        default:
            return "{}\n"
        }
    }

    /// Sends a harmless event (a `seen` for a session nobody knows is ignored by the app) so
    /// support can tell whether the app is listening.
    private func selftest() -> String {
        let e = AgentEvent(agent: .claude, kind: .seen, session: "selftest", ts: now(), src: "selftest")
        guard let data = Wire.encode(e) else { return "error: could not encode" }
        return send(data) ? "ok: delivered to the app" : "not delivered: the app is not running (or not listening)"
    }
}
