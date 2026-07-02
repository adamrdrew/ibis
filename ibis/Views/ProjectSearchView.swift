import SwiftUI

/// Project-wide search UI shown in the sidebar: a query field with a match-case
/// toggle and results grouped by file. Clicking a result opens the file at the
/// matching line.
struct ProjectSearchView: View {
    @Bindable var model: ProjectSearchModel
    let root: URL
    var onOpen: (URL, NSRange) -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            optionsBar
            Divider()
            resultsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.query) { _, _ in scheduleSearch() }
        .onChange(of: model.caseSensitive) { _, _ in model.run(root: root) }
        .task { isFieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search in Folder", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { model.run(root: root) }
            if !model.query.isEmpty {
                Button {
                    model.clear()
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private var optionsBar: some View {
        HStack {
            Toggle(isOn: $model.caseSensitive) {
                Text("Aa")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Match Case")

            Spacer()

            if !model.results.isEmpty {
                Text("\(model.totalMatches) in \(model.results.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var resultsList: some View {
        if !model.results.isEmpty {
            List {
                ForEach(model.results) { file in
                    Section {
                        ForEach(file.matches) { match in
                            Button {
                                onOpen(file.url, match.characterRange)
                            } label: {
                                matchRow(match)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(file.url.lastPathComponent,
                              systemImage: FileIconProvider.symbolName(forFileURL: file.url))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isSearching {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.hasSearched && !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func matchRow(_ match: SearchMatch) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(match.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 30, alignment: .trailing)
            Text(highlighted(match))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    private func highlighted(_ match: SearchMatch) -> AttributedString {
        let line = match.lineText as NSString
        let location = match.matchColumnRange.location
        let end = location + match.matchColumnRange.length
        guard location != NSNotFound, end <= line.length else {
            return AttributedString(match.lineText)
        }

        let rawPrefix = line.substring(to: location)
        let prefix = String(rawPrefix.drop(while: { $0 == " " || $0 == "\t" }))
        let matchText = line.substring(with: match.matchColumnRange)
        let suffix = line.substring(from: end)

        var result = AttributedString(prefix)
        result.foregroundColor = .secondary

        var emphasized = AttributedString(matchText)
        emphasized.foregroundColor = .ibisKelly
        emphasized.inlinePresentationIntent = .stronglyEmphasized

        var tail = AttributedString(suffix)
        tail.foregroundColor = .secondary

        return result + emphasized + tail
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        model.beginSearching()
        let root = root
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            model.run(root: root)
        }
    }
}
