import Foundation
import Darwin
import Testing
import BezelightAgents
@testable import BezelightCore

func makeShortTempDir() -> URL {
    let dir = URL(fileURLWithPath: "/tmp/bz-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls until `condition` holds (or the time runs out). Returns whether it held.
@discardableResult
func eventually(timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Same, for conditions that have to `await` (reading an actor).
@discardableResult
func eventually(timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

/// A tiny HTTP server for tests: serves scripted Server-Sent Events on 127.0.0.1.
final class FakeSSEServer: @unchecked Sendable {
    struct Script {
        var status = 200
        /// (delay in ms before writing, bytes)
        var chunks: [(Int, String)] = []
        /// Close the connection after the last chunk; otherwise hold it open (silence).
        var close = true
    }
    struct Request: Sendable { var path: String; var authorization: String? }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var stopped = false
    private let script: @Sendable (Int) -> Script

    var requests: [Request] { lock.withLock { recorded } }

    init(script: @escaping @Sendable (Int) -> Script) {
        self.script = script
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(listenFD, SHUT_RDWR); close(listenFD)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        var index = 0
        while !isStopped {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            let n = index; index += 1
            Thread.detachNewThread { [self] in serve(client, index: n) }
        }
    }

    private func serve(_ fd: Int32, index: Int) {
        defer { close(fd) }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return }
            data.append(buffer, count: n)
        }
        let head = String(decoding: data, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        lock.withLock { recorded.append(Request(path: path, authorization: auth)) }

        let s = script(index)
        if s.status != 200 {
            write(fd, "HTTP/1.1 \(s.status) Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
        for (delay, chunk) in s.chunks {
            if delay > 0 { usleep(UInt32(delay) * 1000) }
            if isStopped { return }
            write(fd, chunk)
        }
        if !s.close {
            // Hold the connection open without a word, until the client gives up or the test ends.
            var b: UInt8 = 0
            while !isStopped, read(fd, &b, 1) > 0 {}
        }
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = Darwin.write(fd, bytes, bytes.count)
            if n <= 0 { return }
            sent += n
        }
    }
}

/// Where the built `bezelight-hook` lives (next to the test bundle).
func builtHelper() -> URL? {
    final class Token {}
    let bundle = Bundle(for: Token.self).bundleURL
    let candidate = bundle.deletingLastPathComponent().appendingPathComponent("bezelight-hook")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

/// Runs the real helper with `input` on stdin; returns (stdout, exit code, seconds).
@discardableResult
func runHelper(_ helper: URL, _ args: [String], input: Data, home: URL) throws -> (out: String, status: Int32, seconds: Double) {
    let p = Process()
    p.executableURL = helper
    p.arguments = args
    p.environment = ["BEZELIGHT_HOME": home.path, "PATH": "/usr/bin:/bin"]
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
    let began = Date()
    try p.run()
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    p.waitUntilExit()
    let seconds = Date().timeIntervalSince(began)
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    #expect(err.isEmpty, "the helper must never write to stderr")
    return (String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus, seconds)
}
