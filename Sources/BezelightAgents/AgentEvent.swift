import Foundation

/// The coding agents Bezelight can listen to.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, opencode
}

/// Normalised event vocabulary shared by every agent (see docs/AGENT_NOTIFICATIONS.md, section 6).
public enum EventKind: String, Codable, Sendable {
    case start, working, ask, answered, done, error, interrupt, end, substart, substop, seen

    /// Events that finish a turn. At equal timestamps they win over `working`.
    public var isTerminal: Bool {
        switch self {
        case .done, .error, .interrupt, .end: return true
        default: return false
        }
    }
}

/// One normalised event. Small on purpose: it travels in a single datagram and never carries
/// prompts, answers, commands or tool output.
public struct AgentEvent: Codable, Sendable, Equatable {
    public var v: Int
    public var agent: AgentKind
    public var kind: EventKind
    /// ID of the *root* session (OpenCode child sessions are folded into their parent).
    public var session: String
    /// Request ID (OpenCode permission / form), used to pair `ask` with `answered`.
    public var req: String?
    /// Subagent (Claude `agent_id`) or child session (OpenCode) that produced the event.
    public var sub: String?
    public var cwd: String?
    public var pid: Int32?
    /// Transcript path. Only set on Claude `ask` events, so the app can notice a refusal.
    public var tp: String?
    /// Milliseconds since the epoch, taken when the hook process started. Orders events.
    public var ts: Int64
    /// Original event name, for diagnostics only.
    public var src: String?

    public init(
        agent: AgentKind, kind: EventKind, session: String, ts: Int64,
        req: String? = nil, sub: String? = nil, cwd: String? = nil, pid: Int32? = nil,
        tp: String? = nil, src: String? = nil
    ) {
        self.v = Wire.version
        self.agent = agent; self.kind = kind; self.session = session; self.ts = ts
        self.req = req; self.sub = sub; self.cwd = cwd; self.pid = pid; self.tp = tp; self.src = src
    }

    private enum Keys: String, CodingKey { case v, agent, kind, session, req, sub, cwd, pid, tp, ts, src }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? Wire.version
        agent = try c.decode(AgentKind.self, forKey: .agent)
        kind = try c.decode(EventKind.self, forKey: .kind)
        session = try c.decode(String.self, forKey: .session)
        ts = try c.decode(Int64.self, forKey: .ts)
        req = try c.decodeIfPresent(String.self, forKey: .req)
        sub = try c.decodeIfPresent(String.self, forKey: .sub)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        tp = try c.decodeIfPresent(String.self, forKey: .tp)
        src = try c.decodeIfPresent(String.self, forKey: .src)
    }
}

/// Datagram codec. Decoding is defensive: anything malformed, oversized or from an unknown
/// protocol version is dropped silently.
public enum Wire {
    public static let version = 1
    /// Encoded events never exceed this (macOS datagrams top out around 2 KB).
    public static let maxBytes = 1024
    /// Anything larger is not ours.
    public static let maxAcceptedBytes = 2048
    static let maxField = 128
    static let maxPath = 512

    public static func encode(_ event: AgentEvent) -> Data? {
        var e = event
        e.session = clean(e.session, limit: maxField) ?? ""
        guard !e.session.isEmpty else { return nil }
        e.req = clean(e.req, limit: maxField)
        e.sub = clean(e.sub, limit: maxField)
        e.cwd = clean(e.cwd, limit: maxPath)
        e.tp = clean(e.tp, limit: maxPath)
        e.src = clean(e.src, limit: 48)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Shrink the optional, bulky fields until it fits; the transcript path goes first.
        for step in 0..<4 {
            switch step {
            case 1: e.tp = nil
            case 2: if let c = e.cwd, c.count > 64 { e.cwd = String(c.suffix(64)) }
            case 3: e.cwd = nil
            default: break
            }
            if let data = try? enc.encode(e), data.count <= maxBytes { return data }
        }
        return nil
    }

    public static func decode(_ data: Data) -> AgentEvent? {
        guard !data.isEmpty, data.count <= maxAcceptedBytes,
              var e = try? JSONDecoder().decode(AgentEvent.self, from: data),
              e.v == version, e.ts > 0 else { return nil }
        guard let session = clean(e.session, limit: maxField), !session.isEmpty else { return nil }
        e.session = session
        e.req = clean(e.req, limit: maxField)
        e.sub = clean(e.sub, limit: maxField)
        e.cwd = clean(e.cwd, limit: maxPath)
        e.tp = clean(e.tp, limit: maxPath)
        e.src = clean(e.src, limit: 48)
        return e
    }

    /// Trims, drops control characters and caps the length. Returns nil for nil / blank input.
    static func clean(_ s: String?, limit: Int) -> String? {
        guard let s else { return nil }
        let printable = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        var out = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        if out.count > limit { out = String(out.prefix(limit)) }
        return out.isEmpty ? nil : out
    }
}
