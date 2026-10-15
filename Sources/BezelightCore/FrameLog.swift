import Foundation

/// Bounded log of the bytes exchanged with the device, for the Diagnostics view.
public actor FrameLog {
    public struct Entry: Sendable {
        public var date: Date
        public var direction: String // "TX" or "RX"
        public var bytes: Data
        public var note: String
    }

    private var entries: [Entry] = []
    private let capacity = 200
    public init() {}

    public func append(direction: String, bytes: Data, note: String = "") {
        entries.append(Entry(date: Date(), direction: direction, bytes: bytes, note: note))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func all() -> [Entry] { entries }
    public func clear() { entries.removeAll() }

    public nonisolated static func hex(_ data: Data, maxBytes: Int = 32) -> String {
        let head = data.prefix(maxBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > maxBytes ? head + " …" : head
    }
}
