//! Session sidebar for the Win32 apprt. A vertical strip on the left
//! edge of the window that lists each tab as a session row plus a
//! "+ New session" row. Enabled via the `window-show-sidebar` config
//! option, which replaces the top tab bar.

const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const testing = std.testing;

const ITEM_HEIGHT_BASE: i32 = 36;
const PAD_BASE: i32 = 8;
const ACCENT_W_BASE: i32 = 3;

/// Result of hit-testing a point against the sidebar rows.
pub const HitTarget = union(enum) {
    none,
    item: usize,
    new_session,
};

/// Row height in pixels at the given DPI scale.
pub fn itemHeight(scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(ITEM_HEIGHT_BASE)) * scale));
}

/// Hit-test a y coordinate against the sidebar rows. Rows
/// 0..tab_count-1 are sessions, the row directly below the last
/// session is "+ New session", and anything below that (or above the
/// top) is .none.
pub fn hitTest(y: i32, item_h: i32, tab_count: usize) HitTarget {
    if (y < 0 or item_h <= 0) return .none;
    const row: usize = @intCast(@divTrunc(y, item_h));
    if (row < tab_count) return .{ .item = row };
    if (row == tab_count) return .new_session;
    return .none;
}

/// The rectangle of row `index` in a sidebar of the given width.
pub fn itemRect(index: usize, width: i32, item_h: i32) w32.RECT {
    const top = @as(i32, @intCast(index)) * item_h;
    return .{ .left = 0, .top = top, .right = width, .bottom = top + item_h };
}

/// Paint the full sidebar strip using double-buffered GDI painting.
/// Draws session rows (status dot, number, title) and the
/// "+ New session" row. The caller owns BeginPaint/EndPaint.
pub fn paint(win: *Window, hdc_screen: w32.HDC) void {
    const hwnd = win.hwnd orelse return;
    const sidebar_w = win.sidebarWidth();
    if (sidebar_w <= 0) return;

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_h = client_rect.bottom - client_rect.top;
    if (client_h <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, sidebar_w, client_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = win.app.config.background;
    // Sidebar background: terminal bg + 12 per channel. Slightly darker
    // than the tab bar's +20 so the two chrome strips read as distinct.
    const bar_r: u8 = @min(@as(u16, bg.r) + 12, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 12, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 12, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover row: terminal bg + 35 per channel (same as tab bar hover).
    const hover_r: u8 = @min(@as(u16, bg.r) + 35, 255);
    const hover_g: u8 = @min(@as(u16, bg.g) + 35, 255);
    const hover_b: u8 = @min(@as(u16, bg.b) + 35, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active row background: terminal bg (darker than the sidebar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent bar color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);

    // Status dot colors.
    const bell_color = w32.RGB(255, 185, 0);
    const exited_color = w32.RGB(232, 65, 65);

    // --- Fill sidebar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = sidebar_w, .bottom = client_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (win.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Row geometry ---
    const item_h = itemHeight(win.scale);
    const pad: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(PAD_BASE)) * win.scale));
    const accent_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(ACCENT_W_BASE)) * win.scale));
    // Fixed-width status dot column so numbers/titles align across rows.
    const dot_w = pad * 2;

    // --- Draw each session row ---
    for (0..win.tab_count) |i| {
        var row = itemRect(i, sidebar_w, item_h);
        const is_active = (i == win.active_tab);
        const is_hovered = switch (win.sidebar_hover) {
            .item => |h| h == i,
            else => false,
        };

        if (is_active) {
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent bar on the left edge.
            var accent_rect = w32.RECT{
                .left = 0,
                .top = row.top,
                .right = accent_w,
                .bottom = row.bottom,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw status dot.
        if (win.tab_status[i] != .normal) {
            _ = w32.SetTextColor(mem_dc, switch (win.tab_status[i]) {
                .bell => bell_color,
                .exited => exited_color,
                .normal => unreachable,
            });
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var dot_rect = w32.RECT{
                .left = accent_w + pad,
                .top = row.top,
                .right = accent_w + pad + dot_w,
                .bottom = row.bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Draw "N  title" where N is index+1 for the first nine rows
        // (matches the default alt+1..8 goto_tab keybinds).
        var text_buf: [260]u16 = undefined;
        var text_len: usize = 0;
        if (i < 9) {
            text_buf[0] = '1' + @as(u16, @intCast(i));
            text_buf[1] = ' ';
            text_buf[2] = ' ';
            text_len = 3;
        }
        const title_len: usize = win.tab_title_lens[i];
        @memcpy(text_buf[text_len .. text_len + title_len], win.tab_titles[i][0..title_len]);
        text_len += title_len;

        if (text_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = accent_w + pad + dot_w,
                .top = row.top,
                .right = sidebar_w - pad,
                .bottom = row.bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&text_buf),
                @intCast(text_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }
    }

    // --- Draw "+ New session" row ---
    {
        var row = itemRect(win.tab_count, sidebar_w, item_h);
        if (win.sidebar_hover == .new_session) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const label = std.unicode.utf8ToUtf16LeStringLiteral("+ New session");
        var text_rect = w32.RECT{
            .left = accent_w + pad,
            .top = row.top,
            .right = sidebar_w - pad,
            .bottom = row.bottom,
        };
        _ = w32.DrawTextW(
            mem_dc,
            label,
            label.len,
            &text_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, sidebar_w, client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sidebar hitTest: rows map to items" {
    try testing.expectEqual(HitTarget{ .item = 0 }, hitTest(0, 36, 3));
    try testing.expectEqual(HitTarget{ .item = 0 }, hitTest(35, 36, 3));
    try testing.expectEqual(HitTarget{ .item = 2 }, hitTest(2 * 36, 36, 3));
}

test "sidebar hitTest: row boundary belongs to the lower row" {
    // y == item_h is the first pixel of row 1, not part of row 0.
    try testing.expectEqual(HitTarget{ .item = 1 }, hitTest(36, 36, 3));
}

test "sidebar hitTest: new session row directly below sessions" {
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(3 * 36, 36, 3));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(4 * 36 - 1, 36, 3));
}

test "sidebar hitTest: below the new session row is none" {
    try testing.expectEqual(@as(HitTarget, .none), hitTest(4 * 36, 36, 3));
}

test "sidebar hitTest: zero tabs" {
    // With no sessions, row 0 is the "+ New session" row.
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(0, 36, 0));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(36, 36, 0));
}

test "sidebar hitTest: negative y is none" {
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-1, 36, 3));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-100, 36, 3));
}

test "sidebar itemRect: first row spans the full width" {
    const r = itemRect(0, 220, 36);
    try testing.expectEqual(@as(i32, 0), r.left);
    try testing.expectEqual(@as(i32, 0), r.top);
    try testing.expectEqual(@as(i32, 220), r.right);
    try testing.expectEqual(@as(i32, 36), r.bottom);
}

test "sidebar itemRect: rows stack by item height" {
    const r = itemRect(2, 220, 36);
    try testing.expectEqual(@as(i32, 72), r.top);
    try testing.expectEqual(@as(i32, 108), r.bottom);
}

test "sidebar hitTest and itemRect agree on row bounds" {
    const item_h: i32 = 36;
    for (0..4) |i| {
        const r = itemRect(i, 220, item_h);
        try testing.expectEqual(HitTarget{ .item = i }, hitTest(r.top, item_h, 5));
        try testing.expectEqual(HitTarget{ .item = i }, hitTest(r.bottom - 1, item_h, 5));
    }
}
