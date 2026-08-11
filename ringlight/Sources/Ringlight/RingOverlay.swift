import AppKit

final class RingView: NSView {
    var color: NSColor = Warmth.soft.color { didSet { needsDisplay = true } }
    var thickness: CGFloat = 80 { didSet { needsDisplay = true } }

    static let gap: CGFloat = 32

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let outerRect = bounds.insetBy(dx: Self.gap, dy: Self.gap)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: 24, yRadius: 24)
        let inner = NSBezierPath(
            roundedRect: outerRect.insetBy(dx: thickness, dy: thickness),
            xRadius: thickness / 2,
            yRadius: thickness / 2
        )
        outer.append(inner.reversed)
        outer.fill()
    }
}

final class RingWindow: NSWindow {
    private let ringView = RingView()

    init(screen: NSScreen) {
        // visibleFrame + .floating keep the menu bar, menus, and Dock above the
        // ring so system UI is never covered.
        super.init(contentRect: screen.visibleFrame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // The ring must never steal focus or appear in Mission Control/Exposé.
        isExcludedFromWindowsMenu = true
        contentView = ringView
        apply()
    }

    private var dimmed = false

    func apply() {
        ringView.color = Settings.warmth.color
        ringView.thickness = CGFloat(Settings.thickness.rawValue)
        alphaValue = dimmed ? Settings.intensity * 0.35 : Settings.intensity
    }

    // Dim and add transparency while the cursor is near the band so the ring
    // never hides content or UI the user is aiming for.
    func setDimmed(_ dimmed: Bool) {
        self.dimmed = dimmed
        let target = dimmed ? Settings.intensity * 0.35 : Settings.intensity
        guard abs(alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = target
        }
    }

    // The band area plus a margin, in global screen coordinates.
    func hoverZoneContains(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 24
        let inner = frame.insetBy(
            dx: CGFloat(Settings.thickness.rawValue) + margin,
            dy: CGFloat(Settings.thickness.rawValue) + margin
        )
        return frame.contains(point) && !inner.contains(point)
    }
}

final class RingController {
    private var windows: [RingWindow] = []
    private var mouseMonitors: [Any] = []

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuild() }

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateDimming() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            mouseMonitors.append(global)
        }
        mouseMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        } as Any)
    }

    var isOn: Bool { !windows.isEmpty }

    func rebuild() {
        hide()
        guard Settings.enabled else { return }
        let screens = NSScreen.screens.filter { screen in
            guard let selected = Settings.selectedScreen else { return true }
            return screen.localizedName == selected
        }
        windows = screens.map { RingWindow(screen: $0) }
        windows.forEach { $0.orderFrontRegardless() }
        updateDimming()
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    func applySettings() {
        windows.forEach { $0.apply() }
    }

    private func updateDimming() {
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.setDimmed(window.hoverZoneContains(mouse))
        }
    }
}
