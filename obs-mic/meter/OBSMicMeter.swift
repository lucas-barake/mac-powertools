// OBS Mic Meter: menu bar level meter for the "OBS Mic" virtual device.
// The popover also health-checks each link in the chain (driver, OBS monitor
// setting, OBS running, mic permission), so a silent mic is diagnosable at a glance.

import AppKit
import AVFoundation
import CoreAudio
import os

let kVirtualDeviceUID = "OBSMic_UID" as CFString
let kOBSBundleID = "com.obsproject.obs-studio"

// OBS writes its monitor output straight into the virtual device. Anything
// else writing into it would be a separate process, and OBS's desktop audio
// capture would record it as a second copy of the mic.
enum OBSConfig {
    static let root = NSHomeDirectory() + "/Library/Application Support/obs-studio"

    static func iniValue(_ path: String, section: String, key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inSection = false
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inSection = (t == "[\(section)]"); continue }
            if inSection, let eq = t.firstIndex(of: "="), t[..<eq] == key {
                return String(t[t.index(after: eq)...])
            }
        }
        return nil
    }

    // The monitoring device lives in the active profile's basic.ini.
    static func monitoringDeviceID() -> String? {
        guard let profileDir = iniValue(root + "/user.ini", section: "Basic", key: "ProfileDir")
        else { return nil }
        return iniValue(root + "/basic/profiles/\(profileDir)/basic.ini",
                        section: "Audio", key: "MonitoringDeviceId")
    }
}

struct Levels: Sendable {
    var rms: Double = 0
    var peak: Double = 0
}

final class LevelCapture {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    // Written from the CoreAudio IO thread, read from the main thread. The IO
    // thread only ever tries the lock, so it can never be made to wait on a
    // lower-priority thread and miss its deadline.
    private let published = OSAllocatedUnfairLock(initialState: Levels())

    var isCapturing: Bool { ioProcID != nil }
    var device: AudioObjectID { deviceID }

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
        // The block runs directly on the IO thread, so it captures the lock
        // rather than self: resolving a weak reference there would take the
        // runtime's side-table lock and release the object on a real-time thread.
        let published = self.published
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) {
            _, inInputData, _, _, _ in
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
            let cyclePeak = peak
            published.withLockIfAvailable { levels in
                // Fast attack, slow decay, so short bursts stay visible.
                levels.rms = max(rms, levels.rms * 0.85)
                levels.peak = max(cyclePeak, levels.peak * 0.95)
            }
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
        published.withLock { $0 = Levels() }
    }

    func levels() -> Levels {
        published.withLock { $0 }
    }
}

func defaultOutputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return err == noErr ? dev : AudioObjectID(kAudioObjectUnknown)
}

func deviceUID(_ device: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
    return err == noErr ? uid?.takeRetainedValue() as String? : nil
}

func deviceName(_ device: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
    return err == noErr ? (name?.takeRetainedValue() as String?) ?? "?" : "?"
}

func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioObjectID>.size
}

func activeSubDevices(_ aggregate: AudioObjectID) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(aggregate, &addr, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](
        repeating: AudioObjectID(kAudioObjectUnknown),
        count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

// Plays what the OBS Mic device delivers to its consumers on the current default
// output device: one private aggregate with the output device as clock master and
// the virtual device drift-compensated against it, and a copy in the IO callback.
// Hearing this is the only honest way to check what the virtual mic delivers.
final class Loopback {
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private(set) var status = "off"

    var isRunning: Bool { ioProcID != nil }

    func start(virtualDevice: AudioObjectID) {
        stop()
        let output = defaultOutputDevice()
        guard output != kAudioObjectUnknown, let outputUID = deviceUID(output) else {
            status = "no default output device"
            return
        }
        if output == virtualDevice {
            status = "default output is OBS Mic itself, refusing to loop it"
            return
        }
        // The aggregate lists the virtual device first, so its input buffers come
        // first in inInputData and its output buffers first in outOutputData. The
        // physical device's output buffers start after them, and only those are
        // written: writing into the virtual device's own output would feed the
        // tunnel back into itself.
        let outputOffset = streamCount(virtualDevice, scope: kAudioObjectPropertyScopeOutput)
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "dev.lucasbarake.obsmic.loopback.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "OBS Mic Loopback",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: kVirtualDeviceUID as String,
                 kAudioSubDeviceDriftCompensationKey: true],
                [kAudioSubDeviceUIDKey: outputUID],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard err == noErr else {
            status = "aggregate failed (\(err))"
            return
        }
        // The HAL builds the aggregate out of whichever sub-device UIDs it can
        // resolve and reports success either way, so a missing OBS Mic device
        // would leave the physical device as sub-device 0: the copy below would
        // then read that device's own input and play it back on its output.
        guard activeSubDevices(agg).first == virtualDevice else {
            AudioHardwareDestroyAggregateDevice(agg)
            status = "OBS Mic device unavailable"
            return
        }
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inInputData, _, outOutputData, _ in
            let outs = UnsafeMutableAudioBufferListPointer(outOutputData)
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for i in 0..<outs.count {
                guard let dst = outs[i].mData else { continue }
                memset(dst, 0, Int(outs[i].mDataByteSize))
                if i < outputOffset || ins.count == 0 { continue }
                guard let src = ins[0].mData else { continue }
                let inCh = Int(ins[0].mNumberChannels)
                let outCh = Int(outs[i].mNumberChannels)
                let frames = min(Int(ins[0].mDataByteSize) / (inCh * 4),
                                 Int(outs[i].mDataByteSize) / (outCh * 4))
                let s = src.assumingMemoryBound(to: Float32.self)
                let d = dst.assumingMemoryBound(to: Float32.self)
                for f in 0..<frames {
                    for c in 0..<outCh {
                        d[f * outCh + c] = s[f * inCh + (c % inCh)]
                    }
                }
            }
        }
        guard err == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(agg)
            status = "IO proc failed (\(err))"
            return
        }
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(agg, proc)
            AudioHardwareDestroyAggregateDevice(agg)
            status = "start failed (\(err))"
            return
        }
        aggregateID = agg
        ioProcID = proc
        outputDevice = output
        status = "playing on \(deviceName(output))"
    }

    func stop() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        outputDevice = AudioObjectID(kAudioObjectUnknown)
        status = "off"
    }
}

