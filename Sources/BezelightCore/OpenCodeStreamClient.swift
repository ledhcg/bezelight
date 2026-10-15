import Foundation
import BezelightAgents

/// Server-Sent Events parser. Feed it lines (or any chunks); it returns each completed event's
/// `data` payload. Handles `\n` and `\r\n`, comments (`: heartbeat`), multi-line data and a cap on
/// the size of a single line and of a whole event.
public struct SSEParser: Sendable {
    public static let maxLine = 1_048_576
    /// Upper bound for one event's accumulated `data:` lines (many small lines must not add up unbounded).
    public static let maxEvent = 4 * 1_048_576
    private var pending = Data()
    private var data: [Data] = []
    private var dataBytes = 0
    private var discardingEvent = false                        // an oversized event is dropped up to its blank line

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var out: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if line.last == 0x0D { line = line.dropLast() }
            if line.isEmpty {
                if !data.isEmpty { out.append(Data(data.joined(separator: [0x0A]))) }
                data.removeAll(); dataBytes = 0; discardingEvent = false
            } else if discardingEvent {
                continue
            } else if line.first == 0x3A {
                continue                                         // comment / heartbeat
            } else if line.starts(with: Array("data:".utf8)) {
                var value = line.dropFirst(5)
                if value.first == 0x20 { value = value.dropFirst() }
                dataBytes += value.count
                if dataBytes > Self.maxEvent { data.removeAll(); dataBytes = 0; discardingEvent = true; continue }
                data.append(Data(value))
            }                                                     // other fields (event, id, retry) are not needed
        }
        if pending.count > Self.maxLine { pending.removeAll(); data.removeAll(); dataBytes = 0 }
        return out
    }
}

/// How to reach OpenCode 2.0's background service, as it publishes itself in
/// `~/.local/state/opencode/service.json`.
public struct OpenCodeService: Equatable, Sendable {
    public enum LoadError: Error, Equatable {
        case missing
        case invalid
        /// The file points somewhere that is not this machine. We never send the password there.
        case notLoopback(String)
    }

    public var url: URL
    public var password: String
    public var version: String?

    public init(url: URL, password: String, version: String? = nil) { self.url = url; self.password = password; self.version = version }

    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        OpenCodeLocation.serviceFile(home: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
    }

    public static func load(from file: URL = defaultFile()) throws -> OpenCodeService {
        guard let raw = try? Data(contentsOf: file) else { throw LoadError.missing }
        guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let urlText = o["url"] as? String, let password = o["password"] as? String, !password.isEmpty,
              var parts = URLComponents(string: urlText), parts.scheme == "http", let host = parts.host, parts.port != nil
        else { throw LoadError.invalid }
        // The password is only ever sent to this machine. `localhost` is rewritten to the literal
        // address so App Transport Security (which exempts IP literals) does not get in the way.
        switch host.lowercased() {
        case "127.0.0.1", "localhost": parts.host = "127.0.0.1"
        case "::1", "[::1]": parts.host = "[::1]"
        default: throw LoadError.notLoopback(host)
        }
        guard let url = parts.url else { throw LoadError.invalid }
        return OpenCodeService(url: url, password: password, version: o["version"] as? String)
    }

    var authorization: String { "Basic " + Data("opencode:\(password)".utf8).base64EncodedString() }
}

/// Listens to OpenCode 2.0's native event stream (`GET /api/event`) and turns it into agent
/// events. Nothing is installed into OpenCode: the stream covers every session of every client.
///
/// Resilient by design: it waits for OpenCode to appear, re-reads `service.json` on every attempt
/// (the port and password change when the service restarts), backs off between attempts, and
/// treats 45 s of silence as a dead connection (the service sends a heartbeat every 15 s).
public final class OpenCodeStreamClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case waitingForOpenCode
        case connecting
        case connected(version: String?)
        /// OpenCode answered but not as expected (wrong password, an API this build does not know).
        case failed(String)
    }

    public static let silenceTimeout: TimeInterval = 45
    public static let backoff: [TimeInterval] = [1, 2, 5, 10, 30]
    /// Only these events are worth parsing; text and reasoning deltas fly past by the hundred.
    static let interesting: [Data] = ["session.created", "session.execution.", "session.retry", "permission.", "form.",
                                      "session.viewed", "session.deleted"].map { Data("\"\($0)".utf8) }

    private let serviceFile: URL
    private let session: URLSession
    private let handler: @Sendable (AgentEvent) -> Void
    private let onState: @Sendable (State) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current = State.stopped
    private var normalizer = OpenCodeNormalizer()
    private let jitter: @Sendable () -> Double

    public init(serviceFile: URL = OpenCodeService.defaultFile(),
                silenceTimeout: TimeInterval = OpenCodeStreamClient.silenceTimeout,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
                handler: @escaping @Sendable (AgentEvent) -> Void,
                onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.serviceFile = serviceFile
        self.handler = handler
        self.onState = onState
        self.jitter = jitter
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = silenceTimeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]                 // loopback only: never through a proxy
        session = URLSession(configuration: config)
    }

    deinit { task?.cancel(); session.invalidateAndCancel() }

    public var state: State { lock.withLock { current } }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock()
        let t = task; task = nil
        lock.unlock()
        t?.cancel()
        set(.stopped)
    }

    // MARK: loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let began = Date()
            do {
                let service = try OpenCodeService.load(from: serviceFile)
                set(.connecting)
                try await stream(service)
            } catch is CancellationError {
                return
            } catch OpenCodeService.LoadError.missing {
                set(.waitingForOpenCode)
            } catch OpenCodeService.LoadError.notLoopback(let host) {
                set(.failed("OpenCode points at \(host), which is not this machine"))
            } catch OpenCodeService.LoadError.invalid {
                set(.failed("unreadable OpenCode service file"))
            } catch let e as StreamError {
                set(.failed(e.description))
            } catch {
                if Task.isCancelled { return }
                set(.waitingForOpenCode)                        // connection refused / dropped: OpenCode went away
            }
            if Date().timeIntervalSince(began) > 10 { attempt = 0 }       // it was up for a while: start the schedule over
            let wait = Self.backoff[min(attempt, Self.backoff.count - 1)] * jitter()
            attempt += 1
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    struct StreamError: Error, CustomStringConvertible { var description: String }

    private func stream(_ service: OpenCodeService) async throws {
        var request = URLRequest(url: service.url.appendingPathComponent("api/event"))
        request.setValue(service.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError(description: "unexpected response") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw StreamError(description: "OpenCode refused the password")
        case 404: throw StreamError(description: "this OpenCode version has no /api/event")
        default: throw StreamError(description: "OpenCode answered HTTP \(http.statusCode)")
        }
        set(.connected(version: service.version))

        var parser = SSEParser()
        var line = Data()
        var discarding = false                              // inside a line that blew past the cap
        for try await byte in bytes {
            if discarding {
                if byte == 0x0A { discarding = false }
                continue
            }
            line.append(byte)
            if byte != 0x0A {
                // A stream that never sends a newline must not grow this buffer without bound.
                if line.count > SSEParser.maxLine { line.removeAll(); discarding = true }
                continue
            }
            for frame in parser.feed(line) { deliver(frame) }
            line.removeAll(keepingCapacity: true)
        }
    }

    private func deliver(_ frame: Data) {
        guard Self.interesting.contains(where: { frame.range(of: $0) != nil }) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for event in normalizer.events(from: frame, now: now) { handler(event) }
    }

    private func set(_ new: State) {
        let changed: Bool = lock.withLock {
            if current == new { return false }
            current = new; return true
        }
        if changed { onState(new) }
    }
}
