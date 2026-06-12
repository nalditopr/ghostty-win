//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const BrowserPane = @import("BrowserPane.zig");
const Pane = @import("Pane.zig");
const Sidebar = @import("Sidebar.zig");
const Surface = @import("Surface.zig");
const WindowState = @import("WindowState.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
const MAX_TABS: usize = 64;

/// Per-tab status indicator shown in the session sidebar.
pub const TabStatus = enum { normal, bell, exited };

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
/// First of the parallel per-tab arrays (trees, active pane, titles,
/// title lengths, status) indexed by tab position: every per-tab array
/// MUST be listed in tabArrays() so the shared insert/remove/move/swap
/// helpers keep them aligned at all mutation sites.
tab_count: usize = 0,
tab_trees: [64]SplitTree(Pane) = undefined,

/// The currently focused pane within each tab.
tab_active_pane: [64]*Pane = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar. Zero-initialized
/// so input handlers that read it before the first paint (e.g., a
/// synthetic WM_LBUTTONDOWN during startup) get a no-match instead of
/// stack garbage.
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Hit-test rectangle for the "▾" (backend picker) segment beside the
/// new-tab button.
new_tab_dropdown_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// Whether the "▾" (backend picker) segment is being hovered.
hover_new_tab_dropdown: bool = false,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Sidebar row drag state: which session row is being dragged
/// (-1 = none). Mirrors drag_tab but tracks the cursor along Y to
/// reorder session rows. Reorders live via moveTabTo on each move.
sidebar_drag_row: isize = -1,
/// Starting Y position of the sidebar row drag, in client pixels.
sidebar_drag_start_y: i32 = 0,
/// Whether the sidebar row drag has exceeded the threshold and is
/// reordering (distinguishes a click-to-select from a drag).
sidebar_drag_active: bool = false,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [64][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [64]u16 = undefined,

/// Per-tab sidebar status. Cleared to .normal when the tab is selected.
tab_status: [MAX_TABS]TabStatus = [_]TabStatus{.normal} ** MAX_TABS,

/// Current sidebar hover target.
sidebar_hover: Sidebar.HitTarget = .none,

/// Whether the sidebar notifications panel (toggled by the footer
/// bell icon) is open.
notif_panel_open: bool = false,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font used for painting the tab bar (Segoe UI).
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Set during init() when restoring persisted state asked for a
/// maximized window. Consumed when the first tab shows the window
/// (ShowWindow uses SW_SHOWMAXIMIZED instead of SW_SHOW). Always false
/// for quick terminals and non-first windows. Only the main window
/// persists/restores geometry.
restore_maximized: bool = false,

/// True once this window has persisted at least one good (non-degenerate)
/// placement during the session. Guards against a teardown-time
/// GetWindowPlacement returning a minimized/zero rect overwriting the
/// last good save. See savePlacement.
saved_placement_ok: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Pane).Node.Handle = .root,
drag_split_layout: SplitTree(Pane).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Sidebar edge drag-resize state. The width override is in unscaled
/// pixels and wins over `window-sidebar-width` until the next config
/// reload (onConfigChange resets it so the config value re-applies).
sidebar_width_override: ?u32 = null,
dragging_sidebar: bool = false,

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Apply DWM dark/light + caption color based on the configured
/// background. Light vs dark is decided by luminance; CAPTION_COLOR
/// is silently ignored on Windows 10.
fn applyChromeTheme(hwnd: w32.HWND, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const dark_mode: u32 = if (luminance < 0.5) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    const caption_color: u32 = (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16);
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Called from App.config_change so the title bar tracks live config
/// reloads (background color in particular).
pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.background);
    }
    // window-show-sidebar / window-sidebar-width may have changed:
    // drop any drag-resize override so the config value re-applies,
    // then recompute chrome layout and repaint.
    self.sidebar_width_override = null;
    self.updateTabBarVisibility();
    self.handleResize();
    self.invalidateSidebar();
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    const style: u32 = if (options.is_quick_terminal) w32.WS_POPUP else w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    // Window geometry. Defaults to a fixed 800x600 at the OS default
    // position. Three cases, in priority order:
    //   1. The FIRST non-quick-terminal window of the session restores
    //      the saved size/position/maximized state (Windows Terminal
    //      style). app.windows is still empty here because init() runs
    //      before App appends the window to the list.
    //   2. Subsequent windows cascade 30px down/right of the previous.
    //   3. Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    var cw: i32 = 800;
    var ch: i32 = 600;
    // Whether to maximize the window once it is first shown (set from
    // restored state). Recorded on self so addTab() can apply it.
    self.restore_maximized = false;
    var have_restored = false;

    const is_first_window = !options.is_quick_terminal and app.windows.items.len == 0;
    if (is_first_window) {
        if (self.restorePlacement()) |saved| {
            // restorePlacement already clamped the rect onto the current
            // virtual screen, so cx/cy/cw/ch are guaranteed visible.
            cx = saved.x;
            cy = saved.y;
            cw = saved.width;
            ch = saved.height;
            self.restore_maximized = saved.maximized;
            have_restored = true;
        }
    }

    if (!options.is_quick_terminal and !have_restored and app.windows.items.len > 0) {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        style,
        cx,
        cy,
        cw,
        ch,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    applyChromeTheme(hwnd, app.config.background);

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    // Skip when force_opaque (parent window was toggled to opaque via
    // toggle_background_opacity — inherit that state for the new window).
    if (app.config.@"background-opacity" < 1.0 and !options.force_opaque) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    // Create the tab bar font (Segoe UI, 12px at 96 DPI, scaled).
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        0, // iQuality
        0, // iPitchAndFamily
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// Name of the persisted window-state file, under %LOCALAPPDATA%\ghostty.
const WINDOW_STATE_FILE = "window-state";

/// Build the absolute path to the window-state file. Mirrors the
/// `update_check_at` convention used elsewhere in this runtime
/// (%LOCALAPPDATA%\ghostty\...). Caller owns the returned slice.
fn windowStatePath(alloc: std.mem.Allocator) ![]u8 {
    const dir = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "ghostty", WINDOW_STATE_FILE });
}

/// Capture the current window placement and persist it. Called on
/// WM_EXITSIZEMOVE (resize/move settle) and on close, so we never write
/// on every pixel of a drag.
///
/// We persist the window's *restored* rect (GetWindowPlacement's
/// rcNormalPosition) plus the maximized flag, so a maximized window still
/// remembers the underlying size it un-maximizes to. Coordinates are
/// physical pixels in workarea space (see WindowState.zig).
///
/// Only the main window participates: quick terminals manage their own
/// geometry, and additional windows would clobber each other. Errors
/// (missing dir, no permission) are swallowed — persistence is best
/// effort and must never affect normal operation.
pub fn savePlacement(self: *Window) void {
    if (self.is_quick_terminal) return;
    // Only the first window in the App's list owns the persisted state.
    // Additional session windows cascade and do not save (avoids two
    // windows fighting over one file).
    if (self.app.windows.items.len == 0 or self.app.windows.items[0] != self) return;
    const hwnd = self.hwnd orelse return;

    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) return;

    const r = wp.rcNormalPosition;
    const state: WindowState.State = .{
        .width = r.right - r.left,
        .height = r.bottom - r.top,
        .x = r.left,
        .y = r.top,
        // showCmd reflects the persisted (un-minimized) show state.
        // SW_SHOWMAXIMIZED (3) and SW_MAXIMIZE (3) both mean maximized.
        .maximized = wp.showCmd == w32.SW_SHOWMAXIMIZED,
    };

    // Reject a degenerate capture (e.g. a minimized window reporting a
    // tiny/zero normal rect during teardown) so we never clobber a
    // previously-good save with garbage.
    if (!state.validate()) return;

    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(alloc) catch return;
    defer alloc.free(path);

    // Ensure the parent dir exists, then write atomically-ish via
    // truncate. The state is tiny so a partial write is implausible.
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();
    var buf: [160]u8 = undefined;
    const text = state.serialize(&buf) catch return;
    file.writeAll(text) catch return;
    self.saved_placement_ok = true;
}

