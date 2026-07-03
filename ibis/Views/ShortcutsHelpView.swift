import SwiftUI

/// A compact, static reference of Ibis's keyboard shortcuts, grouped by area.
/// Opened from Help ▸ Keyboard Shortcuts.
struct ShortcutsHelpView: View {
    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { action }
    }

    private struct Section: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private let sections: [Section] = [
        Section(title: "File", shortcuts: [
            Shortcut(keys: "⌘N", action: "New File"),
            Shortcut(keys: "⇧⌘N", action: "New Window"),
            Shortcut(keys: "⌘O", action: "Open File…"),
            Shortcut(keys: "⇧⌘O", action: "Open Folder…"),
            Shortcut(keys: "⌘S", action: "Save"),
            Shortcut(keys: "⇧⌘S", action: "Save As…")
        ]),
        Section(title: "Editor", shortcuts: [
            Shortcut(keys: "⌘\\", action: "Split Editor"),
            Shortcut(keys: "⌥⌘→", action: "Focus Next Editor"),
            Shortcut(keys: "⌥⌘←", action: "Focus Previous Editor"),
            Shortcut(keys: "⇧⌘]", action: "Show Next Tab"),
            Shortcut(keys: "⇧⌘[", action: "Show Previous Tab"),
            Shortcut(keys: "⌘W", action: "Close Tab"),
            Shortcut(keys: "⌘L", action: "Go to Line…"),
            Shortcut(keys: "⌘F", action: "Find in File"),
            Shortcut(keys: "⇧⌘F", action: "Find in Folder")
        ]),
        Section(title: "View", shortcuts: [
            Shortcut(keys: "⌘+", action: "Increase Font Size"),
            Shortcut(keys: "⌘-", action: "Decrease Font Size"),
            Shortcut(keys: "⌘0", action: "Actual Size")
        ]),
        Section(title: "Terminal", shortcuts: [
            Shortcut(keys: "⌃`", action: "Show or Hide Terminal"),
            Shortcut(keys: "⌃⇧`", action: "New Terminal Tab"),
            Shortcut(keys: "⌃⇧A", action: "Open in Agent"),
            Shortcut(keys: "⌃⇧]", action: "Show Next Terminal"),
            Shortcut(keys: "⌃⇧[", action: "Show Previous Terminal")
        ])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(section.shortcuts) { shortcut in
                                GridRow {
                                    Text(shortcut.keys)
                                        .font(.body.monospaced())
                                        .gridColumnAlignment(.trailing)
                                        .frame(minWidth: 56, alignment: .trailing)
                                    Text(shortcut.action)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 480, alignment: .leading)
        }
        .frame(width: 480)
    }
}
