# ghostty-win

A native Windows build of the [Ghostty](https://ghostty.org) terminal emulator,
with a session sidebar, embedded browser panes, and per-tab WSL backends.

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

- **Session sidebar** — a vertical list of sessions with numbered rows,
  per-session status dots (bell / process-exited), drag-to-resize, and
  `alt+1`–`alt+8` jumping. Toggle with `window-show-sidebar = true`.
- **Backend picker** — open a new tab or split as your default shell,
  PowerShell, cmd, any installed **WSL distribution** (enumerated live from
  the registry), or an embedded **browser**. Reachable from a dropdown
  chevron on the new-session row, the tab bar's split-button, or
  right-click. Splits inherit their source pane's backend.
- **Browser panes (WebView2)** — open a Chromium-based browser as a split
  or a tab, with an address bar. Requires the Microsoft Edge WebView2
  Runtime (preinstalled on Windows 11).
- **Notifications** — clickable desktop notifications that jump to the
  originating tab, plus an in-app notifications panel in the sidebar.
- **Terminal context menu** — right-click for copy / paste / select-all /
  splits / new tab, with the usual mouse-reporting passthrough.
- **Working-directory inheritance** — new tabs and splits open in the
  current directory (OSC 7), including from PowerShell.
- **Settings gear** — open or reload your config from the sidebar.

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
