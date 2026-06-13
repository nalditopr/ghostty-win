# Ghostty for Windows — Community Build Features

This page documents the features added on top of the base Windows port in this
fork (the `cmux-features` branch). This is an **unofficial community build** of
the Ghostty terminal emulator. It is not affiliated with, endorsed by, or
supported by the Ghostty project — please do not report issues with this build
upstream.

## The Window Model: Workspaces → Tabs → Panes

A window is organized in three levels:

1. **Workspaces** — listed as rows in the vertical **sidebar** on the left
   edge. Exactly one workspace is active at a time; each window starts with
   one (up to 16 per window).
2. **Tabs** — each workspace has its own set of tabs, shown in the **top tab
   bar** (which sits to the right of the sidebar). Switching workspaces swaps
   the whole tab set.
3. **Panes** — each tab splits into terminal and browser panes, exactly as
   before.

The quick terminal is exempt from all of this chrome: it is a single-surface
popup with no sidebar and no tab bar.

## Workspace Sidebar

A cmux-style vertical workspace list on the left edge of the window, one row
per workspace. **Enabled by default**; disable it for a classic look:

```ini
window-show-sidebar = false
```

- **Workspace rows** show a number (1–9 for the first nine rows), the
  workspace name (falling back to "Workspace N" when unnamed), and an accent
  bar on the active row. Click a row to switch to that workspace.
- **Rename a workspace** by double-clicking its row, or right-click →
  *Rename Workspace*. An inline edit box opens over the row.
- **Close a workspace** with the **× button** that appears at the right edge
  of a row on hover (red when the cursor is over it), or right-click →
  *Close Workspace*. Closing a workspace closes all of its tabs; closing the
  last workspace closes the window.
- **Drag a row** up or down to reorder workspaces (a short drag threshold
  keeps plain clicks as selections).
- **Right-click a row** for the workspace menu: *Rename Workspace*, *Close
  Workspace*, *New Workspace* (menu command IDs 9501–9503, useful for UI
  automation).
- **Status dots** appear to the left of the name and aggregate across **all
  tabs in that workspace** (an exited tab outranks a bell):
  - **Amber dot** — the bell rang in one of the workspace's tabs.
  - **Red dot** — a shell process exited in one of the workspace's tabs.
  - The dot clears as you visit the affected tabs (a tab's status clears
    when it is selected).
- **`+ New workspace`** row at the bottom of the list creates a new workspace
  with one tab and switches to it.
- **▾ chevron** at the right edge of the `+ New workspace` row opens the
  **backend picker** and creates a **new workspace** whose **first tab runs
  the chosen backend** (Default / PowerShell / Command Prompt / each WSL
  distro / Browser). Right-clicking the row opens the same picker.
- **Drag to resize**: grab the narrow band along the sidebar's right edge
  (the cursor changes to horizontal resize arrows) and drag. Width is clamped
  to 120–400 px. The dragged width lasts until the next config reload, which
  re-applies your configured `window-sidebar-width`.
- **Footer icons** (bottom strip): bell 🔔 (notifications pane), gear ⚙
  (settings), globe 🌐 (browser pane). Note: the bell and globe glyphs depend
  on a system symbol/emoji font and may render as boxes on stripped-down
  Windows installs.

Both sidebar options reload live (`reload_config`, default `ctrl+shift+,`).

## Top Tab Bar (per workspace)

The top tab bar **coexists with the sidebar** — it is offset to the right of
it — and always shows the **active workspace's** tabs. Switching workspaces
swaps the tab bar's contents.

- **Click a tab** to switch to it; **drag a tab** left/right to reorder.
- **× close button** on the active and hovered tabs closes that tab.
- **Double-click a tab** to rename it inline.
- **`+` button** opens a new tab (with your default shell); the **▾ segment**
  beside it opens the backend picker for a new tab.
- **Right-click a tab** for the tab menu: *Close Tab*, *Close Other Tabs*,
  *Close Tabs to the Right*, *New Tab*. Right-clicking the `+`/`▾` buttons
  opens the backend picker instead.
- **Closing the last tab of a workspace** collapses (closes) that workspace
  when other workspaces exist; only closing the last tab of the **last**
  workspace closes the window.

Visibility follows the standard `window-show-tab-bar` option, evaluated
against the active workspace's tab count:

