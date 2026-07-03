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

    /// Focus the next / previous pane (wraps around).
    func focusPane(offset: Int) {
        guard let currentIndex = panes.firstIndex(where: { $0.id == activePaneID }),
              !panes.isEmpty else { return }
        let next = (currentIndex + offset + panes.count) % panes.count
        activePaneID = panes[next].id
    }
}
