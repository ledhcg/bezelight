import Foundation
import Darwin
import Testing
@testable import BezelightAgents

/// A short, private directory (Unix socket paths are limited to ~100 bytes).
func makeShortTempDir() -> URL {
    let dir = URL(fileURLWithPath: "/tmp/bz-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Binds a datagram socket the way the app's server does, to receive what the sender sends.
private final class Listener {
    let path: String
    let fd: Int32
    init?(path: String) {
        self.path = path
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0, var addr = UnixAddress.make(path: path) else { return nil }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, UnixAddress.size) } }
        guard ok == 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    func receive() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? Data(buffer[0..<n]) : nil
    }
    deinit { close(fd); unlink(path) }
}

// MARK: paths

@Test func pathsHonourTheEnvironmentOverride() {
    let custom = BezelightPaths.current(environment: ["BEZELIGHT_HOME": "/tmp/somewhere"])
    #expect(custom.home.path == "/tmp/somewhere" && custom.socket.path == "/tmp/somewhere/agent.sock")
    #expect(custom.helper.path == "/tmp/somewhere/bin/bezelight-hook" && custom.lock.lastPathComponent == "app.lock")
    // A relative override is ignored rather than trusted.
    let relative = BezelightPaths.current(environment: ["BEZELIGHT_HOME": "relative/dir"])
    #expect(relative.home.path.hasSuffix("/.bezelight"))
    #expect(BezelightPaths.current(environment: [:]).home.lastPathComponent == ".bezelight")
}

// MARK: sending

@Test func senderDeliversAndNeverBlocksWithoutAListener() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.sock").path
    #expect(!DatagramSender.send(Data("x".utf8), toSocketAt: path))                  // nobody there: false, no crash, no wait
    let listener = try #require(Listener(path: path))
    #expect(DatagramSender.send(Data("hello".utf8), toSocketAt: path))
    #expect(listener.receive() == Data("hello".utf8))
}

@Test func senderRejectsUnusableInput() {
    #expect(!DatagramSender.send(Data(), toSocketAt: "/tmp/x.sock"))
    #expect(!DatagramSender.send(Data("x".utf8), toSocketAt: "/tmp/" + String(repeating: "a", count: 200)))
    #expect(UnixAddress.make(path: "") == nil)
}

// MARK: finding the agent

@Test func processWalkSkipsShellsAndFindsTheAgent() {
    let tree: [pid_t: (ppid: pid_t, name: String)] = [
        100: (90, "sh"), 90: (80, "bash"), 80: (70, "2.1.296"), 70: (1, "zsh"),
    ]
    #expect(ProcessTree.agentPID(from: 100, lookup: { tree[$0] }) == 80)         // sh -> bash -> the agent
    #expect(ProcessTree.agentPID(from: 80, lookup: { tree[$0] }) == 80)         // already the agent
    #expect(ProcessTree.agentPID(from: 999, lookup: { tree[$0] }) == nil)       // unknown
    #expect(ProcessTree.agentPID(from: 70, lookup: { tree[$0] }) == nil)        // only shells up to launchd
}

@Test func processWalkIsBounded() {
    let loop: [pid_t: (ppid: pid_t, name: String)] = [10: (11, "sh"), 11: (10, "sh")]
    #expect(ProcessTree.agentPID(from: 10, lookup: { loop[$0] }) == nil)        // cycles cannot hang a hook
}

@Test func theRealProcessTreeHasAParent() {
    #expect(ProcessTree.parent(of: getpid())?.ppid == getppid())
    #expect(ProcessTree.agentPID() != nil)                                       // the test runner is not a shell
}

// MARK: reading stdin

@Test func boundedInputReadsEverythingThenStops() {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let payload = Data(repeating: 0x61, count: 200_000)
    let (readEnd, writeEnd) = (fds[0], fds[1])      // plain values: the writer must not see `fds` change
    DispatchQueue.global().async { payload.withUnsafeBytes { _ = write(writeEnd, $0.baseAddress, $0.count) }; close(writeEnd) }
    #expect(BoundedInput.readAll(fd: readEnd, limit: 1_048_576, timeoutMs: 2000) == payload)
    close(readEnd)
}

@Test func boundedInputRespectsTheLimit() {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let payload = Data(repeating: 0x62, count: 5000)
    payload.withUnsafeBytes { _ = write(fds[1], $0.baseAddress, $0.count) }
    close(fds[1])
    #expect(BoundedInput.readAll(fd: fds[0], limit: 1000, timeoutMs: 500).count == 1000)
    close(fds[0])
}

@Test func boundedInputNeverHangsOnAnOpenPipe() {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    _ = "partial".withCString { write(fds[1], $0, 7) }          // and the writer never closes
    let began = Date()
    let data = BoundedInput.readAll(fd: fds[0], limit: 1000, timeoutMs: 150)
    #expect(data == Data("partial".utf8))
    #expect(Date().timeIntervalSince(began) < 1.0)
    close(fds[0]); close(fds[1])
}

// MARK: the CLI contract

private final class Spy: @unchecked Sendable {
    var sent: [Data] = []
    var order: [String] = []
}

private func cli(_ args: [String], input: Data = Data(), pid: Int32? = 4242, deliver: Bool = true, spy: Spy = Spy()) -> (HookCLI, Spy) {
    (HookCLI(arguments: ["bezelight-hook"] + args,
             readInput: { spy.order.append("read"); return input },
             now: { spy.order.append("now"); return 1_800_000_000_123 },
             agentPID: { pid },
             send: { spy.sent.append($0); return deliver }), spy)
}

@Test func hookForwardsANormalisedEventAndPrintsAnEmptyObject() throws {
    let (c, spy) = cli(["claude"], input: Fixtures.data("claude/PermissionRequest.bash"))
    #expect(c.run() == "{}\n")
    let e = try #require(spy.sent.first.flatMap(Wire.decode))
    #expect(spy.sent.count == 1 && e.kind == .ask && e.agent == .claude && e.pid == 4242 && e.ts == 1_800_000_000_123)
}

@Test func hookTakesTheTimestampBeforeReadingInput() {
    // The time must be when the hook started: slow input must not reorder events.
    let (c, spy) = cli(["codex"], input: Fixtures.data("codex/Stop"))
    _ = c.run()
    #expect(spy.order == ["now", "read"])
}

@Test func hookNeverFailsWhateverItIsGiven() {
    for args in [[], ["bogus"], ["claude"], ["codex"], ["claude", "extra"]] {
        for input in [Data(), Data("garbage".utf8), Data(repeating: 0xFF, count: 5000), Data("{}".utf8)] {
            let (c, _) = cli(args, input: input, deliver: false)
            #expect(c.run() == "{}\n", "args \(args)")
        }
    }
}

@Test func hookSendsNothingForIrrelevantEvents() {
    let (c, spy) = cli(["claude"], input: Fixtures.data("claude/Notification.permission_prompt"))
    #expect(c.run() == "{}\n" && spy.sent.isEmpty)
}

@Test func hookVersionAndSelftest() {
    #expect(cli(["--version"]).0.run() == HookCLI.version + "\n")
    let (ok, spy) = cli(["--selftest"])
    #expect(ok.run().hasPrefix("ok") && spy.sent.count == 1)
    let event = spy.sent.first.flatMap(Wire.decode)
    #expect(event?.kind == .seen && event?.session == "selftest")        // harmless: unknown sessions ignore "seen"
    #expect(cli(["--selftest"], deliver: false).0.run().hasPrefix("not delivered"))
}
