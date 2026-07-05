import Foundation
import AppIntents
import UniformTypeIdentifiers

/// Represents a file in the workspace to the system's intelligence (Siri /
/// Apple Intelligence). Annotating the file-browser rows with this entity is
/// what makes macOS 27 auto-inject the "Ask Siri" context-menu item — the
/// AppKit equivalent of the annotation SwiftUI does for free.
///
/// Uses AppIntents' built-in `FileEntity`, whose identifier carries the file
/// URL, so the system can open and read the file to answer questions about it.
/// `nonisolated` (opting out of the MainActor default isolation) so the
/// `FileEntity`/`Sendable` conformances aren't actor-isolated — Xcode 26's
/// compiler rejects isolated conformances to `Sendable`-constrained protocols.
nonisolated struct WorkspaceFileEntity: FileEntity {
    static let supportedContentTypes: [UTType] = [.item]

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "File"
    static let defaultQuery = Query()

    let id: FileEntityIdentifier
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    nonisolated struct Query: EntityQuery {
        func entities(for identifiers: [FileEntityIdentifier]) async throws -> [WorkspaceFileEntity] {
            var entities: [WorkspaceFileEntity] = []
            for identifier in identifiers {
                let name = (try? await identifier.fileURL)?.lastPathComponent ?? "File"
                entities.append(WorkspaceFileEntity(id: identifier, name: name))
            }
            return entities
        }
    }
}
