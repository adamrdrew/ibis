import AppIntents
import Foundation

/// App Intent (Shortcuts / Siri / Spotlight) that opens a file or folder in Ibis
/// by path. Reuses the same `LaunchRouter` hand-off as Finder/CLI opens.
struct OpenPathIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Ibis"
    static let description = IntentDescription("Opens a file or folder in Ibis by its path.")
    static let openAppWhenRun = true

    @Parameter(title: "Path", description: "The file or folder to open (e.g. ~/Projects/app).")
    var path: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(filePath: expanded).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw OpenPathError.notFound(expanded)
        }

        LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: isDirectory.boolValue))
        return .result()
    }
}

enum OpenPathError: Error, CustomLocalizedStringResourceConvertible {
    case notFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound(let path): "There's no file or folder at \(path)."
        }
    }
}
