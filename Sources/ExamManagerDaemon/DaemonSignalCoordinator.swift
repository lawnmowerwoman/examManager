import Foundation
import Darwin
import ExamManagerCore

/// Bridges POSIX signals into the daemon's normal control flow.
///
/// `launchd` sends SIGTERM for graceful shutdown and may escalate to SIGKILL
/// after the configured timeout. SIGKILL cannot be intercepted, so we do all
/// cleanup work on SIGTERM. SIGHUP is reserved for an explicit allowlist reload.
final class DaemonSignalCoordinator {
    private let controller: ExamModeController
    private let profileObserver: ProfileChangeObserver
    private let emergencyExitObserver: EmergencyExitObserver
    private let logger = ConsoleLogger()
    private let queue = DispatchQueue(label: "de.twocent.exam.signals")
    private let runLoop: CFRunLoop

    private var termSource: DispatchSourceSignal?
    private var hupSource: DispatchSourceSignal?

    init(
        controller: ExamModeController,
        profileObserver: ProfileChangeObserver,
        emergencyExitObserver: EmergencyExitObserver,
        runLoop: CFRunLoop = CFRunLoopGetMain()
    ) {
        self.controller = controller
        self.profileObserver = profileObserver
        self.emergencyExitObserver = emergencyExitObserver
        self.runLoop = runLoop
    }

    func start() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler { [weak self] in
            self?.handleTerminationSignal()
        }
        termSource.resume()
        self.termSource = termSource

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: queue)
        hupSource.setEventHandler { [weak self] in
            self?.handleReloadSignal()
        }
        hupSource.resume()
        self.hupSource = hupSource

        logger.warn("[DaemonSignalCoordinator] Listening for SIGTERM and SIGHUP")
    }

    private func handleTerminationSignal() {
        logger.warn("[DaemonSignalCoordinator] SIGTERM received – shutting down gracefully")
        profileObserver.stopObserving()
        emergencyExitObserver.stopObserving()
        controller.prepareForTermination(signalName: "SIGTERM")
        CFRunLoopStop(runLoop)
    }

    private func handleReloadSignal() {
        logger.warn("[DaemonSignalCoordinator] SIGHUP received – reloading whitelist")
        controller.reloadWhitelist()
    }

    deinit {
        termSource?.cancel()
        hupSource?.cancel()
    }
}
