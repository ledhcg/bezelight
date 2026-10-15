import Foundation

// MARK: what gets installed

/// One hook registration: which event, and how it is run.
public struct HookSpec: Equatable, Sendable {
    public var event: String
    /// Matcher of the group that holds the hook (nil = no `matcher` key).
    public var matcher: String?
    public var async: Bool
    public var timeout: Int
    public init(_ event: String, matcher: String? = nil, async: Bool = false, timeout: Int = 5) {
        self.event = event; self.matcher = matcher; self.async = async; self.timeout = timeout
    }
}

public enum HookCatalog {
    /// Every entry Bezelight writes contains this word in its command. It is how its own entries
    /// are told apart from other tools' (Orca, for one) when installing, repairing and removing.
    public static let marker = "bezelight-hook"

    /// The command is identical for every release: Codex ties its "trusted" decision to the hook's
    /// text, so changing it would force the user to approve again. Only the helper binary changes.
    /// If the helper is gone the command still succeeds and prints `{}`, so the agent never
    /// shows a hook error.
    public static func command(for agent: AgentKind) -> String {
        let path = "\"$HOME/.bezelight/bin/bezelight-hook\""
        return "[ -x \(path) ] && \(path) \(agent.rawValue) || echo '{}'"
    }

    /// Events each agent is asked to report (see docs/AGENT_NOTIFICATIONS.md, 9.2 and 9.3).
    public static func specs(for agent: AgentKind) -> [HookSpec] {
        switch agent {
        case .claude:
            return [
                HookSpec("SessionStart", async: true),
                HookSpec("UserPromptSubmit", async: true),
                HookSpec("PermissionRequest", matcher: "*", async: true),
                // `permission_prompt` is left out on purpose: it arrives 6 s after PermissionRequest.
                HookSpec("Notification", matcher: "elicitation_dialog|agent_needs_input", async: true),
                HookSpec("PostToolUse", matcher: "*", async: true),
                HookSpec("PostToolUseFailure", matcher: "*", async: true),
                HookSpec("Stop", async: true),
                HookSpec("StopFailure", async: true),
                HookSpec("SubagentStart", async: true),
                HookSpec("SubagentStop", async: true),
                HookSpec("SessionEnd", async: true),
            ]
        case .codex:
            // Not async: Codex wants JSON back from Stop, and the helper answers in milliseconds.
            return [
                HookSpec("SessionStart"),
                HookSpec("UserPromptSubmit"),
                HookSpec("PermissionRequest", matcher: "*"),
                HookSpec("PostToolUse", matcher: "*"),
                HookSpec("Stop"),
                HookSpec("Interrupt"),
                HookSpec("SessionEnd"),
            ]
        case .opencode:
            return []       // nothing to install: the app listens to OpenCode's own event stream
        }
    }

    static func entry(_ spec: HookSpec, _ command: String) -> JSONNode.Rendered {
        var fields: [(String, JSONNode.Rendered)] = [("type", .string("command")), ("command", .string(command))]
        if spec.async { fields.append(("async", .bool(true))) }
        fields.append(("timeout", .int(spec.timeout)))
        return .object(fields)
    }

    static func group(_ spec: HookSpec, _ command: String) -> JSONNode.Rendered {
        var fields: [(String, JSONNode.Rendered)] = []
        if let m = spec.matcher { fields.append(("matcher", .string(m))) }
        fields.append(("hooks", .array([entry(spec, command)])))
        return .object(fields)
    }
}

// MARK: state

public enum InstallState: Equatable, Sendable {
    case notInstalled
    case installed
    /// Some events are missing or out of date; they are named.
    case partial(missing: [String])
    case unreadable(String)
}

public struct HookInspection: Equatable, Sendable {
    public var state: InstallState
    /// Bezelight entries found anywhere in the file (also for events no longer in the catalog).
    public var entries: Int
    /// The file turns every hook off (`"disableAllHooks": true`).
    public var hooksDisabled: Bool
}

public enum InstallError: Error, Equatable, CustomStringConvertible {
    case notJSON(String)
    case notAnObject
    case hooksNotObject
    case eventNotArray(String)
    case notWritable(String)
    case missingFolder(String)
    case changedUnderneath
    case invalidResult
    case io(String)

