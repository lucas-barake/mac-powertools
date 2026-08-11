import CoreGraphics
import Darwin

// The only way to make macOS stop treating the panel as a screen is the private
// display-enable configuration API (the same mechanism Lunar's BlackOut
// disconnect and BetterDisplay's "disconnect display" use). Brightness, gamma,
// and mirroring all leave the display in the window management space and let
// input wake it. Symbols are resolved at runtime so an OS update that removes
// them degrades into a clear error instead of a launch failure.
enum PrivateAPI {
    typealias ConfigureDisplayEnabledFn = @convention(c) (
        _ config: CGDisplayConfigRef?,
        _ display: CGDirectDisplayID,
        _ enabled: Bool
    ) -> CGError

    private static let configureDisplayEnabled: ConfigureDisplayEnabledFn? = {
        for name in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, name) {
                return unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
            }
        }
        // CoreGraphics is linked into every AppKit app, but SkyLight may need an
        // explicit load on some configurations.
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) {
            for name in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
                if let sym = dlsym(handle, name) {
                    return unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
                }
            }
        }
        return nil
    }()

    static var isAvailable: Bool { configureDisplayEnabled != nil }

    static func setDisplayEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) throws {
        guard let fn = configureDisplayEnabled else {
            throw BlackoutError.privateAPIUnavailable
        }
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else {
            throw BlackoutError.configurationFailed("CGBeginDisplayConfiguration", err)
        }
        // A display can't be disabled while it is part of a mirror set
        // (disable-monitor's DisableMonitorAppDelegate.m does the same).
        if !enabled, CGDisplayIsInMirrorSet(display) != 0 {
            CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
        }
        err = fn(config, display, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw BlackoutError.configurationFailed("ConfigureDisplayEnabled", err)
        }
        err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else {
            throw BlackoutError.configurationFailed("CGCompleteDisplayConfiguration", err)
        }
    }
}

enum BlackoutError: Error, CustomStringConvertible {
    case privateAPIUnavailable
    case configurationFailed(String, CGError)
    case noBuiltinDisplay
    case builtinIsOnlyDisplay

    var description: String {
        switch self {
        case .privateAPIUnavailable:
            return "The display configuration API is not available on this macOS version."
        case let .configurationFailed(step, err):
            return "\(step) failed with CGError \(err.rawValue)."
        case .noBuiltinDisplay:
            return "No built-in display found."
        case .builtinIsOnlyDisplay:
            return "Refusing to disable the built-in display because it is the only active display."
        }
    }
}
