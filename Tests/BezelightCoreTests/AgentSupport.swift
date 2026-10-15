import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ path: String, in dir: String = "agents", ext: String = "json") -> Data {
        let url = root.appendingPathComponent("\(dir)/\(path).\(ext)")
        guard let d = try? Data(contentsOf: url) else { fatalError("missing fixture \(url.path)") }
        return d
    }
}

/// Drives an `AgentTracker` the way the app would, with a fake clock and a fake keyboard.
struct Rig {
    var tracker: AgentTracker
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    var now = Rig.epoch
    /// The user starts away from the machine.
    var lastInput = Rig.epoch.addingTimeInterval(-86_400)
    var effects: [TrackerEffect] = []

    init(settings: AgentAlertSettings = AgentAlertSettings()) { tracker = AgentTracker(settings: settings) }

    var presence: PresenceSample { PresenceSample(idleSeconds: max(0, now.timeIntervalSince(lastInput)), lastInputAt: lastInput) }
    var ms: Int64 { Int64((now.timeIntervalSince1970 * 1000).rounded()) }

    mutating func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
    mutating func input() { lastInput = now }

    @discardableResult
    mutating func send(_ kind: EventKind, _ agent: AgentKind = .claude, session: String = "s1", req: String? = nil,
                       sub: String? = nil, cwd: String? = nil, pid: Int32? = nil, tp: String? = nil,
                       src: String? = nil, ts: Int64? = nil) -> [TrackerEffect] {
        let e = AgentEvent(agent: agent, kind: kind, session: session, ts: ts ?? ms, req: req, sub: sub, cwd: cwd, pid: pid, tp: tp, src: src)
        let fx = tracker.apply(e, now: now, presence: presence)
        effects += fx
        return fx
    }

    @discardableResult
    mutating func tick(alive: (Int32) -> Bool = { _ in true }) -> [TrackerEffect] {
        let fx = tracker.tick(now: now, presence: presence, alive: alive)
        effects += fx
        return fx
    }

    var display: DisplayState? { tracker.display(now: now) }
    func state(_ session: String = "s1", _ agent: AgentKind = .claude) -> SessionState? {
        tracker.session(SessionKey(agent: agent, session: session))?.state
    }
}

/// Replays a recorded timeline (Tests/Fixtures/timelines/*.jsonl) through the tracker.
///
/// One JSON object per line, `at` in milliseconds from the start:
///   {"at":4000,"fixture":"claude/PermissionRequest.bash"}   real payload through its normalizer
///   {"at":4000,"sse":{...}}                                 raw OpenCode frame
///   {"at":7300,"event":{"agent":"claude","kind":"answered","session":"…","src":"transcript"}}
///   {"at":20000,"input":true}                               the user touches keyboard / mouse
///   {"at":21000,"expect":{"display":"done","state":"done"}} "display": none|needsInput|error|done|working
/// The tracker is ticked once per second, like the app does.
struct Replay {
    static let baseMs: Int64 = 1_800_000_000_000

    let name: String
    var rig: Rig
    var openCode = OpenCodeNormalizer()
    var lastTick: Int64 = 0

    init(_ name: String, settings: AgentAlertSettings = AgentAlertSettings()) { self.name = name; rig = Rig(settings: settings) }

    mutating func run(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = String(decoding: Fixtures.data(name, in: "timelines", ext: "jsonl"), as: UTF8.self)
        for (index, raw) in text.split(separator: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                   "\(name):\(index + 1) is not an object", sourceLocation: sourceLocation)
            let at = (obj["at"] as? NSNumber)?.int64Value ?? 0
            tick(until: at)
            rig.now = Rig.epoch.addingTimeInterval(Double(at) / 1000)
            let where_ = Comment(rawValue: "\(name):\(index + 1) @\(at)ms")

            if let f = obj["fixture"] as? String { apply(try events(fromFixture: f, at: at)) }
            if let sse = obj["sse"] { apply(openCode.events(from: try JSONSerialization.data(withJSONObject: sse), now: Replay.baseMs + at)) }
            if let e = obj["event"] as? [String: Any] { apply([try inline(e, at: at)]) }
            if obj["input"] as? Bool == true { rig.input() }
            if let exp = obj["expect"] as? [String: Any] { check(exp, where_, sourceLocation) }
        }
    }

    private mutating func tick(until at: Int64) {
        var t = lastTick + 1000
        while t <= at {
            rig.now = Rig.epoch.addingTimeInterval(Double(t) / 1000)
            rig.tick()
            t += 1000
        }
        lastTick = max(lastTick, (at / 1000) * 1000)
    }

    private mutating func events(fromFixture f: String, at: Int64) throws -> [AgentEvent] {
        let data = Fixtures.data(f)
        let now = Replay.baseMs + at
        switch f.split(separator: "/").first.map(String.init) {
        case "claude": return ClaudeNormalizer.events(from: data, now: now)
        case "codex": return CodexNormalizer.events(from: data, now: now)
        default: return openCode.events(from: data, now: now)
        }
    }

    private func inline(_ e: [String: Any], at: Int64) throws -> AgentEvent {
        var ev = AgentEvent(agent: AgentKind(rawValue: e["agent"] as? String ?? "") ?? .claude,
                            kind: EventKind(rawValue: e["kind"] as? String ?? "") ?? .working,
                            session: e["session"] as? String ?? "s", ts: Replay.baseMs + at)
        ev.sub = e["sub"] as? String; ev.req = e["req"] as? String; ev.src = e["src"] as? String
        return ev
    }

    private mutating func apply(_ events: [AgentEvent]) {
        for var e in events {
            e.ts = Replay.baseMs + Int64((rig.now.timeIntervalSince(Rig.epoch) * 1000).rounded())
            rig.effects += rig.tracker.apply(e, now: rig.now, presence: rig.presence)
        }
    }

    private func check(_ exp: [String: Any], _ where_: Comment, _ loc: SourceLocation) {
        if let want = exp["display"] as? String {
            let got = rig.display?.kind.rawValue ?? "none"
            #expect(got == want, "display: \(where_)", sourceLocation: loc)
        }
        if let want = exp["state"] as? String {
            let sessions = rig.tracker.sessions
            #expect(sessions.count == 1, "expected one session, have \(sessions.count): \(where_)", sourceLocation: loc)
            #expect(sessions.first?.state.rawValue == want, "state: \(where_)", sourceLocation: loc)
        }
        if let n = (exp["sessions"] as? NSNumber)?.intValue {
            #expect(rig.tracker.sessions.count == n, "session count: \(where_)", sourceLocation: loc)
        }
    }
}

extension Fixtures {
    /// A configuration file with another tool's hooks in it (Tests/Fixtures/configs).
    static func text(_ path: String) -> String {
        guard let s = try? String(contentsOf: root.appendingPathComponent("configs/\(path).json"), encoding: .utf8) else { fatalError("missing config fixture \(path)") }
        return s
    }
}
