import SwiftUI

/// Values the focused workspace window exposes to the menu bar, so `IbisCommands`
/// can act on whichever window is frontmost.
extension FocusedValues {
    @Entry var activeWorkspace: Workspace?
    @Entry var sidebarMode: Binding<SidebarMode>?
}
