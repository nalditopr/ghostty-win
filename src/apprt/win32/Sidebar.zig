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
const EDGE_BAND_BASE: i32 = 5;
const FOOTER_H_BASE: i32 = 32;
const FOOTER_ICON_BASE: i32 = 24;
const NOTIF_HEADER_BASE: i32 = 24;
const NOTIF_ENTRY_BASE: i32 = 40;
const NOTIF_CLEAR_W_BASE: i32 = 48;
const BADGE_BASE: i32 = 14;

/// Sidebar width clamp bounds in unscaled pixels, applied to both the
/// `window-sidebar-width` config value and the drag-resize override.
pub const MIN_WIDTH: u32 = 120;
pub const MAX_WIDTH: u32 = 400;

/// Result of hit-testing a point against the sidebar.
pub const HitTarget = union(enum) {
    none,
    item: usize,
    new_session,
    bell_icon,
    gear_icon,
    browser_icon,
    /// Display index into the notification log, 0 = newest.
    notif_entry: usize,
    notif_clear,
};

/// Pixel value of an unscaled base constant at the given DPI scale.
fn scaled(base: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * scale));
}

/// Row height in pixels at the given DPI scale.
pub fn itemHeight(scale: f32) i32 {
    return scaled(ITEM_HEIGHT_BASE, scale);
}

/// Width of the drag-resize grab band along the sidebar's right edge,
/// in pixels at the given DPI scale.
pub fn edgeBandWidth(scale: f32) i32 {
    return scaled(EDGE_BAND_BASE, scale);
}

/// Height of the footer strip (bell/gear icons) at the given DPI scale.
pub fn footerHeight(scale: f32) i32 {
    return scaled(FOOTER_H_BASE, scale);
}

/// Height of the notifications panel: ~40% of the client height.
pub fn panelHeight(client_h: i32) i32 {
    return @divTrunc(client_h * 2, 5);
}

/// Height of one notification entry row at the given DPI scale.
pub fn notifEntryHeight(scale: f32) i32 {
    return scaled(NOTIF_ENTRY_BASE, scale);
}

/// Icon slot rect for the bell, vertically centered in the footer.
pub fn bellSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    return .{ .left = pad, .top = top, .right = pad + icon, .bottom = top + icon };
}

/// Icon slot rect for the gear, vertically centered in the footer.
pub fn gearSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    return .{ .left = pad + icon + pad, .top = top, .right = pad + icon + pad + icon, .bottom = top + icon };
}

/// Icon slot rect for the browser globe (third slot), vertically
/// centered in the footer.
pub fn globeSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    const left = (pad + icon) * 2 + pad;
    return .{ .left = left, .top = top, .right = left + icon, .bottom = top + icon };
}

/// Hit-test an x coordinate against the drag-resize grab band, which
/// spans [edge - band_w, edge) where `edge` is the sidebar's right
/// edge. A hidden sidebar (edge <= 0) has no band.
pub fn hitTestEdge(x: i32, edge: i32, band_w: i32) bool {
    if (edge <= 0) return false;
    return x >= edge - band_w and x < edge;
}

/// Window-side state hitTest needs beyond the point itself. All
/// fields are plain values so the function stays pure and testable.
pub const HitCtx = struct {
    item_h: i32,
    tab_count: usize,
    /// Full client height (the footer is anchored to the bottom).
    client_h: i32,
    /// Sidebar width (the "Clear" button is right-aligned).
    width: i32,
    scale: f32,
    panel_open: bool,
    /// Number of entries currently in the notification log.
    notif_count: usize,
};

