import Foundation

public final class NotaryStateStore {
    private let store: SecurePlistStore<NotaryExamState>

    public init(logger: PlistStoreLogger? = nil) {
        self.store = SecurePlistStore<NotaryExamState>(
            rootURL: ExamManagerPaths.notaryExamState,
            fallbackURLFactory: {
                let uid = Int(geteuid())
                return URL(fileURLWithPath: "/tmp/\(ExamManagerPaths.notaryExamFallbackPrefix).\(uid).plist", isDirectory: false)
            },
            logger: logger
        )
    }

    public var effectiveURL: URL {
        store.effectiveURL
    }

    public func load() throws -> NotaryExamState {
        try store.load() ?? NotaryExamState()
    }

    public func save(_ state: NotaryExamState) throws {
        try store.save(state)
    }

    @discardableResult
    public func update(_ mutate: (inout NotaryExamState) -> Void) throws -> NotaryExamState {
        var state = try load()
        mutate(&state)
        state.lastChangedAt = Date()
        try save(state)
        return state
    }

    public func setMode(_ mode: NotaryExamState.Mode, command: String) throws -> NotaryExamState {
        try update { state in
            state.mode = mode
            state.lastCommand = command
            if mode != .error {
                state.lastError = nil
            }
            if mode == .inactive {
                state.exit = false
            }
        }
    }

    public func setExit(_ newValue: Bool, command: String = "emergency-exit") throws -> NotaryExamState {
        try update { state in
            state.exit = newValue
            state.lastCommand = command
        }
    }
}
