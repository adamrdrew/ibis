import AppIntents

/// Surfaces Ibis's App Intents in Shortcuts.app and Spotlight without any user
/// setup.
struct IbisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPathIntent(),
            phrases: ["Open a folder in \(.applicationName)"],
            shortTitle: "Open in Ibis",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: OpenInAgentIntent(),
            phrases: ["Open a project in \(.applicationName) with the agent"],
            shortTitle: "Open in Agent",
            systemImageName: "terminal"
        )
    }
}
