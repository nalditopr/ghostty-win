//! A browser pane: WebView2 content hosted in a split-tree leaf next
//! to terminal surfaces. The pane owns a WS_CHILD host HWND (class
//! GhosttyBrowserHost — deliberately NOT the terminal class, whose
//! atom makes App.run skip TranslateMessage) containing an address-bar
//! Edit strip on top and the WebView2 controller below it.
//!
//! WebView2 creation is asynchronous (environment singleton on App,
//! then per-pane controller). The pane holds one in-flight ref on its
//! wrapping Pane from startCreation() until the creation chain ends,
//! so completion callbacks never touch freed memory; completions check
//! `state == .closing` and Close+drop the controller immediately when
//! the pane was torn down mid-flight.
const BrowserPane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const wv2 = @import("webview2.zig");

const log = std.log.scoped(.win32);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Child window ID for the address-bar edit control (search=100,
/// palette=200, rename=300).
pub const ADDRESS_EDIT_ID: u16 = 400;

/// Address-bar strip height in unscaled pixels.
const ADDRESS_BAR_BASE: f32 = 28.0;

/// Max URL length in UTF-16 code units.
const URL_MAX: usize = 2048;

const ControllerHandler = wv2.ControllerCompletedHandler(BrowserPane);
const NavHandler = wv2.NavigationCompletedEventHandler(BrowserPane);
const TitleHandler = wv2.DocumentTitleChangedEventHandler(BrowserPane);
const FocusHandler = wv2.FocusChangedEventHandler(BrowserPane);

/// The parent App.
app: *App,

/// The Window containing this pane's tab.
parent_window: *Window,

/// The Pane wrapping this browser in its tab's SplitTree. Set by
/// Pane.createBrowser immediately after create(); valid until the
/// pane unrefs to zero (which destroys us). Null in the window
/// between create() (which publishes us in the host HWND's
/// GWLP_USERDATA) and Pane.createBrowser — messages arriving in that
/// gap must not dereference it.
pane: ?*Pane = null,

/// The WS_CHILD host window (GhosttyBrowserHost class).
host_hwnd: ?w32.HWND = null,

/// The address-bar Edit control (child of host_hwnd).
address_edit: ?w32.HWND = null,

/// Font for the address-bar Edit (deleted on destroy).
address_font: ?*anyopaque = null,

/// Async-creation lifecycle. `closing` is set by destroy() and by the
/// host's WM_DESTROY (parent died while creation was in flight).
state: enum { creating, ready, failed, closing } = .creating,

controller: ?*wv2.ICoreWebView2Controller = null,
webview: ?*wv2.ICoreWebView2 = null,

/// Event registration tokens (removed in destroy()).
nav_token: wv2.EventRegistrationToken = .{},
title_token: wv2.EventRegistrationToken = .{},
focus_token: wv2.EventRegistrationToken = .{},

/// URL to navigate to once the webview is ready (UTF-16, not
/// NUL-terminated; navigatePending appends the NUL).
pending_url: [URL_MAX + 1]u16 = undefined,
pending_url_len: usize = 0,

/// UTF-8 document title reported to the Window (kept so the slice
/// passed to onPaneTitleChanged has stable backing during the call).
title_buf: [512]u8 = undefined,

/// Create the host window and address bar. Does NOT start WebView2
/// creation: call startCreation() after the pane back-pointer exists
/// and a SplitTree owns it (the async race guard refs the pane).
pub fn create(alloc: Allocator, app: *App, parent: *Window) !*BrowserPane {
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;

    const self = try alloc.create(BrowserPane);
    errdefer alloc.destroy(self);
    self.* = .{
        .app = app,
        .parent_window = parent,
    };

    const blank = L("about:blank");
    @memcpy(self.pending_url[0..blank.len], blank);
    self.pending_url_len = blank.len;

    const sr = parent.surfaceRect();
    const host = w32.CreateWindowExW(
        0,
        App.BROWSER_HOST_CLASS_NAME,
        L(""),
        w32.WS_CHILD,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.host_hwnd = host;
    // Children (the Edit) are destroyed along with the host.
    errdefer {
        _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(host);
        self.host_hwnd = null;
    }
    _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Address-bar Edit. Real geometry is applied by layoutChildren on
    // the first WM_SIZE from layoutSplits.
    const bar_h = self.addressBarHeight();
    const pad = self.addressBarPad();
    const edit = w32.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        @max(sr.right - sr.left - pad * 2, 1),
        @max(bar_h - pad * 2, 1),
        host,
        @ptrFromInt(@as(usize, ADDRESS_EDIT_ID)),
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.address_edit = edit;

    _ = w32.SetWindowTheme(edit, L("DarkMode_Explorer"), null);
    self.address_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(15.0 * parent.scale))),
        0, 0, 0, 400,
        0, 0, 0,
        0, 0, 0, 0, 0,
        L("Segoe UI"),
    );
    if (self.address_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    return self;
}

