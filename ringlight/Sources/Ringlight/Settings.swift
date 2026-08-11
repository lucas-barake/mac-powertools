import AppKit

enum Thickness: Int, CaseIterable {
    case thin = 40
    case medium = 80
    case thick = 140

    var title: String {
        switch self {
        case .thin: return "Thin"
        case .medium: return "Medium"
        case .thick: return "Thick"
        }
    }
}

enum Warmth: String, CaseIterable {
    case cool
    case soft
    case warm

    var title: String {
        switch self {
        case .cool: return "Cool"
        case .soft: return "Soft"
        case .warm: return "Warm"
        }
    }

    var color: NSColor {
        switch self {
        case .cool: return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        case .soft: return NSColor(srgbRed: 1.0, green: 0.96, blue: 0.89, alpha: 1)
        case .warm: return NSColor(srgbRed: 1.0, green: 0.88, blue: 0.72, alpha: 1)
        }
    }
}

struct Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var thickness: Thickness {
        get { Thickness(rawValue: defaults.integer(forKey: "thickness")) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "thickness") }
    }

    static var warmth: Warmth {
        get { Warmth(rawValue: defaults.string(forKey: "warmth") ?? "") ?? .soft }
        set { defaults.set(newValue.rawValue, forKey: "warmth") }
    }

    // Ring opacity, 0.15...1. Stored as Double; 0 means "never set".
    static var intensity: CGFloat {
        get {
            let stored = defaults.double(forKey: "intensity")
            return stored == 0 ? 1 : CGFloat(min(max(stored, 0.15), 1))
        }
        set { defaults.set(Double(newValue), forKey: "intensity") }
    }

    // Empty means every screen. Screens are identified by localizedName, which
    // is stable enough across reconnects for a lighting preference.
    static var selectedScreen: String? {
        get { defaults.string(forKey: "selectedScreen") }
        set { defaults.set(newValue, forKey: "selectedScreen") }
    }
}