    public var description: String {
        switch self {
        case .notJSON(let why): return "the file is not valid JSON (\(why)); nothing was changed"
        case .notAnObject: return "the file does not contain a JSON object; nothing was changed"
        case .hooksNotObject: return "\"hooks\" is not an object; nothing was changed"
        case .eventNotArray(let e): return "hooks.\(e) is not a list; nothing was changed"
        case .notWritable(let p): return "cannot write \(p)"
        case .missingFolder(let p): return "\(p) does not exist (is the agent installed?)"
        case .changedUnderneath: return "the file kept changing while it was being edited; try again"
        case .invalidResult: return "the edit would have produced an invalid file; nothing was changed"
        case .io(let m): return m
        }
    }
}

// MARK: the editor

/// Edits a hooks configuration (`settings.json` of Claude Code, `hooks.json` of Codex) as text.
/// Pure: strings in, strings out. Everything that is not a Bezelight entry stays byte for byte.
public enum HookConfigEditor {
    // MARK: inspect

    public static func inspect(_ text: String, specs: [HookSpec], command: String) -> HookInspection {
        let doc: JSONDocument
        do { doc = try parse(text) } catch { return HookInspection(state: .unreadable("\(error)"), entries: 0, hooksDisabled: false) }
        let disabled = doc.root.member("disableAllHooks").map { $0.kind == .bool && doc.slice($0) == "true" } ?? false
        guard let hooks = doc.root.member("hooks") else {
            return HookInspection(state: .notInstalled, entries: 0, hooksDisabled: disabled)
        }
        guard hooks.kind == .object else {
            return HookInspection(state: .unreadable("\"hooks\" is not an object"), entries: 0, hooksDisabled: disabled)
        }
        var total = 0
        for m in hooks.members where m.value.kind == .array { total += ours(in: m.value, doc).count }

        var missing: [String] = []
        for spec in specs {
            guard let ev = hooks.member(spec.event), ev.kind == .array else { missing.append(spec.event); continue }
            let mine = ours(in: ev, doc)
            if !(mine.count == 1 && isCurrent(ev.elements[mine[0].group], spec, command, doc)) { missing.append(spec.event) }
        }
        let state: InstallState = missing.isEmpty ? .installed : (total == 0 ? .notInstalled : .partial(missing: missing))
        return HookInspection(state: state, entries: total, hooksDisabled: disabled)
    }

    // MARK: install / uninstall

    /// `text == nil` creates a new file. Idempotent: installing twice changes nothing the second time.
    public static func install(_ text: String?, specs: [HookSpec], command: String) throws -> String {
        var t = text ?? "{}"
        let root = try parse(t).root
        guard root.kind == .object else { throw InstallError.notAnObject }
        if let hooks = root.member("hooks"), hooks.kind != .object { throw InstallError.hooksNotObject }

        for spec in specs {
            var doc = try parse(t)
            if let ev = doc.root.member("hooks")?.member(spec.event) {
                guard ev.kind == .array else { throw InstallError.eventNotArray(spec.event) }
                let mine = ours(in: ev, doc)
                if mine.count == 1, isCurrent(ev.elements[mine[0].group], spec, command, doc) { continue }   // already right
                if mine.count == 1, let fixed = replacingInPlace(spec, command, in: ev, group: mine[0].group, doc) {
                    t = fixed                                  // out of date: rewritten where it stands, order untouched
                    continue
                }
                t = try removeOurs(t, onlyEvent: spec.event)
                doc = try parse(t)
            }
            t = try append(spec, command, to: doc)
        }
        if text == nil { t += "\n" }
        try validate(t)
        return t
    }

    public static func uninstall(_ text: String) throws -> String {
        let t = try removeOurs(text, onlyEvent: nil)
        try validate(t)
        return t
    }

    /// Safety net used before anything is written: apart from Bezelight's own entries, the new
    /// file must mean exactly what the old one did. (An empty event list and a missing one mean
    /// the same to an agent, so that difference is ignored.)
    public static func isSafeEdit(old: String?, new: String) -> Bool {
        guard (try? validate(new)) != nil else { return false }
        guard let old else { return true }
        guard let a = try? removeOurs(old, onlyEvent: nil), let b = try? removeOurs(new, onlyEvent: nil),
              let x = meaning(a), let y = meaning(b) else { return false }
        return (x as AnyObject).isEqual(y)
    }

    private static func meaning(_ text: String) -> Any? {
        guard var root = foundation(text) as? [String: Any] else { return nil }
        if var hooks = root["hooks"] as? [String: Any] {
            hooks = hooks.filter { !(($0.value as? [Any])?.isEmpty ?? false) }
            if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        }
        return root
    }

    // MARK: pieces