/// Begin async WebView2 creation. The wrapping pane must be owned by a
/// SplitTree by now; one pane ref is held for the whole creation chain
/// and dropped when the chain ends (env failure, controller failure,
/// or controller completion).
pub fn startCreation(self: *BrowserPane) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse return;
    // Pane.ref never fails (the allocator parameter is unused).
    _ = pane.ref(alloc) catch unreachable;
    self.app.requestWebView2Env(self);
}

/// Full teardown, called from Pane.unref at refcount zero. Mirrors the
/// WGL ordering rule: the controller is Closed and the host HWND
/// destroyed before the parent Window's teardown destroys the parent.
pub fn destroy(self: *BrowserPane, alloc: Allocator) void {
    self.state = .closing;
    if (self.webview) |webview| {
        webview.removeNavigationCompleted(self.nav_token) catch {};
        webview.removeDocumentTitleChanged(self.title_token) catch {};
        webview.release();
        self.webview = null;
    }
    if (self.controller) |controller| {
        controller.removeGotFocus(self.focus_token) catch {};
        controller.close() catch {};
        controller.release();
        self.controller = null;
    }
    if (self.address_font) |f| {
        _ = w32.DeleteObject(f);
        self.address_font = null;
    }
    if (self.host_hwnd) |host| {
        _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(host);
        self.host_hwnd = null;
        self.address_edit = null;
    }
    alloc.destroy(self);
}

