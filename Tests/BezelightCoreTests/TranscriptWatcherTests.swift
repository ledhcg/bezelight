import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private let key = SessionKey(agent: .claude, session: "s1")

private func makeTranscript(_ initial: String) -> (dir: URL, file: URL, handle: FileHandle) {
    let dir = makeShortTempDir()
    let file = dir.appendingPathComponent("t.jsonl")
    FileManager.default.createFile(atPath: file.path, contents: Data(initial.utf8))
    let h = try! FileHandle(forWritingTo: file)
    h.seekToEndOfFile()
    return (dir, file, h)
}
private func append(_ h: FileHandle, _ text: String) { h.write(Data(text.utf8)); try? h.synchronize() }

@Test func theWatcherReportsAToolResultAppendedAfterTheWatchBegan() async throws {
    // What Claude writes when a permission is refused: the call, then a failed result, then a note.
    let (dir, file, h) = makeTranscript(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"old"}]}}"# + "\n")
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = Box<[SessionKey]>([])
    let w = TranscriptWatcher { k in answered.mutate { $0.append(k) } }
    w.watch(key, path: file.path)
    #expect(await eventually { w.watchedCount == 1 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(answered.value.isEmpty, "a tool_result that was already there is history, not an answer")

    append(h, #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"# + "\n")
    try await Task.sleep(for: .milliseconds(150))
    #expect(answered.value.isEmpty, "the call itself is not an answer")

    append(h, #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true}]}}"# + "\n")
    #expect(await eventually { answered.value == [key] })
    #expect(await eventually { w.watchedCount == 0 }, "it stops watching once it has reported")
}

@Test func aMarkerSplitAcrossTwoWritesStillCounts() async throws {
    let (dir, file, h) = makeTranscript("")
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = Box<Int>(0)
    let w = TranscriptWatcher { _ in answered.mutate { $0 += 1 } }
    w.watch(key, path: file.path)
    #expect(await eventually { w.watchedCount == 1 })
    append(h, #"{"type":"user","c":"#)                 // first half of the marker "tool_result"
    append(h, #""tool_re"#)
    try await Task.sleep(for: .milliseconds(200))
    #expect(answered.value == 0, "half a marker is not an answer")
    append(h, #"sult"}"# + "\n")                        // the rest arrives in a later write
    #expect(await eventually { answered.value == 1 })
}

@Test func unwatchingBeforeAnythingHappensReportsNothing() async throws {
    let (dir, file, h) = makeTranscript("")
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = Box<Int>(0)
    let w = TranscriptWatcher { _ in answered.mutate { $0 += 1 } }
    w.watch(key, path: file.path)
    #expect(await eventually { w.watchedCount == 1 })
    w.unwatch(key)
    #expect(await eventually { w.watchedCount == 0 })
    append(h, #"{"type":"tool_result"}"# + "\n")
    try await Task.sleep(for: .milliseconds(1300))                        // longer than the safety timer
    #expect(answered.value == 0)
}

@Test func theWatcherSurvivesMissingAndOddFiles() async throws {
    let dir = makeShortTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let w = TranscriptWatcher { _ in }
    w.watch(key, path: dir.appendingPathComponent("missing.jsonl").path)
    w.watch(key, path: "relative/path.jsonl")
    w.watch(key, path: dir.path)                                           // a directory is not a transcript
    try await Task.sleep(for: .milliseconds(200))
    #expect(w.watchedCount == 0)
    w.unwatch(key); w.stopAll()
}

@Test func aTruncatedFileDoesNotConfuseIt() async throws {
    let (dir, file, h) = makeTranscript(String(repeating: "x", count: 5000))
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = Box<Int>(0)
    let w = TranscriptWatcher { _ in answered.mutate { $0 += 1 } }
    w.watch(key, path: file.path)
    #expect(await eventually { w.watchedCount == 1 })
    try h.truncate(atOffset: 100)
    try await Task.sleep(for: .milliseconds(1300))
    #expect(answered.value == 0)
    h.seekToEndOfFile()
    append(h, #"{"type":"tool_result"}"# + "\n")
    #expect(await eventually { answered.value == 1 })
}

@Test func severalSessionsAreIndependent() async throws {
    let a = makeTranscript(""), b = makeTranscript("")
    defer { try? FileManager.default.removeItem(at: a.dir); try? FileManager.default.removeItem(at: b.dir) }
    let answered = Box<[String]>([])
    let w = TranscriptWatcher { k in answered.mutate { $0.append(k.session) } }
    w.watch(SessionKey(agent: .claude, session: "A"), path: a.file.path)
    w.watch(SessionKey(agent: .claude, session: "B"), path: b.file.path)
    #expect(await eventually { w.watchedCount == 2 })
    append(b.handle, #"{"type":"tool_result"}"# + "\n")
    #expect(await eventually { answered.value == ["B"] })
    #expect(w.watchedCount == 1)
    w.stopAll()
    #expect(w.watchedCount == 0)
}

@Test func watchingTheSameSessionAgainReplacesTheOldWatch() async throws {
    let (dir, file, h) = makeTranscript("")
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = Box<Int>(0)
    let w = TranscriptWatcher { _ in answered.mutate { $0 += 1 } }
    w.watch(key, path: file.path); w.watch(key, path: file.path)
    #expect(await eventually { w.watchedCount == 1 })
    append(h, #"{"type":"tool_result"}"# + "\n")
    #expect(await eventually { answered.value >= 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(answered.value == 1)
}

@Test func systemPresenceReportsSaneNumbers() {
    let now = Date()
    let s = SystemPresence().sample(now: now)
    #expect(s.idleSeconds >= 0 && s.idleSeconds.isFinite)
    #expect(s.lastInputAt <= now)
    #expect(abs(now.timeIntervalSince(s.lastInputAt) - s.idleSeconds) < 0.001)
}