/// Read and validate the persisted window state, clamped onto the
/// current virtual screen so the restored window is always visible.
/// Returns null when there is no state, it is corrupt, or the env is
/// unavailable — callers then fall back to defaults. Best effort: any
/// error path yields null.
fn restorePlacement(self: *Window) ?WindowState.State {
    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(alloc) catch return null;
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    var state = WindowState.State.parse(buf[0..n]) orelse return null;

    // Clamp onto the current virtual screen (handles a removed monitor or
    // an off-screen saved position). Physical pixels throughout.
    const vx = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN);
    const vy = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN);
    const vw = w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN);
    const vh = w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN);
    // If the metrics are unavailable (0 span), skip clamping rather than
    // collapsing the window.
    if (vw > 0 and vh > 0) {
        const adjusted = WindowState.clampToVirtualScreen(
            .{ .x = state.x, .y = state.y, .width = state.width, .height = state.height },
            .{ .x = vx, .y = vy, .width = vw, .height = vh },
        );
        state.x = adjusted.x;
        state.y = adjusted.y;
        state.width = adjusted.width;
        state.height = adjusted.height;
    }

    return state;
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Delete the tab bar font.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the sidebar width in pixels, accounting for DPI scale.
/// Returns 0 when the sidebar is disabled, for quick terminals, or
/// once the window is closing.
pub fn sidebarWidth(self: *const Window) i32 {
    if (self.closing or self.is_quick_terminal) return 0;
    if (!self.app.config.@"window-show-sidebar") return 0;
    const unscaled = self.sidebar_width_override orelse self.app.config.@"window-sidebar-width";
    const width = std.math.clamp(unscaled, Sidebar.MIN_WIDTH, Sidebar.MAX_WIDTH);
    return @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top and the
/// sidebar width from the left.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    rect.left += self.sidebarWidth();
    return rect;
}

/// Returns the currently active Pane, or null if there are no tabs.
pub fn getActivePane(self: *Window) ?*Pane {
    if (self.tab_count == 0) return null;
    return self.tab_active_pane[self.active_tab];
}

/// Returns the currently active terminal Surface, or null if there are
/// no tabs or the active pane has no terminal.
pub fn getActiveSurface(self: *Window) ?*Surface {
    const pane = self.getActivePane() orelse return null;
    return pane.surface();
}

/// Find the tab index containing a given pane.
/// Checks tab_active_pane first, then scans all trees.
pub fn findTabIndex(self: *Window, pane: *Pane) ?usize {
    for (self.tab_active_pane[0..self.tab_count], 0..) |p, i| {
        if (p == pane) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == pane) return i;
        }
    }
    return null;
}

/// Find the tab index containing a given terminal surface. Compares
/// by address against live panes WITHOUT dereferencing `surface`, so
/// callers validating possibly-dangling pointers (jumpToSurface) can
/// use it safely.
pub fn findTabIndexOfSurface(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_pane[0..self.tab_count], 0..) |p, i| {
        if (p.surface() == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view.surface() == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a pane in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, pane: *Pane) ?SplitTree(Pane).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == pane) return entry.handle;
    }
    return null;
}

/// The parallel per-tab arrays as a tuple of array pointers. EVERY
/// per-tab array must be listed here: the mutation sites
/// (addTabWithCommand/addBrowserTab insert, closeTabByIndex remove,
/// moveTabTo reorder, moveTab swap) all operate on this tuple via the
/// tabArrays* helpers below, so an array missing from this list
/// silently desynchronizes from tab indices.
fn tabArrays(self: *Window) struct {
    *[MAX_TABS]SplitTree(Pane),
    *[MAX_TABS]*Pane,
    *[MAX_TABS][256]u16,
    *[MAX_TABS]u16,
    *[MAX_TABS]TabStatus,
} {
    return .{
        &self.tab_trees,
        &self.tab_active_pane,
        &self.tab_titles,
        &self.tab_title_lens,
        &self.tab_status,
    };
}

/// Shift entries [pos, count) right by one in every array of the
/// tuple, opening a gap at pos. The caller fills the gap and bumps its
/// count.
fn tabArraysInsertGap(arrays: anytype, count: usize, pos: usize) void {
    inline for (arrays) |arr| {
        var i: usize = count;
        while (i > pos) : (i -= 1) arr[i] = arr[i - 1];
    }
}

/// Shift entries (idx, count) left by one in every array, overwriting
/// idx. The caller decrements its count (and clears the now-duplicate
/// last slot where stale pointers matter, e.g. tab_trees).
fn tabArraysRemove(arrays: anytype, count: usize, idx: usize) void {
    inline for (arrays) |arr| {
        var i: usize = idx;
        while (i + 1 < count) : (i += 1) arr[i] = arr[i + 1];
    }
}

/// Move the entry at `from` to `to` in every array, shifting the
/// entries between them one slot toward `from`.
fn tabArraysMove(arrays: anytype, from: usize, to: usize) void {
    inline for (arrays) |arr| {
        const saved = arr[from];
        var i: usize = from;
        if (from < to) {
            while (i < to) : (i += 1) arr[i] = arr[i + 1];
        } else {
            while (i > to) : (i -= 1) arr[i] = arr[i - 1];
        }
        arr[to] = saved;
    }
}

/// Swap entries a and b in every array.
fn tabArraysSwap(arrays: anytype, a: usize, b: usize) void {
    inline for (arrays) |arr| {
        std.mem.swap(@TypeOf(arr[a]), &arr[a], &arr[b]);
    }
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithCommand(null, null);
}

/// Like addTab, but optionally overrides the command the new tab runs
/// (the new-session backend picker) and its initial title. The argv
/// and title are copied as needed, so the caller's memory may be freed
/// once this returns. Null command/title behave exactly like addTab.
pub fn addTabWithCommand(
    self: *Window,
    command: ?[]const []const u8,
    title: ?[]const u8,
) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command);
    // After surface.init succeeds, wrap it in a Pane and create the
    // SplitTree which takes ownership via ref(). If this fails, we
    // manually clean up.
    const pane = Pane.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Pane).init(alloc, pane) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees the pane

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    tabArraysInsertGap(self.tabArrays(), self.tab_count, pos);
    self.tab_trees[pos] = tree;
    self.tab_active_pane[pos] = pane;
    self.tab_status[pos] = .normal;
    self.tab_count += 1;

    // Set the initial title: the picked backend name when given (so the
    // sidebar row is identifiable before the shell's OSC title arrives),
    // otherwise the default. Truncated to the title buffer; an invalid
    // UTF-8 title falls back to the default.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);
    if (title) |t| {
        const wlen = std.unicode.utf8ToUtf16Le(
            &self.tab_titles[pos],
            t[0..@min(t.len, 255)],
        ) catch 0;
        if (wlen > 0) self.tab_title_lens[pos] = @intCast(@min(wlen, 255));
    }

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        // If restored state asked for a maximized window, show it maximized
        // so the OS uses the persisted restored rect as the un-maximize size.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                const cmd: i32 = if (self.restore_maximized) w32.SW_SHOWMAXIMIZED else w32.SW_SHOW;
                _ = w32.ShowWindow(h, cmd);
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();
    return surface;
}

