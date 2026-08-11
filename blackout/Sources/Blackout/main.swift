import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let displays = DisplayManager()

    private let toggleItem = NSMenuItem(title: "Disable Built-in Display", action: #selector(toggle), keyEquivalent: "d")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        toggleItem.target = self
        launchAtLoginItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Blackout", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        displays.onExternalTopologyChange = { [weak self] in
            self?.displays.reenableIfHeadless()
            self?.refreshUI()
        }

        if !PrivateAPI.isAvailable {
            toggleItem.isEnabled = false
            alert(
                title: "Unsupported macOS version",
                text: "The display configuration API Blackout relies on is not available. The built-in display cannot be disabled."
            )
        }

        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if displays.builtinIsDisabled {
            try? displays.enableBuiltin()
        }
    }

    @objc private func toggle() {
        do {
            if displays.builtinIsDisabled {
                try displays.enableBuiltin()
            } else {
                try displays.disableBuiltin()
            }
        } catch {
            alert(title: "Blackout", text: "\(error)")
        }
        refreshUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(title: "Launch at Login", text: "\(error.localizedDescription)")
        }
        refreshUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshUI() {
        let disabled = displays.builtinIsDisabled
        toggleItem.title = disabled ? "Enable Built-in Display" : "Disable Built-in Display"
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let symbol = disabled ? "display.trianglebadge.exclamationmark" : "display"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Blackout")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = disabled ? "Blackout: built-in display disabled" : "Blackout: built-in display active"
    }

    private func alert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
