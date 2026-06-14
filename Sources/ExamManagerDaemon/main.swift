import Foundation
import ExamManagerCore

// ─────────────────────────────────────────────────────────────────────────────
// exam-manager-daemon
//
// Deployed as a LaunchDaemon under de.twocent.exam.daemon.
// Runs as root, requires no arguments.
//
// On start  → reads the Config Profile key and applies the correct state.
// At runtime → reacts to MDM profile changes via Darwin notifications,
//              no polling required.
// ─────────────────────────────────────────────────────────────────────────────

let logger = ConsoleLogger()
logger.warn("[exam-manager-daemon] Starting up \(ExamManagerVersion.marketingVersion) (\(ExamManagerVersion.label))")

// 1. Build the controller that orchestrates all subsystems.
let controller = ExamModeController()

// 2. Boot-time reconciliation:
//    If the profile already says ExamModeEnabled=true (e.g. after a reboot
//    while the profile was deployed) and tinyproxy is not yet running,
//    activate immediately.
controller.activateIfProfileDemands()

// 3. Register for MDM profile-change notifications (Darwin notify center).
//    No polling – the system wakes us up when a profile is pushed or removed.
let observer = ProfileChangeObserver(controller: controller)
observer.startObserving()

// 4. Watch the persisted state plist for emergency-exit requests.
let emergencyExitObserver = EmergencyExitObserver(controller: controller)
emergencyExitObserver.startObserving()

// 5. Bridge launchd / operator signals into the daemon lifecycle.
let signalCoordinator = DaemonSignalCoordinator(
    controller: controller,
    profileObserver: observer,
    emergencyExitObserver: emergencyExitObserver
)
signalCoordinator.start()

logger.warn("[exam-manager-daemon] Run loop started – waiting for profile changes and emergency-exit requests")

// 6. Run forever. CFRunLoopRun() blocks here and processes incoming Darwin
//    notifications. The LaunchDaemon plist keeps us alive via KeepAlive=true.
CFRunLoopRun()
