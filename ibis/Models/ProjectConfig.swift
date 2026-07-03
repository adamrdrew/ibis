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

    let fileURL: URL
    private let root: URL

    init(root: URL) {
        self.root = root
        self.fileURL = root.appending(path: ".ibis.json")
        load()
    }

    /// The environment map to merge into terminal sessions (blank keys dropped;
    /// later duplicates win).
    var environment: [String: String] {
        var result: [String: String] = [:]
        for variable in envVars where !variable.key.trimmingCharacters(in: .whitespaces).isEmpty {
            result[variable.key] = variable.value
        }
        return result
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
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            actions = []
            envVars = []
            return
        }
        actions = file.actions?.map { Action(name: $0.name, command: $0.command) } ?? []
        envVars = (file.env ?? [:])
            .sorted { $0.key < $1.key }
            .map { EnvVar(key: $0.key, value: $0.value) }
    }

    func save() throws {
        let file = ConfigFile(
            env: environment.isEmpty ? nil : environment,
            actions: runnableActions.map { ConfigFile.ActionDTO(name: $0.name, command: $0.command) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
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
