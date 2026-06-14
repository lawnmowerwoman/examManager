import Foundation

/// Orchestrates the full enable/disable sequence:
/// reads the config profile → drives the selected proxy backend → updates state.
public final class ExamModeController {

    private let stateStore  = NotaryStateStore()
    private let builtInProxy = ExamProxyManager(logger: ConsoleLogger())
    private let tinyproxy   = TinyproxyManager(logger: ConsoleLogger())
    private let networkProxy = NetworkProxyManager()
    private let jamf        = JamfHelper()
    private let profile     = ConfigProfileReader()
    private let logger      = ConsoleLogger()
    private var lastManagedSettingsSnapshot: String?

    public init() {}

    // MARK: – Public API

    /// Called by the daemon whenever the profile key may have changed.
    /// Compares the desired state (from the profile) with the current
    /// runtime state and acts only when they differ.
    public func applyIfNeeded() {
        let desired = profile.examModeEnabled
        logManagedSettingsSnapshot(desired: desired)
        reconcileProfileStateChange(desired: desired)

        guard !isEmergencyExitActive else {
            log("Emergency exit is latched – skipping profile-driven activation")
            return
        }

        let current = networkProxy.isEnabled()

        guard desired != current else { return }

        if desired {
            activate()
        } else {
            deactivate()
        }
    }

    /// Forces activation regardless of current state (used at daemon start
    /// to recover from a crash while the profile key was already `true`).
    public func activateIfProfileDemands() {
        let desired = profile.examModeEnabled
        logManagedSettingsSnapshot(desired: desired)
        reconcileProfileStateChange(desired: desired)

        guard desired else { return }
        guard !isEmergencyExitActive else {
            log("Emergency exit is latched – skipping boot-time activation")
            return
        }
        activate()
    }

    /// Checks the persisted state for an emergency-exit request and performs
    /// a controlled shutdown when the flag is present.
    public func processEmergencyExitIfNeeded() {
        guard isEmergencyExitActive else { return }

        if let state = try? stateStore.load(),
           state.mode == .inactive,
           state.lastCommand == "emergency-exit" {
            return
        }

        log("Emergency exit requested via /var/db/notaryExam.plist")

        if networkProxy.isEnabled() {
            deactivate(command: "emergency-exit", clearExitFlag: false)
        } else {
            _ = try? stateStore.update { state in
                state.mode = .inactive
                state.lastCommand = "emergency-exit"
                state.proxyMode = .unavailable
                state.lastError = nil
            }
            publishCurrentStateToJamf()
        }
    }

    public func reloadWhitelist() {
        let backend = profile.proxyBackend
        let profileWhitelist = profile.proxyWhitelist
        let verboseLogging = profile.verboseLogging
        let currentProxyMode = (try? stateStore.load().proxyMode) ?? .unavailable

        let backendLabel: String
        switch backend {
        case .internalProxy:
            backendLabel = "built-in proxy"
        case .tinyproxy:
            backendLabel = "tinyproxy"
        case .proxyless:
            backendLabel = "proxyless fallback"
        }
        log("Reloading whitelist via \(backendLabel)")

        do {
            switch backend {
            case .internalProxy:
                let whitelistDomains = try builtInProxy.reloadAllowlist(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist,
                    verboseLogging: verboseLogging
                )
                if currentProxyMode == .fallback {
                    try networkProxy.enable(mode: .fallback, whitelistDomains: whitelistDomains)
                    log("Fallback bypass domains refreshed after built-in proxy whitelist reload")
                }
            case .tinyproxy:
                let whitelistDomains = try tinyproxy.reloadAllowlist(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist
                )
                if currentProxyMode == .fallback {
                    try networkProxy.enable(mode: .fallback, whitelistDomains: whitelistDomains)
                    log("Fallback bypass domains refreshed after tinyproxy whitelist reload")
                }
            case .proxyless:
                let activation = try builtInProxy.prepareProxylessActivation(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist
                )
                try networkProxy.enable(mode: .fallback, whitelistDomains: activation.whitelistDomains)
                log("Proxyless fallback bypass domains refreshed")
            }
        } catch {
            log("ERROR during whitelist reload: \(error)")
        }
    }

    public func prepareForTermination(signalName: String) {
        let normalizedSignal = signalName.lowercased()
        let command = "daemon-shutdown-\(normalizedSignal)"

        log("Preparing graceful shutdown for \(signalName)")
        deactivate(command: command)
    }

    // MARK: – Private

