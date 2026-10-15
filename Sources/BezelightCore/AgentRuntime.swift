import Foundation
import BezelightAgents

/// What the integration is doing, for the settings screen.
public struct RuntimeStatus: Sendable, Equatable {
    public enum Listener: Sendable, Equatable {
        case stopped
        case listening
        /// Another Bezelight already owns the socket.
        case alreadyRunning
        case failed(String)
    }
    public var listener = Listener.stopped
    public var openCode = OpenCodeStreamClient.State.stopped
    public init() {}
}

/// Runs the three event sources and feeds the `AgentCenter`:
///   hooks (Claude, Codex)  ->  socket server
///   OpenCode               ->  stream client
///   Claude refusals        ->  transcript watcher
///
/// Events from every source go through one ordered queue. Spawning a task per event would let
/// them overtake each other, and the tracker drops an event that is older than one it already saw.
public final class AgentRuntime: @unchecked Sendable {
    private let center: AgentCenter
    private let paths: BezelightPaths
    private let openCodeFile: URL
    private let lock = NSLock()
    private var status = RuntimeStatus()
    private var server: AgentHookServer?
    private var client: OpenCodeStreamClient?
    private var watcher: TranscriptWatcher?
    private var pump: Task<Void, Never>?
    private var starting = false                         // guarded by `lock`: a start() is in flight
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    public var onStatusChange: (@Sendable (RuntimeStatus) -> Void)?
    /// Every event, in order, just before the tracker sees it (for the optional event log).
    public var onEvent: (@Sendable (AgentEvent) -> Void)?

    public init(center: AgentCenter, paths: BezelightPaths = .current(), openCodeServiceFile: URL = OpenCodeService.defaultFile()) {
        self.center = center; self.paths = paths; self.openCodeFile = openCodeServiceFile
    }

    deinit { stopSync() }

    public func currentStatus() -> RuntimeStatus { lock.withLock { status } }

    public func start() async {
        // Claim the start under the lock: the awaits below would otherwise let a second start() slip in.
        let claimed = lock.withLock { () -> Bool in
            guard pump == nil, !starting else { return false }
            starting = true
            return true
        }
        guard claimed else { return }

        let (stream, cont) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        let center = self.center
        let pump = Task { [weak self] in
            for await event in stream {
                self?.onEvent?(event)
                await center.ingest(event)
            }
        }

        let watcher = TranscriptWatcher { key in
            // A refusal leaves a `tool_result` in the transcript but no hook: report it ourselves.
            cont.yield(AgentEvent(agent: key.agent, kind: .answered, session: key.session,
                                  ts: Int64(Date().timeIntervalSince1970 * 1000), src: "transcript"))
        }
        await center.setEffectHandler { effect in
            switch effect {
            case .watchTranscript(let key, let path): watcher.watch(key, path: path)
            case .unwatchTranscript(let key), .sessionRemoved(let key): watcher.unwatch(key)
            }
        }

        let server = AgentHookServer(paths: paths) { cont.yield($0) }
        var listener = RuntimeStatus.Listener.listening
        do { try server.start() }
        catch AgentHookServer.StartError.alreadyRunning { listener = .alreadyRunning }
        catch { listener = .failed("\(error)") }

        let client = OpenCodeStreamClient(serviceFile: openCodeFile, handler: { cont.yield($0) }, onState: { [weak self] state in
            self?.update { $0.openCode = state }
        })
        client.start()

        lock.withLock {
            self.pump = pump; self.continuation = cont; self.watcher = watcher
            self.server = listener == .listening ? server : nil
            self.client = client
            self.starting = false
        }
        update { $0.listener = listener }
    }

    public func stop() async {
        let parts = lock.withLock { () -> (Task<Void, Never>?, AsyncStream<AgentEvent>.Continuation?) in
            let p = (pump, continuation)
            return p
        }
        stopSync()
        parts.1?.finish()
        _ = await parts.0?.value
        await center.setEffectHandler(nil)
    }

    private func stopSync() {
        let (s, c, w) = lock.withLock { () -> (AgentHookServer?, OpenCodeStreamClient?, TranscriptWatcher?) in
            let r = (server, client, watcher)
            server = nil; client = nil; watcher = nil; pump = nil; continuation = nil
            return r
        }
        s?.stop(); c?.stop(); w?.stopAll()
        update { $0 = RuntimeStatus() }
    }

    private func update(_ change: (inout RuntimeStatus) -> Void) {
        let new: RuntimeStatus? = lock.withLock {
            var copy = status
            change(&copy)
            guard copy != status else { return nil }
            status = copy
            return copy
        }
        if let new { onStatusChange?(new) }
    }
}
