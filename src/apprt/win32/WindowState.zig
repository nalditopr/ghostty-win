//! Persisted top-level window geometry for the Win32 runtime.
//!
//! Stores the last window size, position, and maximized state so the
//! main window restores to where the user left it — like Windows
//! Terminal and most native Windows apps.
//!
//! ## Storage
//!
//! The state lives in a small human-readable `key=value` text file at
//! `%LOCALAPPDATA%\ghostty\window-state` (see `Window.savePlacement` /
//! `Window.restorePlacement` for the path resolution, which mirrors the
//! existing `update_check_at` convention). Example contents:
//!
//! ```
//! width=1024
//! height=768
//! x=100
//! y=80
//! maximized=false
//! ```
//!
//! Unknown keys are ignored and missing keys keep their defaults, so the
//! format can grow without breaking older/newer builds.
//!
//! ## Coordinate space / DPI
//!
//! The persisted rect is captured from `GetWindowPlacement`'s
//! `rcNormalPosition`, which is the window's *restored* (non-maximized)
//! rectangle. We store and restore raw physical pixels in **workarea
//! coordinates** (the space `GetWindowPlacement`/`SetWindowPlacement`
//! use). Under per-monitor-v2 DPI awareness these are physical pixels on
//! the monitor the window currently occupies.
//!
//! This is intentionally simple: we do NOT normalize to a DPI-independent
//! unit. The trade-off is that if the saved monitor's DPI differs from the
//! restore monitor's DPI, the restored window is sized in the old
//! monitor's pixels. In practice this is the same behavior Windows
//! Terminal had for a long time and is acceptable for a "remember my
//! window" feature; the clamp below still guarantees visibility.

const std = @import("std");

/// Persisted geometry. Plain data, no allocations — safe to copy.
pub const State = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    maximized: bool,

    /// Minimum sensible window dimensions. A saved width/height below
    /// this (e.g. from a corrupt file or a degenerate minimized capture)
    /// is rejected by `validate`.
    pub const min_dim: i32 = 100;

    /// Serialize to the `key=value` text format. Writes into `buf` and
    /// returns the populated slice. The buffer must be large enough; 160
    /// bytes is always sufficient for five i32/bool lines.
    pub fn serialize(self: State, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf,
            \\width={d}
            \\height={d}
            \\x={d}
            \\y={d}
            \\maximized={s}
            \\
        , .{
            self.width,
            self.height,
            self.x,
            self.y,
            if (self.maximized) "true" else "false",
        });
    }

    /// Parse the `key=value` text format. Tolerant of a missing/corrupt
    /// file: unknown keys are skipped, malformed lines are skipped, and a
    /// partial parse returns null unless every required geometry field
    /// (width/height/x/y) was present. `maximized` defaults to false when
    /// absent or unparseable.
    ///
    /// Returns null when the input cannot produce a usable, on-its-face
    /// valid State (see `validate`), so callers fall back to defaults.
    pub fn parse(text: []const u8) ?State {
        var width: ?i32 = null;
        var height: ?i32 = null;
        var x: ?i32 = null;
        var y: ?i32 = null;
        var maximized: bool = false;

        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (std.mem.eql(u8, key, "width")) {
                width = std.fmt.parseInt(i32, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "height")) {
                height = std.fmt.parseInt(i32, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "x")) {
                x = std.fmt.parseInt(i32, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "y")) {
                y = std.fmt.parseInt(i32, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "maximized")) {
                if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) {
                    maximized = true;
                } else {
                    maximized = false;
                }
            }
            // Unknown keys: ignored for forward compatibility.
        }

        const s = State{
            .width = width orelse return null,
            .height = height orelse return null,
            .x = x orelse return null,
            .y = y orelse return null,
            .maximized = maximized,
        };
        if (!s.validate()) return null;
        return s;
    }

    /// Sanity-check the geometry independent of any monitor layout.
    /// Rejects non-positive or absurdly small/large dimensions that
    /// would produce an unusable window.
    pub fn validate(self: State) bool {
        if (self.width < min_dim or self.height < min_dim) return false;
        // Guard against a corrupt file claiming a multi-million-pixel
        // window; 32767 comfortably exceeds any real multi-monitor span.
        if (self.width > 32767 or self.height > 32767) return false;
        return true;
    }
};

/// A rectangle in physical pixels, expressed as origin + size (matching
/// how we store window geometry). Pure value type for the clamp logic.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.height;
    }
};

/// Clamp a saved window rect so it is visible on the current virtual
/// screen (the bounding box of all monitors), given as `screen`.
///
/// Behavior:
///   * If the saved rect overlaps the virtual screen at all, it is
///     nudged so its top-left is on-screen and the title bar is
///     reachable, shrinking only if it is larger than the screen.
///   * If the saved rect is *fully* off-screen (e.g. the monitor it
///     lived on was unplugged), it falls back to centered on the
///     virtual screen at its saved size (clamped to fit).
///
/// Pure function: takes the saved rect and the virtual-screen rect,
/// returns the adjusted rect. No Win32 calls, fully unit-testable.
pub fn clampToVirtualScreen(saved: Rect, screen: Rect) Rect {
    // Never let a window be larger than the whole virtual screen.
    var w = @min(saved.width, screen.width);
    var h = @min(saved.height, screen.height);
    if (w < State.min_dim) w = @min(State.min_dim, screen.width);
    if (h < State.min_dim) h = @min(State.min_dim, screen.height);

    // Does the saved rect intersect the virtual screen at all?
    const intersects = saved.x < screen.right() and
        saved.right() > screen.x and
        saved.y < screen.bottom() and
        saved.bottom() > screen.y;

    if (!intersects) {
        // Fully off-screen → center on the virtual screen.
        return .{
            .x = screen.x + @divTrunc(screen.width - w, 2),
            .y = screen.y + @divTrunc(screen.height - h, 2),
            .width = w,
            .height = h,
        };
    }

    // Partially visible: clamp the top-left so the whole rect (now no
    // larger than the screen) sits inside the virtual screen. This keeps
    // the title bar reachable even if the saved position hung off an
    // edge.
    var nx = saved.x;
    var ny = saved.y;
    if (nx + w > screen.right()) nx = screen.right() - w;
    if (ny + h > screen.bottom()) ny = screen.bottom() - h;
    if (nx < screen.x) nx = screen.x;
    if (ny < screen.y) ny = screen.y;

    return .{ .x = nx, .y = ny, .width = w, .height = h };
}

