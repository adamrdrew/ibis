import AppKit

/// Coordinates window-level unsaved-change confirmation independently of the
/// workspace's document, layout, terminal, and project responsibilities.
@MainActor
final class WorkspaceCloseCoordinator {
    private weak var workspace: Workspace?
    private var isPresentingSheet = false

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func requestWindowClose(proceed: @escaping () -> Void) -> Bool {
        guard let workspace else { return true }

        // Flush the layout now: persistence is otherwise edge-triggered, so a
        // change made before the restore gate opened would be lost with the window.
        workspace.persistLayoutState()
        let dirty = workspace.dirtyDocuments
        guard !dirty.isEmpty else { return true }
        guard !isPresentingSheet,
              let window = workspace.window ?? NSApp.keyWindow else { return false }

        isPresentingSheet = true
        presentCloseConfirmation(dirty, on: window) { [weak self] outcome in
            self?.isPresentingSheet = false
            switch outcome {
            case .discarded, .saved:
                proceed()
            case .cancelled, .saveFailed:
                break
            }
        }
        return false
    }

    func confirmCloseForQuit() async -> Bool {
        guard let workspace else { return true }
        workspace.persistLayoutState()
        let dirty = workspace.dirtyDocuments
        guard !dirty.isEmpty else { return true }
        guard let window = workspace.window ?? NSApp.keyWindow else { return true }

        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            presentCloseConfirmation(dirty, on: window) { outcome in
                switch outcome {
                case .saved, .discarded:
                    continuation.resume(returning: true)
                case .cancelled, .saveFailed:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private enum CloseOutcome {
        case saved
        case discarded
        case cancelled
        case saveFailed
    }

    private func presentCloseConfirmation(
        _ dirty: [OpenDocument],
        on window: NSWindow,
        completion: @escaping (CloseOutcome) -> Void
    ) {
        let message = dirty.count == 1
            ? "Do you want to save the changes you made to “\(dirty[0].name)”?"
            : "You have \(dirty.count) documents with unsaved changes."
        let alert = makeSaveAlert(
            message: message,
            informative: "Your changes will be lost if you don’t save them."
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let workspace = self.workspace else {
                completion(.cancelled)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    if await self.saveAll(dirty, in: workspace) {
                        completion(.saved)
                    } else {
                        workspace.presentError("Some changes couldn’t be saved, so the window stayed open.")
                        completion(.saveFailed)
                    }
                }
            case .alertThirdButtonReturn:
                completion(.discarded)
            default:
                completion(.cancelled)
            }
        }
    }

    private func saveAll(_ dirty: [OpenDocument], in workspace: Workspace) async -> Bool {
        var allSucceeded = true
        for document in dirty where !(await workspace.saveDocument(document)) {
            allSucceeded = false
        }
        return allSucceeded
    }

    private func makeSaveAlert(message: String, informative: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        return alert
    }
}
