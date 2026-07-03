# Ibis — a text editor for developers

A lightweight, folder-oriented macOS code editor (not an IDE): open files/folders,
browse a hierarchical file tree, edit in tabs and resizable split panes, syntax
highlighting, project search, an integrated terminal (tabs + one-key launch of a
configured agent), and a live Git status bar. Opens from Finder, the `ibis` CLI,
the Services menu, and Shortcuts/Siri App Intents; confirms unsaved changes on
close. **No** run/debug, LSP, or plugin marketplace.

- **Platform:** macOS only, deployment target **macOS 27**, SwiftUI + AppKit.
- **Hero color:** kelly green (`Color.ibisKelly`), used sparingly for accents.
- **Not sandboxed.** The App Sandbox was removed so the integrated terminal can
  spawn a real, useful login shell (a sandboxed child shell is crippled — see the
  terminal gotcha below). Ships as a Developer ID-signed, **notarized** app
  distributed from the web, **not** the Mac App Store (same model as VS Code /
  iTerm2 / Xcode). Hardened Runtime stays ON (required for notarization).
  The leftover `files.bookmarks.app-scope` entitlement key is a now-harmless no-op.

## Build & run

Use the Xcode MCP tools (this project is developed from inside Xcode):
- `BuildProject` to compile, `RunProject` to launch, `XcodeRefreshCodeIssuesInFile`
  for quick per-file diagnostics, `RunCodeSnippet` to try code in-context.
- `DocumentationSearch` for Apple API docs — **always** search for macOS 26/27
  APIs rather than relying on training data; many APIs here post-date the cutoff.

## Architecture (all sources under `ibis/`)

