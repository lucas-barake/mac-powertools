import CoreGraphics
import Foundation

final class DisplayManager {
    // Persisted so a crash or forced relaunch while the panel is off can still
    // recover it: without this, losing the process while headless would leave
    // the machine unusable until reboot.
    private(set) var disabledBuiltinID: CGDirectDisplayID? {
        didSet {
            if let disabledBuiltinID {
                UserDefaults.standard.set(Int(disabledBuiltinID), forKey: "disabledBuiltinID")
            } else {
                UserDefaults.standard.removeObject(forKey: "disabledBuiltinID")
            }
            updateWatchdog()
        }
    }

    private var watchdog: Timer?

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

        recoverPersistedState()
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

    // Once no physical display is active, the WindowServer brings up a
    // placeholder virtual display (vendor 'unkn', model 'virt', zero physical
    // size). It must not count as a usable screen, or the headless check would
    // never fire after the last external is unplugged.
    static func isStubDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x756E_6B6E && CGDisplayModelNumber(id) == 0x7669_7274
    }

    static func usableDisplays(besides excluded: [CGDirectDisplayID?]) -> [CGDirectDisplayID] {
        activeDisplays().filter { !isStubDisplay($0) && !excluded.contains($0) }
    }

    func disableBuiltin() throws {
        guard let builtin = Self.builtinDisplay() else { throw BlackoutError.noBuiltinDisplay }
        guard !Self.usableDisplays(besides: [builtin]).isEmpty else { throw BlackoutError.builtinIsOnlyDisplay }
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

    // If every other display goes away while the builtin is disabled (external
    // unplugged, dock sleep), bring the builtin back rather than leave the
    // machine headless.
    func reenableIfHeadless() {
        guard builtinIsDisabled else { return }
        guard Self.usableDisplays(besides: [Self.builtinDisplay(), disabledBuiltinID]).isEmpty else { return }
        // Failures stay disabled and the watchdog retries: a re-enable attempted
        // while the WindowServer is mid-reconfiguration can fail transiently.
        try? enableBuiltin()
    }

    // The reconfiguration callback alone is not enough to guarantee recovery:
    // if it is missed, delivered before the topology settles, or the re-enable
    // call fails once, nothing would retry and the machine stays headless. The
    // watchdog polls the (cheap) active display list the whole time the panel
    // is off and stops as soon as it is back.
    private func updateWatchdog() {
        if builtinIsDisabled, watchdog == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.reenableIfHeadless()
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !builtinIsDisabled {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    private func recoverPersistedState() {
        guard let stored = UserDefaults.standard.object(forKey: "disabledBuiltinID") as? Int else { return }
        let id = CGDirectDisplayID(stored)
        if let builtin = Self.builtinDisplay(), Self.activeDisplays().contains(builtin) {
            // The panel came back on its own (reboot re-enables it); drop the
            // stale record.
            UserDefaults.standard.removeObject(forKey: "disabledBuiltinID")
        } else {
            disabledBuiltinID = id
            reenableIfHeadless()
        }
    }
}
