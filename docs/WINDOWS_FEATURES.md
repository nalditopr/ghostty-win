# Ghostty for Windows — Community Build Features

This page documents the features added on top of the base Windows port in this
fork (the `cmux-features` branch). This is an **unofficial community build** of
the Ghostty terminal emulator. It is not affiliated with, endorsed by, or
supported by the Ghostty project — please do not report issues with this build
upstream.

## Session Sidebar

A cmux-style vertical session list on the left edge of the window. When
enabled it **replaces the top tab bar** — each tab becomes a numbered session
row.

Enable it in your config:

```ini
window-show-sidebar = true
```

- **Session rows** show a number (1–9 for the first nine rows, matching the
  default `alt+N` keybinds), the tab title, and an accent bar on the active
  row. Click a row to switch to it.
- **`+ New session`** row at the bottom of the list opens a new tab.
- **Status dots** appear to the left of the title:
  - **Amber dot** — the bell rang in that tab (only shown if the tab wasn't
    both active and in the foreground window, where you'd already see it).
  - **Red dot** — the shell process in that tab exited.
  - The dot clears when you select the tab.
- **Right-click a row** for the tab menu: *Close Tab*, *Close Other Tabs*,
  *Close Tabs to the Right*, *New Tab*.
- **Drag to resize**: grab the narrow band along the sidebar's right edge
  (the cursor changes to horizontal resize arrows) and drag. Width is clamped
  to 120–400 px. The dragged width lasts until the next config reload, which
  re-applies your configured `window-sidebar-width`.
- **Footer icons** (bottom strip): bell 🔔 (notifications pane), gear ⚙
  (settings), globe 🌐 (browser pane). Note: the bell and globe glyphs depend
  on a system symbol/emoji font and may render as boxes on stripped-down
  Windows installs.

Both sidebar options reload live (`reload_config`, default `ctrl+shift+,`).

## Notifications Pane

Click the **bell icon** in the sidebar footer to toggle a notifications panel
(about 40% of the window height, above the footer).

- Collects the most recent **64** events, newest first:
  - **Amber dot** — bell rang in a tab.
  - **Red dot** — a shell process exited.
  - **Blue dot** — a desktop notification sent by a terminal program (OSC).
- Each entry shows the tab title over the notification text.
- **Click an entry** to jump to the tab that produced it (the window is
  restored and brought to the foreground if needed).
- **Clear** (top-right of the panel header) empties the log.
- The bell icon shows an **amber unread badge** with a count (capped at "9+");
  opening the panel marks everything read.

## Settings Gear

The **gear icon** in the sidebar footer:

- **Left-click** — opens your Ghostty config file in its default editor.
- **Right-click** — menu with:
  - *Open config* — same as left-click.
  - *Open config folder* — opens the containing folder in Explorer.
  - *Reload config* — applies config changes immediately (same code path as
    the `reload_config` keybind).
  - *Set default shell...* — opens a picker (PowerShell / Command Prompt /
    each installed WSL distribution) and makes that the shell every new tab
    and split launches. See [Default Shell](#default-shell) below.

## Default Shell

By default, new terminal tabs and splits launch **`cmd.exe`** on Windows. The
shell is controlled by the standard Ghostty
[`command`](https://ghostty.org/docs/config/reference#command) config option,
which is honored on Windows for every new terminal surface (new windows, tabs,
and splits). Set it once and all default sessions use it:

```ini
# PowerShell 7+ (falls back to Windows PowerShell if pwsh isn't installed)
command = pwsh.exe

# Or classic Windows PowerShell
command = powershell.exe

# Or a WSL distribution
command = wsl.exe --cd ~ -d Ubuntu
```

You can set it two ways:

- **From the GUI** — right-click the gear ⚙ in the sidebar footer and choose
  **Set default shell...**, then pick PowerShell, Command Prompt, or one of
  your installed WSL distributions. This writes the `command` key into your
  config file (updating the existing line if present, otherwise appending it,
  and preserving everything else) and reloads the config, so it takes effect
  for the next tab/split you open. Existing tabs keep their current shell.
- **By editing the config** — add a `command = ...` line yourself and reload
  (gear → *Reload config*, or the `reload_config` keybind).

The value is a program name (looked up on `PATH`) optionally followed by
arguments, exactly as the `command` option documents upstream. The
**backend picker** (the `+`/`▾` new-session menu and the *Split ... With...*
menu) still lets you launch a **one-off** PowerShell/cmd/WSL session for a
single tab or split without changing the default.

## Terminal Right-Click Menu

Right-click inside a terminal pane for a context menu:

- **Copy** (greyed out when nothing is selected), **Paste**, **Select All**
- **Split Right**, **Split Down**
- **New Tab**
- **Open Browser Split** (menu command ID 9107, useful for UI automation)

The menu opens on button **release**, following the Win32 convention.

**Mouse-reporting passthrough:** if the foreground program (vim, htop, etc.)
has enabled mouse reporting, the right-click is sent to that program instead
and no menu appears. Hold **Shift+right-click** to bypass mouse reporting and
force the menu (standard Ghostty `mouse-shift-capture` semantics — programs
or your config can claim Shift, see that option's docs).

All menu items run through the same core binding-action machinery as
keybinds, so they behave identically to the equivalent shortcuts.

## Clickable Desktop Notifications

Desktop notifications raised by terminal programs (e.g. OSC 9) appear as
Windows balloon notifications. **Clicking the balloon jumps to the tab that
sent it** — the window is restored, brought to the foreground, the tab is
selected, and the terminal is focused. Up to 8 balloons can be in flight at
once, and each is also mirrored into the sidebar notifications pane.

## Browser Panes (WebView2)

Open a web browser inside a split, next to your terminals:

- **Globe icon** in the sidebar footer, or **right-click a terminal → Open
  Browser Split**, opens a browser pane to the right of the active pane.
- **Address bar** at the top of the pane:
  - Type a URL and press **Enter** to navigate. `https://` is prepended
    automatically if you omit the scheme.
  - Press **Escape** to move focus from the address bar into the page.
  - After navigation the bar reflects the final URL (it won't overwrite text
    you are currently typing).
- The pane's tab title follows the page's document title.
- Browser panes live in the split tree like terminal panes and start at
  `about:blank`.

**Requirements:**

- `WebView2Loader.dll` must sit next to `ghostty.exe`. The installer ships it
  (it comes from the `Microsoft.Web.WebView2` NuGet package and is
  redistributable per the WebView2 SDK license).
- The **WebView2 Evergreen runtime** must be installed system-wide. It ships
  with Windows 11 and is preinstalled on most updated Windows 10 systems.
- If the loader or runtime is missing, Ghostty still starts normally (the DLL
  is loaded on demand); opening a browser pane then shows
  **"WebView2 runtime unavailable"** in the pane instead of failing.

## WSL Distributions

The build enumerates your installed WSL distributions (name, WSL 1/2 version,
and which one is the default) directly from the registry (`src/os/wsl.zig`),
and launches a shell in one with `wsl.exe --cd ~ -d <Name>`. Installed distros
appear in two places:

- The **new-session backend picker** (right-click the `+`/`▾` new-session
  button or row, or use a terminal's *Split ... With...* menu) lists each
  distro for a one-off tab or split.
- The gear's **Set default shell...** picker lists each distro to make it the
  shell every new session uses (see [Default Shell](#default-shell)).

You can also set `command = wsl.exe --cd ~ -d Ubuntu` (or your distro) directly
in your config.

## Upcoming: Working-Directory Inheritance (OSC 7) + PowerShell Integration

These have landed on the upstream-sync branch and will arrive in a future
build:

- **OSC 7 working-directory reporting on Windows** — `file://` URIs are
  parsed into Windows paths (drive letters, UNC shares, percent-decoding), so
  **new tabs and splits inherit the current working directory**.
- **PowerShell shell-integration fixes** — the OSC 7 emitter now
  percent-encodes path segments, reports UNC paths for network drives, and
  resets the directory on non-filesystem providers (e.g. registry drives).
- **PowerShell `ssh` wrapper** — `ssh` is wrapped with `ghostty +ssh` (when
  the OpenSSH client is on PATH), handling TERM fallback, environment
  propagation, and terminfo installation per your `shell-integration-features`
  flags (`ssh-env` / `ssh-terminfo`).

## Installer

Releases are packaged with Inno Setup via `dist\windows\release.ps1`:

```powershell
# Full build + package
powershell -ExecutionPolicy Bypass -File dist\windows\release.ps1

# Package an existing build with an explicit version
.\dist\windows\release.ps1 -Version 1.2.0 -SkipBuild
```

The script builds with `zig build -Dapp-runtime=win32
-Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`, stages `ghostty.exe`,
`WebView2Loader.dll`, and the `share\` resources (terminfo, themes, shell
integration), then compiles `ghostty-windows-x64-<version>-setup.exe` into
`dist\windows\output\` and prints its SHA256. Inno Setup 6 is required
(`winget install -e --id JRSoftware.InnoSetup`).

What the installer does (and doesn't do):

- **Per-user install, no admin/UAC** — installs to
  `%LOCALAPPDATA%\Programs\Ghostty`, with a Start Menu shortcut and an
  optional desktop icon. Requires Windows 10+ on x64 (or Windows 11 ARM64 via
  x64 emulation).
- **Unsigned** — Windows SmartScreen will warn on first run. Click
  *More info → Run anyway*. Verify the SHA256 printed by the build script if
  in doubt.
- **Never touches PATH** — the installer makes **no environment-variable
  changes of any kind**, by hard rule (`ChangesEnvironment=no`, no registry
  writes). Add it to PATH yourself if you want `ghostty` on the command line.
- **Uninstall preserves your data** — your config and cache in
  `%LOCALAPPDATA%\ghostty` and WebView2 user-data folders are left intact.

## Configuration Example

```ini
# Session sidebar instead of the top tab bar
window-show-sidebar = true

# Sidebar width in unscaled pixels (clamped to 120–400; scaled by DPI)
window-sidebar-width = 260

# Default shell for new tabs/splits (defaults to cmd.exe on Windows).
# Can also be set from the gear menu's "Set default shell..." entry.
command = pwsh.exe
```

Apply with the gear menu's *Reload config* or the `reload_config` keybind.

## Keyboard & Mouse Cheat Sheet

| Input | Where | Action |
|---|---|---|
| `Alt+1` … `Alt+8` | anywhere | Jump to session/tab 1–8 |
| `Alt+9` | anywhere | Jump to the last session/tab |
| Left-click row | sidebar | Switch to that session |
| Left-click `+ New session` | sidebar | New tab |
| Right-click row | sidebar | Close Tab / Close Other Tabs / Close Tabs to the Right / New Tab |
| Drag right edge | sidebar | Resize sidebar (120–400 px) |
| Left-click bell 🔔 | sidebar footer | Toggle notifications pane (marks all read) |
| Left-click entry | notifications pane | Jump to the source tab |
| Left-click `Clear` | notifications pane | Empty the notification log |
| Left-click gear ⚙ | sidebar footer | Open config file |
| Right-click gear ⚙ | sidebar footer | Open config / Open config folder / Reload config / Set default shell... |
| Left-click globe 🌐 | sidebar footer | Open a browser split |
| Right-click | terminal | Copy / Paste / Select All / Split Right / Split Down / New Tab / Open Browser Split |
| `Shift`+right-click | terminal | Force the context menu when a program captures the mouse |
| `Enter` | browser address bar | Navigate (adds `https://` if no scheme) |
| `Escape` | browser address bar | Move focus into the web page |
| Click balloon | desktop notification | Jump to the tab that sent it |