- **App/** — `IbisApp` (`@main`; four scenes: a compact non-resizable `Window`
  launcher, a `WindowGroup(for: WorkspaceRef)` for editor windows at a 4:3
  `defaultSize`, a content-sized "Keyboard Shortcuts" `Window`, and `Settings`),
  `AppDelegate` (Finder/CLI opens via `LaunchRouter`; also the "Open in Ibis"
  Services provider), `IbisCommands` (full menu bar, targets the frontmost window
  via focused scene values), `FocusedValues`, `LaunchRouter` (open hand-off; an
  optional `runAgent` flag, consumed once, launches the agent on open),
  `OpenPathIntent`/`OpenInAgentIntent` (App Intents), `IbisShortcuts`
  (`AppShortcutsProvider`).
- **Models/** — `@Observable`, `@MainActor`. `Workspace` (root, file tree, pane
  layout, file ops, FSEvents, `terminal` dock, `git` status, unsaved-change
  prompts), `FileNode` (lazy tree node), `EditorPane`/`EditorLayout`,
  `OpenDocument`, `AppSettings` (UserDefaults-backed), `ProjectSearchModel`,
  `WorkspaceRef`, `WorkspaceFileEntity` (App Intents), `TerminalDock`/
  `TerminalSession` (integrated terminal; mirror the pane/tab model),
  `GitStatusModel` (shells out to `git`), `WorkspaceStateStore` (per-root tab/pane
  restoration snapshot in UserDefaults).
- **FileSystem/** — `FileTreeLoader`, `FileSystemWatcher` (FSEvents),
  `FileOperations`, `SecurityScopedAccess`.
- **Syntax/** — `Language` (ext → highlight.js name), `SyntaxHighlighter`
  (actor wrapping the **HighlighterSwift** package; engine is swappable behind
  this seam), `ProjectSearch`.
- **Views/** — `WorkspaceView` (NavigationSplitView; editor + terminal dock
  [bottom or trailing] + `StatusBarView` git bar), `FileOutlineView`
  (NSOutlineView-backed browser), `CodeEditorView` + `LineNumberRulerView`
  (NSTextView editor), `EditorAreaView`/`EditorPaneView`/`TabBarView`,
  `TerminalDockView`/`TerminalSessionView`/`TerminalTabBarView` (SwiftTerm-backed),
  `StatusBarView`, `ProjectSearchView`, `SettingsView`, `WelcomeView` (the launcher),
  `ShortcutsHelpView` (Help ▸ Keyboard Shortcuts).
- **Support/** — `EditorChrome`, `Color+Ibis`, `FileIconProvider`,
  `ShellResolver` (login shell + environment for the terminal), `WindowCloseGuard`
  (window-close confirmation, see gotcha), `SharePresenter` (holds an
  `NSSharingServicePicker` alive during presentation).

## Critical gotchas & hard-won lessons

**Never edit `ibis.xcodeproj/project.pbxproj` directly.** A hook blocks it and it
can crash Xcode. There is no MCP tool for target build settings — when one is
needed (bundle id, entitlements, platforms, packages), give the user precise
steps to change it in Xcode and stop. New source files/assets are picked up
automatically (the target uses a `PBXFileSystemSynchronizedRootGroup`), so just
write them under `ibis/`.

**Info.plist is a real, merged file.** `INFOPLIST_FILE = ibis/Info.plist` with
`GENERATE_INFOPLIST_FILE = YES` — Xcode uses the file as the base and merges the
`INFOPLIST_KEY_*` generated keys on top, so the file only holds what codegen can't
express: `CFBundleDocumentTypes` (folder + text/source/data), the `NSServices`
"Open in Ibis" entry, and Sparkle keys. Traps: the service's `NSPortName` must
equal `CFBundleName` (`ibis`, lowercase) or the menu item appears but does nothing;
Services registration is cached, so a new item needs `pbs -flush` or a launch of
the built app to show up. The Sparkle keys (`SUFeedURL`, `SUPublicEDKey`) are
**placeholders** — the Sparkle package isn't wired up yet.

**"Open in Ibis" Service:** declared in `NSServices` (above) + handled by
`AppDelegate.openInIbis(_:userData:error:)`, registered via
`NSApp.servicesProvider = self`. It reads file URLs off the pasteboard and routes
them through `LaunchRouter`, same as Finder/CLI/App-Intent opens.

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

**Windows & restoration:** two scenes, because splash and editor need different
sizing/resizability (a single `WindowGroup` can't vary those). A `Window`
launcher (`WelcomeView`, `windowResizability(.contentSize)`, fixed-width content,
`restorationBehavior(.disabled)`) is the primary scene, so it opens on a plain
launch; it dismisses itself (`@Environment(\.dismiss)`) when a file/folder opens
and drains the `LaunchRouter` for CLI/Finder opens. Editor windows come from the
`WindowGroup(for: WorkspaceRef)` with a 4:3 `defaultSize`. *Window* restoration is
native `WindowGroup(for:)` scene restoration (respects the system "Close windows
when quitting" setting); no security-scoped bookmarks needed now that the app is
unsandboxed. On top of that, `WorkspaceStateStore` persists each root's **tab/pane
layout + selection** (keyed by root path in UserDefaults, capped to 20 roots) so a
reopened folder restores its editors — the window frame is native, the contents
are this store. `File ▸ New Window` opens the launcher.

**Integrated terminal (SwiftTerm):** each `TerminalSession` owns a
`LocalProcessTerminalView` that forks the user's login shell in a PTY
(`ShellResolver`: `getpwuid` → `$SHELL` → `/bin/zsh`, launched with a leading-`-`
argv[0] like Terminal.app, `TERM=xterm-256color`, cwd = workspace root). The App
Sandbox **must be off** — a sandboxed child shell inherits the container and is
useless (no PATH tools, no filesystem access, `tty pgrp` errors).

**Never detach a SwiftTerm view from the window** — doing so resets its buffer,
so the running process appears to lose all scrollback/history. This bit us three
times: (1) switching terminal tabs via a single `.id()`-swapped slot, (2) hiding
the dock by removing it from the view tree, and (3) flipping the dock between
bottom and trailing by switching `VStack`↔`HStack` (a container-type change breaks
subtree identity). Fixes, all keeping every terminal view **mounted at all times**:
tabs live in a `ZStack` (only the active shown via `opacity`/`allowsHitTesting`);
the dock stays in the layout even when hidden via a nested-frame trick
(`.frame(height: h).frame(height: visible ? h : 0).clipped()`) that collapses the
*space* to zero while keeping the terminal laid out at full height (also avoids a
resize-to-zero SIGWINCH); and orientation uses **`AnyLayout`** (swap
`HStackLayout`/`VStackLayout` on one container) which preserves subview identity.
The dock is a plain stack + a custom drag handle, **not** `VSplitView`, because
VSplitView can't collapse a pane to 0.

**Integrated terminal, continued:** a `TerminalSession` can run a specific command
instead of an interactive shell — that's how "Open in Agent" works: it launches
the configured agent through a login shell (`shell -l -c "<cmd>"`, so PATH
resolves) in a new tab rooted at the workspace. When any shell/agent exits,
`processTerminated` flips `isRunning` and the dock overlays a "Shell exited —
Restart" affordance (Return on the active terminal); Restart reuses the same view.
Git status refreshes off the same FSEvents watcher, so committing/branch-switching
in a terminal updates the status bar within the watcher's latency.

**Menu commands that target a window need `focusedSceneValue`, not
`focusedValue`.** `@FocusedValue`-published values only resolve when a view
*inside* the window holds focus — so with a folder open but no editor focused,
every window-targeting command (Show Terminal, Save As, Split, …) greyed out.
`WorkspaceView` publishes `activeWorkspace`/`sidebarMode` via `.focusedSceneValue`
so they resolve whenever the window is frontmost, regardless of inner focus.
(Read side is still `@FocusedValue` in `IbisCommands`.)

**Unsaved-changes confirmation on close.** Tab close routes through
`Workspace.requestCloseTab` (skips the prompt if the file is still open in another
pane). Window close is the hard part: SwiftUI exposes no "window will close" hook,
so `WindowCloseGuard` (an `NSViewRepresentable` in the window background) installs
an **`NSWindowDelegate` proxy** on the host window that implements
`windowShouldClose` and **forwards every other delegate method to SwiftUI's own
delegate** (`forwardingTarget(for:)` + `responds(to:)`), so scene management isn't
disturbed. It can veto the close and re-issue it (via a `proceed` closure /
`performClose`) once the confirmation resolves. Don't just replace `window.delegate`
outright — you'll break SwiftUI window handling.

**Debugging opaque rendering issues:** when reading code and theorizing fails
(as with the tab-bar line), **instrument the running app** — dump the live AppKit
view tree and CALayer tree (class, frame, owner) and pixel-probe. That found the
culprit immediately when source-reading had a 100% failure rate.

## Dependencies

- **HighlighterSwift** (`import Highlighter`) — highlight.js via JavaScriptCore.
  Added as an SPM package (user adds packages in Xcode). `Package.resolved` is
  committed.
- **SwiftTerm** (`import SwiftTerm`) — VT100/xterm terminal emulator + PTY host
  (`LocalProcessTerminalView`). SPM package; pulls in `swift-argument-parser`.
  Requires the sandbox to be off (see terminal gotcha). `Package.resolved`
  committed.