    private static func parse(_ text: String) throws -> JSONDocument {
        do { return try JSONDocument(text) } catch let e as JSONError { throw InstallError.notJSON(e.description) }
    }

    private static func validate(_ text: String) throws {
        guard foundation(text) != nil else { throw InstallError.invalidResult }
    }

    private static func foundation(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// (group index, entry index) of every Bezelight entry in an event's list of groups.
    private static func ours(in event: JSONNode, _ doc: JSONDocument) -> [(group: Int, entry: Int)] {
        var found: [(Int, Int)] = []
        for (g, group) in event.elements.enumerated() where group.kind == .object {
            guard let list = group.member("hooks"), list.kind == .array else { continue }
            for (e, entry) in list.elements.enumerated() where entry.kind == .object {
                if let cmd = entry.member("command")?.string, cmd.contains(HookCatalog.marker) { found.append((g, e)) }
            }
        }
        return found
    }

    /// True when the group is exactly what we would write for `spec`.
    private static func isCurrent(_ group: JSONNode, _ spec: HookSpec, _ command: String, _ doc: JSONDocument) -> Bool {
        guard let actual = try? JSONSerialization.jsonObject(with: Data(doc.bytes[group.range])) else { return false }
        return (actual as AnyObject).isEqual(HookCatalog.group(spec, command).foundation)
    }

    /// Rewrites a group that holds nothing but Bezelight's one entry, keeping its place and layout.
    private static func replacingInPlace(_ spec: HookSpec, _ command: String, in event: JSONNode, group g: Int, _ doc: JSONDocument) -> String? {
        let old = event.elements[g]
        guard old.kind == .object, let list = old.member("hooks"), list.kind == .array, list.elements.count == 1 else { return nil }
        let start = old.range.lowerBound
        let indent = doc.startsOwnLine(start) ? doc.lineIndent(at: start) : doc.lineIndent(at: event.range.lowerBound)
        let multiline = doc.bytes[old.range].contains(0x0A)
        let text = HookCatalog.group(spec, command).text(indent: indent, unit: doc.indentUnit, newline: doc.newline, multiline: multiline)
        return doc.replacing(old, with: text)
    }

    private static func append(_ spec: HookSpec, _ command: String, to doc: JSONDocument) throws -> String {
        let group = HookCatalog.group(spec, command)
        guard let hooks = doc.root.member("hooks") else {
            return doc.appending(to: doc.root, key: "hooks", child: .object([(spec.event, .array([group]))]))
        }
        guard hooks.kind == .object else { throw InstallError.hooksNotObject }
        guard let ev = hooks.member(spec.event) else {
            return doc.appending(to: hooks, key: spec.event, child: .array([group]))
        }
        guard ev.kind == .array else { throw InstallError.eventNotArray(spec.event) }
        return doc.appending(to: ev, child: group)
    }

    /// Removes Bezelight's entries (one at a time, re-reading the file in between), together
    /// with any group, event or `hooks` object that this leaves empty.
    private static func removeOurs(_ text: String, onlyEvent: String?) throws -> String {
        var t = text
        for _ in 0..<500 {                                   // far more than a file can hold; just a bound
            let doc = try parse(t)
            guard doc.root.kind == .object else { throw InstallError.notAnObject }
            guard let hooks = doc.root.member("hooks"), hooks.kind == .object else { return t }

            var target: (event: Int, group: Int, entry: Int)?
            for (i, m) in hooks.members.enumerated() where m.value.kind == .array && (onlyEvent == nil || m.key == onlyEvent) {
                if let first = ours(in: m.value, doc).first { target = (i, first.group, first.entry); break }
            }
            guard let (e, g, entry) = target else { return t }

            let event = hooks.members[e].value
            let group = event.elements[g]
            let list = group.member("hooks")!
            if list.elements.count >= 2 {
                t = doc.removing(child: entry, of: list)                       // a foreign hook shares the group: take only ours
            } else if event.elements.count >= 2 {
                t = doc.removing(child: g, of: event)
            } else if hooks.members.count >= 2 {
                t = doc.removing(child: e, of: hooks)
            } else if doc.root.members.count >= 2 {
                t = doc.removing(child: doc.root.members.firstIndex { $0.key == "hooks" }!, of: doc.root)
            } else {
                t = doc.replacing(doc.root, with: "{}")
            }
        }
        throw InstallError.invalidResult
    }
}

extension JSONDocument {
    func slice(_ node: JSONNode) -> String { String(decoding: bytes[node.range], as: UTF8.self) }
}