test "winsize: serialize/parse round-trip" {
    const testing = std.testing;
    const in = State{ .width = 1024, .height = 768, .x = 100, .y = 80, .maximized = false };
    var buf: [256]u8 = undefined;
    const text = try in.serialize(&buf);
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(in.width, out.width);
    try testing.expectEqual(in.height, out.height);
    try testing.expectEqual(in.x, out.x);
    try testing.expectEqual(in.y, out.y);
    try testing.expectEqual(in.maximized, out.maximized);
}

test "winsize: serialize/parse round-trip maximized + negative coords" {
    const testing = std.testing;
    // Negative coords occur on secondary monitors left/above the primary.
    const in = State{ .width = 1920, .height = 1080, .x = -1920, .y = -200, .maximized = true };
    var buf: [256]u8 = undefined;
    const text = try in.serialize(&buf);
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(in.x, out.x);
    try testing.expectEqual(in.y, out.y);
    try testing.expect(out.maximized);
}

test "winsize: parse tolerates whitespace, unknown keys, and key reorder" {
    const testing = std.testing;
    const text =
        \\# a comment-ish line with no equals is skipped
        \\  maximized = true
        \\unknown_future_key=42
        \\height=600
        \\  width =  800
        \\x=10
        \\y=20
        \\
    ;
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    try testing.expectEqual(@as(i32, 10), out.x);
    try testing.expectEqual(@as(i32, 20), out.y);
    try testing.expect(out.maximized);
}

test "winsize: parse rejects corrupt / incomplete input → null" {
    const testing = std.testing;
    // Empty file.
    try testing.expect(State.parse("") == null);
    // Garbage bytes.
    try testing.expect(State.parse("\x00\xff not a config at all") == null);
    // Missing required field (no width).
    try testing.expect(State.parse("height=600\nx=1\ny=2\n") == null);
    // Non-numeric value for a required field.
    try testing.expect(State.parse("width=abc\nheight=600\nx=1\ny=2\n") == null);
    // Degenerate (too small) dimensions are rejected by validate.
    try testing.expect(State.parse("width=1\nheight=1\nx=0\ny=0\n") == null);
    // Absurdly large dimensions rejected.
    try testing.expect(State.parse("width=999999\nheight=999999\nx=0\ny=0\n") == null);
}

test "winsize: clamp leaves a fully-visible rect unchanged" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const saved = Rect{ .x = 100, .y = 80, .width = 1024, .height = 768 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expectEqual(saved.x, out.x);
    try testing.expectEqual(saved.y, out.y);
    try testing.expectEqual(saved.width, out.width);
    try testing.expectEqual(saved.height, out.height);
}

test "winsize: clamp nudges a partially off-screen rect back inside" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    // Hangs off the right and bottom edges.
    const saved = Rect{ .x = 1800, .y = 1000, .width = 800, .height = 600 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expect(out.x >= screen.x);
    try testing.expect(out.y >= screen.y);
    try testing.expect(out.right() <= screen.right());
    try testing.expect(out.bottom() <= screen.bottom());
    // Size preserved (it fits after the move).
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    try testing.expectEqual(@as(i32, 1120), out.x); // 1920 - 800
    try testing.expectEqual(@as(i32, 480), out.y); // 1080 - 600
}

test "winsize: clamp centers a fully off-screen rect (monitor removed)" {
    const testing = std.testing;
    // Single monitor remains at origin; saved rect was on a now-removed
    // monitor far to the right.
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const saved = Rect{ .x = 5000, .y = 200, .width = 800, .height = 600 };
    const out = clampToVirtualScreen(saved, screen);
    // Centered.
    try testing.expectEqual(@as(i32, (1920 - 800) / 2), out.x);
    try testing.expectEqual(@as(i32, (1080 - 600) / 2), out.y);
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    // And it's on-screen.
    try testing.expect(out.x >= screen.x and out.right() <= screen.right());
}

test "winsize: clamp shrinks a rect larger than the virtual screen" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const saved = Rect{ .x = -200, .y = -100, .width = 4000, .height = 3000 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expectEqual(@as(i32, 1280), out.width);
    try testing.expectEqual(@as(i32, 720), out.height);
    try testing.expect(out.x >= screen.x);
    try testing.expect(out.y >= screen.y);
    try testing.expect(out.right() <= screen.right());
    try testing.expect(out.bottom() <= screen.bottom());
}

test "winsize: clamp respects a virtual screen with a negative origin" {
    const testing = std.testing;
    // Primary at origin, secondary monitor to the left (negative x).
    const screen = Rect{ .x = -1920, .y = 0, .width = 3840, .height = 1080 };
    const saved = Rect{ .x = -1800, .y = 100, .width = 1000, .height = 700 };
    const out = clampToVirtualScreen(saved, screen);
    // Already visible → unchanged.
    try testing.expectEqual(saved.x, out.x);
    try testing.expectEqual(saved.y, out.y);
}
