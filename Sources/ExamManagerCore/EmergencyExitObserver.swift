import Foundation

/// Watches the persisted state plist for emergency-exit requests.
///
/// Profile changes stay event-driven via Darwin notifications. The emergency
/// exit is intentionally implemented as a tiny polling loop because
/// `defaults write /var/db/notaryExam exit true` does not emit a dedicated
/// notification we can subscribe to reliably.
public final class EmergencyExitObserver {
    private let controller: ExamModeController
    private let logger = ConsoleLogger()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "de.twocent.exam.emergency-exit")

    public init(controller: ExamModeController) {
        self.controller = controller
    }

    public func startObserving(interval: TimeInterval = 2.0) {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.controller.processEmergencyExitIfNeeded()
        }
        timer.resume()

        self.timer = timer
        logger.warn("[EmergencyExitObserver] Polling /var/db/notaryExam.plist for exit requests")
    }

    public func stopObserving() {
        guard let timer else { return }

        timer.cancel()
        self.timer = nil
        logger.warn("[EmergencyExitObserver] Stopped polling /var/db/notaryExam.plist")
    }

    deinit {
        stopObserving()
    }
}