/// Add a browser (WebView2) pane as a new tab. Mirrors
/// addTabWithCommand's tab-array bookkeeping with a BrowserPane leaf
/// instead of a terminal surface; the title is "Browser" until the
/// first DocumentTitleChanged. Closing it never prompts (no core
/// surface, so no running-process check applies).
pub fn addBrowserTab(self: *Window) !void {
    if (self.closing) return error.WindowClosing;
    // Quick terminals are transient single-surface popups with no tab
    // bar or sidebar; no UI path offers them a browser tab, but guard
    // anyway so a future caller can't create unreachable chrome.
    if (self.is_quick_terminal) return error.QuickTerminal;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    // Build the single-pane tree. The errdefers only cover the gap
    // until the tree takes ownership via ref() (same shape as
    // newBrowserSplit); past the block the insertion below cannot
    // fail, so the tree is never deinit'd after tab_trees holds it.
    var browser: *BrowserPane = undefined;
    var browser_pane: *Pane = undefined;
    const tree = blk: {
        const b = try BrowserPane.create(alloc, self.app, self);
        errdefer b.destroy(alloc);
        const new_pane = try Pane.createBrowser(alloc, b);
        errdefer alloc.destroy(new_pane);
        const t = try SplitTree(Pane).init(alloc, new_pane);
        browser = b;
        browser_pane = new_pane;
        break :blk t;
    };

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    tabArraysInsertGap(self.tabArrays(), self.tab_count, pos);
    self.tab_trees[pos] = tree;
    self.tab_active_pane[pos] = browser_pane;
    self.tab_status[pos] = .normal;
    self.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Browser");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        // First tab — not reachable from the current UI (the picker
        // only exists on live windows, which always have >= 1 tab),
        // but mirror addTabWithCommand for robustness.
        if (self.hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        self.layoutSplits();
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();

    // Begin async WebView2 creation now that the tree owns the pane
    // (the in-flight race guard refs it).
    browser.startCreation();

    // Focus the address bar so the user can type a URL immediately.
    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Close a tab by pane pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, pane: *Pane) void {
    log.debug("closeTab called for pane={x} tab_count={}", .{ @intFromPtr(pane), self.tab_count });
    const idx = self.findTabIndex(pane) orelse return;
    self.closeTabByIndex(idx);
}

fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.cancelTabRename();

    // Detach the tab from the window state BEFORE tree.deinit():
    // deinit can destroy a browser host HWND, which moves focus
    // synchronously and re-enters our wndprocs (WM_SETFOCUS &c).
    // Those handlers read tab_trees/tab_active_pane/active_tab and
    // must never observe the dying tab. The local copy stays valid:
    // SplitTree is a value whose deinit frees the shared heap data.
    var tree = self.tab_trees[idx];
    tabArraysRemove(self.tabArrays(), self.tab_count, idx);
    self.tab_count -= 1;
    // The shift leaves a duplicate of the last tree past the new
    // count; clear it so nothing can ever walk stale node pointers.
    self.tab_trees[self.tab_count] = .empty;

    if (self.tab_count == 0) {
        // Set closing before deinit so re-entrant input/focus messages
        // are dropped by the wndproc guards while panes are torn down.
        self.closing = true;
        tree.deinit(); // unrefs all panes → Pane.unref frees at ref_count=0
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    tree.deinit();
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndexOfSurface(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndexOfSurface(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}

/// Close a single terminal surface's pane. See closeSplitPane.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const pane = surface.pane orelse return;
    self.closeSplitPane(pane);
}

/// Close a single pane within a split tree. If it's the last pane
/// in the tab, close the entire tab instead.
pub fn closeSplitPane(self: *Window, pane: *Pane) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(pane) orelse {
        log.debug("closeSplitPane: pane not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitPane: not split, closing whole tab", .{});
        self.closeTab(pane);
        return;
    }

    const handle = self.findHandle(tab, pane) orelse {
        log.debug("closeSplitPane: handle not found", .{});
        return;
    };
    log.debug("closeSplitPane: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the pane pointer from the next handle before we modify the tree.
    const next_pane: ?*Pane = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitPane: has_next={}", .{next_pane != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove pane from split tree", .{});
        return;
    };
    log.debug("closeSplitPane: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    // Publish the new tree and a surviving active pane BEFORE deiniting
    // the old tree: the deinit can destroy a browser host HWND, which
    // moves focus synchronously and re-enters wndprocs that read
    // tab_trees/tab_active_pane. They must see post-removal state, not
    // the dying pane.
    var old_tree = self.tab_trees[tab];
    self.tab_trees[tab] = new_tree;
    const survivor: ?*Pane = next_pane orelse blk: {
        var it = new_tree.iterator();
        break :blk if (it.next()) |entry| entry.view else null;
    };
    if (survivor) |sp| self.tab_active_pane[tab] = sp;
    old_tree.deinit();

    if (next_pane) |np| {
        log.debug("closeSplitPane: focusing next pane", .{});
        self.layoutSplits();
        np.focus();
    } else {
        log.debug("closeSplitPane: no next pane, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}

/// Switch to the tab at the given index.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabRename();
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    // Clear any in-progress sidebar row drag (e.g. a goto_tab keybind
    // fired mid-drag). handleSidebarClick sets this AFTER its own
    // selectTabIndex call, so the click-then-drag path is unaffected.
    if (self.sidebar_drag_row >= 0) {
        self.sidebar_drag_row = -1;
        self.sidebar_drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    self.tab_status[idx] = .normal;
    const pane = self.tab_active_pane[idx];
    self.layoutSplits();
    pane.focus();
    self.updateWindowTitle();
    self.invalidateSidebar();
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                if (entry.view.hwnd()) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}

fn layoutNode(self: *Window, tree: SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (view.hwnd()) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Pane).Node.Handle,
    layout: SplitTree(Pane).Split.Layout,
};

fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

fn startDividerDrag(self: *Window, handle: SplitTree(Pane).Node.Handle, layout: SplitTree(Pane).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// True when x is inside the drag-resize grab band along the sidebar's
/// right edge. A hidden sidebar has no band.
fn hitTestSidebarEdge(self: *const Window, x: i32) bool {
    return Sidebar.hitTestEdge(x, self.sidebarWidth(), Sidebar.edgeBandWidth(self.scale));
}

fn startSidebarDrag(self: *Window) void {
    if (self.closing) return;
    self.dragging_sidebar = true;
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateSidebarDrag(self: *Window, x: i32) void {
    if (!self.dragging_sidebar or self.closing) return;
    const unscaled = std.math.clamp(
        @round(@as(f32, @floatFromInt(x)) / self.scale),
        @as(f32, @floatFromInt(Sidebar.MIN_WIDTH)),
        @as(f32, @floatFromInt(Sidebar.MAX_WIDTH)),
    );
    const new_width: u32 = @intFromFloat(unscaled);
    if (self.sidebar_width_override) |cur| if (cur == new_width) return;
    self.sidebar_width_override = new_width;
    // Same live relayout as the divider drag: move the surfaces and
    // repaint the chrome strips immediately.
    self.handleResize();
    if (self.hwnd) |h| _ = w32.UpdateWindow(h);
}

fn endSidebarDrag(self: *Window) void {
    if (!self.dragging_sidebar) return;
    self.dragging_sidebar = false;
    _ = w32.ReleaseCapture();
}

/// End an in-progress sidebar row drag-reorder, releasing capture if
/// one was held. Idempotent: a no-op when no row drag is active.
fn endSidebarRowDrag(self: *Window) void {
    if (self.sidebar_drag_row < 0) return;
    self.sidebar_drag_row = -1;
    self.sidebar_drag_active = false;
    _ = w32.ReleaseCapture();
}

/// Compute the target row index for a sidebar row drag at client y.
/// Mirrors the tab bar's midpoint rule: the slot whose midpoint the
/// cursor has passed. Clamped to the valid session row range.
fn sidebarDragTarget(self: *const Window, y: i32) usize {
    if (self.tab_count == 0) return 0;
    const item_h = Sidebar.itemHeight(self.scale);
    if (item_h <= 0) return 0;
    var target: usize = 0;
    for (0..self.tab_count) |i| {
        const slot_top: i32 = @as(i32, @intCast(i)) * item_h;
        const slot_mid = slot_top + @divTrunc(item_h, 2);
        if (y >= slot_mid) target = i;
    }
    if (target >= self.tab_count) target = self.tab_count - 1;
    return target;
}

/// Create a new split in the active tab. Splits inherit the source
/// pane's backend (Windows Terminal semantics): a split off a WSL or
/// PowerShell tab opens the same shell. Browser panes have no terminal
/// surface, so a split off one falls back to the configured default.
pub fn newSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    if (self.tab_count == 0) return;
    // Surface.init deep copies the argv, so borrowing the source
    // surface's copy is fine.
    const command: ?[]const []const u8 = if (self.tab_active_pane[self.active_tab].surface()) |src|
        src.spawn_command
    else
        null;
    return self.newSplitWithCommand(direction, command);
}

/// Like newSplit, but with an explicit command override (the backend
/// picker) instead of inheriting the source pane's backend. Null runs
/// the configured default. The argv is copied by Surface.init, so the
/// caller's memory may be freed once this returns.
pub fn newSplitWithCommand(
    self: *Window,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_pane = self.tab_active_pane[tab];
    const handle = self.findHandle(tab, active_pane) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split, command);

    // Create a single-node tree for the new surface's pane. The block
    // scopes the pane errdefer to the window between Pane.create and
    // the tree taking ownership via ref().
    var inserted_pane: *Pane = undefined;
    var insert_tree = blk: {
        const new_pane = try Pane.create(alloc, new_surface);
        errdefer alloc.destroy(new_pane);
        const tree = try SplitTree(Pane).init(alloc, new_pane);
        inserted_pane = new_pane;
        break :blk tree;
    };
    defer insert_tree.deinit();

    // Split the current tree at the active pane.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new pane.
    self.tab_active_pane[tab] = inserted_pane;

    self.layoutSplits();
    inserted_pane.focus();
}

/// Create a new browser (WebView2) split in the active tab, in the
/// given direction off the active pane.
pub fn newBrowserSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    if (self.closing) return;
    if (self.tab_count == 0) {
        // Not reachable from the current UI (the sidebar/context menu
        // only exist on live windows, which always have >= 1 tab).
        log.warn("newBrowserSplit: no tabs, ignoring", .{});
        return;
    }
    // An in-progress inline tab rename owns an Edit control whose
    // teardown re-enters via EN_KILLFOCUS; settle it before mutating
    // the tree (same protocol as addTabWithCommand/selectTabIndex).
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_pane = self.tab_active_pane[tab];
    const handle = self.findHandle(tab, active_pane) orelse return;

    // Build the single-pane insert tree. The errdefers only cover the
    // gap until the tree takes ownership via ref(); after the block,
    // insert_tree.deinit() is the sole cleanup path (no double-free
    // when split() fails).
    var browser: *BrowserPane = undefined;
    var browser_pane: *Pane = undefined;
    var insert_tree = blk: {
        const b = try BrowserPane.create(alloc, self.app, self);
        errdefer b.destroy(alloc);
        const new_pane = try Pane.createBrowser(alloc, b);
        errdefer alloc.destroy(new_pane);
        const tree = try SplitTree(Pane).init(alloc, new_pane);
        browser = b;
        browser_pane = new_pane;
        break :blk tree;
    };
    defer insert_tree.deinit();

    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    self.tab_active_pane[tab] = browser_pane;
    self.layoutSplits();

    // Begin async WebView2 creation now that the tree owns the pane
    // (the in-flight race guard refs it).
    browser.startCreation();

    // Focus the address bar so the user can type a URL immediately.
    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_pane = self.tab_active_pane[tab];
    const handle = self.findHandle(tab, active_pane) orelse return;

    const target: SplitTree(Pane).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |pane| {
            self.tab_active_pane[tab] = pane;
            pane.focus();
        },
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_pane = self.tab_active_pane[tab];
    const handle = self.findHandle(tab, active_pane) orelse return;

    const layout: SplitTree(Pane).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_pane = self.tab_active_pane[tab];
    const handle = self.findHandle(tab, active_pane) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp non-negative before casting
            // so a negative sentinel doesn't panic the @intCast.
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    tabArraysSwap(self.tabArrays(), self.active_tab, new_index);
    self.active_tab = new_index;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Update the top-level window title to match the active tab's title.
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Called when a terminal surface's title changes. Delegates to the
/// pane variant.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const pane = surface.pane orelse return;
    self.onPaneTitleChanged(pane, title);
}

/// Called when a pane's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onPaneTitleChanged(self: *Window, pane: *Pane, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(pane) orelse return;
    var wbuf: [256]u16 = undefined;
    // utf8ToUtf16Le ASSERTS the destination is large enough (no
    // DestTooSmall error in std 0.15) and titles can exceed 256
    // UTF-16 units (browser titles are website-controlled; OSC titles
    // up to 511 bytes). One UTF-8 byte produces at most one UTF-16
    // unit, so capping the input at 255 bytes makes the worst case
    // fit.
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, capUtf8(title, 255)) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Cap a UTF-8 string at `max_bytes`, backing up to a sequence
/// boundary so the cut doesn't strand a partial multi-byte sequence
/// (which would invalidate the whole string and drop the title).
fn capUtf8(title: []const u8, max_bytes: usize) []const u8 {
    if (title.len <= max_bytes) return title;
    var len = max_bytes;
    while (len > 0 and (title[len] & 0xC0) == 0x80) len -= 1;
    return title[0..len];
}

/// Set the sidebar status indicator for the tab containing a surface.
/// No-op if the surface is not in any tab of this window.
pub fn setTabStatusForSurface(self: *Window, surface: *Surface, status: TabStatus) void {
    const idx = self.findTabIndexOfSurface(surface) orelse return;
    if (self.tab_status[idx] == status) return;
    self.tab_status[idx] = status;
    self.invalidateSidebar();
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    // The sidebar replaces the tab bar entirely when enabled.
    const should_show = if (self.sidebarWidth() > 0) false else switch (show_config) {
        .always => true,
        .auto => self.tab_count > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Invalidate the sidebar region so it gets repainted.
pub fn invalidateSidebar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = self.sidebarWidth(),
        .bottom = 32767,
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Handle WM_PAINT: paint the window chrome (tab bar and sidebar)
/// with a single BeginPaint/EndPaint pair.
fn paintChrome(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    self.paintTabBar(hdc_screen);
    if (self.sidebarWidth() > 0) Sidebar.paint(self, hdc_screen);
}

/// Paint the tab bar using double-buffered GDI painting.
/// Draws tab backgrounds, text labels, close buttons (x), and the new-tab (+) button.
fn paintTabBar(self: *Window, hdc_screen: w32.HDC) void {
    const hwnd = self.hwnd orelse return;

    // If the tab bar is not visible, there is nothing to paint.
    if (!self.tab_bar_visible) return;

    const bar_h = self.tabBarHeight();
    if (bar_h <= 0) return;

    // Get client rect width.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    if (client_w <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = self.app.config.background;
    // Bar background: terminal bg + 20 brightness per channel (slightly lighter).
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover background: bar bg + 15 more (total +35 from terminal bg).
    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active tab background: terminal bg (darker than bar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent line color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);

    // Close button colors.
    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);

    // --- Fill bar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Calculate tab geometry ---
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * self.scale));
    const dropdown_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * self.scale));

    const tab_count_i32: i32 = @intCast(self.tab_count);
    const available_w = client_w - new_tab_btn_w - dropdown_btn_w;

    // Calculate each tab's width: proportional, min 60px.
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * self.scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * self.scale));

    var tab_w: i32 = if (tab_count_i32 > 0)
        @divTrunc(available_w, tab_count_i32)
    else
        0;
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    // --- Draw each tab ---
    var x: i32 = 0;
    for (0..self.tab_count) |i| {
        const is_active = (i == self.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);

        // Last tab gets remainder width to fill the available area.
        const this_tab_w: i32 = if (i == self.tab_count - 1 and tab_count_i32 > 0)
            @max(available_w - x, min_tab_w)
        else
            tab_w;

        // Store hit-test rect.
        self.tab_rects[i] = w32.RECT{
            .left = x,
            .top = 0,
            .right = x + this_tab_w,
            .bottom = bar_h,
        };

        // Draw tab background. CreateSolidBrush failures are rare (GDI
        // handle exhaustion) and must NOT skip the loop body's geometry
        // update at the bottom — `continue`ing would leave subsequent
        // tabs sharing the same x position.
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent line at bottom.
            var accent_rect = w32.RECT{
                .left = x,
                .top = bar_h - accent_h,
                .right = x + this_tab_w,
                .bottom = bar_h,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw tab title text.
        const title_len = self.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&self.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Draw close button (x) — visible on active or hovered tabs.
        if (is_active or is_hovered) {
            const close_x = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
            const close_y_center = @divTrunc(bar_h, 2);
            const close_text_color = if (is_hovered and self.hover_close and @as(isize, @intCast(i)) == self.hover_tab)
                close_hover_color
            else
                close_normal_color;

            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign as close
            var close_rect = w32.RECT{
                .left = close_x,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_x + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        x += this_tab_w;
    }

    // --- Draw new-tab (+) button ---
    {
        const btn_left = x;
        const btn_right = x + new_tab_btn_w;
        self.new_tab_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };

        // Hover highlight for new-tab button.
        if (self.hover_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            const nt_brush = w32.CreateSolidBrush(hover_color);
            if (nt_brush) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- Draw backend picker (▾) segment beside the new-tab button ---
    {
        const dd_left = self.new_tab_rect.right;
        self.new_tab_dropdown_rect = w32.RECT{
            .left = dd_left,
            .top = 0,
            .right = dd_left + dropdown_btn_w,
            .bottom = bar_h,
        };

        // Hover highlight, independent of the "+" half.
        if (self.hover_new_tab_dropdown) {
            var dd_rect = self.new_tab_dropdown_rect;
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &dd_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, if (self.hover_new_tab_dropdown)
            active_text_color
        else
            inactive_text_color);
        const chevron_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25BE}");
        var chevron_rect = self.new_tab_dropdown_rect;
        _ = w32.DrawTextW(
            mem_dc,
            chevron_char,
            1,
            &chevron_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, client_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null,
                mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null,
            self.saved_rect.left, self.saved_rect.top,
            self.saved_rect.right - self.saved_rect.left,
            self.saved_rect.bottom - self.saved_rect.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0,
        w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint
/// the tab bar and sidebar.
fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Check the "▾" backend picker segment beside the new-tab button;
    // anchor the picker under the split button, not at the click.
    if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
        self.showBackendMenu(self.new_tab_rect.left, self.tabBarHeight(), .new_tab);
        return;
    }

    // Check new-tab button.
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check each tab.
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            // Check close button area (right side of tab).
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                // Start tracking potential tab drag
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Lift the source tab out, shift the tabs between, drop it at the
    // destination.
    tabArraysMove(self.tabArrays(), from, to);

    self.active_tab = to;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;
    var new_dropdown = false;

    if (y < self.tabBarHeight()) {
        // Check new-tab button and the "▾" segment beside it.
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
            new_dropdown = true;
        } else {
            // Check tabs.
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
            for (0..self.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_close != self.hover_close or
        new_new_tab != self.hover_new_tab or new_dropdown != self.hover_new_tab_dropdown)
    {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.hover_new_tab_dropdown = new_dropdown;
        self.invalidateTabBar();
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;

// Sidebar gear (settings) context menu command IDs.
const GEAR_CTX_OPEN_CONFIG: usize = 9201;
const GEAR_CTX_OPEN_FOLDER: usize = 9202;
const GEAR_CTX_RELOAD: usize = 9203;
// Opens a second popup that writes `command = <choice>` into the user
// config (the default-shell picker). 9410+ avoids every taken range
// (9001-9004/9101-9107/9201-9203/9300-9322/9400 close-pane).
const GEAR_CTX_SET_DEFAULT_SHELL: usize = 9410;

// Default-shell picker command IDs (the second popup opened by
// "Set default shell..."). Each writes the chosen program/argv to the
// `command` config key. Installed WSL distros are appended at
// DEFAULT_SHELL_DISTRO_BASE + index, capped below the next reserved ID.
const DEFAULT_SHELL_PWSH: usize = 9411;
const DEFAULT_SHELL_CMD: usize = 9412;
const DEFAULT_SHELL_DISTRO_BASE: usize = 9420;
const DEFAULT_SHELL_DISTRO_CAP: usize = 9450;

// Backend picker command IDs (right-click on the sidebar "+ New
// session" row or the tab bar "+" button opens it targeting a new
// tab; the surface context menu's "Split ... With..." entries open it
// targeting a split). Installed WSL distros are appended at
// NEW_SESSION_DISTRO_BASE + index; the Browser entry at 9320 caps the
// distro list so a pathological install count can't collide with it.
const NEW_SESSION_DEFAULT: usize = 9300;
const NEW_SESSION_PWSH: usize = 9301;
const NEW_SESSION_CMD: usize = 9302;
const NEW_SESSION_DISTRO_BASE: usize = 9310;
const NEW_SESSION_BROWSER: usize = 9320;

/// What a backend-picker menu ID resolves to. Pure mapping from the
/// TrackPopupMenu result (0 = dismissed) and the number of distro
/// entries that were appended; gaps in the ID space and distro IDs at
/// or past the count resolve to .none.
const PickerSelection = union(enum) {
    none,
    default,
    pwsh,
    cmd,
    distro: usize,
    browser,
};

fn pickerSelection(cmd_id: usize, distro_count: usize) PickerSelection {
    switch (cmd_id) {
        NEW_SESSION_DEFAULT => return .default,
        NEW_SESSION_PWSH => return .pwsh,
        NEW_SESSION_CMD => return .cmd,
        NEW_SESSION_BROWSER => return .browser,
        else => {},
    }
    if (cmd_id < NEW_SESSION_DISTRO_BASE) return .none;
    const idx = cmd_id - NEW_SESSION_DISTRO_BASE;
    if (idx >= distro_count) return .none;
    return .{ .distro = idx };
}

/// Menu label for a WSL distro row: the name, with " (default)"
/// appended for the distro wsl.exe launches without -d. Allocated;
/// caller frees.
fn distroMenuLabel(
    alloc: Allocator,
    name: []const u8,
    is_default: bool,
) Allocator.Error![]const u8 {
    return if (is_default)
        std.fmt.allocPrint(alloc, "{s} (default)", .{name})
    else
        alloc.dupe(u8, name);
}

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Right-click on the "+" button or its "▾" segment opens the
    // new-session backend picker instead of the tab context menu.
    if ((x >= self.new_tab_rect.left and x < self.new_tab_rect.right) or
        (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right))
    {
        self.showBackendMenu(x, y, .new_tab);
        return;
    }

    // Hit-test to find which tab was right-clicked.
    var clicked_tab: ?usize = null;
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }

    self.showTabContextMenu(clicked_tab, x, y);
}

/// Show the tab context menu at client coordinates (x, y). Shared by
/// the tab bar and the sidebar. If clicked_tab is null (empty area),
/// only "New Tab" is shown.
fn showTabContextMenu(self: *Window, clicked_tab: ?usize, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                var current = tab;
                var i: usize = self.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = self.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab or self.hover_new_tab_dropdown) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.hover_new_tab_dropdown = false;
        self.invalidateTabBar();
    }
}

/// Hit-test a client point against the sidebar with this window's
/// current geometry and notification state.
fn sidebarHitTest(self: *Window, x: i32, y: i32) Sidebar.HitTarget {
    const hwnd = self.hwnd orelse return .none;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return .none;
    return Sidebar.hitTest(x, y, .{
        .item_h = Sidebar.itemHeight(self.scale),
        .tab_count = self.tab_count,
        .client_h = rect.bottom - rect.top,
        .width = self.sidebarWidth(),
        .scale = self.scale,
        .panel_open = self.notif_panel_open,
        .notif_count = self.app.notifCount(),
    });
}

/// Handle a left-button click in the sidebar region.
/// Selects the clicked session row or creates a new tab.
fn handleSidebarClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        .none => {},
        .item => |i| {
            // Select immediately (like the tab bar) and start tracking
            // a potential drag-reorder. selectTabIndex clears any stale
            // drag state, so set ours afterward.
            self.selectTabIndex(i);
            self.sidebar_drag_row = @intCast(i);
            self.sidebar_drag_start_y = y;
            self.sidebar_drag_active = false;
            if (self.hwnd) |h| _ = w32.SetCapture(h);
        },
        .row_close => |i| self.closeTabByIndex(i),
        .new_session => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
                return;
            };
        },
        .new_session_dropdown => {
            // Anchor the picker under the row (Windows Terminal
            // dropdown feel) rather than at the click point.
            const row = Sidebar.itemRect(
                self.tab_count,
                self.sidebarWidth(),
                Sidebar.itemHeight(self.scale),
            );
            self.showBackendMenu(row.left, row.bottom, .new_tab);
        },
        .bell_icon => {
            self.notif_panel_open = !self.notif_panel_open;
            self.app.markNotifsRead();
            self.invalidateSidebar();
        },
        .gear_icon => self.app.openConfigFile(),
        .browser_icon => self.newBrowserSplit(.right) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .notif_entry => |i| {
            if (self.app.notifAt(i)) |entry| {
                _ = self.app.jumpToSurface(entry.window, entry.surface);
            }
        },
        .notif_clear => {
            self.app.clearNotifs();
            self.invalidateSidebar();
        },
    }
}

