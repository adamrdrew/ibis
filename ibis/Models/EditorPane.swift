import Foundation
import Observation

/// One editor pane: an ordered set of open tabs (documents) and the selected
/// one. A workspace can hold several panes side by side.
@Observable
final class EditorPane: Identifiable {
    let id = UUID()
    var tabDocuments: [OpenDocument] = []
    /// The selected tab, identified by document id (not URL) so untitled
    /// documents select correctly.
    var selectedID: OpenDocument.ID?

    /// Bumped to ask this pane's editor to take keyboard focus (e.g. from the
    /// Focus Next/Previous Editor commands, which need focus to follow visibly).
    var focusToken = 0

    func requestFocus() {
        focusToken += 1
    }

    var selectedDocument: OpenDocument? {
        tabDocuments.first { $0.id == selectedID }
    }

    /// Opens a document as a tab (or focuses it if already open).
    func open(_ document: OpenDocument) {
        if !tabDocuments.contains(where: { $0.id == document.id }) {
            tabDocuments.append(document)
        }
        selectedID = document.id
    }

    /// Reorders a tab, moving the document with `fromID` to sit at the position
    /// of the tab with `toID` (dropping onto a tab). Selection is preserved.
    /// Returns `false` when the move can't apply here (e.g. the dragged tab
    /// belongs to another pane), so the drop can decline instead of falsely
    /// reporting success.
    @discardableResult
    func moveTab(fromID: OpenDocument.ID, toID: OpenDocument.ID) -> Bool {
        guard fromID != toID,
              let from = tabDocuments.firstIndex(where: { $0.id == fromID }),
              let to = tabDocuments.firstIndex(where: { $0.id == toID }) else { return false }
        let document = tabDocuments.remove(at: from)
        let insertion = tabDocuments.firstIndex(where: { $0.id == toID }) ?? to
        // Insert before the target when moving left, after it when moving right.
        tabDocuments.insert(document, at: from < to ? insertion + 1 : insertion)
        return true
    }

    /// Replaces every tab backed by `old` with `new` (used when Save As retargets
    /// a document onto a URL another open document already backed, so no orphaned
    /// duplicate buffer is left behind for the same file).
    func replace(_ old: OpenDocument, with new: OpenDocument) {
        guard old !== new else { return }
        var replaced = false
        for index in tabDocuments.indices where tabDocuments[index].id == old.id {
            tabDocuments[index] = new
            replaced = true
        }
        guard replaced else { return }
        var seen = Set<OpenDocument.ID>()
        tabDocuments = tabDocuments.filter { seen.insert($0.id).inserted }
        if selectedID == old.id { selectedID = new.id }
    }

    /// Closes a document's tab, selecting a sensible neighbor.
    func close(_ document: OpenDocument) {
        guard let index = tabDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        tabDocuments.remove(at: index)
        if selectedID == document.id {
            selectedID = tabDocuments.isEmpty
                ? nil
                : tabDocuments[min(index, tabDocuments.count - 1)].id
        }
    }
}

/// The arrangement of panes within a workspace window. Starts as a single pane;
/// can be split into resizable vertical slices.
@Observable
final class EditorLayout {
    var panes: [EditorPane]
    var activePaneID: EditorPane.ID

    init() {
        let pane = EditorPane()
        self.panes = [pane]
        self.activePaneID = pane.id
    }

    var activePane: EditorPane? {
        panes.first { $0.id == activePaneID } ?? panes.first
    }

    /// Splits the active pane, carrying its current document into a new pane to
    /// the right and focusing it.
    func splitActive() {
        let newPane = EditorPane()
        if let active = activePane, let document = active.selectedDocument {
            newPane.open(document)
        }
        let insertionIndex = (panes.firstIndex { $0.id == activePaneID } ?? panes.count - 1) + 1
        panes.insert(newPane, at: insertionIndex)
        activePaneID = newPane.id
    }

    /// Closes a pane, unless it's the last one remaining.
    func closePane(_ id: EditorPane.ID) {
        guard panes.count > 1 else { return }
        panes.removeAll { $0.id == id }
        if activePaneID == id {
            activePaneID = panes.last?.id ?? activePaneID
        }
    }

    /// Focus the next / previous pane (wraps around), moving keyboard focus to
    /// its editor as well as the active-pane indicator.
    func focusPane(offset: Int) {
        guard let currentIndex = panes.firstIndex(where: { $0.id == activePaneID }),
              !panes.isEmpty else { return }
        let next = (currentIndex + offset + panes.count) % panes.count
        let pane = panes[next]
        activePaneID = pane.id
        pane.requestFocus()
    }
}
