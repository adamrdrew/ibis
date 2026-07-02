import Foundation

/// A lightweight, `Codable` reference to a workspace root, used as the value
/// type for the data-driven `WindowGroup`. Kept small and value-typed so SwiftUI
/// can persist and restore windows.
struct WorkspaceRef: Codable, Hashable, Identifiable {
    var path: String
    var isDirectory: Bool

    var id: String { path }
    var url: URL { URL(filePath: path) }

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    init(url: URL, isDirectory: Bool) {
        self.path = url.path(percentEncoded: false)
        self.isDirectory = isDirectory
    }
}
