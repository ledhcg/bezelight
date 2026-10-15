import Foundation

/// UI languages. `system` follows macOS and falls back to English.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, en, vi, zhHans = "zh-Hans", ja, ko

    public var id: String { rawValue }

    /// Name written in its own language (never translated, so users can always find theirs).
    public var nativeName: String? {
        switch self {
        case .system: return nil
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
}

/// Runtime localisation with live language switching.
///
/// Strings live in `Resources/<lang>.lproj/Localizable.strings` so translators only edit plain
/// `.strings` files. A missing key falls back to English, then to the key itself; a unit test
/// guarantees every language defines every key.
public enum Localizer {
    public static let supported: [AppLanguage] = AppLanguage.allCases.filter { $0 != .system }

    private static let state = NSLock()
    private nonisolated(unsafe) static var selected: AppLanguage = .system
    private nonisolated(unsafe) static var cache: [String: Bundle] = [:]

    public static var language: AppLanguage {
        get { state.withLock { selected } }
        set { state.withLock { selected = newValue; cachedResolved = nil } }
    }

    /// `resolved` is asked for by every string on screen, so it is remembered until the language
    /// choice or the system's language list changes.
    private nonisolated(unsafe) static var cachedResolved: AppLanguage?
    private nonisolated(unsafe) static var localeObserver: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil) { _ in
            state.withLock { cachedResolved = nil }
        }
    }()

    /// The concrete language in use (`system` resolved against the user's preferred languages).
    public static var resolved: AppLanguage {
        _ = localeObserver
        return state.withLock {
            if let c = cachedResolved { return c }
            let value = computeResolved(selected)
            cachedResolved = value
            return value
        }
    }

    private static func computeResolved(_ l: AppLanguage) -> AppLanguage {
        if l != .system { return l }
        for pref in Locale.preferredLanguages {
            let code = pref.lowercased()
            if code.hasPrefix("zh") { return .zhHans }
            if let match = supported.first(where: { code == $0.rawValue.lowercased() || code.hasPrefix($0.rawValue.lowercased() + "-") }) {
                return match
            }
        }
        return .en
    }

    public static func tr(_ key: String) -> String {
        lookup(key, in: resolved) ?? lookup(key, in: .en) ?? key
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale(identifier: resolved.rawValue), arguments: args)
    }

    /// Every key defined for `language` (used by the completeness test).
    public static func keys(for language: AppLanguage) -> Set<String> {
        guard let b = languageBundle(language),
              let path = b.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else { return [] }
        return Set(dict.keys)
    }

    private static func lookup(_ key: String, in lang: AppLanguage) -> String? {
        guard let b = languageBundle(lang) else { return nil }
        let missing = "\u{0}missing"
        let v = b.localizedString(forKey: key, value: missing, table: nil)
        return v == missing ? nil : v
    }

    private static func languageBundle(_ lang: AppLanguage) -> Bundle? {
        state.lock(); defer { state.unlock() }
        if let b = cache[lang.rawValue] { return b }
        guard let res = resourceBundle(),
              let path = res.path(forResource: lang.rawValue, ofType: "lproj"),
              let b = Bundle(path: path) else { return nil }
        cache[lang.rawValue] = b
        return b
    }

    private final class Marker {}

    /// Finds SwiftPM's resource bundle without `Bundle.module`, whose generated accessor aborts the
    /// process when the bundle is missing. Inside a `.app` it sits in `Contents/Resources`; in
    /// `swift run` / `swift test` it sits next to the executable or test bundle. If nothing is
    /// found the UI simply shows the string keys.
    private static func resourceBundle() -> Bundle? {
        let name = "Bezelight_BezelightCore.bundle"
        let here = Bundle(for: Marker.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            here.resourceURL,
            here.bundleURL.deletingLastPathComponent(),
        ]
        for dir in candidates {
            if let url = dir?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        }
        return nil
    }
}

/// Shorthand used throughout the UI.
public func tr(_ key: String) -> String { Localizer.tr(key) }
public func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.tr(key), locale: Locale(identifier: Localizer.resolved.rawValue), arguments: args)
}