/// Handle a right-button click in the sidebar region: show the same
/// tab context menu as the tab bar for the clicked session row, or the
/// settings menu for the gear icon.
fn handleSidebarRightClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    const clicked_tab: ?usize = switch (self.sidebarHitTest(x, y)) {
        .item => |i| i,
        .gear_icon => {
            self.showGearContextMenu(x, y);
            return;
        },
        .new_session, .new_session_dropdown => {
            self.showBackendMenu(x, y, .new_tab);
            return;
        },
        else => null,
    };
    self.showTabContextMenu(clicked_tab, x, y);
}

/// True if pwsh.exe (PowerShell 7+) is on the executable search path.
fn havePwsh() bool {
    var buf: [512]u16 = undefined;
    const n = w32.SearchPathW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"),
        null,
        buf.len,
        &buf,
        null,
    );
    return n > 0 and n < buf.len;
}

/// Where a backend picked from showBackendMenu opens: a new tab, or a
/// split off the active pane in the given direction.
pub const BackendTarget = union(enum) {
    new_tab,
    split: SplitTree(Pane).Split.Direction,
};

/// Show the backend picker at client coordinates (x, y): "Default" /
/// "PowerShell" / "Command Prompt", each installed WSL distribution
/// (Windows Terminal style), and "Browser" (a WebView2 pane). The
/// selection opens as a new tab or as a split per `target`; tabs are
/// titled after the picked backend.
pub fn showBackendMenu(self: *Window, x: i32, y: i32, target: BackendTarget) void {
    // Quick terminals exclude picker-created tabs/splits entirely.
    // They have no tab bar or sidebar, so the only QT-reachable call
    // site is the surface "Split ... With..." menu (grayed there too).
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_DEFAULT, std.unicode.utf8ToUtf16LeStringLiteral("Default"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (a cheap registry read)
    // so new installs show up without restarting. Freed after the menu
    // closes; selections copy what they need. Capped to the ID space
    // below NEW_SESSION_BROWSER.
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);

            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                NEW_SESSION_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_BROWSER, std.unicode.utf8ToUtf16LeStringLiteral("Browser"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;

    // Resolve the picked backend to an argv (null = the configured
    // default — explicit for splits, which otherwise inherit the
    // source pane's backend) and a tab title. Browser is a pane kind,
    // not a command: dispatch it directly.
    const Backend = struct {
        argv: ?[]const []const u8,
        title: ?[]const u8,
    };
    var distro_argv: [5][]const u8 = undefined;
    const backend: Backend = switch (pickerSelection(@intCast(cmd), distros.len)) {
        .none => return,
        .browser => {
            switch (target) {
                .new_tab => self.addBrowserTab() catch |err| {
                    log.err("failed to create browser tab: {}", .{err});
                },
                .split => |dir| self.newBrowserSplit(dir) catch |err| {
                    log.err("failed to open browser split: {}", .{err});
                },
            }
            return;
        },
        .default => .{ .argv = null, .title = null },
        .pwsh => .{
            .argv = if (havePwsh()) &.{"pwsh.exe"} else &.{"powershell.exe"},
            .title = "PowerShell",
        },
        .cmd => .{ .argv = &.{"cmd.exe"}, .title = "cmd" },
        .distro => |idx| blk: {
            const distro = distros[idx];
            distro_argv = .{ "wsl.exe", "--cd", "~", "-d", distro.name };
            break :blk .{ .argv = &distro_argv, .title = distro.name };
        },
    };

    switch (target) {
        .new_tab => _ = self.addTabWithCommand(backend.argv, backend.title) catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .split => |dir| self.newSplitWithCommand(dir, backend.argv) catch |err| {
            log.err("failed to create split: {}", .{err});
        },
    }
}

/// Show the settings (gear) context menu at client coordinates (x, y).
fn showGearContextMenu(self: *Window, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_CONFIG, std.unicode.utf8ToUtf16LeStringLiteral("Open config"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_FOLDER, std.unicode.utf8ToUtf16LeStringLiteral("Open config folder"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_RELOAD, std.unicode.utf8ToUtf16LeStringLiteral("Reload config"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_SET_DEFAULT_SHELL, std.unicode.utf8ToUtf16LeStringLiteral("Set default shell..."));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;
    switch (@as(usize, @intCast(cmd))) {
        GEAR_CTX_OPEN_CONFIG => self.app.openConfigFile(),
        GEAR_CTX_OPEN_FOLDER => self.app.openConfigFolder(),
        // Same path as the reload_config keybind: core performAction
        // forwards to the apprt's .reload_config handler.
        GEAR_CTX_RELOAD => self.app.core_app.performAction(
            self.app,
            .reload_config,
        ) catch |err| {
            log.err("failed to reload config: {}", .{err});
        },
        // Open the default-shell picker anchored where the gear menu
        // was. A second popup keeps this off the modal stack of the
        // first (TrackPopupMenuEx has already returned).
        GEAR_CTX_SET_DEFAULT_SHELL => self.showDefaultShellMenu(x, y),
        else => {},
    }
}

/// Resolve a default-shell picker command ID and the distro count that
/// was shown to the config value to write (e.g. "pwsh.exe" or
/// "wsl.exe --cd ~ -d Ubuntu"), or null when the menu was dismissed or
/// the ID is out of range. Pure mapping so it can be unit-tested; the
/// distro value is written into `distro_buf` and the slice returned
/// points into it.
fn defaultShellValue(
    cmd_id: usize,
    distros: []const internal_os.wsl.Distro,
    distro_buf: []u8,
) ?[]const u8 {
    switch (cmd_id) {
        DEFAULT_SHELL_PWSH => return if (havePwsh()) "pwsh.exe" else "powershell.exe",
        DEFAULT_SHELL_CMD => return "cmd.exe",
        else => {},
    }
    if (cmd_id < DEFAULT_SHELL_DISTRO_BASE) return null;
    const idx = cmd_id - DEFAULT_SHELL_DISTRO_BASE;
    if (idx >= distros.len) return null;
    // wsl.exe needs the distro selected explicitly so the default shell
    // is deterministic regardless of the WSL default.
    return std.fmt.bufPrint(
        distro_buf,
        "wsl.exe --cd ~ -d {s}",
        .{distros[idx].name},
    ) catch null;
}

/// Show the default-shell picker at client coordinates (x, y):
/// "PowerShell" / "Command Prompt" / each installed WSL distribution.
/// The chosen backend is written to the `command` config key (via
/// App.setDefaultShell), which the default-tab path already honors, and
/// the config is reloaded so it takes effect for new tabs/splits.
fn showDefaultShellMenu(self: *Window, x: i32, y: i32) void {
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (mirrors showBackendMenu).
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        DEFAULT_SHELL_DISTRO_CAP - DEFAULT_SHELL_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);
            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                DEFAULT_SHELL_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    if (self.closing) return;

    var distro_buf: [512]u8 = undefined;
    const value = defaultShellValue(@intCast(cmd), distros, &distro_buf) orelse return;
    self.app.setDefaultShell(value);
}

/// Handle mouse movement over the sidebar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleSidebarMouseMove(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    const new_hover = self.sidebarHitTest(x, y);
    if (!std.meta.eql(new_hover, self.sidebar_hover)) {
        self.sidebar_hover = new_hover;
        self.invalidateSidebar();
    }
}

/// Reset sidebar hover state when the mouse leaves the sidebar.
fn clearSidebarHover(self: *Window) void {
    if (self.sidebar_hover != .none) {
        self.sidebar_hover = .none;
        self.invalidateSidebar();
    }
}

/// Rename edit control child ID.
const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    // Cancel any existing rename
    self.cancelTabRename();

    const hwnd = self.hwnd orelse return;
    const rect = self.tab_rects[tab_idx];

    // tab_titles stores only `tab_title_lens` valid u16s; the rest is
    // uninitialized. CreateWindowExW reads a NUL-terminated wide string,
    // so a NUL-terminated copy avoids the Edit displaying garbage past
    // the real title.
    var title_buf: [257]u16 = undefined;
    const tlen = self.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], self.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 0, 0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}

