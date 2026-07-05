import Foundation

/// UserDefaults is documented as thread-safe but isn't marked `Sendable`; this
/// box lets it ride in a task-local without tripping strict-concurrency checks.
struct DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// The `UserDefaults` every lightweight Ibis store reads and writes
/// (`WorkspaceStateStore`, `WorkspaceTrust`, `MCPTokenStore`, `AppSettings`,
/// `ProjectConfigOpenStore`). The app always sees `.standard`; tests bind
/// `override` to a throwaway suite so they can never read or mutate the
/// developer's real preferences — an interrupted test run used to leave real
/// state clobbered. Task-local, so each test's redirection is scoped to its own
/// async call tree with no shared global to race on.
enum IbisDefaults {
    @TaskLocal static var override: DefaultsBox?

    static var store: UserDefaults { override?.defaults ?? .standard }
}