```ini
# always | auto (default; show when the workspace has 2+ tabs) | never
window-show-tab-bar = auto
```

## Window Size & Position Persistence

The main window remembers its size, position, and maximized state across
restarts (like Windows Terminal). The state is saved on move/resize/close to
a small `key=value` text file at `%LOCALAPPDATA%\ghostty\window-state` and
restored (clamped to the visible screen) at startup. Only the first window
persists its placement — additional windows cascade — and quick terminal
windows never save.

## Notifications Pane

Click the **bell icon** in the sidebar footer to toggle a notifications panel
(about 40% of the window height, above the footer).

- Collects the most recent **64** events, newest first:
  - **Amber dot** — bell rang in a tab.
  - **Red dot** — a shell process exited.
  - **Blue dot** — a desktop notification sent by a terminal program (OSC).
- Each entry shows the tab title over the notification text.
- **Click an entry** to jump to the tab that produced it — including across
  workspaces: the window is restored and brought to the foreground if needed,
  the workspace containing the tab is selected first, then the tab itself.
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
**backend picker** (the tab bar's `▾` segment, the sidebar's `▾` chevron, and
the *Split ... With...* menu) still lets you launch a **one-off**
PowerShell/cmd/WSL session — as a tab, as a new workspace's first tab, or as
a split — without changing the default.

## Terminal Right-Click Menu

Right-click inside a terminal pane for a context menu:

- **Copy** (greyed out when nothing is selected), **Paste**, **Select All**
- **Split Right**, **Split Down**
- **Split Right With...**, **Split Down With...** — open the backend picker
  (PowerShell / cmd / WSL distros / Browser) for the new split. Plain splits
  inherit the source pane's backend instead.
