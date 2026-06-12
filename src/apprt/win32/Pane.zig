//! A Pane is the unit of content held by a tab's SplitTree leaf. It is
//! a heap-allocated, reference-counted wrapper implementing the
//! SplitTree view protocol (ref/unref/eql — see the doc comment in
//! src/datastruct/split_tree.zig). Content is either a terminal
//! Surface or a WebView2 BrowserPane.
const Pane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const BrowserPane = @import("BrowserPane.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// What this pane displays.
content: Content,

pub const Content = union(enum) {
    terminal: *Surface,
    browser: *BrowserPane,
};

/// Allocate a pane wrapping a terminal surface and set the surface's
/// back-pointer. The caller owns the allocation until a SplitTree
/// ref()s the pane.
pub fn create(alloc: Allocator, surface_ptr: *Surface) Allocator.Error!*Pane {
    const pane = try alloc.create(Pane);
    pane.* = .{ .content = .{ .terminal = surface_ptr } };
    surface_ptr.pane = pane;
    return pane;
}

/// Allocate a pane wrapping a browser and set the browser's
/// back-pointer. Same ownership contract as create().
pub fn createBrowser(alloc: Allocator, browser: *BrowserPane) Allocator.Error!*Pane {
    const pane = try alloc.create(Pane);
    pane.* = .{ .content = .{ .browser = browser } };
    browser.pane = pane;
    return pane;
}

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Pane, alloc: Allocator) Allocator.Error!*Pane {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// SplitTree view protocol: decrement reference count. At zero the
/// content is torn down and the pane itself is freed.
pub fn unref(self: *Pane, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count > 0) return;
    switch (self.content) {
        .terminal => |surface_ptr| {
            if (surface_ptr.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            surface_ptr.deinit();
            alloc.destroy(surface_ptr);
        },
        // Closes the controller and destroys the host HWND before the
        // parent Window teardown, mirroring the WGL ordering rule.
        .browser => |browser| browser.destroy(alloc),
    }
    alloc.destroy(self);
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Pane, other: *const Pane) bool {
    return self == other;
}

/// The content's HWND, if it has one.
pub fn hwnd(self: *const Pane) ?w32.HWND {
    return switch (self.content) {
        .terminal => |surface_ptr| surface_ptr.hwnd,
        .browser => |browser| browser.host_hwnd,
    };
}

/// Give keyboard focus to the content.
pub fn focus(self: *const Pane) void {
    if (self.hwnd()) |h| _ = w32.SetFocus(h);
}

/// The terminal surface, or null for non-terminal content.
pub fn surface(self: *const Pane) ?*Surface {
    return switch (self.content) {
        .terminal => |surface_ptr| surface_ptr,
        .browser => null,
    };
}
