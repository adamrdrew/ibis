import Foundation

/// One line in a rendered unified diff.
nonisolated struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// A pending agent-proposed edit awaiting the human's review.
nonisolated struct DiffProposal: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
    let displayName: String
    let lines: [DiffLine]
    /// The full proposed content, written on Apply.
    let afterText: String
    let added: Int
    let removed: Int
}

/// Line-level diff via `CollectionDifference`. Unchanged lines (the LCS) become
/// context; the rest are emitted as removed (old) / added (new) in order.
nonisolated enum LineDiff {
    static func compute(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)

        var removedOld = Set<Int>()
        var insertedNew = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOld.contains(oldIndex) {
                result.append(DiffLine(kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedNew.contains(newIndex) {
                result.append(DiffLine(kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                // Unchanged line present in both sequences.
                result.append(DiffLine(kind: .context, text: oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                result.append(DiffLine(kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else {
                result.append(DiffLine(kind: .added, text: newLines[newIndex]))
                newIndex += 1
            }
        }
        return result
    }

    /// Builds a proposal, or nil if the content is unchanged.
    static func proposal(fileURL: URL, before: String, after: String) -> DiffProposal? {
        guard before != after else { return nil }
        let lines = compute(old: before, new: after)
        return DiffProposal(
            fileURL: fileURL,
            displayName: fileURL.lastPathComponent,
            lines: lines,
            afterText: after,
            added: lines.filter { $0.kind == .added }.count,
            removed: lines.filter { $0.kind == .removed }.count
        )
    }
}