    private func activate() {
        let backend = profile.proxyBackend
        let profileWhitelist = profile.proxyWhitelist
        let verboseLogging = profile.verboseLogging
        let backendLabel: String
        switch backend {
        case .internalProxy:
            backendLabel = "built-in proxy"
        case .tinyproxy:
            backendLabel = "tinyproxy"
        case .proxyless:
            backendLabel = "proxyless fallback"
        }
        log("Profile says ExamModeEnabled=true – activating via \(backendLabel)")
        do {
            _ = try stateStore.setMode(.activating, command: "profile-enable")
            let activation: ExamProxyManager.ActivationResult

            switch backend {
            case .internalProxy:
                try tinyproxy.disable()
                activation = try builtInProxy.enable(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist,
                    verboseLogging: verboseLogging
                )
            case .tinyproxy:
                builtInProxy.disable()
                let tinyproxyActivation = try tinyproxy.enable(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist
                )
                activation = ExamProxyManager.ActivationResult(
                    mode: tinyproxyActivation.mode,
                    whitelistDomains: tinyproxyActivation.whitelistDomains,
                    tinyproxyInstalled: tinyproxyActivation.tinyproxyInstalled,
                    tinyproxyVersion: tinyproxyActivation.tinyproxyVersion
                )
            case .proxyless:
                builtInProxy.disable()
                try tinyproxy.disable()
                activation = try builtInProxy.prepareProxylessActivation(
                    jamfProURL: jamf.jamfProURL,
                    profileWhitelist: profileWhitelist
                )
            }

            try stateStore.update { state in
                state.mode = .active
                state.lastCommand = "profile-enable"
                state.tinyproxyInstalled = activation.tinyproxyInstalled
                state.tinyproxyVersion = activation.tinyproxyVersion
                switch activation.mode {
                case .internalProxy:
                    state.proxyMode = .internalProxy
                case .tinyproxy:
                    state.proxyMode = .tinyproxy
                case .fallback:
                    state.proxyMode = .fallback
                }
                state.lastError = nil
            }
            try networkProxy.enable(mode: activation.mode, whitelistDomains: activation.whitelistDomains)
            publishCurrentStateToJamf()
            log("Exam mode active (\(describe(activation.mode)))")
        } catch {
            log("ERROR during activation: \(error)")
            _ = try? stateStore.update { state in
                state.mode = .error
                state.lastCommand = "profile-enable"
                state.lastError = String(describing: error)
                state.proxyMode = .unavailable
            }
            publishCurrentStateToJamf()
        }
    }

    private func deactivate(command: String = "profile-disable", clearExitFlag: Bool = true) {
        log("Deactivating exam mode (\(command))")
        var errors: [String] = []

        do {
            _ = try stateStore.setMode(.deactivating, command: command)
        } catch {
            errors.append("state preflight: \(error)")
        }

        do {
            try networkProxy.disable()
        } catch {
            errors.append("proxy settings: \(error)")
        }

        builtInProxy.disable()

        do {
            try tinyproxy.disable()
        } catch {
            errors.append("tinyproxy: \(error)")
        }

        do {
            try stateStore.update { state in
                state.mode = .inactive
                state.lastCommand = command
                state.proxyMode = .unavailable
                if clearExitFlag {
                    state.exit = false
                }
                state.lastError = nil
            }
        } catch {
            errors.append("state finalization: \(error)")
        }

        publishCurrentStateToJamf()

        if errors.isEmpty {
            log("Exam mode inactive")
            return
        }

        let joined = errors.joined(separator: " | ")
        log("Deactivation completed with issues: \(joined)")

        _ = try? stateStore.update { state in
            state.mode = .error
            state.lastCommand = command
            state.lastError = joined
        }
    }

    private var isEmergencyExitActive: Bool {
        (try? stateStore.load().exit) ?? false
    }

    /// Clears the emergency-exit latch when the managed profile state actually
    /// changes. This gives us a deterministic reset point without letting
    /// unrelated state writes override the exit flag.
    private func reconcileProfileStateChange(desired: Bool) {
        guard let state = try? stateStore.load() else { return }
        guard state.lastProfileEnabled != desired else { return }

        _ = try? stateStore.update { state in
            state.lastProfileEnabled = desired
            state.exit = false
            state.lastError = nil
        }

        log("Profile state changed to \(desired) – clearing emergency exit latch")
    }

    private func publishCurrentStateToJamf() {
        guard let state = try? stateStore.load() else { return }

        jamf.publishExamState(state) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let update):
                _ = try? self.stateStore.update { state in
                    state.jamfComputerID = update.computerID
                    state.jamfEAID = update.eaID
                    state.jamfEAName = update.eaName
                }
                self.log("Jamf EA updated: \(update.eaName)")
            case .failure(let error):
                self.log("Jamf EA update skipped/failed: \(error)")
            }
        }
    }

    private func log(_ message: String) {
        logger.warn("[ExamModeController] \(message)")
    }

    private func logManagedSettingsSnapshot(desired: Bool) {
        let backend = profile.proxyBackend
        let snapshot = profile.diagnosticSnapshot()
        let message =
            "Managed settings snapshot: ExamModeEnabled=\(desired) raw=\(snapshot.examModeEnabled), " +
            "backend=\(backend.rawValue) raw=\(snapshot.proxyBackend), " +
            "whitelistEntries=\(snapshot.whitelistCount), sources=\(snapshot.sourceDescription)"
        guard lastManagedSettingsSnapshot != message else { return }
        lastManagedSettingsSnapshot = message
        log(message)
    }

    private func describe(_ mode: NetworkProxyManager.ActivationMode) -> String {
        switch mode {
        case .internalProxy:
            return "internal"
        case .tinyproxy:
            return "tinyproxy"
        case .fallback:
            return "fallback"
        }
    }
}
