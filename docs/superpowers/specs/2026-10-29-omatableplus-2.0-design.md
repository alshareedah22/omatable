# OmaTablePlus 2.0: its own app, still an Omarchy plugin

Date: 2026-10-29 · Status: approved 2026-10-29 (with all four pro additions)

## Why

Today the OmaTablePlus window lives inside the `omarchy-shell` process (a `panel` plugin): a shell
crash takes open queries with it, the window has no app identity (no launcher entry, no icon in
window lists, no window rules), and its memory stays in the shell. The user wants it to be a real
app that is still installed, updated and listed as an Omarchy plugin, with zero configuration
and light on the machine (the rules OmaDBngin 1.7 set).

## Verified on 2026-10-29 (spike)

- A separate `quickshell -p <dir>` process opens a normal tiled Hyprland window.
- `//@ pragma AppId omatableplus` makes its Hyprland class `omatableplus` (launcher icon, window
  rules). `//@ pragma UseQApplication` enables native menus and dialogs.
- Omarchy's `qs.Commons` and `qs.Ui` load in that process when the config folder links them
  (`Commons`, `Ui` → `$OMARCHY_PATH/shell/…`): theme colors, fonts, buttons and fields work and
  follow theme changes (they read the theme files themselves). The bare name `Color` does not
  resolve in the root file: the root uses a qualified import.
- An `IpcHandler` in the app answers `qs -p <dir> ipc call …`: a second launch focuses the first.

## Shape

```
blackcode.omatableplus/            (the plugin, as installed by omarchy plugin add)
  manifest.json                    kinds: bar-widget, panel (panel = thin forwarder, see below)
  Bar.qml                          bar icon: opens/focuses the app; status; quick actions
  Panel.qml                        forwarder: summon payloads (OmaDBngin) -> the app
  omatableplus                     launcher script: run, focus, setup, uninstall
  app/shell.qml                    the app's root: ShellRoot + window + IPC
  qml/ …                           today's UI, unchanged where possible
  omatableplus/ …, tablectl        the Python helper, unchanged
```

The launcher builds a runtime config folder once per plugin version in
`~/.local/state/omatableplus/app/` with links to `app/shell.qml`, `qml/`, the icon, and Omarchy's
`Commons` and `Ui`, then runs `quickshell -p <it> -n -d`. `-n` keeps one instance; if one is
running, the launcher calls its IPC (`focus`, or `open <connection>`) instead.

## Features

### 1. A real app
- Own process and window: tiles, floats, goes fullscreen, moves between workspaces like any app.
  A crash closes only OmaTablePlus.
- **Launcher entry** in SUPER+SPACE → Apps, with the OmaTablePlus icon, and quick actions
  *New query* and *Connections*.
- One instance: launching again (launcher, bar, OmaDBngin) focuses the window; a connection
  payload opens that connection in it.
- Window size and position kept between runs (Hyprland rules written by setup are not needed:
  the app restores its own size).
- Closing the window ends the app and its helper: nothing runs while it is closed.

### 2. Zero configuration
`omarchy plugin add …/omatableplus --enable` and it is ready. On the plugin's first start
(`omatableplus setup`, run once by the bar widget, marker file):
- writes the launcher entry `~/.local/share/applications/omatableplus.desktop`;
- installs the database drivers in the background (today this happens on first open), so the
  first open is instant;
- adds SUPER+ALT+T (opens OmaTablePlus) to `~/.config/hypr/bindings.lua` only if free.
`omatableplus uninstall` removes the entry, the shortcut and the runtime folder.

### 3. Light on the machine
- Closed: no process at all besides the bar icon (no polling).
- Open: the helper as today (one Python process); no timers that repaint while idle.
- Measured with `tools/measure-load` like OmaDBngin: shell CPU and RSS must not grow from the
  plugin; the app's own idle CPU ≤ 0.5 % of a core.

### 4. Bar icon
- Click opens or focuses the app. Shows a dot while the app runs.
- Right-click: recent connections, *New query*, *Open app*.

### 5. Compatibility
- OmaDBngin's *Open in OmaTablePlus* keeps working unchanged: the `panel` entry point stays as a
  forwarder (summon payload → the app).
- Saved connections, history, keyring passwords and the driver venv stay where they are.

## Pro additions inside the app (all four chosen for 2.0)

- Native menu bar (File, Edit, View, Connection, Help) with the existing shortcuts listed.
- Native file dialogs (open/save .sql, import CSV, export, backups) instead of the in-app picker.
- Several windows: *Open connection in new window*.
- Restore last session: reopen the connections and tabs that were open.

## Out of scope

Rewriting the UI or the helper, packaging outside Omarchy (AUR), multi-user/remote features.
