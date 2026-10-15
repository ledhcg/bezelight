import Foundation

/// One 8-bit RGB colour as shown on screen (sRGB-encoded).
public struct LEDColor: Equatable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    public static let black = LEDColor(r: 0, g: 0, b: 0)

    /// Linear interpolation toward `target`, `t` in 0...1.
    public func lerped(to target: LEDColor, t: Double) -> LEDColor {
        let k = max(0, min(1, t))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * k).rounded())
        }
        return LEDColor(r: mix(r, target.r), g: mix(g, target.g), b: mix(b, target.b))
    }
}

/// Which part of the display drives the LEDs in `screen` mode.
public enum CaptureRegion: String, CaseIterable, Sendable, Codable {
    case full, left, right, top, bottom
    /// Crops a fixed 12% off the top and bottom (a quick manual letterbox).
    case cinema
}

/// What the LEDs show. Raw values are persisted in the settings file: do not rename.
public enum LightMode: String, CaseIterable, Sendable, Codable {
    case staticColor
    case screen
    case musicBass
    case musicMid
    case musicTreble
    case musicSpectrum
    case musicEqualizer
    case rainbow
    case breathing
    case comet
    case spectrumCycling
    case starryNight
    /// The strip is a pure indicator for coding agents (Claude Code, Codex, OpenCode). It needs
    /// neither the screen nor audio, so it asks for no permission and cannot disturb the other modes.
    case agents

    public var isMusic: Bool {
        switch self {
        case .musicBass, .musicMid, .musicTreble, .musicSpectrum, .musicEqualizer: return true
        default: return false
        }
    }

    /// Modes that animate on their own clock and need neither screen nor audio.
    public var isAnimation: Bool {
        switch self {
        case .rainbow, .breathing, .comet, .spectrumCycling, .starryNight: return true
        default: return false
        }
    }

    public enum Group: String, CaseIterable, Sendable { case color, screen, music, animation, agents }

    public var group: Group {
        if isMusic { return .music }
        if isAnimation { return .animation }
        if self == .agents { return .agents }
        return self == .screen ? .screen : .color
    }
}

/// Built-in colour gradients for the Rainbow effect.
public enum PalettePreset: String, CaseIterable, Sendable, Codable {
    case rainbow, sunset, ocean, synthwave, custom
}

/// Tunables of the animated effects. Speeds run 0...1 (0 slowest).
public struct EffectParams: Codable, Sendable, Equatable {
    public var speed = 0.5
    public var palette = PalettePreset.rainbow
    /// Used by Rainbow (custom palette), Breathing and Starry Night.
    public var colors: [LEDColor] = [LEDColor(r: 255, g: 0, b: 0), LEDColor(r: 0, g: 170, b: 255), LEDColor(r: 255, g: 102, b: 0)]
    public var randomColors = false
    public var cometSize = 0.5
    public var cometRainbow = true
    public var cometColor = LEDColor(r: 0, g: 170, b: 255)
    public var starDensity = 0.5
    public var starBackground = LEDColor.black
    public var cyclingSaturation = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        speed = get(.speed, speed); palette = get(.palette, palette); colors = get(.colors, colors)
        randomColors = get(.randomColors, randomColors); cometSize = get(.cometSize, cometSize)
        cometRainbow = get(.cometRainbow, cometRainbow); cometColor = get(.cometColor, cometColor)
        starDensity = get(.starDensity, starDensity); starBackground = get(.starBackground, starBackground)
        cyclingSaturation = get(.cyclingSaturation, cyclingSaturation)
    }

    private enum Keys: String, CodingKey {
        case speed, palette, colors, randomColors, cometSize, cometRainbow, cometColor
        case starDensity, starBackground, cyclingSaturation
    }
}