/// Apply the edit text as the new tab title and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (wlen > 0) {
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| { _ = w32.DeleteObject(f); self.rename_font = null; }
    self.invalidateTabBar();
    self.invalidateSidebar();

    // Return focus to the active pane
    if (self.getActivePane()) |p| p.focus();
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| { _ = w32.DeleteObject(f); self.rename_font = null; }
        if (self.getActivePane()) |p| p.focus();
    }
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    // Flag teardown FIRST: destroying a browser pane's host HWND inside
    // cleanupAllSurfaces moves focus synchronously back into
    // windowWndProc (WM_SETFOCUS), and other queued input can be
    // dispatched during the destroy. The closing guards drop those
    // messages so nothing touches the mid-teardown tab arrays.
    self.closing = true;

    // Cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;

    // Invalidate any in-flight desktop-notification click targets that
    // point at this window before its memory is freed.
    app.dropDesktopNotifsForWindow(self);

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SIZE => {
            window.handleResize();
            return 0;
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| switch (entry.view.content) {
                    .terminal => |s| if (s.scrollbar) |sb| {
                        _ = sb.repositionAndResize();
                    },
                    .browser => |b| b.onParentWindowMoved(),
                };
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| switch (entry.view.content) {
                    .terminal => |s| s.in_live_resize = true,
                    .browser => {},
                };
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| switch (entry.view.content) {
                    .terminal => |s| s.in_live_resize = false,
                    .browser => {},
                };
            }
            // Resize/move drag settled — persist the new geometry. This
            // debounces saves: nothing is written during the live drag
            // (WM_SIZE/WM_MOVE), only once on settle.
            window.savePlacement();
            return 0;
        },
        w32.WM_CLOSE => {
            // Capture final geometry before teardown. close() flips the
            // closing flag and destroys the HWND, after which the rect is
            // unrecoverable.
            window.savePlacement();
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintChrome();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child pane.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the content.
            if (window.getActivePane()) |p| p.focus();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hitTestSidebarEdge(x)) {
                window.startSidebarDrag();
                return 0;
            }
            if (x < window.sidebarWidth()) {
                window.handleSidebarClick(x, y);
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            if (window.dragging_sidebar) {
                window.endSidebarDrag();
                return 0;
            }
            if (window.sidebar_drag_row >= 0) {
                window.endSidebarRowDrag();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click on tab bar starts inline rename
            if (y < window.tabBarHeight()) {
                for (0..window.tab_count) |i| {
                    const rect = window.tab_rects[i];
                    if (x >= rect.left and x < rect.right) {
                        window.startTabRename(i);
                        return 0;
                    }
                }
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (x < window.sidebarWidth()) {
                window.handleSidebarRightClick(x, y);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            if (window.dragging_sidebar) {
                window.updateSidebarDrag(x);
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.tab_count > 1) {
                    // Use uniform tab widths for drag target calculation,
                    // not the painted widths (the last tab gets stretched
                    // to fill remaining space, skewing its midpoint).
                    const from: usize = @intCast(window.drag_tab);
                    const first_w = window.tab_rects[0].right - window.tab_rects[0].left;
                    var target: usize = 0;
                    for (0..window.tab_count) |i| {
                        const slot_left: i32 = @intCast(@as(i32, @intCast(i)) * first_w);
                        const slot_mid = slot_left + @divTrunc(first_w, 2);
                        if (x >= slot_mid) {
                            target = i;
                        }
                    }
                    // Clamp to valid range
                    if (target >= window.tab_count) target = window.tab_count - 1;
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            // Handle sidebar row drag-reorder.
            if (window.sidebar_drag_row >= 0) {
                const dy = if (y > window.sidebar_drag_start_y)
                    y - window.sidebar_drag_start_y
                else
                    window.sidebar_drag_start_y - y;
                const threshold = Sidebar.dragThreshold(window.scale);
                if (!window.sidebar_drag_active and dy > threshold) {
                    window.sidebar_drag_active = true;
                }
                if (window.sidebar_drag_active and window.tab_count > 1) {
                    const from: usize = @intCast(window.sidebar_drag_row);
                    const target = window.sidebarDragTarget(y);
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.sidebar_drag_row = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (window.hitTestSidebarEdge(x)) {
                // Over the resize band: suppress row hover so the
                // band reads as a grab edge, not a row.
                window.clearSidebarHover();
                return 0;
            }
            if (x < window.sidebarWidth()) {
                window.handleSidebarMouseMove(x, y);
                return 0;
            }
            window.clearSidebarHover();
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            // While dragging the sidebar edge the cursor can leave the
            // band (the width is clamped), so don't re-hit-test.
            if (window.dragging_sidebar) {
                if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| {
                    _ = w32.SetCursor(cursor);
                }
                return 1;
            }
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestSidebarEdge(pt.x)) {
                    if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            window.clearSidebarHover();
            return 0;
        },
        w32.WM_CAPTURECHANGED => {
            // Capture stolen (e.g. a menu or modal opened mid-drag):
            // end the sidebar edge drag and any row drag-reorder so they
            // stop tracking the mouse. Re-entry from our own
            // ReleaseCapture is a no-op via the dragging_sidebar /
            // sidebar_drag_row guards.
            window.endSidebarDrag();
            window.endSidebarRowDrag();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: window title cap ascii passes through" {
    try testing.expectEqualStrings("hello", capUtf8("hello", 255));
}

test "unit: window title cap exact boundary is unchanged" {
    try testing.expectEqualStrings("abcd", capUtf8("abcd", 4));
}

test "unit: window title cap truncates past the boundary" {
    try testing.expectEqualStrings("abc", capUtf8("abcdef", 3));
}

test "unit: window title cap backs up over a split multi-byte sequence" {
    // "aé" = 61 C3 A9; a cap of 2 lands inside é.
    try testing.expectEqualStrings("a", capUtf8("a\xC3\xA9", 2));
    // 4-byte emoji (U+1F600 = F0 9F 98 80) split at every interior byte.
    const emoji = "ab\xF0\x9F\x98\x80";
    try testing.expectEqualStrings("ab", capUtf8(emoji, 3));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 4));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 5));
}

test "unit: window title cap at a sequence boundary keeps the sequence" {
    try testing.expectEqualStrings("a\xC3\xA9", capUtf8("a\xC3\xA9b", 3));
}

test "unit: window title cap empty and degenerate inputs" {
    try testing.expectEqualStrings("", capUtf8("", 255));
    try testing.expectEqualStrings("", capUtf8("abc", 0));
    // All continuation bytes (malformed input): backs up to empty
    // rather than returning a partial sequence.
    try testing.expectEqualStrings("", capUtf8("\x80\x80\x80", 2));
}

test "unit: tab arrays insert gap at the end moves nothing" {
    var ids = [_]u8{ 1, 2, 3, 0xAA };
    var lens = [_]u16{ 10, 20, 30, 0xBBBB };
    tabArraysInsertGap(.{ &ids, &lens }, 3, 3);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0xAA }, &ids);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 30, 0xBBBB }, &lens);
}