- **New Tab**
- **Close Pane** — closes this pane (or the whole tab when it's the only
  pane), with your `close_surface` keybind shown as a hint.

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
sent it** — the window is restored, brought to the foreground, the workspace
containing the tab is selected (even if it's not the active one), the tab is
selected, and the terminal is focused. Up to 8 balloons can be in flight at
once, and each is also mirrored into the sidebar notifications pane.

## Browser Panes (WebView2)

Open a web browser inside a split or a tab, next to your terminals:

- **Globe icon** in the sidebar footer opens a browser pane to the right of
  the active pane; the **backend picker**'s *Browser* entry opens one as a
  new tab or split.
- **Address bar** at the top of the pane:
  - Type a URL and press **Enter** to navigate. `https://` is prepended
    automatically if you omit the scheme.
  - Press **Escape** to move focus from the address bar into the page.
  - After navigation the bar reflects the final URL (it won't overwrite text
    you are currently typing).
  - An **× button** at the right end of the address-bar strip closes the
    browser pane (closing the tab when it's the only pane).
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

## Agent Scripting — `+browser`, `+workspace`, `+tab`, `+send`, `+notify`

A running Ghostty instance exposes a scripting API over a per-process named
pipe (`ghostty-ipc-<pid>`), so scripts and agents can drive it from any
shell. The target instance is found via the `GHOSTTY_PID` environment
variable (exported into every shell Ghostty spawns); outside one, the CLI
connects to the sole running instance and errors if there are zero or
several. All of these are Windows-only.

### `+browser` — scripted browser control

```text
ghostty +browser open <url> [--tab|--split]   # open a pane, prints its id
ghostty +browser navigate <url> [--id N]
ghostty +browser eval <js> [--id N]           # prints the JSON result
ghostty +browser snapshot [--id N]            # accessibility tree: {ref, role, name}
ghostty +browser click <ref> [--id N]         # ref = backendNodeId from snapshot
ghostty +browser fill <ref> <text> [--id N]
ghostty +browser list                         # ids of live browser panes
```

Without `--id`, the most recently created browser pane is used — panes are
addressed **across all windows and workspaces**, so a command can drive a
browser pane sitting in a background workspace.

### `+workspace` / `+tab` / `+send` / `+notify` — workspace, tab, keystroke, and attention control

These operate on the *target window* (the foreground Ghostty window, else
the first live one). Workspace and tab indices are window-local; `+tab` and
`+send` default to the active workspace and accept `--workspace I` to address
another. JSON list output is printed to stdout.

```text
ghostty +workspace list                         # [{index, name, active, tab_count}]
ghostty +workspace new [--name X]               # new workspace + default tab, prints {index}
ghostty +workspace new --worktree <branch> [--repo P] [--name X]   # git worktree workspace
ghostty +workspace select <index>
ghostty +workspace close <index>                # closing the last one closes the window

ghostty +tab list [--workspace I]               # [{index, title, active}]
ghostty +tab new [--workspace I] [--command "..."]   # prints {index}; inherits backend without --command
ghostty +tab select <index> [--workspace I]
ghostty +tab close <index> [--workspace I]

ghostty +send <text> [--workspace I] [--tab J] [--enter]
```

`+send` writes `text` to the child PTY of the active pane of the target tab,
exactly as typed input would; `--enter` appends a carriage return so the line
is submitted. The target pane must be a terminal (a browser pane has no PTY).

```
ghostty +notify ring  [--workspace I] [--tab J]   # flag a pane "needs attention"
ghostty +notify clear [--workspace I] [--tab J]   # clear the flag
```

`+notify ring` flags the active pane of the target tab for attention (see
**Notification Rings** below); `clear` removes it. Both default to the active
workspace's active tab. The target pane must be a terminal.

## Notification Rings

A per-pane **"needs attention / waiting for input"** indicator — the signal an
agent raises when it has stopped to ask you something while you are looking
elsewhere. Attention is surfaced at three levels at once so you can find the
waiting pane even when it is not visible:

- **Pane ring** — a 3px DPI-scaled blue border (accent `#3D8EF8`) drawn around
  the flagged pane in the visible split layout, but **only when it is not the
  focused pane** (you are never ringed around what you are already looking at).
- **Top tab dot** — a blue dot on the tab that contains a flagged pane.
- **Sidebar row** — the workspace row lights up with the blue accent bar and a
  blue dot, so a background workspace where an agent is waiting reads at a
  glance.

Attention **clears automatically** when the pane gains focus or its
tab+workspace become active (like the bell/exited status), so simply looking at
the pane dismisses it.

There are two ways to raise attention, both explicit and reliable:

1. **CLI** — `ghostty +notify ring [--workspace I --tab J]` over the agent IPC
   pipe (see above). Pair it with a wrapper, e.g. run your agent then
   `ghostty +notify ring` when it blocks.
2. **OSC sequence** — a program emits, on its own pane:
   ```sh
   printf '\033]9;@ghostty-attention:ring\033\\'    # set
   printf '\033]9;@ghostty-attention:clear\033\\'   # clear
   ```
   PowerShell:
   ```powershell
   $e=[char]27; Write-Host "$e]9;@ghostty-attention:ring$e\" -NoNewline
   ```
   This rides the OSC 9 desktop-notification channel with a private
   `@ghostty-attention:` marker, so it needs no new terminal-parser support and
   produces no balloon or log entry — only the ring.

**Detection honesty.** There is **no automatic "the agent is blocked on stdin"
heuristic**. Reliably detecting a blocked-on-input process through ConPTY is not
feasible without false positives (a paused pager, a long compile, and a prompt
waiting for input are indistinguishable from the read side), so attention is
**explicit-signal-only**: shell integration, an agent, or a wrapper must emit
the OSC or call `+notify`. This is a deliberate trade of "magic" for
correctness.

**Worktree workspaces** — `+workspace new --worktree <branch>` binds a new
workspace to a git worktree (the "one agent per branch" primitive). Ghostty
runs `git worktree add <repo>/.worktrees/<branch> -b <branch>` (omitting `-b`
to attach the branch if it already exists), names the workspace after the
branch (override with `--name`), and spawns every tab of that workspace inside
the worktree directory. The repository is the client's current directory
(sent over IPC, since the running Ghostty's cwd is its own) or an explicit
`--repo P`. The `git` invocation runs on the IPC pipe thread before the
workspace is created, so a slow checkout never stalls the UI; on a git failure
(or a branch name that would escape `.worktrees`, e.g. containing `/`, `\`, or
`..`) the command reports the error and creates no workspace.

## Working-Directory Inheritance (OSC 7) + PowerShell Integration

- **OSC 7 working-directory reporting on Windows** — `file://` URIs are
  parsed into Windows paths (drive letters, UNC shares, percent-decoding), so
  **new tabs and splits inherit the current working directory**.
- **PowerShell shell integration** — the OSC 7 emitter percent-encodes path
  segments, reports UNC paths for network drives, and resets the directory on
  non-filesystem providers (e.g. registry drives).
- **PowerShell `ssh` wrapper** — `ssh` is wrapped with `ghostty +ssh` (when
  the OpenSSH client is on PATH), handling TERM fallback, environment
  propagation, and terminfo installation per your `shell-integration-features`
  flags (`ssh-env` / `ssh-terminfo`).

## WSL Distributions

The build enumerates your installed WSL distributions (name, WSL 1/2 version,
and which one is the default) directly from the registry (`src/os/wsl.zig`),
and launches a shell in one with `wsl.exe --cd ~ -d <Name>`. Installed distros
appear in two places:

- The **backend picker** (the tab bar's `▾` segment, the sidebar's `▾`
  chevron, or a terminal's *Split ... With...* menu) lists each distro for a
  one-off tab, new workspace, or split.
- The gear's **Set default shell...** picker lists each distro to make it the
  shell every new session uses (see [Default Shell](#default-shell)).

You can also set `command = wsl.exe --cd ~ -d Ubuntu` (or your distro) directly
in your config.

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
  `%LOCALAPPDATA%\ghostty` (including the persisted window state) and
  WebView2 user-data folders are left intact.

## Configuration Example

```ini
# Workspace sidebar (on by default; set false for a classic look)
window-show-sidebar = true

# Sidebar width in unscaled pixels (default 220, clamped to 120–400; scaled by DPI)
window-sidebar-width = 260

# Top tab bar: always | auto (default) | never, per the active workspace's tab count
window-show-tab-bar = auto

# Default shell for new tabs/splits (defaults to cmd.exe on Windows).
# Can also be set from the gear menu's "Set default shell..." entry.
command = pwsh.exe
```

Apply with the gear menu's *Reload config* or the `reload_config` keybind.

## Keyboard & Mouse Cheat Sheet

| Input | Where | Action |
|---|---|---|
| `Alt+1` … `Alt+8` | anywhere | Jump to tab 1–8 **within the active workspace** |
| `Alt+9` | anywhere | Jump to the last tab of the active workspace |
| Left-click row | sidebar | Switch to that workspace |
| Drag row up/down | sidebar | Reorder workspaces |
| Double-click row | sidebar | Rename the workspace inline |
| Hover row → click `×` | sidebar | Close the workspace |
| Right-click row | sidebar | Rename Workspace / Close Workspace / New Workspace |
| Left-click `+ New workspace` | sidebar | New workspace (with one tab) |
| Left-click `▾` on that row | sidebar | Backend picker → new **workspace** whose first tab runs the chosen backend |
| Drag right edge | sidebar | Resize sidebar (120–400 px) |
| Left-click tab | tab bar | Switch to that tab |
| Drag tab left/right | tab bar | Reorder tabs |
| Double-click tab | tab bar | Rename the tab inline |
| Click tab `×` | tab bar | Close the tab (last tab collapses the workspace) |
| Left-click `+` / `▾` | tab bar | New tab / backend picker for a new tab |
| Right-click tab | tab bar | Close Tab / Close Other Tabs / Close Tabs to the Right / New Tab |
| Left-click bell 🔔 | sidebar footer | Toggle notifications pane (marks all read) |
| Left-click entry | notifications pane | Jump to the source tab (any workspace) |
| Left-click `Clear` | notifications pane | Empty the notification log |
| Left-click gear ⚙ | sidebar footer | Open config file |
| Right-click gear ⚙ | sidebar footer | Open config / Open config folder / Reload config / Set default shell... |
| Left-click globe 🌐 | sidebar footer | Open a browser split |
| Right-click | terminal | Copy / Paste / Select All / Split Right / Split Down / Split ... With... / New Tab / Close Pane |
| `Shift`+right-click | terminal | Force the context menu when a program captures the mouse |
| `Enter` | browser address bar | Navigate (adds `https://` if no scheme) |
| `Escape` | browser address bar | Move focus into the web page |
| Click `×` | browser address bar | Close the browser pane |
| Click balloon | desktop notification | Jump to the tab that sent it (any workspace) |