/// Hit-test a point against the sidebar. Top-to-bottom: session rows
/// (0..tab_count-1), the "+ New session" row, then — when open — the
/// notifications panel (header with the Clear button, entry rows
/// newest-first), and finally the footer strip (bell/gear icons). The
/// row area ends at the panel top (footer top when closed); rows under
/// the panel/footer are not hit.
pub fn hitTest(x: i32, y: i32, ctx: HitCtx) HitTarget {
    if (y < 0 or ctx.item_h <= 0) return .none;
    if (y >= ctx.client_h) return .none;

    const footer_top = ctx.client_h - footerHeight(ctx.scale);
    if (y >= footer_top) {
        // Footer icon slots span the full strip height for a more
        // forgiving click zone; only x decides the slot.
        const pad = scaled(PAD_BASE, ctx.scale);
        const icon = scaled(FOOTER_ICON_BASE, ctx.scale);
        if (x >= pad and x < pad + icon) return .bell_icon;
        const gear_left = pad + icon + pad;
        if (x >= gear_left and x < gear_left + icon) return .gear_icon;
        const globe_left = gear_left + icon + pad;
        if (x >= globe_left and x < globe_left + icon) return .browser_icon;
        return .none;
    }

    if (ctx.panel_open) {
        const panel_top = footer_top - panelHeight(ctx.client_h);
        if (y >= panel_top) {
            const rel = y - panel_top;
            const header_h = scaled(NOTIF_HEADER_BASE, ctx.scale);
            if (rel < header_h) {
                const clear_w = scaled(NOTIF_CLEAR_W_BASE, ctx.scale);
                if (x >= ctx.width - clear_w) return .notif_clear;
                return .none;
            }
            const entry_h = notifEntryHeight(ctx.scale);
            if (entry_h <= 0) return .none;
            const idx: usize = @intCast(@divTrunc(rel - header_h, entry_h));
            if (idx < ctx.notif_count) return .{ .notif_entry = idx };
            return .none;
        }
    }

    const row: usize = @intCast(@divTrunc(y, ctx.item_h));
    if (row < ctx.tab_count) return .{ .item = row };
    if (row == ctx.tab_count) return .new_session;
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
    const pad = scaled(PAD_BASE, win.scale);
    const accent_w = scaled(ACCENT_W_BASE, win.scale);
    // Fixed-width status dot column so numbers/titles align across rows.
    const dot_w = pad * 2;

    // Footer/panel geometry. Session rows are painted full-length and
    // the panel/footer fills below overdraw them, which clips rows to
    // the visible area without GDI clip regions.
    const footer_top = client_h - footerHeight(win.scale);
    const panel_top = if (win.notif_panel_open)
        footer_top - panelHeight(client_h)
    else
        footer_top;

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

    // --- Notifications panel ---
    if (win.notif_panel_open and panel_top < footer_top) {
        // Panel background: terminal bg + 6, slightly darker than the
        // sidebar's +12 so the panel reads as a separate layer.
        const panel_r: u8 = @min(@as(u16, bg.r) + 6, 255);
        const panel_g: u8 = @min(@as(u16, bg.g) + 6, 255);
        const panel_b: u8 = @min(@as(u16, bg.b) + 6, 255);
        var panel_rect = w32.RECT{ .left = 0, .top = panel_top, .right = sidebar_w, .bottom = footer_top };
        if (w32.CreateSolidBrush(w32.RGB(panel_r, panel_g, panel_b))) |brush| {
            _ = w32.FillRect(mem_dc, &panel_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Header row: "Clear" text button, right-aligned.
        const header_h = scaled(NOTIF_HEADER_BASE, win.scale);
        const clear_w = scaled(NOTIF_CLEAR_W_BASE, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .notif_clear)
            active_text_color
        else
            inactive_text_color);
        const clear_label = std.unicode.utf8ToUtf16LeStringLiteral("Clear");
        var clear_rect = w32.RECT{
            .left = sidebar_w - clear_w,
            .top = panel_top,
            .right = sidebar_w - pad,
            .bottom = panel_top + header_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            clear_label,
            clear_label.len,
            &clear_rect,
            w32.DT_RIGHT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Entries, newest first. Entries that cross the footer are
        // drawn truncated (the footer fill below overdraws the rest).
        const entry_h = notifEntryHeight(win.scale);
        var entry_top = panel_top + header_h;
        var i: usize = 0;
        while (entry_top < footer_top) : ({
            i += 1;
            entry_top += entry_h;
        }) {
            const entry = win.app.notifAt(i) orelse break;
            const entry_bottom = @min(entry_top + entry_h, footer_top);

            const entry_hovered = switch (win.sidebar_hover) {
                .notif_entry => |h| h == i,
                else => false,
            };
            if (entry_hovered) {
                var hover_rect = w32.RECT{ .left = 0, .top = entry_top, .right = sidebar_w, .bottom = entry_bottom };
                if (w32.CreateSolidBrush(hover_color)) |brush| {
                    _ = w32.FillRect(mem_dc, &hover_rect, brush);
                    _ = w32.DeleteObject(@ptrCast(brush));
                }
            }

            // Kind dot, colored like the session status dots.
            _ = w32.SetTextColor(mem_dc, switch (entry.kind) {
                .bell => bell_color,
                .exited => exited_color,
                .osc => accent_color,
            });
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var entry_dot_rect = w32.RECT{
                .left = accent_w + pad,
                .top = entry_top,
                .right = accent_w + pad + dot_w,
                .bottom = entry_bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &entry_dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );

            // Two lines: title (bright) over body (dim).
            const text_left = accent_w + pad + dot_w;
            const half_h = @divTrunc(entry_h, 2);
            if (entry.title_len > 0) {
                _ = w32.SetTextColor(mem_dc, active_text_color);
                var title_rect = w32.RECT{
                    .left = text_left,
                    .top = entry_top,
                    .right = sidebar_w - pad,
                    .bottom = @min(entry_top + half_h, entry_bottom),
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&entry.title),
                    @intCast(entry.title_len),
                    &title_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }
            if (entry.body_len > 0 and entry_top + half_h < entry_bottom) {
                _ = w32.SetTextColor(mem_dc, inactive_text_color);
                var body_rect = w32.RECT{
                    .left = text_left,
                    .top = entry_top + half_h,
                    .right = sidebar_w - pad,
                    .bottom = entry_bottom,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&entry.body),
                    @intCast(entry.body_len),
                    &body_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }
        }
    }

    // --- Footer strip ---
    {
        // Re-fill with the sidebar bg to overdraw any rows that ran
        // under the footer.
        var footer_rect = w32.RECT{ .left = 0, .top = footer_top, .right = sidebar_w, .bottom = client_h };
        if (w32.CreateSolidBrush(bar_color)) |brush| {
            _ = w32.FillRect(mem_dc, &footer_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Bell icon. U+1F514 falls back through GDI font linking; on
        // systems without an emoji/symbol font it may render as tofu.
        var bell_rect = bellSlotRect(footer_top, win.scale);
        const bell_hot = win.notif_panel_open or win.sidebar_hover == .bell_icon;
        _ = w32.SetTextColor(mem_dc, if (bell_hot) active_text_color else inactive_text_color);
        const bell_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F514}");
        _ = w32.DrawTextW(
            mem_dc,
            bell_char,
            bell_char.len,
            &bell_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Gear icon: U+2699 without U+FE0F so GDI keeps the text-style
        // glyph instead of the color emoji presentation.
        var gear_rect = gearSlotRect(footer_top, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .gear_icon)
            active_text_color
        else
            inactive_text_color);
        const gear_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{2699}");
        _ = w32.DrawTextW(
            mem_dc,
            gear_char,
            gear_char.len,
            &gear_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Browser globe icon. Like the bell, U+1F310 relies on GDI
        // font linking for the glyph.
        var globe_rect = globeSlotRect(footer_top, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .browser_icon)
            active_text_color
        else
            inactive_text_color);
        const globe_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F310}");
        _ = w32.DrawTextW(
            mem_dc,
            globe_char,
            globe_char.len,
            &globe_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Unread badge: amber square at the bell's top-right corner.
        const unread = win.app.notif_unread;
        if (unread > 0) {
            const badge = scaled(BADGE_BASE, win.scale);
            var badge_rect = w32.RECT{
                .left = bell_rect.right - badge + scaled(5, win.scale),
                .top = bell_rect.top - scaled(3, win.scale),
                .right = bell_rect.right + scaled(5, win.scale),
                .bottom = bell_rect.top - scaled(3, win.scale) + badge,
            };
            if (w32.CreateSolidBrush(bell_color)) |brush| {
                _ = w32.FillRect(mem_dc, &badge_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            var count_buf: [2]u16 = undefined;
            const count_len: u32 = if (unread > 9) blk: {
                count_buf[0] = '9';
                count_buf[1] = '+';
                break :blk 2;
            } else blk: {
                count_buf[0] = '0' + @as(u16, @intCast(unread));
                break :blk 1;
            };
            // The tab font is too tall for the badge; use a temporary
            // smaller one.
            if (w32.CreateFontW(
                -scaled(10, win.scale),
                0, 0, 0,
                w32.FW_NORMAL,
                0, 0, 0,
                w32.DEFAULT_CHARSET,
                0, 0, 0, 0,
                std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
            )) |badge_font| {
                const prev_font = w32.SelectObject(mem_dc, badge_font);
                _ = w32.SetTextColor(mem_dc, w32.RGB(32, 32, 32));
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&count_buf),
                    @intCast(count_len),
                    &badge_rect,
                    w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
                );
                _ = w32.SelectObject(mem_dc, prev_font);
                _ = w32.DeleteObject(badge_font);
            }
        }
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, sidebar_w, client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// hitTest context used by the tests: scale 1.0, 400px tall, 220px
/// wide. Derived geometry: footer_top=368, panel_h=160, panel_top=208
/// (open), bell x in [8,32), gear x in [40,64), globe x in [72,96),
/// panel header y in [208,232) with Clear at x>=172, entry rows 40px
/// from y=232.
fn testCtx(tab_count: usize, panel_open: bool, notif_count: usize) HitCtx {
    return .{
        .item_h = 36,
        .tab_count = tab_count,
        .client_h = 400,
        .width = 220,
        .scale = 1.0,
        .panel_open = panel_open,
        .notif_count = notif_count,
    };
}

test "sidebar hitTest: rows map to items" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(HitTarget{ .item = 0 }, hitTest(10, 0, ctx));
    try testing.expectEqual(HitTarget{ .item = 0 }, hitTest(10, 35, ctx));
    try testing.expectEqual(HitTarget{ .item = 2 }, hitTest(10, 2 * 36, ctx));
}

test "sidebar hitTest: row boundary belongs to the lower row" {
    // y == item_h is the first pixel of row 1, not part of row 0.
    try testing.expectEqual(HitTarget{ .item = 1 }, hitTest(10, 36, testCtx(3, false, 0)));
}

test "sidebar hitTest: new session row directly below sessions" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 4 * 36 - 1, ctx));
}

test "sidebar hitTest: below the new session row is none" {
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 4 * 36, testCtx(3, false, 0)));
}

