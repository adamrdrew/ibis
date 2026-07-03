import SwiftUI

/// Editor for a project's `.ibis.json`: named actions (build / test / lint / …)
/// and environment variables. Mutates the live `ProjectConfig`; Done saves the
/// file (and keeps it out of git), Cancel reverts to the last saved version.
struct ProjectSettingsView: View {
    @Bindable var config: ProjectConfig
    /// Persist the config and re-apply env. Called on Done.
    var commit: () -> Void
    var dismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                actionsSection
                environmentSection
            }
            .formStyle(.grouped)
            .navigationTitle("Project Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        config.load() // revert unsaved edits to last saved
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commit()
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 560, height: 540)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            if config.actions.isEmpty {
                emptyRow("No actions yet")
            }
            ForEach($config.actions) { $action in
                ActionRow(action: $action) {
                    config.actions.removeAll { $0.id == action.id }
                }
            }
            addButton("Add Action") {
                config.actions.append(ProjectConfig.Action())
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Named commands you can run from the toolbar or the Project menu.")
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section {
            if config.envVars.isEmpty {
                emptyRow("No variables yet")
            }
            ForEach($config.envVars) { $variable in
                EnvRow(variable: $variable) {
                    config.envVars.removeAll { $0.id == variable.id }
                }
            }
            addButton("Add Variable") {
                config.envVars.append(ProjectConfig.EnvVar())
            }
        } header: {
            Text("Environment Variables")
        } footer: {
            Text("Injected into terminal and agent sessions opened afterward. Saved in .ibis.json, which Ibis adds to .gitignore.")
        }
    }

    // MARK: - Shared bits

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle.fill")
                .foregroundStyle(Color.ibisKelly)
        }
        .buttonStyle(.borderless)
    }
}

/// One action row: name + command, with a delete control revealed on hover.
private struct ActionRow: View {
    @Binding var action: ProjectConfig.Action
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("name", text: $action.name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 130)
            TextField("command", text: $action.command)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
            RemoveButton(action: onRemove)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

/// One environment variable row: KEY + value, delete revealed on hover.
private struct EnvRow: View {
    @Binding var variable: ProjectConfig.EnvVar
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("KEY", text: $variable.key)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 160)
            TextField("value", text: $variable.value)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
            RemoveButton(action: onRemove)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

private struct RemoveButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
        .accessibilityLabel("Remove")
    }
}