/// Environment-creation completion (called by App, possibly
/// synchronously when the singleton already exists). Consumes the
/// in-flight pane ref on every path except the controller-creation
/// continuation, which carries it to onControllerCreated.
pub fn onEnvironment(self: *BrowserPane, env_opt: ?*wv2.ICoreWebView2Environment) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse return;
    if (self.state == .closing) {
        pane.unref(alloc);
        return;
    }
    // The pane was closed out of every tab while environment creation
    // was pending: the in-flight ref is the only thing keeping it
    // alive. Drop it (freeing the pane and this BrowserPane) instead
    // of building a controller for a zombie host. parent_window is
    // valid whenever state != .closing (the host's WM_DESTROY flags
    // closing before the window can go away).
    if (self.parent_window.findTabIndex(pane) == null) {
        pane.unref(alloc);
        return;
    }
    const env = env_opt orelse {
        log.warn("browser pane: WebView2 environment unavailable", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    const host = self.host_hwnd orelse {
        pane.unref(alloc);
        return;
    };
    const handler = ControllerHandler.create(alloc, self, onControllerCreated) catch {
        log.warn("browser pane: oom creating controller handler", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    env.createController(host, handler) catch {
        handler.unref();
        log.warn("browser pane: CreateCoreWebView2Controller failed", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    handler.unref();
}

fn onControllerCreated(
    self: *BrowserPane,
    error_code: wv2.HRESULT,
    controller_opt: ?*wv2.ICoreWebView2Controller,
) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse {
        if (controller_opt) |c| c.close() catch {};
        return;
    };
    // End of the creation chain: drop the in-flight ref. This may free
    // self (and the pane) when the pane closed during creation, so it
    // must be the very last thing that runs.
    defer pane.unref(alloc);

    const controller = controller_opt orelse {
        log.warn("browser pane: controller creation failed hr=0x{x:0>8}", .{
            @as(u32, @bitCast(error_code)),
        });
        if (self.state != .closing) self.setFailed();
        return;
    };
    if (self.state == .closing) {
        // Pane was torn down while creation was in flight: shut the
        // browser process down now; the callee-owned reference is
        // released by WebView2 after Invoke returns.
        controller.close() catch {};
        return;
    }
    if (self.parent_window.findTabIndex(pane) == null) {
        // The tab closed while controller creation was in flight; the
        // host HWND survived (the in-flight ref kept the pane alive)
        // so state is still .creating. Don't wire up a zombie: shut
        // the browser process down and let the deferred unref free
        // the pane and this BrowserPane.
        controller.close() catch {};
        return;
    }

    controller.addRef();
    self.controller = controller;

    const webview = controller.getCoreWebView2() catch {
        controller.close() catch {};
        controller.release();
        self.controller = null;
        log.warn("browser pane: get_CoreWebView2 failed", .{});
        self.setFailed();
        return;
    };
    self.webview = webview;

    // GotFocus is the authoritative active-pane signal: clicks inside
    // the webview never reach the host HWND.
    if (FocusHandler.create(alloc, self, onGotFocus)) |h| {
        defer h.unref();
        self.focus_token = controller.addGotFocus(h) catch .{};
    } else |_| {}
    if (NavHandler.create(alloc, self, onNavigationCompleted)) |h| {
        defer h.unref();
        self.nav_token = webview.addNavigationCompleted(h) catch .{};
    } else |_| {}
    if (TitleHandler.create(alloc, self, onDocumentTitleChanged)) |h| {
        defer h.unref();
        self.title_token = webview.addDocumentTitleChanged(h) catch .{};
    } else |_| {}

    self.state = .ready;
    self.updateBounds();
    if (self.host_hwnd) |host| {
        controller.putIsVisible(w32.IsWindowVisible_(host) != 0) catch {};
    }
    self.navigatePending();
}

fn onGotFocus(self: *BrowserPane, sender: ?*wv2.ICoreWebView2Controller, args: ?*wv2.IUnknown) void {
    _ = sender;
    _ = args;
    if (self.state == .closing) return;
    const pane = self.pane orelse return;
    const win = self.parent_window;
    if (win.closing) return;
    // Only record the pane as active for the tab that actually owns
    // it; a stale focus event must never plant a dangling pointer in
    // another tab's slot.
    const idx = win.findTabIndex(pane) orelse return;
    win.tab_active_pane[idx] = pane;
}

fn onNavigationCompleted(
    self: *BrowserPane,
    sender: ?*wv2.ICoreWebView2,
    args_opt: ?*wv2.ICoreWebView2NavigationCompletedEventArgs,
) void {
    if (self.state == .closing) return;
    if (args_opt) |args| {
        const success = args.getIsSuccess() catch false;
        if (!success) {
            const status = args.getWebErrorStatus() catch -1;
            log.warn("browser navigation failed web_error_status={}", .{status});
        }
    }
    // Reflect the final URI in the address bar — unless the user is
    // typing in it (don't clobber a half-entered URL).
    const webview = sender orelse (self.webview orelse return);
    const uri = webview.getSource() catch return;
    defer wv2.CoTaskMemFree(uri);
    if (self.address_edit) |edit| {
        if (w32.GetFocus() != edit) {
            _ = w32.SetWindowTextW(edit, uri);
        }
    }
}

fn onDocumentTitleChanged(self: *BrowserPane, sender: ?*wv2.ICoreWebView2, args: ?*wv2.IUnknown) void {
    _ = args; // Always null per the IDL.
    if (self.state == .closing) return;
    const pane = self.pane orelse return;
    const webview = sender orelse (self.webview orelse return);
    const title16 = webview.getDocumentTitle() catch return;
    defer wv2.CoTaskMemFree(title16);
    // The title is website-controlled and unbounded; utf16LeToUtf8
    // ASSERTS the destination is large enough (no DestTooSmall error
    // in std 0.15), so cap the input before converting. One UTF-16
    // code unit expands to at most 3 UTF-8 bytes (surrogate pairs are
    // 2 units -> 4 bytes, which is smaller per unit).
    var span: []const u16 = std.mem.span(title16);
    const max_units = (self.title_buf.len - 1) / 3;
    if (span.len > max_units) {
        span = span[0..max_units];
        // Don't cut a surrogate pair in half: a dangling high
        // surrogate would make the whole conversion fail.
        if (span.len > 0 and span[span.len - 1] >= 0xD800 and span[span.len - 1] <= 0xDBFF) {
            span = span[0 .. span.len - 1];
        }
    }
    const len = std.unicode.utf16LeToUtf8(self.title_buf[0 .. self.title_buf.len - 1], span) catch return;
    self.title_buf[len] = 0;
    self.parent_window.onPaneTitleChanged(pane, self.title_buf[0..len :0]);
}

/// Navigate to the address bar's text. Prepends https:// when the
/// text has no scheme. Stashes the URL when the webview isn't ready.
pub fn navigateFromAddressBar(self: *BrowserPane) void {
    const edit = self.address_edit orelse return;
    var wbuf: [URL_MAX]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));
    if (wlen == 0) return;

    const scheme = L("https://");
    const has_scheme = std.mem.indexOf(u16, wbuf[0..wlen], L("://")) != null;
    var url_buf: [URL_MAX + scheme.len + 1]u16 = undefined;
    var url_len: usize = 0;
    if (!has_scheme) {
        @memcpy(url_buf[0..scheme.len], scheme);
        url_len = scheme.len;
    }
    @memcpy(url_buf[url_len .. url_len + wlen], wbuf[0..wlen]);
    url_len += wlen;
    url_buf[url_len] = 0;

    if (self.state == .ready) {
        if (self.webview) |webview| {
            webview.navigate(@ptrCast(&url_buf)) catch |err| {
                log.warn("browser navigate failed: {}", .{err});
                return;
            };
            self.focusWebView();
            return;
        }
    }
    // Not ready yet: replace the pending URL.
    const n = @min(url_len, URL_MAX);
    @memcpy(self.pending_url[0..n], url_buf[0..n]);
    self.pending_url_len = n;
}

fn navigatePending(self: *BrowserPane) void {
    if (self.pending_url_len == 0) return;
    const webview = self.webview orelse return;
    self.pending_url[self.pending_url_len] = 0;
    webview.navigate(@ptrCast(&self.pending_url)) catch |err| {
        log.warn("browser pending navigate failed: {}", .{err});
    };
    self.pending_url_len = 0;
}

/// Move keyboard focus into the webview (via the host's WM_SETFOCUS,
/// which calls MoveFocus). Used when Escape leaves the address bar.
pub fn focusWebView(self: *BrowserPane) void {
    if (self.host_hwnd) |host| _ = w32.SetFocus(host);
}

/// Window-level WM_MOVE: WebView2 needs to be told its screen position
/// changed even though the child HWND didn't move client-relative.
pub fn onParentWindowMoved(self: *BrowserPane) void {
    if (self.state != .ready) return;
    if (self.controller) |controller| {
        controller.notifyParentWindowPositionChanged() catch {};
    }
}

fn addressBarHeight(self: *const BrowserPane) i32 {
    return @intFromFloat(@round(ADDRESS_BAR_BASE * self.parent_window.scale));
}

fn addressBarPad(self: *const BrowserPane) i32 {
    return @intFromFloat(@round(3.0 * self.parent_window.scale));
}

/// Re-layout the address bar and webview bounds from the host's
/// current client rect.
fn updateBounds(self: *BrowserPane) void {
    const host = self.host_hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(host, &rect) == 0) return;
    self.layoutChildren(rect.right - rect.left, rect.bottom - rect.top);
}

fn layoutChildren(self: *BrowserPane, width: i32, height: i32) void {
    const bar_h = self.addressBarHeight();
    const pad = self.addressBarPad();
    if (self.address_edit) |edit| {
        _ = w32.MoveWindow(
            edit,
            pad,
            pad,
            @max(width - pad * 2, 1),
            @max(bar_h - pad * 2, 1),
            1,
        );
    }
    if (self.state != .ready) return;
    const controller = self.controller orelse return;
    // put_Bounds takes physical pixels relative to the host.
    controller.putBounds(.{
        .left = 0,
        .top = bar_h,
        .right = @max(width, 0),
        .bottom = @max(height, bar_h),
    }) catch {};
}

fn setFailed(self: *BrowserPane) void {
    self.state = .failed;
    if (self.host_hwnd) |host| {
        _ = w32.InvalidateRect(host, null, 1);
    }
}

fn paintHost(self: *BrowserPane, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    if (self.app.bg_brush) |brush| {
        _ = w32.FillRect(hdc, &rect, brush);
    }
    if (self.state == .failed) {
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
        _ = w32.SetTextColor(hdc, w32.RGB(200, 200, 200));
        var old_font: ?*anyopaque = null;
        if (self.parent_window.tab_font) |font| {
            old_font = w32.SelectObject(hdc, font);
        }
        defer if (old_font) |f| {
            _ = w32.SelectObject(hdc, f);
        };
        const text = L("WebView2 runtime unavailable");
        var text_rect = rect;
        _ = w32.DrawTextW(
            hdc,
            text,
            text.len,
            &text_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }
}

/// Window procedure for browser host HWNDs (GhosttyBrowserHost class).
/// GWLP_USERDATA stores a *BrowserPane pointer.
pub fn hostWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self: *BrowserPane = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            const width: i32 = @intCast(lparam & 0xFFFF);
            const height: i32 = @intCast((lparam >> 16) & 0xFFFF);
            self.layoutChildren(width, height);
            return 0;
        },

        w32.WM_SHOWWINDOW => {
            if (self.state == .ready) {
                if (self.controller) |controller| {
                    controller.putIsVisible(wparam != 0) catch {};
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            const win = self.parent_window;
            if (!win.closing) {
                // Same guard as onGotFocus: only write the slot of the
                // tab that owns this pane (a zombie host or a pane not
                // yet in a tree must not be recorded anywhere).
                if (self.pane) |pane| {
                    if (win.findTabIndex(pane)) |idx| {
                        win.tab_active_pane[idx] = pane;
                    }
                }
            }
            if (self.state == .ready) {
                if (self.controller) |controller| {
                    controller.moveFocus(.programmatic) catch {};
                }
            } else if (self.address_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
            return 0;
        },

        w32.WM_ERASEBKGND => {
            if (self.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            self.paintHost(hwnd);
            return 0;
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for the address-bar Edit (same scheme as
            // the search edit in App.surfaceWndProc).
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, w32.RGB(45, 45, 45));
            if (self.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_DESTROY => {
            // Destroyed by the parent window while async creation was
            // still in flight (destroy() zeroes GWLP_USERDATA before
            // its own DestroyWindow, so it never reaches here). Flag
            // closing so the completion callback Closes+drops the
            // controller instead of touching a dead HWND.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.state = .closing;
            self.host_hwnd = null;
            self.address_edit = null;
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