test "unit: tab arrays insert gap in the middle shifts the tail right" {
    var ids = [_]u8{ 1, 2, 3, 0 };
    var lens = [_]u16{ 10, 20, 30, 0 };
    tabArraysInsertGap(.{ &ids, &lens }, 3, 1);
    // The gap at 1 still holds its old value (the caller overwrites
    // it); entries 2..3 are the old 1..2.
    try testing.expectEqualSlices(u8, &.{ 1, 2, 2, 3 }, &ids);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 20, 30 }, &lens);
}

test "unit: tab arrays remove at both edges" {
    const Status = enum { normal, bell };
    // Right edge: pure count decrement, no movement.
    {
        var ids = [_]u8{ 1, 2, 3 };
        var status = [_]Status{ .normal, .bell, .bell };
        tabArraysRemove(.{ &ids, &status }, 3, 2);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &ids);
        try testing.expectEqualSlices(Status, &.{ .normal, .bell, .bell }, &status);
    }
    // Left edge: everything shifts down one (the last slot keeps a
    // duplicate the caller clears where stale pointers matter).
    {
        var ids = [_]u8{ 1, 2, 3 };
        var status = [_]Status{ .bell, .normal, .bell };
        tabArraysRemove(.{ &ids, &status }, 3, 0);
        try testing.expectEqualSlices(u8, &.{ 2, 3, 3 }, &ids);
        try testing.expectEqualSlices(Status, &.{ .normal, .bell, .bell }, &status);
    }
}

