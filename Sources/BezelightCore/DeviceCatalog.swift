import Foundation

/// How a kit's LED segments are arranged around the screen, in wiring order.
///
/// Orientation, seen from the front of the display, verified on real hardware:
/// - `perimeter4`: left edge going up, top edge going right, right edge going down,
///   bottom edge going left (a clockwise loop that starts at the bottom-left).
/// - `perimeter3`: the same loop without the bottom edge.
/// - `sides2`: left edge going up, then right edge going down.
/// - `strip`: one straight run along a chosen screen edge.
public enum LayoutKind: String, Codable, Sendable, CaseIterable {
    case perimeter4, perimeter3, sides2, strip

    /// Number of LED segments the kind has.
    public var zoneCount: Int {
        switch self {
        case .perimeter4: return 4
        case .perimeter3: return 3
        case .sides2: return 2
        case .strip: return 1
        }
    }
}

public enum ScreenEdge: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left
}

/// A known LED kit. `zones` lists the LED count of each segment in wiring order.
public struct DevicePreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: LayoutKind
    public let zones: [Int]
    public var ledCount: Int { zones.reduce(0, +) }
    public init(id: String, kind: LayoutKind, zones: [Int]) { self.id = id; self.kind = kind; self.zones = zones }
}

public enum DeviceCatalog {
    /// Product codes the controller reports in its handshake, with their LED segments.
    public static let presets: [DevicePreset] = [
        .init(id: "SK0121", kind: .perimeter3, zones: [13, 25, 13]),
        .init(id: "SK0124", kind: .perimeter3, zones: [14, 26, 14]),
        .init(id: "SK0127", kind: .perimeter3, zones: [17, 31, 17]),
        .init(id: "SK0132", kind: .perimeter3, zones: [20, 37, 20]),
        .init(id: "SK0134", kind: .perimeter3, zones: [15, 41, 15]),
        .init(id: "SK0149", kind: .perimeter3, zones: [19, 69, 19]),
        .init(id: "SKA124", kind: .perimeter3, zones: [18, 34, 18]),
        .init(id: "SKA127", kind: .perimeter3, zones: [20, 41, 20]),
        .init(id: "SKA132", kind: .perimeter3, zones: [25, 45, 25]),
        .init(id: "SKA134", kind: .perimeter3, zones: [21, 51, 21]),
        .init(id: "SK0L21", kind: .perimeter4, zones: [13, 25, 13, 25]),
        .init(id: "SK0L24", kind: .perimeter4, zones: [14, 26, 14, 26]),
        .init(id: "SK0L27", kind: .perimeter4, zones: [17, 31, 17, 31]),
        .init(id: "SK0L32", kind: .perimeter4, zones: [20, 37, 20, 37]),
        .init(id: "SK0L34", kind: .perimeter4, zones: [15, 41, 15, 41]),
        .init(id: "SKB124", kind: .perimeter4, zones: [18, 34, 18, 34]),
        .init(id: "SKB127", kind: .perimeter4, zones: [20, 41, 20, 41]),
        .init(id: "SKB132", kind: .perimeter4, zones: [25, 44, 25, 44]),
        .init(id: "SKB134", kind: .perimeter4, zones: [21, 50, 21, 50]),
        .init(id: "SK0201", kind: .sides2, zones: [20, 20]),
        .init(id: "SK0202", kind: .sides2, zones: [30, 30]),
        .init(id: "SK0204", kind: .sides2, zones: [25, 25]),
        .init(id: "SK0F01", kind: .sides2, zones: [29, 29]),
        .init(id: "SK0F02", kind: .sides2, zones: [25, 25]),
        .init(id: "SK0402", kind: .strip, zones: [72]),
        .init(id: "SK0403", kind: .strip, zones: [96]),
        .init(id: "SK0404", kind: .strip, zones: [144]),
        .init(id: "SK0801", kind: .strip, zones: [2]),
        .init(id: "SK0802", kind: .strip, zones: [18]),
        .init(id: "SK0803", kind: .strip, zones: [10]),
        .init(id: "SK0901", kind: .strip, zones: [14]),
        .init(id: "SK0E01", kind: .strip, zones: [16]),
        .init(id: "SK0H01", kind: .strip, zones: [2]),
        .init(id: "SK0H02", kind: .strip, zones: [4]),
        .init(id: "SK0K01", kind: .strip, zones: [120]),
        .init(id: "SK0K02", kind: .strip, zones: [15]),
        .init(id: "SK0M01", kind: .strip, zones: [24]),
        .init(id: "SK0N01", kind: .strip, zones: [256]),
        .init(id: "SK0N02", kind: .strip, zones: [1024]),
        .init(id: "SK0N03", kind: .strip, zones: [253]),
        .init(id: "SK0S01", kind: .strip, zones: [32]),
    ]

    public static let customID = "custom"
    public static let defaultPresetID = "SK0L27"
    /// Upper bound for user-defined layouts; the largest known kit has 1024 LEDs.
    public static let maxLEDs = 1024

    public static func preset(id: String) -> DevicePreset? { presets.first { $0.id == id } }
}

/// The user's strip: a known preset or a custom layout, plus orientation fixes.
public struct DeviceProfile: Codable, Sendable, Equatable {
    /// A `DeviceCatalog` preset id, or `DeviceCatalog.customID`.
    public var presetID: String = DeviceCatalog.defaultPresetID
    public var customKind: LayoutKind = .perimeter4
    /// LED count per segment for a custom layout (`customKind.zoneCount` entries are used).
    public var custom: [Int] = [17, 31, 17, 31]
    /// Edge a straight strip is mounted on.
    public var stripEdge: ScreenEdge = .bottom
    /// Wiring runs the opposite way round.
    public var reversed = false
    /// Left and right swapped (strip mounted from the other side).
    public var mirrored = false

    public init() {}

    // Missing keys fall back to defaults, so settings saved by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? presetID
        customKind = try c.decodeIfPresent(LayoutKind.self, forKey: .customKind) ?? customKind
        custom = try c.decodeIfPresent([Int].self, forKey: .custom) ?? custom
        stripEdge = try c.decodeIfPresent(ScreenEdge.self, forKey: .stripEdge) ?? stripEdge
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? reversed
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? mirrored
    }

    private enum Keys: String, CodingKey { case presetID, customKind, custom, stripEdge, reversed, mirrored }

    public var kind: LayoutKind {
        DeviceCatalog.preset(id: presetID)?.kind ?? customKind
    }

    public var zones: [Int] {
        if let p = DeviceCatalog.preset(id: presetID) { return p.zones }
        var z = custom.map { max(0, min(DeviceCatalog.maxLEDs, $0)) }
        while z.count < customKind.zoneCount { z.append(0) }
        return Array(z.prefix(customKind.zoneCount))
    }

    public var ledCount: Int { min(DeviceCatalog.maxLEDs, max(1, zones.reduce(0, +))) }

    public var layout: LedLayout {
        LedLayout.build(kind: kind, zones: zones, stripEdge: stripEdge, mirrored: mirrored, reversed: reversed)
    }
}
