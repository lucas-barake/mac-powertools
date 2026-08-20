// OBS Mic Meter: menu bar level meter for the "OBS Mic" virtual device.
// The status item icon is a live level bar; the popover shows a larger meter
// plus a health check for each link in the chain (driver, router, OBS, mic
// permission), so a dead tunnel is diagnosable at a glance.

import AppKit
import AVFoundation
import CoreAudio

let kVirtualDeviceUID = "OBSMic_UID" as CFString
let kOBSBundleID = "com.obsproject.obs-studio"

final class LevelCapture {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var currentRMS: Double = 0
    private var currentPeak: Double = 0

    var isCapturing: Bool { ioProcID != nil }

    func deviceExists() -> Bool {
        resolveDevice() != kAudioObjectUnknown
    }

    private func resolveDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = kVirtualDeviceUID
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &dev)
        }
        return err == noErr ? dev : AudioObjectID(kAudioObjectUnknown)
    }

    // Re-resolves the device and rebuilds the IO proc as needed, so the meter
    // survives coreaudiod restarts and driver reinstalls.
    func ensureCapturing() {
        let dev = resolveDevice()
        if dev == kAudioObjectUnknown {
            stop()
            return
        }
        if dev == deviceID, ioProcID != nil { return }
        stop()
        deviceID = dev

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            var sumSquares: Double = 0
            var count: Int = 0
            var peak: Double = 0
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float32.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                for i in 0..<n {
                    let v = Double(samples[i])
                    sumSquares += v * v
                    peak = max(peak, abs(v))
                }
                count += n
            }
            let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
            self.lock.lock()
            // Fast attack, slow decay, so short bursts stay visible.
            self.currentRMS = max(rms, self.currentRMS * 0.85)
            self.currentPeak = max(peak, self.currentPeak * 0.95)
            self.lock.unlock()
        }
        guard err == noErr, let procID else { return }
        if AudioDeviceStart(dev, procID) == noErr {
            ioProcID = procID
        } else {
            AudioDeviceDestroyIOProcID(dev, procID)
        }
    }

    func stop() {
        if let procID = ioProcID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        lock.lock()
        currentRMS = 0
        currentPeak = 0
        lock.unlock()
    }

    func levels() -> (rms: Double, peak: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (currentRMS, currentPeak)
    }
}

func decibels(_ linear: Double) -> Double {
    linear > 0 ? max(20 * log10(linear), -60) : -60
}

// 0...1 position on the meter for a -60...0 dB scale.
func meterFraction(_ linear: Double) -> Double {
    (decibels(linear) + 60) / 60
}

final class MeterView: NSView {
    var rms: Double = 0
    var peak: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        let barRect = bounds.insetBy(dx: 0, dy: 6)
        let radius: CGFloat = 4
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()

        let fraction = CGFloat(meterFraction(rms))
        if fraction > 0.01 {
            var fillRect = barRect
            fillRect.size.width = barRect.width * fraction
            let color: NSColor = fraction > 0.92 ? .systemRed
                : fraction > 0.75 ? .systemYellow : .systemGreen
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        let peakX = barRect.minX + barRect.width * CGFloat(meterFraction(peak))
        if peakX > barRect.minX + 2 {
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSRect(x: peakX - 1, y: barRect.minY, width: 2, height: barRect.height).fill()
        }
    }
}

final class StatusRow: NSStackView {
    private let dot = NSTextField(labelWithString: "●")
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        dot.font = .systemFont(ofSize: 10)
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(ok: Bool, text: String) {
        dot.textColor = ok ? .systemGreen : .systemRed
        label.stringValue = text
    }
}

final class PopoverViewController: NSViewController {
    let meterView = MeterView()
    let dbLabel = NSTextField(labelWithString: "-60 dB")
    let driverRow = StatusRow(title: "Driver")
    let routerRow = StatusRow(title: "Router")
    let obsRow = StatusRow(title: "OBS")
    let micRow = StatusRow(title: "Mic access")

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let title = NSTextField(labelWithString: "OBS Mic")
        title.font = .boldSystemFont(ofSize: 13)

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.widthAnchor.constraint(equalToConstant: 240).isActive = true
        meterView.heightAnchor.constraint(equalToConstant: 26).isActive = true

        dbLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dbLabel.textColor = .secondaryLabelColor

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small

        for v in [title, meterView, dbLabel, driverRow, routerRow, obsRow, micRow, quit] {
            stack.addArrangedSubview(v)
        }
        view = stack
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let capture = LevelCapture()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let popoverVC = PopoverViewController()
    var timer: Timer?
    var routerRunning = false
    var healthTick = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.contentViewController = popoverVC
        popover.behavior = .transient

        capture.ensureCapturing()
        checkRouter()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.stop()
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func tick() {
        healthTick += 1
        if healthTick % 20 == 0 {
            capture.ensureCapturing()
            checkRouter()
        }

        let (rms, peak) = capture.levels()
        statusItem.button?.image = menuBarImage(rms: rms, deviceOK: capture.isCapturing)

        if popover.isShown {
            popoverVC.meterView.rms = rms
            popoverVC.meterView.peak = peak
            popoverVC.meterView.needsDisplay = true
            popoverVC.dbLabel.stringValue = String(format: "%.1f dB", decibels(rms))

            popoverVC.driverRow.set(
                ok: capture.isCapturing,
                text: capture.isCapturing ? "Driver: OBS Mic device active"
                                          : "Driver: OBS Mic device not found")
            popoverVC.routerRow.set(
                ok: routerRunning,
                text: routerRunning ? "Router: obsmic-router running"
                                    : "Router: obsmic-router not running")
            let obsRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: kOBSBundleID).isEmpty
            popoverVC.obsRow.set(
                ok: obsRunning,
                text: obsRunning ? "OBS: running" : "OBS: not running")
            let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            popoverVC.micRow.set(
                ok: micOK,
                text: micOK ? "Mic access: granted"
                            : "Mic access: denied — meter reads silence")
        }
    }

    func checkRouter() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "obsmic-router"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.routerRunning = p.terminationStatus == 0 }
        }
        try? task.run()
    }

    func menuBarImage(rms: Double, deviceOK: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let bar = NSRect(x: 1, y: 3, width: 24, height: 10)
            NSColor.tertiaryLabelColor.setStroke()
            let outline = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()

            if !deviceOK {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 9),
                    .foregroundColor: NSColor.systemRed,
                ]
                ("!" as NSString).draw(at: NSPoint(x: 11, y: 3), withAttributes: attrs)
                return true
            }

            let fraction = CGFloat(meterFraction(rms))
            if fraction > 0.01 {
                var fill = bar.insetBy(dx: 1.5, dy: 1.5)
                fill.size.width *= fraction
                let color: NSColor = fraction > 0.92 ? .systemRed
                    : fraction > 0.75 ? .systemYellow : .systemGreen
                color.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
