import Foundation

/// What a controller says about itself after the `Moni-A` handshake.
public struct DeviceIdentity: Sendable, Equatable {
    /// Six-character product code, e.g. `SK0L27`.
    public var model: String
    /// Hex of the serial bytes that follow the comma, or `000000` when absent.
    public var serial: String
    /// Which handshake attempt succeeded (1...3).
    public var attempt: Int
}

/// Brings a freshly opened port into a known state and asks the controller who it is.
///
/// The controller answers `Moni-A` with `SKxxxx[,<serial bytes>]` terminated by CR/LF. Pulsing
/// DTR/RTS first restarts boards whose reset line is wired to the USB bridge, and a short
/// settle time lets the firmware finish booting before it is asked anything.
public enum DeviceProbe {
    static let lineReleaseMs: UInt32 = 60
    static let stabilizeMs: UInt32 = 350
    static let retryMs: UInt32 = 120
    static let attempts = 3

    /// Blocks for up to ~1.2 s: call it off the main thread.
    public static func identify(on port: SerialPort) -> DeviceIdentity? {
        prepareTransport(port)
        for attempt in 1...attempts {
            if var info = queryOnce(port) { info.attempt = attempt; return info }
            if attempt < attempts { usleep(retryMs * 1000) }
        }
        return nil
    }

    static func prepareTransport(_ port: SerialPort) {
        port.flush()
        port.setControlLines(dtr: false, rts: false)
        usleep(lineReleaseMs * 1000)
        port.setControlLines(dtr: true, rts: true)
        usleep(stabilizeMs * 1000)
        port.flush()
    }

    private static func queryOnce(_ port: SerialPort) -> DeviceIdentity? {
        port.flush()
        try? port.write(WireProtocol.handshake())
        var reply = Data()
        for _ in 0..<10 where reply.count < 63 {
            usleep(50_000)
            reply.append(port.read(maxLen: 64))
            if let last = reply.last, last == 10 || last == 13 { break }
        }
        return parse(reply)
    }

    /// Parses `SK0L27,<serial>\r\n`. Returns nil for anything that is not a controller reply.
    public static func parse(_ raw: Data) -> DeviceIdentity? {
        var bytes = [UInt8](raw)
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        guard bytes.count >= 6, bytes[0] == 0x53, bytes[1] == 0x4B else { return nil } // "SK"
        let model = String(decoding: bytes[0..<6], as: UTF8.self).uppercased()
        guard model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var serial = "000000"
        if let comma = bytes.firstIndex(of: 0x2C) {
            guard comma >= 6 else { return nil }
            let tail = bytes[(comma + 1)...]
            if !tail.isEmpty { serial = tail.map { String(format: "%02X", $0) }.joined() }
        }
        return DeviceIdentity(model: model, serial: serial, attempt: 1)
    }
}
