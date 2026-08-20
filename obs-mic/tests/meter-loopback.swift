// Drives the meter's Loopback against real CoreAudio. The production source is
// compiled in verbatim minus its NSApplication bootstrap, so Loopback,
// LevelCapture and the free device helpers here are the shipping ones.
import CoreAudio
import Foundation

var gFailures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        FileHandle.standardError.write("ok:   \(message)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        gFailures += 1
    }
}

@main
enum MeterLoopbackTests {
    static func main() {
        // The IO callback writes the aggregate's input into every output buffer
        // past the virtual device's own. That offset is meaningless when the
        // OBS Mic device is gone: the HAL still builds the aggregate out of the
        // sub-devices it could find, so the loopback would copy the physical
        // device's input straight into the physical device's output.
        let orphaned = Loopback()
        orphaned.start(virtualDevice: AudioObjectID(kAudioObjectUnknown))
        let ranWithoutVirtualDevice = orphaned.isRunning
        let statusWithoutVirtualDevice = orphaned.status
        orphaned.stop()
        check(!ranWithoutVirtualDevice,
              "loopback refuses to run when the OBS Mic device is unknown")
        check(statusWithoutVirtualDevice != "off" && !ranWithoutVirtualDevice,
              "refusal is reported to the popover, got \"\(statusWithoutVirtualDevice)\"")

        let capture = LevelCapture()
        capture.ensureCapturing()
        if capture.isCapturing && defaultOutputDevice() != capture.device {
            let live = Loopback()
            live.start(virtualDevice: capture.device)
            let running = live.isRunning
            let status = live.status
            live.stop()
            check(running, "loopback runs with the real OBS Mic device, got \"\(status)\"")
            check(!live.isRunning && live.aggregateID == AudioObjectID(kAudioObjectUnknown),
                  "stop tears the aggregate down")
        } else {
            FileHandle.standardError.write(
                "skip: no OBS Mic device or it is the default output\n".data(using: .utf8)!)
        }
        capture.stop()

        exit(gFailures == 0 ? 0 : 1)
    }
}
