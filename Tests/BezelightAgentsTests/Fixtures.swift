import Foundation

/// Real, sanitised payloads captured from Claude Code, Codex and OpenCode (Tests/Fixtures/agents).
enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ path: String) -> Data {
        let url = root.appendingPathComponent("agents/\(path).json")
        guard let d = try? Data(contentsOf: url) else { fatalError("missing fixture \(url.path)") }
        return d
    }

    static func all(_ agent: String) -> [(name: String, data: Data)] {
        let dir = root.appendingPathComponent("agents/\(agent)")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.map { ($0.replacingOccurrences(of: ".json", with: ""), (try? Data(contentsOf: dir.appendingPathComponent($0))) ?? Data()) }
    }
}

extension Fixtures {
    static func text(_ path: String) -> String {
        let url = root.appendingPathComponent("configs/\(path).json")
        guard let d = try? String(contentsOf: url, encoding: .utf8) else { fatalError("missing fixture \(url.path)") }
        return d
    }
}
