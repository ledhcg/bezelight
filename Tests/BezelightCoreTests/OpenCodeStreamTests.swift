import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private func frame(_ type: String, _ data: String, created: Int = 1_800_000_000_000) -> String {
    #"data: {"id":"evt_1","created":\#(created),"type":"\#(type)","data":\#(data)}"# + "\n\n"
}
private let root = "ses_root"

// MARK: parser

@Test func sseParserHandlesTheBasics() {
    var p = SSEParser()
    #expect(p.feed(Data("data: one\n\n".utf8)) == [Data("one".utf8)])
    #expect(p.feed(Data("data: a\r\ndata: b\r\n\r\n".utf8)) == [Data("a\nb".utf8)])        // CRLF + multi-line data
    #expect(p.feed(Data(": heartbeat\n\n".utf8)).isEmpty)                                    // comments are not events
    #expect(p.feed(Data("event: x\nid: 7\nretry: 5\ndata:no-space\n\n".utf8)) == [Data("no-space".utf8)])
    #expect(p.feed(Data("data: two\n\ndata: three\n\n".utf8)) == [Data("two".utf8), Data("three".utf8)])
}

@Test func sseParserWaitsForTheBlankLineAndSurvivesFragments() {
    var p = SSEParser()
    #expect(p.feed(Data("data: par".utf8)).isEmpty)
    #expect(p.feed(Data("tial".utf8)).isEmpty)
    #expect(p.feed(Data("\n".utf8)).isEmpty)                                                  // line done, event not yet
    #expect(p.feed(Data("\n".utf8)) == [Data("partial".utf8)])
    var byByte = SSEParser(), out: [Data] = []
    for b in Array("data: x\n\ndata: y\n\n".utf8) { out += byByte.feed(Data([b])) }
    #expect(out == [Data("x".utf8), Data("y".utf8)])
}

@Test func sseParserDropsAnAbsurdLine() {
    var p = SSEParser()
    #expect(p.feed(Data(repeating: 0x61, count: SSEParser.maxLine + 10)).isEmpty)
    #expect(p.feed(Data("data: ok\n\n".utf8)) == [Data("ok".utf8)])                          // and recovers
}

// MARK: service file

private func writeService(_ dir: URL, url: String, password: String = "pw", version: String? = "2.0.28") -> URL {
    let file = dir.appendingPathComponent("service.json")
    var o: [String: Any] = ["url": url, "password": password, "pid": 1, "id": "x"]
    if let version { o["version"] = version }
    try? JSONSerialization.data(withJSONObject: o).write(to: file)
    return file
}

@Test func serviceFileIsReadAndLocalhostNormalised() throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let s = try OpenCodeService.load(from: writeService(dir, url: "http://127.0.0.1:49374"))
    #expect(s.url.absoluteString == "http://127.0.0.1:49374" && s.password == "pw" && s.version == "2.0.28")
    #expect(s.authorization == "Basic " + Data("opencode:pw".utf8).base64EncodedString())
    #expect(try OpenCodeService.load(from: writeService(dir, url: "http://localhost:5000")).url.host == "127.0.0.1")
    #expect(try OpenCodeService.load(from: writeService(dir, url: "http://[::1]:5000")).url.host == "::1")
}

@Test func serviceFilePointingElsewhereIsRefused() {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    for url in ["http://10.0.0.5:4000", "http://example.com:80", "http://127.0.0.1.evil.com:80", "http://192.168.1.2:1"] {
        #expect(throws: OpenCodeService.LoadError.self, "\(url)") { try OpenCodeService.load(from: writeService(dir, url: url)) }
    }
}

