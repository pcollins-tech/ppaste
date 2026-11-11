import AppKit

/// A global keyboard shortcut (Carbon key code + modifiers) that can be stored in UserDefaults.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiersRaw: UInt
    var keyLabel: String

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRaw).intersection(.deviceIndependentFlagsMask) }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    static let defaultPrimary = Shortcut(keyCode: 9, modifiersRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "V")
    static let defaultAlternate = Shortcut(keyCode: 9, modifiersRaw: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyLabel: "V")
}

/// User preferences, backed by UserDefaults. Posts `AppSettings.didChange` when something that needs
/// to be re-applied (hotkeys) changes.
enum AppSettings {
    static let didChange = Notification.Name("ppaste.settings.didChange")
    private static let defaults = UserDefaults.standard

    private static func load(_ key: String) -> Shortcut?? {
        guard let data = defaults.data(forKey: key) else { return .none }          // never set → use default
        if data.isEmpty { return .some(nil) }                                       // explicitly cleared
        return (try? JSONDecoder().decode(Shortcut.self, from: data)).map { .some($0) } ?? .none
    }
    private static func save(_ s: Shortcut?, _ key: String) {
        defaults.set(s.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var primaryShortcut: Shortcut? {
        get { load("primaryShortcut") ?? .defaultPrimary }
        set { save(newValue, "primaryShortcut") }
    }
    static var alternateShortcut: Shortcut? {
        get { load("alternateShortcut") ?? .defaultAlternate }
        set { save(newValue, "alternateShortcut") }
    }

    /// Bundle IDs the user added; copies made while these apps are frontmost are not saved.
    static var ignoredBundleIDs: [String] {
        get { defaults.stringArray(forKey: "ignoredBundleIDs") ?? [] }
        set { defaults.set(newValue, forKey: "ignoredBundleIDs") }
    }

    /// How long image clips are kept. 0 means forever.
    static var imageRetentionDays: Int {
        get { defaults.object(forKey: "imageRetentionDays") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "imageRetentionDays") }
    }
}
