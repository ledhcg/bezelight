import Foundation
import Darwin

public enum SerialError: Error, Sendable, LocalizedError {
    case openFailed(path: String, reason: String)
    case notOpen
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason): return "\(path): \(reason)"
        case .notOpen: return "port not open"
        case .ioError(let m): return m
        }
    }
}

/// Minimal POSIX serial port (8N1, raw). Thread-safe; non-blocking I/O with a bounded write wait.
public final class SerialPort: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    public let path: String
    public let baudRate: Int

    public init(path: String, baudRate: Int = 115200) {
        self.path = path; self.baudRate = baudRate
    }

    deinit { close() }

    public var isOpen: Bool { lock.withLock { fd >= 0 } }

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return }
        let newFd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard newFd >= 0 else {
            throw SerialError.openFailed(path: path, reason: String(cString: strerror(errno)))
        }
        // Exclusive access: fail fast if another app (e.g. the vendor's) already drives the port,
        // instead of two programs interleaving bytes and making the LEDs flicker.
        guard ioctl(newFd, TIOCEXCL) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(newFd)
            throw SerialError.openFailed(path: path, reason: reason)
        }
        do { try configure(fd: newFd, baud: baudRate) } catch {
            Darwin.close(newFd)
            throw error
        }
        fd = newFd
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    public func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try writeAll($0) }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { try writeAll($0) }
    }

    private func writeAll(_ buf: UnsafeRawBufferPointer) throws {
        let handle = lock.withLock { fd }
        guard handle >= 0 else { throw SerialError.notOpen }
        guard let base = buf.baseAddress else { return }
        var sent = 0
        let deadline = Date().addingTimeInterval(0.5)
        while sent < buf.count {
            let n = Darwin.write(handle, base + sent, buf.count - sent)
            if n < 0 {
                guard errno == EINTR || errno == EAGAIN else { throw SerialError.ioError(String(cString: strerror(errno))) }
                // Output queue full: wait for room, but never hang on a stalled device.
                guard Date() < deadline else { throw SerialError.ioError("write timed out") }
                var p = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 50)
                continue
            }
            sent += n
        }
    }

    /// Drives the modem control lines. Many USB bridges wire DTR/RTS to the board's reset pin, so
    /// pulsing them restarts the controller into a known state.
    public func setControlLines(dtr: Bool, rts: Bool) {
        let handle = lock.withLock { fd }
        guard handle >= 0 else { return }
        var dtrBit = Int32(TIOCM_DTR), rtsBit = Int32(TIOCM_RTS)
        _ = ioctl(handle, dtr ? TIOCMBIS : TIOCMBIC, &dtrBit)
        _ = ioctl(handle, rts ? TIOCMBIS : TIOCMBIC, &rtsBit)
    }

    /// Discards anything queued in either direction.
    public func flush() {
        let handle = lock.withLock { fd }
        if handle >= 0 { tcflush(handle, TCIOFLUSH) }
    }

    /// Returns whatever bytes are waiting (possibly none). Never blocks.
    public func read(maxLen: Int = 256) -> Data {
        let handle = lock.withLock { fd }
        guard handle >= 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: maxLen)
        let n = Darwin.read(handle, &buf, maxLen)
        return n > 0 ? Data(buf.prefix(n)) : Data()
    }

    /// USB serial candidates, callout devices first (`cu.*` does not wait for carrier detect).
    public static func listPorts() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        let prefixes = ["cu.usb", "cu.wch", "cu.SLAB", "tty.usb", "tty.wch", "tty.SLAB"]
        return items
            .filter { name in prefixes.contains { name.hasPrefix($0) } }
            .sorted { a, b in
                if a.hasPrefix("cu.") != b.hasPrefix("cu.") { return a.hasPrefix("cu.") }
                return a < b
            }
            .map { "/dev/\($0)" }
    }

    // MARK: - termios

    private func configure(fd: Int32, baud: Int) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw SerialError.ioError("tcgetattr: \(String(cString: strerror(errno)))") }
        cfmakeraw(&t)
        let standard = Self.speedConstant(for: baud)
        cfsetispeed(&t, standard ?? speed_t(B230400))
        cfsetospeed(&t, standard ?? speed_t(B230400))
        t.c_cflag |= tcflag_t(CREAD | CLOCAL)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        t.c_cflag |= tcflag_t(CS8)
        // Reads must never block the stream. Index with the libc constants: VMIN/VTIME are 16/17
        // on macOS (6/5 on Linux); hard-coding Linux's values leaves VMIN=1 and read() hangs.
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw SerialError.ioError("tcsetattr: \(String(cString: strerror(errno)))") }
        if standard == nil {
            // Non-standard rates (e.g. 460800/921600): IOSSIOSPEED sets the exact divisor.
            var speed = speed_t(baud)
            guard ioctl(fd, 0x80085402 /* IOSSIOSPEED = _IOW('T', 2, speed_t) */, &speed) == 0 else {
                throw SerialError.ioError("IOSSIOSPEED \(baud): \(String(cString: strerror(errno)))")
            }
        }
        tcflush(fd, TCIOFLUSH)
    }

    private static func speedConstant(for baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }
}
