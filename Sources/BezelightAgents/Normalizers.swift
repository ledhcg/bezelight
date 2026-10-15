import Foundation

/// Pure functions that turn what an agent emits into `AgentEvent`s.
///
/// Privacy rule: these read an explicit allow-list of fields (session id, cwd, agent id, event
/// name, notification type, transcript path). Prompts, answers, commands and tool output are
/// never read into an event, so they cannot leak by accident.
enum HookJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ o: [String: Any], _ key: String) -> String? {
        guard let s = o[key] as? String, !s.isEmpty else { return nil }
        return s
    }
}

public enum ClaudeNormalizer {
    /// `stdin` is the JSON a Claude Code hook receives. Returns zero or more events.
    public static func events(from stdin: Data, now: Int64, pid: Int32? = nil) -> [AgentEvent] {
        guard let o = HookJSON.object(stdin),
              let name = HookJSON.string(o, "hook_event_name"),
              let session = HookJSON.string(o, "session_id") else { return [] }
        let cwd = HookJSON.string(o, "cwd")
        let agentID = HookJSON.string(o, "agent_id")

        func make(_ kind: EventKind, sub: String? = nil, tp: String? = nil) -> [AgentEvent] {
            [AgentEvent(agent: .claude, kind: kind, session: session, ts: now,
                        sub: sub, cwd: cwd, pid: pid, tp: tp, src: name)]
        }

        switch name {
        case "SessionStart": return make(.start)
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure": return make(.working, sub: agentID)
        case "PermissionRequest":
            // Covers AskUserQuestion too (Phase 0: it arrives as a PermissionRequest).
            return make(.ask, sub: agentID, tp: HookJSON.string(o, "transcript_path"))
        case "Notification":
            // `permission_prompt` is deliberately ignored: it arrives ~6 s after the
            // PermissionRequest that already reported it.
            switch HookJSON.string(o, "notification_type") {
            case "elicitation_dialog", "agent_needs_input": return make(.ask, sub: agentID)
            default: return []
            }
        case "Stop": return make(.done)
        case "StopFailure": return make(.error)
        case "SessionEnd": return make(.end)
        case "SubagentStart":
            guard let id = agentID else { return [] }
            return make(.substart, sub: id)
        case "SubagentStop":
            guard let id = agentID else { return [] }
            return make(.substop, sub: id)
        default: return []
        }
    }
}

public enum CodexNormalizer {
    public static func events(from stdin: Data, now: Int64, pid: Int32? = nil) -> [AgentEvent] {
        guard let o = HookJSON.object(stdin),
              let name = HookJSON.string(o, "hook_event_name"),
              let session = HookJSON.string(o, "session_id") else { return [] }
        let cwd = HookJSON.string(o, "cwd")
        let agentID = HookJSON.string(o, "agent_id")

        func make(_ kind: EventKind, sub: String? = nil) -> [AgentEvent] {
            [AgentEvent(agent: .codex, kind: kind, session: session, ts: now,
                        sub: sub, cwd: cwd, pid: pid, src: name)]
        }

        switch name {
        case "SessionStart": return make(.start)
        case "UserPromptSubmit", "PostToolUse": return make(.working, sub: agentID)
        case "PermissionRequest": return make(.ask, sub: agentID)
        case "Stop": return make(.done)
        // Phase 0: refusing or pressing Esc produces only `Interrupt` (no Stop, no PostToolUse).
        case "Interrupt": return make(.interrupt)
        case "SessionEnd": return make(.end)
        case "SubagentStart":
            guard let id = agentID else { return [] }
            return make(.substart, sub: id)
        case "SubagentStop":
            guard let id = agentID else { return [] }
            return make(.substop, sub: id)
        default: return []
        }
    }
}

