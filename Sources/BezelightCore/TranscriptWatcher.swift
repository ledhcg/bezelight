import Foundation
import Darwin
import CoreGraphics
import BezelightAgents

/// Notices when Claude Code's transcript gets a `tool_result`, which is the only trace of a
/// permission being refused (no hook fires for a refusal or Esc; see docs, Phase 0).
///
/// Privacy: only bytes appended after the watch began are looked at, in memory, for one marker.
/// Nothing is stored, logged or sent anywhere.
public final class TranscriptWatcher: @unchecked Sendable {
    private final class Watch {
        let fd: Int32
        var offset: UInt64
        var carry = Data()
        var source: DispatchSourceFileSystemObject?
        init(fd: Int32, offset: UInt64) { self.fd = fd; self.offset = offset }
    }

    static let marker = Data("\"tool_result\"".utf8)
    /// A burst bigger than this is not scanned in full: only its tail is.
    static let maxScan: UInt64 = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "bezelight.transcript-watcher")
    private let onAnswered: @Sendable (SessionKey) -> Void
    private var watches: [SessionKey: Watch] = [:]
    private var timer: DispatchSourceTimer?

    public init(onAnswered: @escaping @Sendable (SessionKey) -> Void) { self.onAnswered = onAnswered }

    // Not `stopAll()`: the last reference can be dropped on `queue` itself (a timer tick holds
    // `self` briefly), and `queue.sync` from its own queue traps.
    deinit { teardown() }

    public var watchedCount: Int { queue.sync { watches.count } }

    public func watch(_ key: SessionKey, path: String) {
        queue.async { [self] in
            unwatchLocked(key)
            guard path.hasPrefix("/") else { return }
            let fd = open(path, O_RDONLY | O_EVTONLY)
            guard fd >= 0 else { return }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return }
            let w = Watch(fd: fd, offset: UInt64(st.st_size))
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.check(key) }
            src.setCancelHandler { close(fd) }
            src.resume()
            w.source = src
            watches[key] = w
            startTimerLocked()
        }
    }

    public func unwatch(_ key: SessionKey) { queue.async { [self] in unwatchLocked(key) } }

    public func stopAll() { queue.sync { teardown() } }

    private func teardown() {
        for key in Array(watches.keys) { unwatchLocked(key) }
        timer?.cancel(); timer = nil
    }

    // MARK: private (on `queue`)

    private func unwatchLocked(_ key: SessionKey) {
        guard let w = watches.removeValue(forKey: key) else { return }
        w.source?.cancel()
        if watches.isEmpty { timer?.cancel(); timer = nil }
    }

    /// A once-a-second safety net: file events can be coalesced or missed.
    private func startTimerLocked() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for key in Array(self.watches.keys) { self.check(key) }
        }
        t.resume()
        timer = t
    }

    private func check(_ key: SessionKey) {
        guard let w = watches[key] else { return }
        var st = stat()
        guard fstat(w.fd, &st) == 0 else { unwatchLocked(key); return }
        let size = UInt64(st.st_size)
        if size < w.offset { w.offset = size; w.carry.removeAll(); return }          // truncated / rewritten
        guard size > w.offset else { return }

        var from = w.offset
        if size - from > Self.maxScan { from = size - Self.maxScan; w.carry.removeAll() }
        var found = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while from < size, !found {
            let want = Int(min(UInt64(buffer.count), size - from))
            let n = pread(w.fd, &buffer, want, off_t(from))
            if n <= 0 { break }
            var window = w.carry
            window.append(buffer, count: n)
            if window.range(of: Self.marker) != nil { found = true }
            w.carry = window.suffix(Self.marker.count - 1)
            from += UInt64(n)
        }
        w.offset = from
        if found {
            unwatchLocked(key)
            onAnswered(key)
        }
    }
}

/// Real keyboard / mouse activity, from the HID system. Needs no permission (it reports a time, not
/// the keys), which Phase 0 confirmed.
public struct SystemPresence: PresenceProvider {
    public init() {}

    public func sample(now: Date) -> PresenceSample {
        let any = CGEventType(rawValue: ~0)!
        var idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        if !idle.isFinite || idle < 0 { idle = 0 }
        return PresenceSample(idleSeconds: idle, lastInputAt: now.addingTimeInterval(-idle))
    }
}
