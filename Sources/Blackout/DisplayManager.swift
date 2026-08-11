import CoreGraphics
import Foundation

final class DisplayManager {
    private(set) var disabledBuiltinID: CGDirectDisplayID?

    var onExternalTopologyChange: (() -> Void)?

    var builtinIsDisabled: Bool { disabledBuiltinID != nil }

    init() {
        let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard let userInfo else { return }
            // Only react once a change batch is applied, not on begin events.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { manager.onExternalTopologyChange?() }
        }
        CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func builtinDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    func disableBuiltin() throws {
        guard let builtin = Self.builtinDisplay() else { throw BlackoutError.noBuiltinDisplay }
        let others = Self.activeDisplays().filter { $0 != builtin }
        guard !others.isEmpty else { throw BlackoutError.builtinIsOnlyDisplay }
        try PrivateAPI.setDisplayEnabled(builtin, false)
        disabledBuiltinID = builtin
    }

    func enableBuiltin() throws {
        // After a disconnect the builtin may no longer be in the online list, so
        // fall back to the ID captured when it was disabled.
        guard let builtin = Self.builtinDisplay() ?? disabledBuiltinID else {
            throw BlackoutError.noBuiltinDisplay
        }
        try PrivateAPI.setDisplayEnabled(builtin, true)
        disabledBuiltinID = nil
    }

    // If every non-builtin display goes away while the builtin is disabled
    // (external unplugged, dock sleep), bring the builtin back rather than leave
    // the machine headless.
    func reenableIfHeadless() {
        guard builtinIsDisabled else { return }
        let builtin = Self.builtinDisplay()
        let others = Self.activeDisplays().filter { $0 != builtin && $0 != disabledBuiltinID }
        guard others.isEmpty else { return }
        try? enableBuiltin()
    }
}
