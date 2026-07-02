# Ibis — a text editor for developers

A lightweight, folder-oriented macOS code editor (not an IDE): open files/folders,
browse a hierarchical file tree, edit in tabs and resizable split panes, syntax
highlighting, project search. **No** run/debug, LSP, or plugin marketplace.

- **Platform:** macOS only, deployment target **macOS 27**, SwiftUI + AppKit.
- **Hero color:** kelly green (`Color.ibisKelly`), used sparingly for accents.
- **Sandboxed** with read-write access to user-selected files + app-scope bookmarks.

## Build & run

Use the Xcode MCP tools (this project is developed from inside Xcode):
- `BuildProject` to compile, `RunProject` to launch, `XcodeRefreshCodeIssuesInFile`
  for quick per-file diagnostics, `RunCodeSnippet` to try code in-context.
- `DocumentationSearch` for Apple API docs — **always** search for macOS 26/27
  APIs rather than relying on training data; many APIs here post-date the cutoff.

## Architecture (all sources under `ibis/`)

- **App/** — `IbisApp` (`@main`, data-driven `WindowGroup(for: WorkspaceRef)` +
  `Settings`), `AppDelegate` (Finder/CLI opens via `LaunchRouter`), `IbisCommands`
  (full menu bar, targets the focused window via `@FocusedValue`), `FocusedValues`.
- **Models/** — `@Observable`, `@MainActor`. `Workspace` (root, file tree, pane
  layout, file ops, FSEvents), `FileNode` (lazy tree node), `EditorPane`/
  `EditorLayout`, `OpenDocument`, `AppSettings` (UserDefaults-backed),
  `ProjectSearchModel`, `WorkspaceRef`, `WorkspaceFileEntity` (App Intents).
- **FileSystem/** — `FileTreeLoader`, `FileSystemWatcher` (FSEvents),
  `FileOperations`, `SecurityScopedAccess`.
- **Syntax/** — `Language` (ext → highlight.js name), `SyntaxHighlighter`
  (actor wrapping the **HighlighterSwift** package; engine is swappable behind
  this seam), `ProjectSearch`.
- **Views/** — `WorkspaceView` (NavigationSplitView), `FileOutlineView`
  (NSOutlineView-backed browser), `CodeEditorView` + `LineNumberRulerView`
  (NSTextView editor), `EditorAreaView`/`EditorPaneView`/`TabBarView`,
  `ProjectSearchView`, `SettingsView`, `WelcomeView`.

## Critical gotchas & hard-won lessons

**Never edit `ibis.xcodeproj/project.pbxproj` directly.** A hook blocks it and it
can crash Xcode. There is no MCP tool for target build settings — when one is
needed (bundle id, entitlements, platforms, packages), give the user precise
steps to change it in Xcode and stop. New source files/assets are picked up
automatically (the target uses a `PBXFileSystemSynchronizedRootGroup`), so just
write them under `ibis/`.

**Line-number gutter (`LineNumberRulerView`):** draw via
`drawHashMarksAndLabels(in:)`, **never** override `NSView.draw(_:)` — the number
drawing forces TextKit layout, and doing that from `draw(_:)` corrupts the shared
layout and blanks the editor text + breaks the pane. The stray "line through the
leftmost tab" was **not** the split divider — it was `NSRulerView`'s private
`drawSeparatorInRect:` hook (macOS 26 scroll-edge "pocket" machinery) drawing the
ruler's trailing separator up through the header band. Fix: override
`@objc(drawSeparatorInRect:)` as a no-op.

**Editor `NSTextView` setup:** must set `isVerticallyResizable`, `minSize`,
`maxSize`, `autoresizingMask`, and an initial frame, or it lays out at zero
height and can't be clicked/focused. Reset horizontal scroll with
`textView.scrollRangeToVisible(_:)`, **never** `NSClipView.setBoundsOrigin`
(that pushes content out of view).

**Chrome alignment:** the sidebar mode switcher and the editor tab-bar header
must both use `EditorChrome.headerHeight` with a `Divider()` immediately after
and horizontal padding only, so their separators line up across the split view.

**File browser is `NSOutlineView`-backed** (`FileOutlineView`), not a SwiftUI
`List` — SwiftUI can't do native double-click rename, Finder drag in/out, or
⌥-copy, and a `List` row's double-tap gesture breaks single-click selection.
Context menu goes through the standard `.menu` + `menuNeedsUpdate` path (not a
`menu(for:)` override) so AppKit can augment it with system items.

**"Ask Siri" / Apple Intelligence context-menu item (macOS 27):** there is **no**
`NSMenu`/`NSMenuItem` API for it — the system injects it when a view is annotated
with an App Intents entity. Do NOT confuse this with donating actions to Siri
(that needs custom App Intents). The mechanism: import `AppIntents` alongside
`AppKit` (activates the `_AppIntents_AppKit` cross-import overlay), define a
`WorkspaceFileEntity: FileEntity` (built-in AppIntents protocol; its
`FileEntityIdentifier` carries the file URL so Siri can read the file), and set
`NSOutlineView.appIntentsDataSource` to a coordinator conforming to
`NSTableViewAppIntentsDataSource`, returning
`EntityIdentifier(for: WorkspaceFileEntity.self, identifier: .file(url:))` per row.
App Intents metadata extraction runs automatically at build. The item is
system-gated (macOS 27 + Siri/Apple Intelligence enabled) and cannot be
force-injected or unit-tested — verify empirically.

**Window/session restoration:** the idiomatic approach is native
`WindowGroup(for:)` scene restoration (respects the system "Close windows when
quitting" setting) **plus** security-scoped bookmarks so restored windows regain
file access — not a bespoke session store. (A hand-rolled one was removed.)

**Debugging opaque rendering issues:** when reading code and theorizing fails
(as with the tab-bar line), **instrument the running app** — dump the live AppKit
view tree and CALayer tree (class, frame, owner) and pixel-probe. That found the
culprit immediately when source-reading had a 100% failure rate.

## Dependencies

- **HighlighterSwift** (`import Highlighter`) — highlight.js via JavaScriptCore.
  Added as an SPM package (user adds packages in Xcode). `Package.resolved` is
  committed.