func decibels(_ linear: Double) -> Double {
    linear > 0 ? max(20 * log10(linear), -60) : -60
}

// 0...1 position on the meter for a -60...0 dB scale.
func meterFraction(_ linear: Double) -> Double {
    (decibels(linear) + 60) / 60
}

// Shared so the menu bar bar and the popover meter can never disagree on where
// the level stops being healthy.
func meterColor(_ fraction: CGFloat) -> NSColor {
    fraction > 0.92 ? .systemRed : fraction > 0.75 ? .systemYellow : .systemGreen
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
            meterColor(fraction).setFill()
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
    let monitorRow = StatusRow(title: "OBS monitor")
    let obsRow = StatusRow(title: "OBS")
    let micRow = StatusRow(title: "Mic access")
    let hearButton = NSButton(checkboxWithTitle: "Hear OBS Mic on my speakers (OBS desktop audio hears it too)", target: nil, action: #selector(hearToggled(_:)))
    let hearStatus = NSTextField(labelWithString: "")
    var onHearToggled: ((Bool) -> Void)?

    @objc func hearToggled(_ sender: NSButton) {
        onHearToggled?(sender.state == .on)
    }

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

        for v in [title, meterView, dbLabel, hearButton, hearStatus,
                  driverRow, monitorRow, obsRow, micRow, quit] {
            stack.addArrangedSubview(v)
        }
        view = stack
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let capture = LevelCapture()
    let loopback = Loopback()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let popoverVC = PopoverViewController()
    var timer: Timer?
    var healthTick = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: 44)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popoverVC.onHearToggled = { [weak self] on in
            guard let self else { return }
            if on {
                self.loopback.start(virtualDevice: self.capture.device)
            } else {
                self.loopback.stop()
            }
            self.popoverVC.hearStatus.stringValue = self.loopback.status
        }

        capture.ensureCapturing()

        let tickTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes, or the meter freezes for as long as the status item,
        // a menu, or a modal panel is tracking events.
        RunLoop.main.add(tickTimer, forMode: .common)
        timer = tickTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        loopback.stop()
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
            if popoverVC.hearButton.state == .on {
                let wanted = capture.isCapturing && loopback.isRunning
                    && loopback.outputDevice == defaultOutputDevice()
                if !wanted {
                    loopback.stop()
                    if capture.isCapturing { loopback.start(virtualDevice: capture.device) }
                    popoverVC.hearStatus.stringValue = loopback.status
                }
            }
        }

        let levels = capture.levels()
        let (rms, peak) = (levels.rms, levels.peak)
        let dark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        statusItem.button?.image = menuBarImage(
            rms: rms, deviceOK: capture.isCapturing, dark: dark)

        if popover.isShown {
            popoverVC.meterView.rms = rms
            popoverVC.meterView.peak = peak
            popoverVC.meterView.needsDisplay = true
            popoverVC.dbLabel.stringValue = String(format: "%.1f dB", decibels(rms))

            popoverVC.driverRow.set(
                ok: capture.isCapturing,
                text: capture.isCapturing ? "Driver: OBS Mic device active"
                                          : "Driver: OBS Mic device not found")
            let monitorOK = OBSConfig.monitoringDeviceID() == (kVirtualDeviceUID as String)
            popoverVC.monitorRow.set(
                ok: monitorOK,
                text: monitorOK ? "OBS monitor: OBS Mic"
                                : "OBS monitor: not OBS Mic (Settings, Audio, Monitoring Device)")
            let obsRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: kOBSBundleID).isEmpty
            popoverVC.obsRow.set(
                ok: obsRunning,
                text: obsRunning ? "OBS: running" : "OBS: not running")
            let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            popoverVC.micRow.set(
                ok: micOK,
                text: micOK ? "Mic access: granted"
                            : "Mic access: denied, meter reads silence")
        }
    }

    func menuBarImage(rms: Double, deviceOK: Bool, dark: Bool) -> NSImage {
        let size = NSSize(width: 40, height: 16)
        let fore: NSColor = dark ? NSColor.white.withAlphaComponent(0.9)
                                 : NSColor.black.withAlphaComponent(0.8)
        return NSImage(size: size, flipped: false) { _ in
            if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "OBS Mic"),
               let tinted = mic.withSymbolConfiguration(
                   .init(pointSize: 11, weight: .semibold)
                       .applying(.init(paletteColors: [fore]))) {
                tinted.draw(in: NSRect(x: 0, y: 2, width: 11, height: 12))
            }

            let bar = NSRect(x: 14, y: 3, width: 25, height: 10)
            // Visible track even at silence, so the icon never disappears
            // into the menu bar.
            fore.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            fore.setStroke()
            let outline = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()

            if !deviceOK {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 9),
                    .foregroundColor: NSColor.systemRed,
                ]
                ("!" as NSString).draw(at: NSPoint(x: 24, y: 3), withAttributes: attrs)
                return true
            }

            let fraction = CGFloat(meterFraction(rms))
            if fraction > 0.01 {
                var fill = bar.insetBy(dx: 1.5, dy: 1.5)
                fill.size.width *= fraction
                meterColor(fraction).setFill()
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
