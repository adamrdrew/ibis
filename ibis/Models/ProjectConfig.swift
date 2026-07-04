import Foundation
import Observation

/// The per-project configuration stored in `.ibis.json` at the workspace root:
/// named actions (build / test / lint / …, non-prescriptive) and environment
/// variables injected into the workspace's terminal sessions.
///
/// This is the live, editable model (the Project Settings GUI mutates it). It
/// serializes to/from `.ibis.json` and keeps that file out of git.
@Observable
@MainActor
final class ProjectConfig {
    struct Action: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var command: String = ""

        static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.name == rhs.name && lhs.command == rhs.command
        }
    }

    struct EnvVar: Identifiable, Equatable {
        let id = UUID()
        var key: String = ""
        var value: String = ""

        static func == (lhs: EnvVar, rhs: EnvVar) -> Bool {
            lhs.key == rhs.key && lhs.value == rhs.value
        }
    }

    var actions: [Action] = []
    var envVars: [EnvVar] = []

    /// Set when `.ibis.json` exists but couldn't be parsed. In that state we must
    /// not treat the config as empty or a Save would overwrite the user's real
    /// (if malformed) file with nothing. The UI surfaces this and blocks saving.
    private(set) var loadError: String?

    /// The raw top-level JSON object as last parsed, so unknown keys (settings a
    /// newer Ibis or the user added) survive a round-trip through Save.
    @ObservationIgnored private var rawObject: [String: Any] = [:]

    let fileURL: URL
    private let root: URL

    init(root: URL) {
        self.root = root
        self.fileURL = root.appending(path: ".ibis.json")
        load()
    }

    /// Environment keys Ibis refuses to inject regardless of trust. These hijack
    /// shell or dynamic-loader startup — running attacker code *before* the user's
    /// command — and have no legitimate project-config use, so blocking them is
    /// defense-in-depth against a trusted repo that later gains a hostile
    /// `.ibis.json` (e.g. via a merged PR), where the trust prompt won't re-appear.
    private static let blockedEnvKeys: Set<String> = [
        "ZDOTDIR", "ENV", "BASH_ENV", "LD_PRELOAD", "LD_LIBRARY_PATH",
        // HOME and XDG_CONFIG_HOME redirect where the shell looks for its startup
        // files (zsh's ZDOTDIR *defaults to* HOME; fish/others read
        // XDG_CONFIG_HOME), so overriding them makes a new login shell source the
        // repo's own rc scripts before the user's command — the same startup
        // hijack ZDOTDIR is blocked for. Neither has a legitimate project use.
        "HOME", "XDG_CONFIG_HOME",
    ]

    /// Whether a key is a code-injection vector we never inject (see above).
    /// Matches the fixed list plus the whole `DYLD_*` family.
    static func isBlockedEnvKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return blockedEnvKeys.contains(upper) || upper.hasPrefix("DYLD_")
    }

    /// The environment map to merge into terminal sessions (blank keys dropped;
    /// code-injection keys dropped; later duplicates win).
    var environment: [String: String] {
        var result: [String: String] = [:]
        for variable in envVars {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !Self.isBlockedEnvKey(key) else { continue }
            // Inject the trimmed key — exporting `"PATH "` (with the stray space
            // the user validated away) would be a useless, non-matching entry.
            result[key] = variable.value
        }
        return result
    }

    /// Whether the config carries anything Ibis would execute on the user's
    /// behalf (environment merged into shells, or runnable actions) — i.e.
    /// whether opening this folder warrants a trust prompt.
    var hasExecutableContent: Bool {
        !environment.isEmpty || !runnableActions.isEmpty
    }

    /// Actions that are actually runnable (have a name and a command).
    var runnableActions: [Action] {
        actions.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // File absent → an empty config is the correct state.
            actions = []
            envVars = []
            rawObject = [:]
            loadError = nil
            return
        }
        guard let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            // File present but unparseable — flag it and leave the model untouched
            // so a subsequent Save is refused rather than destroying the file.
            loadError = "The .ibis.json file couldn’t be read (invalid JSON). Fix or delete it before saving from here."
            return
        }
        loadError = nil
        rawObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        actions = file.actions?.map { Action(name: $0.name, command: $0.command) } ?? []
        envVars = (file.env ?? [:])
            .sorted { $0.key < $1.key }
            .map { EnvVar(key: $0.key, value: $0.value) }
    }

    enum SaveError: LocalizedError {
        case unparseableExisting(String)
        var errorDescription: String? {
            switch self { case .unparseableExisting(let m): m }
        }
    }

    func save() throws {
        // Never overwrite a file we failed to parse — that would silently discard
        // whatever the user actually had in it.
        if let loadError { throw SaveError.unparseableExisting(loadError) }

        // Preserve any unknown top-level keys, replacing only env/actions.
        var object = rawObject
        let env = environment
        if env.isEmpty { object.removeValue(forKey: "env") } else { object["env"] = env }
        let runnable = runnableActions
        if runnable.isEmpty {
            object.removeValue(forKey: "actions")
        } else {
            object["actions"] = runnable.map { ["name": $0.name, "command": $0.command] }
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: fileURL, options: .atomic)
        // The file can hold environment secrets — keep it owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
        rawObject = object
        ensureGitignored()
    }

    /// Appends `.ibis.json` to the project's `.gitignore` (creating it if needed)
    /// so the local config never gets committed. Idempotent, additive only.
    private func ensureGitignored() {
        let gitignore = root.appending(path: ".gitignore")
        let entry = ".ibis.json"
        var contents = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        let alreadyListed = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == entry }
        guard !alreadyListed else { return }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += entry + "\n"
        try? contents.write(to: gitignore, atomically: true, encoding: .utf8)
    }

    // MARK: - On-disk shape

    private struct ConfigFile: Codable {
        var env: [String: String]?
        var actions: [ActionDTO]?

        struct ActionDTO: Codable {
            var name: String
            var command: String
        }
    }
}