test "sidebar hitTest: zero tabs" {
    // With no sessions, row 0 is the "+ New session" row.
    const ctx = testCtx(0, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 36, ctx));
}

test "sidebar hitTest: negative y is none" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, -1, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, -100, ctx));
}

test "sidebar hitTest: y at or below the client bottom is none" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 400, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 500, ctx));
}

test "sidebar hitTest: footer bell and gear slots" {
    const ctx = testCtx(3, false, 0);
    // Bell: x in [8, 32).
    try testing.expectEqual(@as(HitTarget, .none), hitTest(7, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(8, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(31, 399, ctx));
    // Gap between the slots.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(32, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(39, 368, ctx));
    // Gear: x in [40, 64).
    try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(40, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(63, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(64, 368, ctx));
    // Gap, then globe: x in [72, 96).
    try testing.expectEqual(@as(HitTarget, .none), hitTest(71, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(72, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(95, 399, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(96, 368, ctx));
}

test "sidebar hitTest: footer boundary clips the row area" {
    // y=368 is the first footer pixel; y=367 is still row territory
    // (row 10 with 36px rows — past the tab rows, so .none).
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(10, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 367, ctx));
}

test "sidebar hitTest: closed panel area behaves as row space" {
    // With the panel closed, y in [208, 368) is plain row space.
    const ctx = testCtx(10, false, 5);
    try testing.expectEqual(HitTarget{ .item = 6 }, hitTest(10, 220, ctx));
}

test "sidebar hitTest: open panel covers the row area beneath it" {
    // Rows end at panel_top=208: y=207 is row 5, y=208 is the panel
    // header (not Clear at x=10).
    const ctx = testCtx(10, true, 5);
    try testing.expectEqual(HitTarget{ .item = 5 }, hitTest(10, 207, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 208, ctx));
}

test "sidebar hitTest: panel header Clear button is right-aligned" {
    // Clear zone: x >= width-48 = 172, header y in [208, 232).
    const ctx = testCtx(3, true, 5);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(171, 208, ctx));
    try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(172, 208, ctx));
    try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(219, 231, ctx));
    // First entry pixel is no longer the header.
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(219, 232, ctx));
}

test "sidebar hitTest: panel entries stack newest-first below the header" {
    // Entries are 40px: entry 0 in [232, 272), entry 1 in [272, 312).
    const ctx = testCtx(3, true, 2);
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, 232, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, 271, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 1 }, hitTest(10, 272, ctx));
    // Beyond the log: empty panel space.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 312, ctx));
}

