import Foundation

/// Serial wire format spoken by the supported LED controllers (see `docs/PROTOCOL.md`).
///
/// One LED frame is `"Ada" 0x00 countHi countLo` followed by `count` RGB triplets: no checksum,
/// no footer. A 96-LED strip therefore needs 6 + 288 = 294 bytes per frame, which takes 25.5 ms
/// at 115200 baud (8N1) and caps the stream at ~39 fps. The controller also expects the
/// ASCII string `Moni-A` once after the port is opened.
public enum WireProtocol: Sendable {
    public static let magic: [UInt8] = [0x41, 0x64, 0x61] // "Ada"
    public static let headerSize = 6

    /// Sent once after opening the port.
    public static func handshake() -> Data { Data("Moni-A".utf8) }

    /// Fills the 6-byte header of `buffer` for `count` LEDs. `buffer` must be `headerSize + 3 * count` long.
    public static func writeHeader(into buffer: inout [UInt8], count: Int) {
        buffer[0] = magic[0]; buffer[1] = magic[1]; buffer[2] = magic[2]
        buffer[3] = 0
        buffer[4] = UInt8((count >> 8) & 0xFF)
        buffer[5] = UInt8(count & 0xFF)
    }

    /// Encodes one frame. The streaming hot path writes into a reused buffer instead (see
    /// `DeviceManager`); this form is for tests, tools and documentation.
    public static func encode(colors: [LEDColor]) -> Data {
        var out = [UInt8](repeating: 0, count: headerSize + colors.count * 3)
        writeHeader(into: &out, count: colors.count)
        for (i, c) in colors.enumerated() {
            out[headerSize + i * 3] = c.r
            out[headerSize + i * 3 + 1] = c.g
            out[headerSize + i * 3 + 2] = c.b
        }
        return Data(out)
    }

    /// Splits a captured byte stream into LED frames (for analysing recorded traffic).
    public static func splitStream(_ data: Data) -> [Data] {
        var frames: [Data] = []
        var i = data.startIndex
        while i + headerSize <= data.endIndex {
            guard data[i] == magic[0], data[i + 1] == magic[1], data[i + 2] == magic[2] else { i += 1; continue }
            let n = Int(data[i + 4]) << 8 | Int(data[i + 5])
            let end = i + headerSize + n * 3
            guard end <= data.endIndex else { break }
            frames.append(Data(data[i..<end]))
            i = end
        }
        return frames
    }
}
