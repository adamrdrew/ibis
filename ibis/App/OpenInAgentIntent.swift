import AppIntents
import Foundation

/// App Intent that opens a folder in Ibis and starts the configured agent in a
/// terminal tab. Enqueues on the same `LaunchRouter` hand-off as other opens,
/// flagged so the opening workspace launches the agent once.
struct OpenInAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder in Agent"
    static let description = IntentDescription("Opens a folder in Ibis and starts the configured agent in its terminal.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", description: "The folder to open (e.g. ~/Projects/app).")
    var path: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(filePath: expanded).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw OpenPathError.notFound(expanded)
        }
        guard isDirectory.boolValue else {
            throw OpenPathError.notAFolder(expanded)
        }

        LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: true), runAgent: true)
        return .result()
    }
}