test "unit: tab arrays move right, left, and adjacent" {
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 0, 3);
        try testing.expectEqualSlices(u8, &.{ 2, 3, 4, 1 }, &ids);
    }
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 3, 0);
        try testing.expectEqualSlices(u8, &.{ 4, 1, 2, 3 }, &ids);
    }
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 1, 2);
        try testing.expectEqualSlices(u8, &.{ 1, 3, 2, 4 }, &ids);
    }
}

test "unit: tab arrays swap" {
    var ids = [_]u8{ 1, 2, 3 };
    var lens = [_]u16{ 10, 20, 30 };
    tabArraysSwap(.{ &ids, &lens }, 0, 2);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, &ids);
    try testing.expectEqualSlices(u16, &.{ 30, 20, 10 }, &lens);
}

test "unit: tab arrays stay aligned across a mutation sequence" {
    // The real invariant: entry i of every parallel array must describe
    // the same logical tab after any mix of operations. Tab n carries
    // id n and "title" n+100.
    var ids: [5]u8 = undefined;
    var titles: [5]u8 = undefined;
    var count: usize = 0;
    const arrays = .{ &ids, &titles };

    // Insert 1 then 2 at the end, then 3 in the middle: order 1,3,2.
    tabArraysInsertGap(arrays, count, 0);
    ids[0] = 1;
    titles[0] = 101;
    count += 1;
    tabArraysInsertGap(arrays, count, 1);
    ids[1] = 2;
    titles[1] = 102;
    count += 1;
    tabArraysInsertGap(arrays, count, 1);
    ids[1] = 3;
    titles[1] = 103;
    count += 1;

    tabArraysMove(arrays, 0, 2); // 3,2,1
    tabArraysSwap(arrays, 0, 1); // 2,3,1
    tabArraysRemove(arrays, count, 1); // 2,1
    count -= 1;

    try testing.expectEqualSlices(u8, &.{ 2, 1 }, ids[0..count]);
    for (ids[0..count], titles[0..count]) |id, title| {
        try testing.expectEqual(id + 100, title);
    }
}

