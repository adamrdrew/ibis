import Testing
import Foundation
@testable import ibis

@MainActor
@Suite struct EditorPaneTests {
    @Test func openAddsAndSelects() {
        let pane = EditorPane()
        let doc = OpenDocument()
        pane.open(doc)
        #expect(pane.tabDocuments.count == 1)
        #expect(pane.selectedID == doc.id)
        #expect(pane.selectedDocument === doc)
    }

    @Test func openingSameDocumentTwiceDoesNotDuplicate() {
        let pane = EditorPane()
        let doc = OpenDocument()
        pane.open(doc)
        pane.open(doc)
        #expect(pane.tabDocuments.count == 1)
    }

    @Test func closeSelectsNeighbor() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument(); let c = OpenDocument()
        pane.open(a); pane.open(b); pane.open(c)
        pane.selectedID = b.id
        pane.close(b)
        #expect(pane.tabDocuments.count == 2)
        // Selection lands on the tab that took b's slot (c).
        #expect(pane.selectedID == c.id)
    }

    @Test func closingLastTabClearsSelection() {
        let pane = EditorPane()
        let a = OpenDocument()
        pane.open(a)
        pane.close(a)
        #expect(pane.tabDocuments.isEmpty)
        #expect(pane.selectedID == nil)
    }

    @Test func closingUnselectedTabKeepsSelection() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument()
        pane.open(a); pane.open(b)
        pane.selectedID = b.id
        pane.close(a)
        #expect(pane.selectedID == b.id)
    }

    @Test func moveTabRightReorders() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument(); let c = OpenDocument()
        pane.open(a); pane.open(b); pane.open(c)
        #expect(pane.moveTab(fromID: a.id, toID: c.id))
        #expect(pane.tabDocuments.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func moveTabLeftReorders() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument(); let c = OpenDocument()
        pane.open(a); pane.open(b); pane.open(c)
        #expect(pane.moveTab(fromID: c.id, toID: a.id))
        #expect(pane.tabDocuments.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func moveTabRejectsUnknownSource() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument()
        pane.open(a); pane.open(b)
        let foreign = OpenDocument()
        #expect(pane.moveTab(fromID: foreign.id, toID: a.id) == false)
        #expect(pane.tabDocuments.map(\.id) == [a.id, b.id])
    }

    @Test func replaceSwapsDocumentAndRetargetsSelection() {
        let pane = EditorPane()
        let a = OpenDocument(); let b = OpenDocument()
        pane.open(a); pane.open(b)
        pane.selectedID = a.id
        let replacement = OpenDocument()
        pane.replace(a, with: replacement)
        #expect(pane.tabDocuments.contains { $0.id == replacement.id })
        #expect(pane.tabDocuments.contains { $0.id == a.id } == false)
        #expect(pane.selectedID == replacement.id)
    }

    @Test func requestFocusBumpsToken() {
        let pane = EditorPane()
        let before = pane.focusToken
        pane.requestFocus()
        #expect(pane.focusToken == before + 1)
    }
}

@MainActor
@Suite struct EditorLayoutTests {
    @Test func startsWithSingleActivePane() {
        let layout = EditorLayout()
        #expect(layout.panes.count == 1)
        #expect(layout.activePane === layout.panes.first)
    }

    @Test func splitActiveAddsPaneCarryingDocumentAndFocusesIt() {
        let layout = EditorLayout()
        let doc = OpenDocument()
        layout.activePane?.open(doc)
        layout.splitActive()
        #expect(layout.panes.count == 2)
        let newPane = layout.activePane
        #expect(newPane !== layout.panes.first)
        #expect(newPane?.selectedDocument === doc)
    }

    @Test func splitInsertsAfterActivePane() {
        let layout = EditorLayout()
        layout.splitActive() // panes: [p0, p1], active p1
        let p1 = layout.activePaneID
        layout.activePaneID = layout.panes[0].id
        layout.splitActive() // new pane inserted after p0, before p1
        #expect(layout.panes.count == 3)
        #expect(layout.panes.last?.id == p1)
    }

    @Test func closePaneRemovesAndReassignsActive() {
        let layout = EditorLayout()
        layout.splitActive()
        let active = layout.activePaneID
        layout.closePane(active)
        #expect(layout.panes.count == 1)
        #expect(layout.activePaneID != active)
    }

    @Test func closingLastPaneIsNoOp() {
        let layout = EditorLayout()
        let only = layout.activePaneID
        layout.closePane(only)
        #expect(layout.panes.count == 1)
        #expect(layout.activePaneID == only)
    }

    @Test func focusPaneWrapsAround() {
        let layout = EditorLayout()
        layout.splitActive() // two panes; active is index 1
        let first = layout.panes[0].id
        layout.focusPane(offset: 1) // wrap forward from index 1 -> index 0
        #expect(layout.activePaneID == first)
    }
}
