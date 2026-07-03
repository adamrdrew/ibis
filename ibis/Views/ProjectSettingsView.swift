import SwiftUI

/// Editor for a project's `.ibis.json`: named actions (build / test / lint / …)
/// and environment variables. Mutates the live `ProjectConfig`; saving writes
/// the file (and keeps it out of git).
struct ProjectSettingsView: View {
    @Bindable var config: ProjectConfig
    /// Persist the config and re-apply env. Called on Done.
    var commit: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                Section("Actions") {
                    ForEach($config.actions) { $action in
                        HStack(spacing: 8) {
                            TextField("Name", text: $action.name)
                                .frame(width: 130)
                            TextField("Command", text: $action.command)
                                .font(.system(.body, design: .monospaced))
                            removeButton { config.actions.removeAll { $0.id == action.id } }
                        }
                    }
                    Button {
                        config.actions.append(ProjectConfig.Action())
                    } label: {
                        Label("Add Action", systemImage: "plus")
                    }
                }

                Section("Environment Variables") {
                    ForEach($config.envVars) { $variable in
                        HStack(spacing: 8) {
                            TextField("KEY", text: $variable.key)
                                .frame(width: 180)
                                .font(.system(.body, design: .monospaced))
                            TextField("value", text: $variable.value)
                                .font(.system(.body, design: .monospaced))
                            removeButton { config.envVars.removeAll { $0.id == variable.id } }
                        }
                    }
                    Button {
                        config.envVars.append(ProjectConfig.EnvVar())
                    } label: {
                        Label("Add Variable", systemImage: "plus")
                    }
                }

                Section {
                    Text("Saved to .ibis.json in the project (added to .gitignore). Environment variables are injected into terminal and agent sessions opened afterward.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 560)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Remove")
    }
}