/// Turns frames of OpenCode 2.0's native event stream (`GET /api/event`) into events.
///
/// Stateful: it remembers which sessions are children so a subagent's activity is folded into
/// its root session. A child's start and end become `substart` / `substop`; only the root's
/// execution end is a `done`.
public struct OpenCodeNormalizer: Sendable {
    private var parents: [String: String] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 512) { self.capacity = capacity }

    /// `frame` is the JSON after the SSE `data:` prefix.
    public mutating func events(from frame: Data, now: Int64) -> [AgentEvent] {
        guard let e = HookJSON.object(frame), let type = HookJSON.string(e, "type") else { return [] }
        let data = e["data"] as? [String: Any] ?? [:]
        guard let sid = HookJSON.string(data, "sessionID") ?? (data["form"] as? [String: Any]).flatMap({ HookJSON.string($0, "sessionID") })
        else { return [] }
        let ts = (e["created"] as? NSNumber)?.int64Value ?? now
        let cwd = directory(of: e) ?? directory(of: data)

        if type == "session.created" {
            if let parent = HookJSON.string(data, "parentID") {
                remember(child: sid, parent: parent)
                return [make(.substart, rootID(of: sid), ts, sub: sid, cwd: cwd, type: type)]
            }
            return [make(.start, sid, ts, cwd: cwd, type: type)]
        }

        let root = rootID(of: sid)
        let sub: String? = root == sid ? nil : sid

        switch type {
        case "session.execution.started":
            // A child's start was already reported by its `session.created`.
            return sub == nil ? [make(.working, root, ts, cwd: cwd, type: type)] : []
        case "session.retry.scheduled":
            return [make(.working, root, ts, sub: sub, cwd: cwd, type: type)]
        case "session.execution.succeeded":
            return [make(sub == nil ? .done : .substop, root, ts, sub: sub, cwd: cwd, type: type)]
        case "session.execution.failed":
            // A failing child is the parent's business: only the root's failure is an error.
            return [make(sub == nil ? .error : .substop, root, ts, sub: sub, cwd: cwd, type: type)]
        case "session.execution.interrupted":
            return [make(sub == nil ? .interrupt : .substop, root, ts, sub: sub, cwd: cwd, type: type)]
        case "permission.asked":
            guard let id = HookJSON.string(data, "id") else { return [] }
            return [make(.ask, root, ts, req: id, sub: sub, cwd: cwd, type: type)]
        case "permission.replied":
            guard let id = HookJSON.string(data, "requestID") else { return [] }
            return [make(.answered, root, ts, req: id, sub: sub, cwd: cwd, type: type)]
        case "form.created":
            guard let form = data["form"] as? [String: Any], let id = HookJSON.string(form, "id") else { return [] }
            return [make(.ask, root, ts, req: id, sub: sub, cwd: cwd, type: type)]
        case "form.replied", "form.rejected", "form.cancelled":
            guard let id = HookJSON.string(data, "id") ?? HookJSON.string(data, "requestID") else { return [] }
            return [make(.answered, root, ts, req: id, sub: sub, cwd: cwd, type: type)]
        case "session.viewed":
            return sub == nil ? [make(.seen, root, ts, cwd: cwd, type: type)] : []
        case "session.deleted":
            return [make(sub == nil ? .end : .substop, root, ts, sub: sub, cwd: cwd, type: type)]
        default:
            return []
        }
    }

    // MARK: helpers

    private func make(_ kind: EventKind, _ session: String, _ ts: Int64, req: String? = nil,
                      sub: String? = nil, cwd: String?, type: String) -> AgentEvent {
        AgentEvent(agent: .opencode, kind: kind, session: session, ts: ts, req: req, sub: sub, cwd: cwd, src: type)
    }

    private func directory(of o: [String: Any]) -> String? {
        (o["location"] as? [String: Any]).flatMap { HookJSON.string($0, "directory") }
    }

    private func rootID(of id: String) -> String {
        var cur = id
        for _ in 0..<8 {
            guard let p = parents[cur] else { break }
            cur = p
        }
        return cur
    }

    private mutating func remember(child: String, parent: String) {
        if parents[child] == nil { order.append(child) }
        parents[child] = parent
        while order.count > capacity { parents.removeValue(forKey: order.removeFirst()) }
    }
}
