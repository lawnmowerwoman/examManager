import Foundation

/// Watches for MDM preference-push notifications using the Darwin
/// notification center and triggers the controller when they arrive.
///
/// macOS posts `com.apple.ManagedClient.preferencesDidChange` whenever
/// a managed preference domain changes – this is exactly the signal we
/// need when Jamf deploys or removes a Config Profile.
///
/// As a belt-and-suspenders measure a second notification
/// `com.apple.MCX.ManagedPreferencesChanged` (used by older MDM stacks)
/// is also observed.
public final class ProfileChangeObserver {

    // The two notification names posted by the macOS MDM stack.
    private static let notifications: [CFString] = [
        "com.apple.ManagedClient.preferencesDidChange" as CFString,
        "com.apple.MCX.ManagedPreferencesChanged"      as CFString,
    ]

    private let controller: ExamModeController
    private let logger = ConsoleLogger()
    private var isObserving = false
    private var reconcileTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "de.twocent.exam.profile-reconcile")

    public init(controller: ExamModeController) {
        self.controller = controller
    }

    // MARK: – Public

    /// Registers for both MDM notifications. The callbacks fire on the
    /// Darwin notification delivery queue; we hop to a serial background
    /// queue before calling the controller so the run loop stays free.
    public func startObserving() {
        guard !isObserving else { return }

        for name in Self.notifications {
            registerDarwinObserver(for: name)
        }
        startFallbackPolling()
        isObserving = true
        logger.warn("[ProfileChangeObserver] Listening for MDM profile changes")
    }

    public func stopObserving() {
        guard isObserving else { return }

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = observerPointer
        for name in Self.notifications {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawValue: name), nil)
        }
        reconcileTimer?.cancel()
        reconcileTimer = nil

        isObserving = false
        logger.warn("[ProfileChangeObserver] Stopped listening for MDM profile changes")
    }

    // MARK: – Darwin notification registration

    private func registerDarwinObserver(for name: CFString) {
        let observer = observerPointer

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                // Recover self from the opaque pointer without consuming the
                // retain (the observer lives for the daemon's lifetime).
                guard let observer else { return }
                let me = Unmanaged<ProfileChangeObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                me.handleNotification()
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    private var observerPointer: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: – Handler

    private func handleNotification() {
        logger.warn("[ProfileChangeObserver] MDM notification received – checking profile key")
        // Small delay to let CFPreferences flush the new value from the MDM
        // write before we read it. 500 ms is sufficient in practice.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.controller.applyIfNeeded()
        }
    }

    private func startFallbackPolling(interval: TimeInterval = 10.0) {
        guard reconcileTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.controller.applyIfNeeded()
        }
        timer.resume()
        reconcileTimer = timer
        logger.warn("[ProfileChangeObserver] Fallback polling enabled every \(Int(interval))s")
    }

    deinit {
        stopObserving()
    }
}
