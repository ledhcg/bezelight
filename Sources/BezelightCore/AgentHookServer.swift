import Foundation
import Darwin
import BezelightAgents

/// Receives the events `bezelight-hook` sends. A Unix datagram socket in a private directory:
/// no network port, reachable only by the same user, and silent for the sender when we are not
/// running.
///
/// Flood control: bursts of `working` events (a tool-heavy turn fires one per tool call) are
/// coalesced, and the total rate is capped, so a misbehaving sender cannot swamp the app.
public final class AgentHookServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        case alreadyRunning                // another Bezelight owns the lock
        case pathTooLong
        case failed(String)
    }

    private let paths: BezelightPaths
    private let queue = DispatchQueue(label: "bezelight.agent-hook-server", qos: .userInitiated)
    private let handler: @Sendable (AgentEvent) -> Void
    private var source: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var lockFD: Int32 = -1

    // Flood control (touched only on `queue`).
    private var lastAdmitted: [String: (kind: EventKind, at: UInt64)] = [:]
    private var windowStart: UInt64 = 0
    private var inWindow = 0
    public static let coalesceNanos: UInt64 = 50_000_000
    public static let maxWorkingPerSecond = 200
    public static let maxOtherPerSecond = 1000

    /// Counters for diagnostics and tests.
    public private(set) var received = 0
    public private(set) var dropped = 0

    public init(paths: BezelightPaths = .current(), handler: @escaping @Sendable (AgentEvent) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    // Not `stop()`: the last reference can be dropped on `queue` itself while a read is being
    // handled, and `queue.sync` from its own queue traps.
    deinit { shutDown() }

    public var socketPath: String { paths.socket.path }
    public var isRunning: Bool { queue.sync { source != nil } }

    public func start() throws {
        try queue.sync {
            guard source == nil else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: paths.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(paths.home.path, 0o700)

            // One server per user: the lock keeps a second app instance from stealing the socket.
            let lock = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw StartError.failed("lock: \(String(cString: strerror(errno)))") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw StartError.alreadyRunning }

            guard var addr = UnixAddress.make(path: paths.socket.path) else { close(lock); throw StartError.pathTooLong }
            unlink(paths.socket.path)                       // a leftover from a crash; we hold the lock, so it is stale
            let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard fd >= 0 else { close(lock); throw StartError.failed("socket: \(String(cString: strerror(errno)))") }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, UnixAddress.size) }
            }
            guard bound == 0 else {
                let message = String(cString: strerror(errno))
                close(fd); close(lock)
                throw StartError.failed("bind: \(message)")
            }
            chmod(paths.socket.path, 0o600)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var big: Int32 = 256 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))

            socketFD = fd; lockFD = lock
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.drain() }
            src.resume()
            source = src
        }
    }

    public func stop() { queue.sync { shutDown() } }

    private func shutDown() {
        // The descriptor must outlive the dispatch source: close it from the cancel handler, or a quick
        // stop/start could hand the same number to the new socket while the old source is still registered.
        if socketFD >= 0 {
            let fd = socketFD
            if let src = source { src.setCancelHandler { close(fd) }; src.cancel() } else { close(fd) }
            socketFD = -1
            unlink(paths.socket.path)                       // now, so it cannot remove a newer socket later
        } else {
            source?.cancel()
        }
        source = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    // MARK: receiving (on `queue`)

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: Wire.maxAcceptedBytes + 1)
        while true {
            let n = recv(socketFD, &buffer, buffer.count, 0)
            if n <= 0 { return }                            // EAGAIN: drained
            received += 1
            guard let event = Wire.decode(Data(buffer[0..<n])) else { dropped += 1; continue }
            if admit(event) { handler(event) } else { dropped += 1 }
        }
    }

    private func admit(_ e: AgentEvent) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - windowStart >= 1_000_000_000 { windowStart = now; inWindow = 0; lastAdmitted.removeAll(keepingCapacity: true) }
        inWindow += 1
        let key = "\(e.agent.rawValue)|\(e.session)|\(e.sub ?? "")"
        let admitted: Bool
        if e.kind == .working {
            guard inWindow <= Self.maxWorkingPerSecond else { return false }
            // Drop a `working` only when the one just before it, from the same source, was also
            // `working`. If anything else came between (a question, say), this one may be its
            // answer (Claude has no separate "answered" event) and must get through.
            if let last = lastAdmitted[key], last.kind == .working, now - last.at < Self.coalesceNanos { return false }
            admitted = true
        } else {
            // Everything else matters (a question, an end), so only an extreme flood is refused.
            admitted = inWindow <= Self.maxOtherPerSecond
        }
        if admitted { lastAdmitted[key] = (e.kind, now) }
        return admitted
    }
}