@Test func serviceFileProblemsAreReportedNotCrashed() {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: OpenCodeService.LoadError.missing) { try OpenCodeService.load(from: dir.appendingPathComponent("nope.json")) }
    let bad = dir.appendingPathComponent("bad.json")
    for text in ["", "{", "[]", #"{"url":"http://127.0.0.1:1"}"#, #"{"url":"http://127.0.0.1","password":"x"}"#,
                 #"{"url":"https://127.0.0.1:1","password":"x"}"#, #"{"url":"http://127.0.0.1:1","password":""}"#] {
        try? Data(text.utf8).write(to: bad)
        #expect(throws: OpenCodeService.LoadError.invalid, "\(text)") { try OpenCodeService.load(from: bad) }
    }
}

@Test func stateDirectoryFollowsXDG() {
    #expect(OpenCodeService.defaultFile(environment: ["XDG_STATE_HOME": "/x/state"]).path == "/x/state/opencode/service.json")
    #expect(OpenCodeService.defaultFile(environment: [:]).path.hasSuffix("/.local/state/opencode/service.json"))
    #expect(OpenCodeService.defaultFile(environment: ["XDG_STATE_HOME": "relative"]).path.hasSuffix("/.local/state/opencode/service.json"))
}

// MARK: the client against a fake service

private func makeClient(_ dir: URL, serviceURL: String?, silence: TimeInterval = 5, got: Box<[AgentEvent]>, states: Box<[OpenCodeStreamClient.State]>) -> (OpenCodeStreamClient, URL) {
    let file = dir.appendingPathComponent("service.json")
    if let serviceURL { _ = writeService(dir, url: serviceURL) }
    let c = OpenCodeStreamClient(serviceFile: file, silenceTimeout: silence, jitter: { 0.01 },
                                 handler: { e in got.mutate { $0.append(e) } }, onState: { s in states.mutate { $0.append(s) } })
    return (c, file)
}