test "unit: picker selection maps the fixed entries" {
    try testing.expectEqual(PickerSelection.default, pickerSelection(NEW_SESSION_DEFAULT, 0));
    try testing.expectEqual(PickerSelection.pwsh, pickerSelection(NEW_SESSION_PWSH, 0));
    try testing.expectEqual(PickerSelection.cmd, pickerSelection(NEW_SESSION_CMD, 0));
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 0));
}

test "unit: picker selection maps distro ids by index" {
    try testing.expectEqual(PickerSelection{ .distro = 0 }, pickerSelection(NEW_SESSION_DISTRO_BASE, 3));
    try testing.expectEqual(PickerSelection{ .distro = 2 }, pickerSelection(NEW_SESSION_DISTRO_BASE + 2, 3));
    // At or past the appended count: stale or foreign ID, no action.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE + 3, 3));
}

test "unit: picker selection ignores dismissal and unknown ids" {
    // TrackPopupMenu returns 0 when the menu is dismissed.
    try testing.expectEqual(PickerSelection.none, pickerSelection(0, 5));
    // Gaps in the ID space around the distro range.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_CMD + 1, 5));
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE - 1, 5));
    // The Surface "Split ... With..." IDs (9321/9322) live above the
    // browser entry and must not resolve here.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_BROWSER + 1, 5));
}

test "unit: picker browser id can never be claimed by a distro" {
    // The call site caps the distro list below NEW_SESSION_BROWSER;
    // even an uncapped count must resolve 9320 to browser, with the
    // last representable distro index directly below it.
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 64));
    const cap = NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE;
    try testing.expectEqual(
        PickerSelection{ .distro = cap - 1 },
        pickerSelection(NEW_SESSION_BROWSER - 1, cap),
    );
}

test "unit: picker menu ids match the reserved registry" {
    // 9300-9302 shells, 9310-9319 distros, 9320 browser (see the menu
    // ID comment block); a change here collides with other menus.
    try testing.expectEqual(@as(usize, 9300), NEW_SESSION_DEFAULT);
    try testing.expectEqual(@as(usize, 9301), NEW_SESSION_PWSH);
    try testing.expectEqual(@as(usize, 9302), NEW_SESSION_CMD);
    try testing.expectEqual(@as(usize, 9310), NEW_SESSION_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9320), NEW_SESSION_BROWSER);
}

test "unit: distro menu label formats the default marker" {
    const alloc = testing.allocator;
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", false);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04", label);
    }
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", true);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04 (default)", label);
    }
}

test "unit: default-shell value maps the fixed shells" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{};

    // cmd is deterministic.
    try testing.expectEqualStrings(
        "cmd.exe",
        defaultShellValue(DEFAULT_SHELL_CMD, distros, &buf).?,
    );

    // pwsh resolves to one of the two PowerShell exes depending on
    // whether PowerShell 7 is installed on the test host.
    const pwsh = defaultShellValue(DEFAULT_SHELL_PWSH, distros, &buf).?;
    try testing.expect(
        std.mem.eql(u8, pwsh, "pwsh.exe") or
            std.mem.eql(u8, pwsh, "powershell.exe"),
    );
}

test "unit: default-shell value formats the distro argv" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
        .{ .name = "Debian", .guid = "{y}", .is_default = false, .version = 2 },
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Ubuntu",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE, distros, &buf).?,
    );
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Debian",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf).?,
    );
}

test "unit: default-shell value ignores dismissal and out-of-range ids" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
    };
    // Dismissal (0) and ids in gaps / past the distro count.
    try testing.expectEqual(@as(?[]const u8, null), defaultShellValue(0, distros, &buf));
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE - 1, distros, &buf),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf),
    );
}

test "unit: default-shell menu ids match the reserved registry" {
    // 9410 set-default entry, 9411/9412 shells, 9420+ distros capped at
    // 9450 (see the menu ID comment block). A change here risks a
    // collision with another menu's IDs.
    try testing.expectEqual(@as(usize, 9410), GEAR_CTX_SET_DEFAULT_SHELL);
    try testing.expectEqual(@as(usize, 9411), DEFAULT_SHELL_PWSH);
    try testing.expectEqual(@as(usize, 9412), DEFAULT_SHELL_CMD);
    try testing.expectEqual(@as(usize, 9420), DEFAULT_SHELL_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9450), DEFAULT_SHELL_DISTRO_CAP);
}

// Pull the persisted window-state module's unit tests (serialize/parse
// round-trip, corrupt-input tolerance, off-screen clamp) into the test
// binary. Window.zig uses WindowState's decls, but Zig only auto-includes
// a referenced file's `test` blocks when the file itself is referenced
// for testing — hence this explicit reference.
test {
    _ = WindowState;
}
