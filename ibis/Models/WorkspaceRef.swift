import Foundation

/// A lightweight, `Codable` reference to a workspace root, used as the value
/// type for the data-driven `WindowGroup`. Kept small and value-typed so SwiftUI
/// can persist and restore windows.
struct WorkspaceRef: Codable, Hashable, Identifiable {
    var path: String
    var isDirectory: Bool

    /// Identity is the *canonical* path (symlinks resolved, no trailing slash) so
    /// the same folder opened two ways — `/tmp/p` vs `/private/tmp/p`, with or
    /// without a trailing slash — resolves to one window instead of spawning a
    /// duplicate workspace (each with its own document cache, so edits to the same
    /// file in both would clobber). Equality/hashing key off this too, so SwiftUI's
    /// `WindowGroup(for:)` de-dupes and focuses the existing window.
    var id: String { Self.canonical(path) }
    var url: URL { URL(filePath: path) }

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    init(url: URL, isDirectory: Bool) {
        self.path = url.path(percentEncoded: false)
        self.isDirectory = isDirectory
    }

    static func canonical(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false).strippingTrailingSlashes
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: WorkspaceRef, rhs: WorkspaceRef) -> Bool { lhs.id == rhs.id }
}
