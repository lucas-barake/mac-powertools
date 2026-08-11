import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let ring = RingController()

    private let toggleItem = NSMenuItem(title: "Turn Ringlight On", action: #selector(toggle), keyEquivalent: "r")
    private let screensMenu = NSMenu()
    private let thicknessMenu = NSMenu()
    private let warmthMenu = NSMenu()
    private let intensityMenu = NSMenu()
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(submenu("Screen", screensMenu))
        menu.addItem(submenu("Thickness", thicknessMenu))
        menu.addItem(submenu("Warmth", warmthMenu))
        menu.addItem(submenu("Intensity", intensityMenu))
        menu.addItem(.separator())
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Ringlight", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu

        for thickness in Thickness.allCases {
            let item = NSMenuItem(title: thickness.title, action: #selector(pickThickness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = thickness.rawValue
            thicknessMenu.addItem(item)
        }
        for warmth in Warmth.allCases {
            let item = NSMenuItem(title: warmth.title, action: #selector(pickWarmth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = warmth.rawValue
            warmthMenu.addItem(item)
        }
        for intensity in Intensity.allCases {
            let item = NSMenuItem(title: intensity.title, action: #selector(pickIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = intensity.rawValue
            intensityMenu.addItem(item)
        }

        if Settings.enabled {
            ring.rebuild()
        }
        refreshUI()
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func toggle() {
        Settings.enabled = !ring.isOn
        ring.rebuild()
        refreshUI()
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        Settings.selectedScreen = sender.representedObject as? String
        ring.rebuild()
    }

    @objc private func pickThickness(_ sender: NSMenuItem) {
        Settings.thickness = Thickness(rawValue: sender.representedObject as! Int)!
        ring.applySettings()
    }

    @objc private func pickWarmth(_ sender: NSMenuItem) {
        Settings.warmth = Warmth(rawValue: sender.representedObject as! String)!
        ring.applySettings()
    }

    @objc private func pickIntensity(_ sender: NSMenuItem) {
        Settings.intensity = Intensity(rawValue: sender.representedObject as! Int)!
        ring.applySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshUI() {
        let on = ring.isOn
        toggleItem.title = on ? "Turn Ringlight Off" : "Turn Ringlight On"
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let image = NSImage(systemSymbolName: on ? "circle.circle.fill" : "circle.circle", accessibilityDescription: "Ringlight")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func refreshScreensMenu() {
        screensMenu.removeAllItems()
        let all = NSMenuItem(title: "All Screens", action: #selector(pickScreen(_:)), keyEquivalent: "")
        all.target = self
        all.state = Settings.selectedScreen == nil ? .on : .off
        screensMenu.addItem(all)
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(pickScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.localizedName
            item.state = Settings.selectedScreen == screen.localizedName ? .on : .off
            screensMenu.addItem(item)
        }
    }

    private func refreshChecks() {
        refreshScreensMenu()
        for item in thicknessMenu.items {
            item.state = (item.representedObject as? Int) == Settings.thickness.rawValue ? .on : .off
        }
        for item in warmthMenu.items {
            item.state = (item.representedObject as? String) == Settings.warmth.rawValue ? .on : .off
        }
        for item in intensityMenu.items {
            item.state = (item.representedObject as? Int) == Settings.intensity.rawValue ? .on : .off
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshChecks()
        refreshUI()
    }
}

extension AppDelegate: NSMenuDelegate {}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
