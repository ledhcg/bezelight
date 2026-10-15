import Foundation

/// Final colour stage: gamma curve, white balance and brightness folded into one 768-entry
/// lookup table, so the hot path is a single table read per channel.
public enum OutputCurve {
    /// `lut[channel * 256 + value]`. Brightness is applied after the gamma curve, i.e. as a
    /// physical dimming of the LEDs, not as a change of the colour curve.
    public static func lut(brightness: Double, gamma: Double, gains: (r: Double, g: Double, b: Double)) -> [UInt8] {
        let b = max(0, min(1, brightness))
        let g = max(0.5, min(4, gamma))
        let gs = [gains.r, gains.g, gains.b].map { max(0, min(1, $0)) }
        var out = [UInt8](repeating: 0, count: 768)
        for c in 0..<3 {
            for i in 0..<256 {
                let v = 255 * pow(Double(i) / 255, g) * b * gs[c]
                out[c * 256 + i] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        return out
    }
}

/// Owns the serial connection and the wire frame.
///
/// - Frames are encoded straight into one reusable buffer through the output LUT.
/// - A frame is written as soon as it is submitted, but never faster than the UART can drain
///   it (294 bytes @ 115200 baud = 25.5 ms), so the stream never queues up and adds latency.
/// - Unchanged frames are not rewritten; a 10 Hz keep-alive stops the firmware from blanking.
/// - A lost cable/port is re-opened automatically.
public actor DeviceManager {
    public struct State: Sendable {
        public var portPath: String?
        public var baudRate: Int = 115200
        public var connected: Bool = false
        public var ledCount: Int = 60
        public var brightness: Double = 0.8
        public var lastError: String?
        public var txBytes: Int = 0
        public var fps: Double = 0
        /// What the controller reported in its handshake (nil if it did not answer).
        public var identity: DeviceIdentity?
    }

    private static let keepAlive: Duration = .milliseconds(100)
    /// Shortest gap between frames: the time the UART needs to drain one (8N1 = 10 bits per byte).
    private var minInterval: Duration = .milliseconds(26)
    private var buttonHandler: (@Sendable () -> Void)?

    private var port: SerialPort?
    /// True while `connect()` is probing the controller: no frame or button read may touch the port meanwhile.
    private var handshaking = false
    private var payload: [UInt8] = []
    private var scratch: [UInt8] = []
    private var lut = OutputCurve.lut(brightness: 0.8, gamma: 2.2, gains: (1, 1, 1))
    private var gamma = 2.2
    private var gains: (r: Double, g: Double, b: Double) = (1, 1, 1)
    private var lastColors: [LEDColor] = []
    private var dirty = false
    private var wantConnected = false
    private var reconnectAt = ContinuousClock.now
    private var lastSend = ContinuousClock.now.advanced(by: .seconds(-3600))
    private var statStart = ContinuousClock.now
    private var statFrames = 0
    private var keepAliveTask: Task<Void, Never>?
    private var log: FrameLog?
    public private(set) var state = State()

    public init(log: FrameLog? = nil) { self.log = log }

    public func setLog(_ log: FrameLog?) { self.log = log }

    /// Called when the controller's physical button is pressed (models that have one).
    public func setButtonHandler(_ handler: (@Sendable () -> Void)?) { buttonHandler = handler }

    public func configure(portPath: String, baudRate: Int, ledCount: Int, brightness: Double) {
        state.portPath = portPath; state.baudRate = baudRate
        state.ledCount = ledCount; state.brightness = brightness
        rebuildLUT()
    }

    /// Brightness 0...1, gamma, per-channel white balance gains 0...1.
    public func setOutput(brightness: Double, gamma: Double, gains: (r: Double, g: Double, b: Double)) async {
        state.brightness = max(0, min(1, brightness))
        self.gamma = gamma; self.gains = gains
        rebuildLUT()
        if !lastColors.isEmpty { await submit(lastColors) } // re-encode the current frame now
    }

    public func setBrightness(_ v: Double) async {
        await setOutput(brightness: v, gamma: gamma, gains: gains)
    }

    private func rebuildLUT() {
        lut = OutputCurve.lut(brightness: state.brightness, gamma: gamma, gains: gains)
    }

    /// The exact bytes that will go on the wire (header + RGB). For diagnostics and tests.
    public func currentPayload() -> [UInt8] { payload }

    public func availablePorts() -> [String] { SerialPort.listPorts() }

    public func connect() async {
        guard let path = state.portPath else { return }
        wantConnected = true
        port?.close(); port = nil
        state.identity = nil                                // the previous board's identity must not steer button polling
        handshaking = true
        defer { handshaking = false }
        let p = SerialPort(path: path, baudRate: state.baudRate)
        do {
            try p.open()
            port = p
            state.connected = true; state.lastError = nil
            // Reset the control lines and ask the controller who it is (takes up to ~1 s, so do
            // it off this actor). A board that does not answer is still driven: the user chose it.
            state.identity = await Task.detached { DeviceProbe.identify(on: p) }.value
            state.txBytes += WireProtocol.handshake().count
            await log?.append(direction: "TX", bytes: WireProtocol.handshake(), note: "handshake")
            if let id = state.identity {
                await log?.append(direction: "RX", bytes: Data("\(id.model),\(id.serial)".utf8), note: "identity")
            }
            // This model needs two blank frames after a reconnect before it streams cleanly.
            if state.identity?.model == "SK0121" { await primeStream(p) }
            // disconnect() or a newer connect() may have run while we were suspended.
            guard wantConnected, port === p else { return }
            dirty = true
            startKeepAlive()
        } catch {
            state.connected = false; state.lastError = String(describing: error)
        }
    }

    /// Sends an all-black frame so the LEDs turn off (the controller otherwise keeps the last colour).
    public func blackout() {
        guard let port, port.isOpen, state.ledCount > 0 else { return }
        var frame = [UInt8](repeating: 0, count: WireProtocol.headerSize + 3 * state.ledCount)
        WireProtocol.writeHeader(into: &frame, count: state.ledCount)
        try? port.write(frame)
        try? port.write(frame) // twice: a frame still in flight must not be the last one the strip sees
        payload = []; scratch = []; lastColors = []
    }

    public func disconnect() {
        wantConnected = false
        keepAliveTask?.cancel(); keepAliveTask = nil
        port?.close(); port = nil
        state.connected = false
    }

    /// Submit the newest frame (one colour per LED, un-gamma'd). Cheap: LUT encode + compare.
    public func submit(_ colors: [LEDColor]) async {
        lastColors = colors
        let n = state.ledCount
        let c = colors.count == n ? colors : Self.resample(colors, to: n)
        if payload.count != WireProtocol.headerSize + 3 * n { allocateBuffers(n) }
        lut.withUnsafeBufferPointer { l in
            scratch.withUnsafeMutableBufferPointer { s in
                for i in 0..<n {
                    let o = WireProtocol.headerSize + i * 3
                    s[o] = l[Int(c[i].r)]
                    s[o + 1] = l[256 + Int(c[i].g)]
                    s[o + 2] = l[512 + Int(c[i].b)]
                }
            }
        }
        if scratch != payload {
            swap(&scratch, &payload) // scratch now holds the previous frame; fully rewritten next time
            dirty = true
        }
        await flushIfDue()
    }

    private func allocateBuffers(_ n: Int) {
        var buf = [UInt8](repeating: 0, count: WireProtocol.headerSize + 3 * n)
        WireProtocol.writeHeader(into: &buf, count: n)
        payload = buf; scratch = buf
        dirty = true
        let seconds = Double(buf.count * 10) / Double(max(1, state.baudRate)) + 0.001
        minInterval = .milliseconds(Int((seconds * 1000).rounded(.up)))
    }

    private func primeStream(_ p: SerialPort) async {
        var blank = [UInt8](repeating: 0, count: WireProtocol.headerSize + 3 * state.ledCount)
        WireProtocol.writeHeader(into: &blank, count: state.ledCount)
        for _ in 0..<2 {
            try? p.write(blank)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard let self else { return }
                await self.flushIfDue()
            }
        }
    }

    private func flushIfDue() async {
        let now = ContinuousClock.now
        guard wantConnected, !handshaking else { return }
        pollButton()
        if port == nil {
            if now >= reconnectAt { await connect() }
            if port == nil { reconnectAt = now.advanced(by: .seconds(1)); return }
        }
        guard !payload.isEmpty else { return }
        let since = now - lastSend
        if (dirty && since >= minInterval) || since >= Self.keepAlive {
            await send(now: now)
        }
    }

    /// SK0204 reports its button as a 0x00 byte on the serial line.
    private func pollButton() {
        guard state.identity?.model == "SK0204", let port, port.isOpen, let handler = buttonHandler else { return }
        if port.read(maxLen: 8).contains(0x00) { handler() }
    }

    private func send(now: ContinuousClock.Instant) async {
        guard let port, port.isOpen else { return }
        do {
            try port.write(payload)
        } catch {
            state.lastError = String(describing: error)
            state.connected = false
            port.close(); self.port = nil
            reconnectAt = now.advanced(by: .seconds(1))
            return
        }
        dirty = false
        lastSend = now
        state.txBytes += payload.count
        statFrames += 1
        let elapsed = now - statStart
        if elapsed >= .seconds(1) {
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            state.fps = Double(statFrames) / secs
            statFrames = 0; statStart = now
            // Once a second: sample the wire log and drain any ACK bytes.
            await log?.append(direction: "TX", bytes: Data(payload), note: "\(state.ledCount) leds")
            let rx = port.read()
            if !rx.isEmpty { await log?.append(direction: "RX", bytes: rx) }
        }
    }

    static func resample(_ src: [LEDColor], to n: Int) -> [LEDColor] {
        guard !src.isEmpty, n > 0 else { return Array(repeating: .black, count: max(0, n)) }
        if src.count == n { return src }
        return (0..<n).map { i in
            let pos = Double(i) * Double(src.count - 1) / Double(max(1, n - 1))
            return src[Int(pos.rounded())]
        }
    }
}