test "sidebar hitTest: partially clipped entry is hittable above the footer" {
    // Entry 3 spans [352, 392) but the footer starts at 368; only the
    // visible band hits.
    const ctx = testCtx(3, true, 8);
    try testing.expectEqual(HitTarget{ .notif_entry = 3 }, hitTest(100, 360, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 3 }, hitTest(100, 367, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(100, 368, ctx));
}

test "sidebar footerHeight and panelHeight scale" {
    try testing.expectEqual(@as(i32, 32), footerHeight(1.0));
    try testing.expectEqual(@as(i32, 48), footerHeight(1.5));
    try testing.expectEqual(@as(i32, 64), footerHeight(2.0));
    try testing.expectEqual(@as(i32, 160), panelHeight(400));
    try testing.expectEqual(@as(i32, 0), panelHeight(0));
}

test "sidebar footer slots: hitTest x range matches the painted rects" {
    const bell = bellSlotRect(368, 1.0);
    const gear = gearSlotRect(368, 1.0);
    const globe = globeSlotRect(368, 1.0);
    try testing.expectEqual(@as(i32, 8), bell.left);
    try testing.expectEqual(@as(i32, 32), bell.right);
    try testing.expectEqual(@as(i32, 40), gear.left);
    try testing.expectEqual(@as(i32, 64), gear.right);
    try testing.expectEqual(@as(i32, 72), globe.left);
    try testing.expectEqual(@as(i32, 96), globe.right);
    // Icons are vertically centered in the 32px footer.
    try testing.expectEqual(@as(i32, 372), bell.top);
    try testing.expectEqual(@as(i32, 396), bell.bottom);
    try testing.expectEqual(@as(i32, 372), globe.top);
    try testing.expectEqual(@as(i32, 396), globe.bottom);
}

test "sidebar hitTest: globe slot scales with DPI" {
    // At 2.0 scale: pad=16, icon=48 — globe x in [144, 192),
    // footer_top = 800 - 64 = 736.
    const ctx: HitCtx = .{
        .item_h = 72,
        .tab_count = 2,
        .client_h = 800,
        .width = 440,
        .scale = 2.0,
        .panel_open = false,
        .notif_count = 0,
    };
    try testing.expectEqual(@as(HitTarget, .none), hitTest(143, 736, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(144, 736, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(191, 799, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(192, 736, ctx));
    const globe = globeSlotRect(736, 2.0);
    try testing.expectEqual(@as(i32, 144), globe.left);
    try testing.expectEqual(@as(i32, 192), globe.right);
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
    const ctx = testCtx(5, false, 0);
    for (0..4) |i| {
        const r = itemRect(i, 220, ctx.item_h);
        try testing.expectEqual(HitTarget{ .item = i }, hitTest(10, r.top, ctx));
        try testing.expectEqual(HitTarget{ .item = i }, hitTest(10, r.bottom - 1, ctx));
    }
}

test "sidebar hitTestEdge: band ends at the edge" {
    try testing.expect(hitTestEdge(215, 220, 5));
    try testing.expect(hitTestEdge(219, 220, 5));
    try testing.expect(!hitTestEdge(220, 220, 5));
    try testing.expect(!hitTestEdge(214, 220, 5));
}

test "sidebar hitTestEdge: hidden sidebar has no band" {
    try testing.expect(!hitTestEdge(0, 0, 5));
    try testing.expect(!hitTestEdge(-3, 0, 5));
    try testing.expect(!hitTestEdge(-1, -10, 5));
}

test "sidebar edgeBandWidth: scales with DPI" {
    try testing.expectEqual(@as(i32, 5), edgeBandWidth(1.0));
    try testing.expectEqual(@as(i32, 8), edgeBandWidth(1.5));
    try testing.expectEqual(@as(i32, 10), edgeBandWidth(2.0));
}