@Test func clientReadsEventsWithTheRightCredentials() async throws {
    let events = frame("session.created", #"{"sessionID":"\#(root)","location":{"directory":"/w/app"}}"#)
        + frame("session.execution.started", #"{"sessionID":"\#(root)"}"#)
        + frame("permission.asked", #"{"id":"per_1","sessionID":"\#(root)","action":"shell","resources":["secret command"]}"#)
    let server = FakeSSEServer { _ in .init(chunks: [(0, ": heartbeat\n\n"), (0, events)], close: false) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }

    #expect(await eventually { got.value.count == 3 })
    #expect(got.value.map(\.kind) == [.start, .working, .ask])
    #expect(got.value.allSatisfy { $0.session == root && $0.agent == .opencode })
    #expect(got.value[0].cwd == "/w/app")
    #expect(got.value.map { Wire.encode($0).map { String(decoding: $0, as: UTF8.self) } ?? "" }.allSatisfy { !$0.contains("secret") })

    let req = try #require(server.requests.first)
    #expect(req.path == "/api/event")
    #expect(req.authorization == "Basic " + Data("opencode:pw".utf8).base64EncodedString())
    #expect(states.value.contains(.connected(version: "2.0.28")))
}

@Test func clientReassemblesEventsSplitAcrossWrites() async throws {
    let one = frame("session.execution.succeeded", #"{"sessionID":"\#(root)"}"#)
    let cut = one.index(one.startIndex, offsetBy: 30)
    let server = FakeSSEServer { _ in .init(chunks: [(0, String(one[..<cut])), (60, String(one[cut...]))], close: false) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually { got.value.count == 1 })
    #expect(got.value.first?.kind == .done)
}

@Test func clientSkipsTheNoise() async throws {
    let noise = (0..<50).map { frame("session.text.delta", #"{"sessionID":"\#(root)","delta":"private text \#($0)"}"#) }.joined()
        + frame("shell.created", #"{"sessionID":"\#(root)"}"#) + frame("session.usage.updated", #"{"sessionID":"\#(root)"}"#)
    let server = FakeSSEServer { _ in .init(chunks: [(0, noise), (0, frame("session.viewed", #"{"sessionID":"\#(root)"}"#))], close: false) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually { got.value.count == 1 })
    #expect(got.value.first?.kind == .seen)
}

@Test func clientReconnectsAfterTheConnectionDrops() async throws {
    let server = FakeSSEServer { i in
        .init(chunks: [(0, frame(i == 0 ? "session.execution.started" : "session.execution.succeeded", #"{"sessionID":"\#(root)"}"#))], close: i == 0)
    }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually(timeout: 32) { got.value.map(\.kind) == [.working, .done] })
    #expect(server.requests.count >= 2)
}

@Test func clientRereadsTheServiceFileOnEveryAttempt() async throws {
    let good = FakeSSEServer { _ in .init(chunks: [(0, frame("session.viewed", #"{"sessionID":"\#(root)"}"#))], close: false) }
    defer { good.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, file) = makeClient(dir, serviceURL: nil, got: got, states: states)       // OpenCode not running yet
    client.start(); defer { client.stop() }
    #expect(await eventually { client.state == .waitingForOpenCode })
    _ = writeService(dir, url: "http://127.0.0.1:\(good.port)")                           // it starts: new port, new password
    #expect(await eventually(timeout: 32) { got.value.count == 1 })
    _ = file
}

@Test func clientReportsAWrongPasswordAndKeepsTrying() async throws {
    let counter = Box<Int>(0)
    let server = FakeSSEServer { _ in counter.mutate { $0 += 1 }; return .init(status: 401) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually { client.state == .failed("OpenCode refused the password") })
    #expect(await eventually(timeout: 32) { counter.value >= 2 })
    #expect(got.value.isEmpty)
}

@Test func clientReportsAnApiItDoesNotKnow() async throws {
    let server = FakeSSEServer { _ in .init(status: 404) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually { client.state == .failed("this OpenCode version has no /api/event") })
}

@Test func clientNeverSendsAPasswordToAnotherMachine() async throws {
    let decoy = FakeSSEServer { _ in .init(chunks: [], close: false) }
    defer { decoy.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://10.255.255.1:\(decoy.port)", got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually { if case .failed = client.state { return true } else { return false } })
    try await Task.sleep(for: .milliseconds(200))
    #expect(decoy.requests.isEmpty && got.value.isEmpty)
}

@Test func clientGivesUpOnASilentConnection() async throws {
    // Headers sent, then nothing: not even a heartbeat. After the silence limit it must reconnect.
    let server = FakeSSEServer { _ in .init(chunks: [], close: false) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", silence: 0.6, got: got, states: states)
    client.start(); defer { client.stop() }
    #expect(await eventually(timeout: 32) { server.requests.count >= 2 })
}

@Test func stoppingEndsEverything() async throws {
    let server = FakeSSEServer { _ in .init(chunks: [], close: true) }
    defer { server.stop() }
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let got = Box<[AgentEvent]>([]), states = Box<[OpenCodeStreamClient.State]>([])
    let (client, _) = makeClient(dir, serviceURL: "http://127.0.0.1:\(server.port)", got: got, states: states)
    client.start()
    #expect(await eventually { server.requests.count >= 1 })
    client.stop()
    #expect(client.state == .stopped)
    let n = server.requests.count
    try await Task.sleep(for: .milliseconds(400))
    #expect(server.requests.count <= n + 1)
    client.start(); client.stop(); client.stop()                  // idempotent
}

@Test func anEventMadeOfEndlessSmallLinesIsDroppedNotBuffered() {
    var parser = SSEParser()
    let line = Data(("data: " + String(repeating: "x", count: 60_000) + "\n").utf8)
    var delivered = 0
    for _ in 0..<200 { delivered += parser.feed(line).count }        // 12 MB with no blank line
    #expect(delivered == 0)
    #expect(parser.feed(Data("\n".utf8)).isEmpty)                    // the blank line ends the dropped event
    #expect(parser.feed(Data("data: ok\n\n".utf8)) == [Data("ok".utf8)])   // and the next one is read normally
}
