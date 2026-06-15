# ghostty-win

A native Windows build of the [Ghostty](https://ghostty.org) terminal emulator,
with a workspace sidebar, embedded browser panes, and per-tab WSL backends.

> [!IMPORTANT]
> **This is an unofficial community build. It is not affiliated with,
> endorsed by, or supported by the Ghostty project or its maintainers.**
> Please do not report issues with this build to the upstream Ghostty
> project — file them here instead. "Ghostty" is the name of the upstream
> project; this repository is an independent Windows port.

## What this is

Ghostty's terminal core, font stack, and ConPTY layer already compile on
Windows upstream. This project adds the missing native Windows application
layer — a Win32 `apprt` (application runtime) — on top of that core. It is
derived from the work in [InsipidPoint/ghostty-windows](https://github.com/InsipidPoint/ghostty-windows),
synced against [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty),
and extended with the features below.

## Features

- **Workspaces** — a window holds workspaces (sidebar rows), each with its
  own set of tabs, each tab splitting into panes. The **workspace sidebar**
  (on by default) has numbered rows with per-workspace status dots
  (bell / process-exited, aggregated over the workspace's tabs),
  rename (double-click or right-click), hover close-`×`, drag-to-reorder,
  and drag-to-resize. Disable with `window-show-sidebar = false`.
- **Per-workspace tab bar** — the top tab bar coexists with the sidebar and
  shows the active workspace's tabs, with close-`×`, drag-to-reorder,
  double-click rename, and `+`/`▾` new-tab buttons; `alt+1`–`alt+8` jump to
  tabs within the active workspace. `window-show-tab-bar = always/auto/never`
  applies per the active workspace's tab count.
- **Backend picker** — open a new tab, workspace, or split as your default
  shell, PowerShell, cmd, any installed **WSL distribution** (enumerated live
  from the registry), or an embedded **browser**. The `▾` chevron on the
  sidebar's new-workspace row creates a **new workspace** whose first tab
  runs the chosen backend; the tab bar's `▾` segment opens it as a new tab
  in the active workspace; a terminal's *Split ... With...* menu opens it as
  a split. Plain splits inherit their source pane's backend.
- **Browser panes (WebView2)** — open a Chromium-based browser as a split
  or a tab, with an address bar and close-`×`. Requires the Microsoft Edge
  WebView2 Runtime (preinstalled on Windows 11).
- **`ghostty +browser` CLI** — script the embedded browser panes of a
  running instance over a named pipe: `open` / `navigate` / `eval` /
  `snapshot` / `click` / `fill` / `list`.
- **Agent orchestration CLI** — drive a running instance from a script or
  another agent over the same pipe: `+workspace` / `+tab` / `+split` /
  `+surface` (create and focus panes), `+send` (type into a pane),
  `+read-screen` (read another pane's screen — the agent-reads-agent
  primitive), `+status` / `+log` (per-tab status, progress, and a ring log
  surfaced in the sidebar), `+notify` (attention rings), and `+session` /
  `+hooks` (capture & resume Claude Code / Codex sessions).
- **Per-pane corner buttons** — every pane shows an always-visible,
  cmux-style action cluster in its top-right corner: **New Terminal**,
  **New Browser**, **Split Right**, **Split Down**.
- **Input gestures** — `ctrl+b` toggles the sidebar, `ctrl`+scroll zooms the
  font, and smart `ctrl+c` / `ctrl+v` copy/paste (`ctrl+c` still sends
  `SIGINT` when nothing is selected).
- **Notifications** — clickable desktop notifications that jump to the
  originating tab (across workspaces), plus an in-app notifications panel
  in the sidebar.
- **Terminal context menu** — right-click for copy / paste / select-all /
  splits / new tab / close pane, with the usual mouse-reporting passthrough.
- **Working-directory inheritance** — new tabs and splits open in the
  current directory (OSC 7), including from PowerShell.
- **Window state persistence** — size, position, and maximized state are
  restored across restarts (`%LOCALAPPDATA%\ghostty\window-state`).
- **Settings gear** — open or reload your config, or set the default shell,
  from the sidebar.

See [`docs/WINDOWS_FEATURES.md`](docs/WINDOWS_FEATURES.md) for the full
feature guide and a keyboard/mouse cheat sheet.

## Building

Requires [Zig](https://ziglang.org/download/) **0.15.2**.

```powershell
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

The executable lands at `zig-out\bin\ghostty.exe`. Browser panes also need
`WebView2Loader.dll` (from the [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2)
NuGet package, `build/native/x64/`) beside the executable.

> [!NOTE]
> On a Windows host the bare `x86_64-windows` target resolves to the MSVC
> ABI and fails to link (`undefined symbol: WinMain`). Pass
> `-Dtarget=x86_64-windows-gnu` explicitly.

### Installer

`dist\windows\release.ps1` builds a ReleaseFast binary, stages it with
`WebView2Loader.dll`, and (with [Inno Setup 6](https://jrsoftware.org/isdl.php)
installed) produces a per-user installer under `dist\windows\output\`. The
installer never modifies `PATH` or other environment variables and preserves
your config on uninstall. Releases are currently unsigned, so SmartScreen
will warn on first run.

## Staying in sync with upstream

```powershell
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
git merge upstream/main
```

## Development and AI assistance

This port was developed with substantial AI assistance (Claude Code).
Per upstream Ghostty's contribution rules, any code proposed back to
ghostty-org/ghostty must be fully understood and disclosed by the human
submitter — see [`AI_POLICY.md`](AI_POLICY.md). That policy governs
contributions to *upstream*; it is reproduced here because parts of this
work may be upstreamed over time.

## License

[MIT](LICENSE) — Copyright © 2024 Mitchell Hashimoto and Ghostty
contributors, and the contributors to this Windows port. The Ghostty
name and logo belong to the upstream project and are not licensed for
use by this build beyond nominative reference.
