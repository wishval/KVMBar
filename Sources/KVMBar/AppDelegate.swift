import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: kSubsystem, category: "app")
    private var statusController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()

        log.notice("KVMBar starting (bundled: \(isBundledApp), skylight: \(SkyLight.shared.available), ddc: \(DDC.shared.symbolsAvailable))")
        if !isBundledApp {
            log.warning("running as a bare binary — launch at login and notifications are unavailable")
        }

        let controller = StatusMenuController()
        statusController = controller

        DisplayManager.shared.onStateChange = { [weak controller] state in
            controller?.stateChanged(state)
            DisplayWatcher.shared.scheduleProbeTimerUpdate()
        }
        DisplayManager.shared.async { DisplayManager.shared.refreshState() }

        DisplayWatcher.shared.start()
        CommandListener.start()
        UserNotifier.requestAuthorizationIfNeeded()
    }

    private func terminateIfAlreadyRunning() {
        guard isBundledApp else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            log.notice("another KVMBar instance is running (pid \(others[0].processIdentifier)) — exiting")
            NSApp.terminate(nil)
        }
    }
}
