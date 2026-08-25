// Drives the popover the way a user does: the meter's own AppDelegate wiring,
// the real popover shown from the status item, and clicks on the Hear checkbox.
// The production source is compiled in verbatim minus its NSApplication bootstrap.
import AppKit
import Foundation

var gHearFailures = 0

func hearCheck(_ condition: Bool, _ message: String) {
    let line = (condition ? "ok:   " : "FAIL: ") + message + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if !condition { gHearFailures += 1 }
}

@main
enum PopoverHearTests {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))

        app.activate(ignoringOtherApps: true)
        delegate.togglePopover()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hearCheck(delegate.popover.isShown, "popover is shown")

        delegate.popoverVC.hearButton.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hearCheck(delegate.popoverVC.hearButton.state == .on, "checkbox is on after the click")
        // The handler reports what the loopback did, so an empty status means the
        // click never reached it.
        hearCheck(delegate.popoverVC.hearStatus.stringValue != "",
                  "checking Hear runs the loopback handler, status is "
                      + "\"\(delegate.popoverVC.hearStatus.stringValue)\"")
        let startedPlaying = delegate.loopback.isRunning

        delegate.popoverVC.hearButton.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hearCheck(delegate.popoverVC.hearButton.state == .off, "checkbox is off after the click")
        if startedPlaying {
            hearCheck(!delegate.loopback.isRunning,
                      "unchecking Hear stops playing on the speakers")
        } else {
            FileHandle.standardError.write(
                "skip: loopback never started, nothing to stop\n".data(using: .utf8)!)
        }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification))
        exit(gHearFailures == 0 ? 0 : 1)
    }
}
