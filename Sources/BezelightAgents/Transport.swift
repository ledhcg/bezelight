import Foundation
import Darwin

/// Where Bezelight keeps its files for agent integration. `BEZELIGHT_HOME` overrides the default,
/// which lets tests (and anyone debugging) run a second, isolated instance.
public struct BezelightPaths: Sendable, Equatable {
    public var home: URL

    public init(home: URL) { self.home = home }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> BezelightPaths {
        if let custom = environment["BEZELIGHT_HOME"], custom.hasPrefix("/") {
            return BezelightPaths(home: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return BezelightPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bezelight", isDirectory: true))
    }

    public var socket: URL { home.appendingPathComponent("agent.sock") }
    public var lock: URL { home.appendingPathComponent("app.lock") }
    public var bin: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public var helper: URL { bin.appendingPathComponent("bezelight-hook") }
    public var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }
}

public enum UnixAddress {
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminator.
    public static let maxPathBytes = 103

    public static func make(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static let size = socklen_t(MemoryLayout<sockaddr_un>.size)
}

/// Fire-and-forget delivery to the app. Never blocks and never throws: if nobody is listening the
/// event is simply dropped, which is exactly what a hook helper must do.
public enum DatagramSender {
    @discardableResult
    public static func send(_ data: Data, toSocketAt path: String) -> Bool {
        guard !data.isEmpty, var addr = UnixAddress.make(path: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let len = UnixAddress.size
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, len)
                }
            }
        }
        return sent == data.count
    }
}

/// Finds the agent a hook belongs to: the nearest ancestor that is not a shell.
///
/// Matching by name does not work (Claude Code's process is called `2.1.296` and often runs
/// behind a wrapper), and hooks are usually launched through `sh -c`, so the shells in between
/// are skipped instead.
public enum ProcessTree {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "env", "login", "sudo", "nohup", "timeout", "xargs", "script"]

    public static func parent(of pid: pid_t) -> (ppid: pid_t, name: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (info.kp_eproc.e_ppid, name)
    }

    /// `lookup` is injectable so the walk can be tested without real processes.
    public static func agentPID(from start: pid_t = getppid(),
                                lookup: (pid_t) -> (ppid: pid_t, name: String)? = ProcessTree.parent(of:)) -> Int32? {
        var pid = start
        for _ in 0..<12 {
            guard pid > 1, let info = lookup(pid) else { return nil }
            if !shells.contains(info.name.lowercased()) { return pid }
            pid = info.ppid
        }
        return nil
    }
}

/// Reads stdin without ever hanging a hook: bounded in size and in time.
public enum BoundedInput {
    public static func readAll(fd: Int32 = STDIN_FILENO, limit: Int = 1_048_576, timeoutMs: Int32 = 2000) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        while out.count < limit {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32((deadline - now) / 1_000_000))
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { break }
            let n = read(fd, &buffer, min(buffer.count, limit - out.count))
            if n <= 0 { break }                 // end of input (or an error): done
            out.append(buffer, count: n)
        }
        return out
    }
}
