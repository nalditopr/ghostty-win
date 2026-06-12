//! Named-pipe IPC server core for agent-scriptable browser control
//! (`ghostty +browser open|eval|snapshot|click ...`).
//!
//! Wire protocol: newline-delimited JSON over a message-type named pipe
//! at \\.\pipe\ghostty-browser-<pid>.
//!
//!   request:  {"id":1,"cmd":"open","args":{"url":"https://..."}}\n
//!   response: {"id":1,"ok":true,"data":...}\n
//!             {"id":1,"ok":false,"error":"..."}\n
//!
//! The module is split into three layers:
//!
//!   (a) a pure protocol layer (parse / serialize / framing) with no
//!       OS dependencies, unit-tested on any target;
//!   (b) a thin Win32 named-pipe layer (extern decls + a security
//!       descriptor restricting the pipe to the current user);
//!   (c) `Server`, which ties them together: a dedicated pipe thread
//!       accepts one client at a time, reads newline-delimited
//!       requests, heap-allocates each parsed `Request`, and hands it
//!       to a callback. In production the callback PostMessageW's the
//!       request pointer to App's msg_hwnd; here it is modeled as a
//!       plain function pointer so the module stays standalone.
//!       Responses may be written from any thread via send{Ok,Error}.
//!
//! Concurrency note (the reason the pipe is opened FILE_FLAG_OVERLAPPED):
//! a synchronous duplex pipe handle serializes *all* I/O on the file
//! object, so a WriteFile issued from another thread (e.g. the GUI
//! thread answering a request) blocks behind the pipe thread's pending
//! ReadFile — deadlocking request/response. Overlapped I/O keeps reads
//! and writes independent and gives us clean shutdown via an event +
//! CancelIoEx instead of the dummy-connect / CancelSynchronousIo hacks
//! needed for synchronous handles.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = std.log.scoped(.win32_ipc);

// ---------------------------------------------------------------------------
// Protocol layer (pure; no OS dependencies)
// ---------------------------------------------------------------------------

/// Hard cap on a single newline-delimited request line. Anything larger
/// is a protocol violation and drops the connection.
pub const max_line_bytes: usize = 1024 * 1024;

/// Commands the browser IPC understands. The server core only validates
/// the name; execution lives with the callback owner (App).
pub const Command = enum {
    open,
    navigate,
    eval,
    snapshot,
    click,
    fill,
};

/// Protocol-level failures that map to error responses.
pub const ErrorCode = enum {
    parse_error,
    invalid_request,
    unknown_command,
    message_too_long,

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "request is not valid JSON",
            .invalid_request => "request must be an object with a non-negative integer \"id\", a string \"cmd\", and an optional object \"args\"",
            .unknown_command => "unknown command",
            .message_too_long => "request exceeds maximum length",
        };
    }
};

/// A parsed request. Heap-allocated by `parseLine`; whoever receives it
/// (the callback, in production the GUI thread after the PostMessageW
/// hop) owns it and must call `destroy()` exactly once.
pub const Request = struct {
    gpa: Allocator,
    /// Backing storage for `args`; everything the json Value points at
    /// lives here.
    arena: std.heap.ArenaAllocator,
    id: u64,
    cmd: Command,
    /// The request's "args" object, or `.null` when absent.
    args: std.json.Value,

    pub fn destroy(self: *Request) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const ParseFailure = struct {
    /// Request id when it could be recovered from the malformed
    /// request, 0 otherwise.
    id: u64,
    code: ErrorCode,
};

pub const ParseResult = union(enum) {
    ok: *Request,
    err: ParseFailure,
};

/// Parse one newline-stripped request line. Protocol violations are
/// reported in-band as `.err` (so the server can answer them); only
/// allocation failure is a Zig error.
pub fn parseLine(gpa: Allocator, line: []const u8) Allocator.Error!ParseResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        line,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parseFailure(&arena, 0, .parse_error),
    };

    const obj = switch (root) {
        .object => |o| o,
        else => return parseFailure(&arena, 0, .invalid_request),
    };

    const id: u64 = id: {
        const value = obj.get("id") orelse
            return parseFailure(&arena, 0, .invalid_request);
        switch (value) {
            .integer => |i| {
                if (i < 0) return parseFailure(&arena, 0, .invalid_request);
                break :id @intCast(i);
            },
            else => return parseFailure(&arena, 0, .invalid_request),
        }
    };

    const cmd: Command = cmd: {
        const value = obj.get("cmd") orelse
            return parseFailure(&arena, id, .invalid_request);
        const name = switch (value) {
            .string => |s| s,
            else => return parseFailure(&arena, id, .invalid_request),
        };
        break :cmd std.meta.stringToEnum(Command, name) orelse
            return parseFailure(&arena, id, .unknown_command);
    };

    const args: std.json.Value = args: {
        const value = obj.get("args") orelse break :args .null;
        switch (value) {
            .object, .null => break :args value,
            else => return parseFailure(&arena, id, .invalid_request),
        }
    };

    const req = try gpa.create(Request);
    req.* = .{
        .gpa = gpa,
        .arena = arena,
        .id = id,
        .cmd = cmd,
        .args = args,
    };
    return .{ .ok = req };
}

fn parseFailure(
    arena: *std.heap.ArenaAllocator,
    id: u64,
    code: ErrorCode,
) ParseResult {
    arena.deinit();
    return .{ .err = .{ .id = id, .code = code } };
}

/// Serialize a success response, trailing newline included. `data_json`
/// must already be valid JSON (the GUI thread typically produces it
/// with std.json); null serializes as "data":null. Caller owns the
/// returned slice.
pub fn serializeOk(
    alloc: Allocator,
    id: u64,
    data_json: ?[]const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"id\":{d},\"ok\":true,\"data\":{s}}}\n",
        .{ id, data_json orelse "null" },
    );
}

/// Serialize an error response, trailing newline included. `msg` is
/// JSON-escaped. id 0 means the request id could not be recovered.
/// Caller owns the returned slice.
pub fn serializeError(
    alloc: Allocator,
    id: u64,
    msg: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"id\":{d},\"ok\":false,\"error\":{f}}}\n",
        .{ id, std.json.fmt(msg, .{}) },
    );
}

/// Newline framing with partial-buffer accumulation: ReadFile chunks go
/// in via feed(), complete lines (without their "\n" or "\r\n") come
/// out via next(). Slices returned by next() are only valid until the
/// next feed() call.
pub const LineFramer = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Offset of the first unconsumed byte in `buf`.
    start: usize = 0,

    pub fn deinit(self: *LineFramer, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.* = undefined;
    }

    pub fn feed(
        self: *LineFramer,
        alloc: Allocator,
        chunk: []const u8,
    ) error{ OutOfMemory, MessageTooLong }!void {
        // Compact the consumed prefix so the buffer can't grow without
        // bound across many requests.
        if (self.start > 0) {
            const remaining = self.buf.items.len - self.start;
            std.mem.copyForwards(
                u8,
                self.buf.items[0..remaining],
                self.buf.items[self.start..],
            );
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }
        if (self.buf.items.len + chunk.len > max_line_bytes) {
            return error.MessageTooLong;
        }
        try self.buf.appendSlice(alloc, chunk);
    }

    pub fn next(self: *LineFramer) ?[]const u8 {
        const unread = self.buf.items[self.start..];
        const nl = std.mem.indexOfScalar(u8, unread, '\n') orelse return null;
        var line = unread[0..nl];
        self.start += nl + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        return line;
    }
};

// ---------------------------------------------------------------------------
// Win32 pipe layer
// ---------------------------------------------------------------------------

// Constants not exposed by std.os.windows.
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x00000008;
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_USER_CLASS: c_int = 1; // TOKEN_INFORMATION_CLASS.TokenUser
const SDDL_REVISION_1: u32 = 1;

const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: windows.DWORD,
};

const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetOverlappedResult(
    hFile: windows.HANDLE,
    lpOverlapped: *windows.OVERLAPPED,
    lpNumberOfBytesTransferred: *windows.DWORD,
    bWait: windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitForMultipleObjects(
    nCount: windows.DWORD,
    lpHandles: [*]const windows.HANDLE,
    bWaitAll: windows.BOOL,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

extern "advapi32" fn OpenProcessToken(
    ProcessHandle: windows.HANDLE,
    DesiredAccess: windows.DWORD,
    TokenHandle: *windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn GetTokenInformation(
    TokenHandle: windows.HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: windows.DWORD,
    ReturnLength: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertSidToStringSidW(
    Sid: *anyopaque,
    StringSid: *?windows.LPWSTR,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: windows.LPCWSTR,
    StringSDRevision: windows.DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.ULONG,
) callconv(.winapi) windows.BOOL;

/// Security descriptor restricting the pipe to the current user:
/// SDDL "D:P(A;;GA;;;<user-sid>)" — a protected DACL (no inherited
/// ACEs) with a single ACE granting GENERIC_ALL to the process owner's
/// SID. Everyone else — other local users, services, and (belt and
/// suspenders, on top of PIPE_REJECT_REMOTE_CLIENTS) remote clients —
/// is implicitly denied.
const PipeSecurity = struct {
    descriptor: *anyopaque,

    fn init(alloc: Allocator) !PipeSecurity {
        // Current process token → TOKEN_USER → SID.
        var token: windows.HANDLE = undefined;
        if (OpenProcessToken(
            windows.GetCurrentProcess(),
            TOKEN_QUERY,
            &token,
        ) == 0) return error.OpenProcessTokenFailed;
        defer windows.CloseHandle(token);

        var token_buf: [256]u8 align(@alignOf(TOKEN_USER)) = undefined;
        var needed: windows.DWORD = 0;
        if (GetTokenInformation(
            token,
            TOKEN_USER_CLASS,
            &token_buf,
            token_buf.len,
            &needed,
        ) == 0) return error.GetTokenInformationFailed;
        const user: *const TOKEN_USER = @ptrCast(&token_buf);
        const sid = user.User.Sid orelse return error.GetTokenInformationFailed;

        // SID → "S-1-5-21-..." string.
        var sid_w: ?windows.LPWSTR = null;
        if (ConvertSidToStringSidW(sid, &sid_w) == 0) {
            return error.ConvertSidFailed;
        }
        defer _ = LocalFree(sid_w);
        const sid_utf8 = try std.unicode.utf16LeToUtf8Alloc(
            alloc,
            std.mem.span(sid_w.?),
        );
        defer alloc.free(sid_utf8);

        // SDDL string → security descriptor (LocalAlloc'd by the OS).
        const sddl = try std.fmt.allocPrint(
            alloc,
            "D:P(A;;GA;;;{s})",
            .{sid_utf8},
        );
        defer alloc.free(sddl);
        const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl);
        defer alloc.free(sddl_w);

        var sd: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w.ptr,
            SDDL_REVISION_1,
            &sd,
            null,
        ) == 0) return error.ConvertSddlFailed;

        return .{ .descriptor = sd.? };
    }

    fn deinit(self: *PipeSecurity) void {
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }
};

/// Format the production pipe name "ghostty-browser-<pid>" into buf.
/// The CLI client resolves the target window's pid and opens
/// \\.\pipe\ghostty-browser-<pid> with CreateFileW.
pub fn defaultPipeName(buf: []u8) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buf,
        "ghostty-browser-{d}",
        .{windows.GetCurrentProcessId()},
    );
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Invoked on the pipe thread for each successfully parsed request.
/// The callee takes ownership of `req` and must call `req.destroy()`
/// exactly once. In production wiring this PostMessageW's the request
/// pointer to App's msg_hwnd and the GUI thread answers later via
/// `server.sendOk` / `server.sendError`; answering directly from the
/// callback also works. The signature deliberately does not mention
/// `*Server` (that would create a type dependency loop through the
/// callback field); owners reach their server through `ctx`.
pub const RequestCallback = *const fn (ctx: ?*anyopaque, req: *Request) void;

pub const Server = struct {
    alloc: Allocator,
    /// Full "\\.\pipe\<name>" path, NUL-terminated UTF-16, owned.
    path_w: [:0]u16,
    pipe: windows.HANDLE,
    callback: RequestCallback,
    callback_ctx: ?*anyopaque,

    /// Manual-reset, signaled once by stop(); every subsequent wait
    /// returns immediately.
    stop_event: windows.HANDLE,
    /// Completion event for connect/read overlapped ops (pipe thread only).
    io_event: windows.HANDLE,
    /// Completion event for write overlapped ops; guarded by write_mutex.
    write_event: windows.HANDLE,

    /// Serializes senders so each response is one atomic pipe message.
    write_mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    /// Create the pipe \\.\pipe\<name> and spawn the pipe thread.
    /// `name` is the bare pipe name (see `defaultPipeName`).
    pub fn start(
        alloc: Allocator,
        name: []const u8,
        callback: RequestCallback,
        callback_ctx: ?*anyopaque,
    ) !*Server {
        const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
        defer alloc.free(path);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        errdefer alloc.free(path_w);

        var sec = try PipeSecurity.init(alloc);
        defer sec.deinit();
        var sa = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = sec.descriptor,
            .bInheritHandle = windows.FALSE,
        };

        // The pipe is created here, synchronously, so a client may
        // CreateFileW the moment start() returns. FIRST_PIPE_INSTANCE
        // defeats pipe-squatting: creation fails if the name already
        // exists. Message type so each WriteFile is one message; byte
        // read mode because the newline framing handles splitting and
        // never needs ERROR_MORE_DATA handling.
        const pipe = kernel32.CreateNamedPipeW(
            path_w.ptr,
            windows.PIPE_ACCESS_DUPLEX |
                FILE_FLAG_FIRST_PIPE_INSTANCE |
                FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_MESSAGE |
                windows.PIPE_READMODE_BYTE |
                windows.PIPE_WAIT |
                PIPE_REJECT_REMOTE_CLIENTS,
            1, // single instance: one agent client at a time
            64 * 1024,
            64 * 1024,
            0,
            &sa,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        errdefer windows.CloseHandle(pipe);

        const stop_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(stop_event);
        const io_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(io_event);
        const write_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(write_event);

        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .path_w = path_w,
            .pipe = pipe,
            .callback = callback,
            .callback_ctx = callback_ctx,
            .stop_event = stop_event,
            .io_event = io_event,
            .write_event = write_event,
            .running = std.atomic.Value(bool).init(true),
            .connected = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stop the pipe thread and free everything, including `self`.
    ///
    /// Unblocking mechanism: because every blocking op on the pipe
    /// thread (ConnectNamedPipe / ReadFile) is overlapped and actually
    /// waits on WaitForMultipleObjects({io_event, stop_event}), stop()
    /// only has to signal stop_event and CancelIoEx any in-flight op.
    /// No client-side dummy connect or CancelSynchronousIo needed —
    /// those are the workarounds for synchronous handles, which we
    /// can't use anyway (see the module doc on the sync-handle
    /// write/read deadlock).
    ///
    /// Must be the last call into the server: callers are responsible
    /// for ensuring no sendOk/sendError is in flight on other threads
    /// (in production, App stops IPC before tearing down the GUI
    /// thread's response path).
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        _ = SetEvent(self.stop_event);
        // Cancels pending I/O issued by any thread on this handle,
        // including a sender blocked in GetOverlappedResult.
        _ = kernel32.CancelIoEx(self.pipe, null);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        windows.CloseHandle(self.pipe);
        windows.CloseHandle(self.stop_event);
        windows.CloseHandle(self.io_event);
        windows.CloseHandle(self.write_event);
        self.alloc.free(self.path_w);
        self.alloc.destroy(self);
    }

    /// Send a success response. Thread-safe. `data_json` must already
    /// be valid serialized JSON; null sends "data":null.
    pub fn sendOk(self: *Server, id: u64, data_json: ?[]const u8) !void {
        const msg = try serializeOk(self.alloc, id, data_json);
        defer self.alloc.free(msg);
        try self.writeAll(msg);
    }

    /// Send an error response. Thread-safe. `msg` is JSON-escaped.
    pub fn sendError(self: *Server, id: u64, msg: []const u8) !void {
        const out = try serializeError(self.alloc, id, msg);
        defer self.alloc.free(out);
        try self.writeAll(out);
    }

    // -- pipe thread ------------------------------------------------------

    fn run(self: *Server) void {
        while (self.running.load(.acquire)) {
            switch (self.acceptOne()) {
                .connected => {
                    self.connected.store(true, .release);
                    self.readLoop();
                    self.connected.store(false, .release);
                    _ = DisconnectNamedPipe(self.pipe);
                },
                // A client connected and vanished before we accepted.
                .retry => _ = DisconnectNamedPipe(self.pipe),
                .shutdown => return,
            }
        }
    }

    const AcceptResult = enum { connected, retry, shutdown };

    fn acceptOne(self: *Server) AcceptResult {
        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.io_event;
        _ = ResetEvent(self.io_event);

        var pending = false;
        if (ConnectNamedPipe(self.pipe, &ov) == 0) {
            switch (windows.GetLastError()) {
                .PIPE_CONNECTED => {}, // client raced us; already connected
                .IO_PENDING => pending = true,
                .NO_DATA => return .retry,
                else => |err| {
                    log.warn(
                        "ConnectNamedPipe failed, stopping IPC server: error={d}",
                        .{@intFromEnum(err)},
                    );
                    return .shutdown;
                },
            }
        }
        if (pending) {
            if (self.completeOverlapped(&ov) == null) return .shutdown;
        }
        if (!self.running.load(.acquire)) return .shutdown;
        return .connected;
    }

    fn readLoop(self: *Server) void {
        var framer: LineFramer = .{};
        defer framer.deinit(self.alloc);

        var buf: [4096]u8 = undefined;
        while (self.running.load(.acquire)) {
            const n = self.readChunk(&buf) orelse return;
            if (n == 0) continue;

            framer.feed(self.alloc, buf[0..n]) catch |err| {
                if (err == error.MessageTooLong) {
                    self.sendError(0, ErrorCode.message_too_long.message()) catch {};
                }
                // Framing state is unrecoverable; drop the connection.
                return;
            };
            while (framer.next()) |line| {
                if (line.len == 0) continue;
                self.dispatchLine(line);
            }
        }
    }

    /// One overlapped ReadFile. Returns bytes read, or null when the
    /// client disconnected or the server is stopping.
    fn readChunk(self: *Server, buf: []u8) ?windows.DWORD {
        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.io_event;
        _ = ResetEvent(self.io_event);

        if (kernel32.ReadFile(
            self.pipe,
            @ptrCast(buf.ptr),
            @intCast(buf.len),
            null,
            &ov,
        ) == 0) {
            switch (windows.GetLastError()) {
                .IO_PENDING => {},
                else => return null, // BROKEN_PIPE etc.: client gone
            }
        }
        return self.completeOverlapped(&ov);
    }

    /// Wait for an overlapped connect/read on io_event to complete,
    /// racing the stop event. Returns bytes transferred, or null on
    /// stop or failure. On stop the op is canceled and drained so the
    /// kernel is done with `ov` before it leaves the caller's stack.
    fn completeOverlapped(
        self: *Server,
        ov: *windows.OVERLAPPED,
    ) ?windows.DWORD {
        const handles = [_]windows.HANDLE{ self.io_event, self.stop_event };
        const which = WaitForMultipleObjects(
            handles.len,
            &handles,
            windows.FALSE,
            windows.INFINITE,
        );
        var n: windows.DWORD = 0;
        if (which != windows.WAIT_OBJECT_0) {
            // Stop requested (or the wait itself failed): cancel + drain.
            _ = kernel32.CancelIoEx(self.pipe, ov);
            _ = GetOverlappedResult(self.pipe, ov, &n, windows.TRUE);
            return null;
        }
        if (GetOverlappedResult(self.pipe, ov, &n, windows.TRUE) == 0) return null;
        return n;
    }

    fn dispatchLine(self: *Server, line: []const u8) void {
        const result = parseLine(self.alloc, line) catch {
            // OOM: an error response would also have to allocate.
            return;
        };
        switch (result) {
            .ok => |req| self.callback(self.callback_ctx, req),
            .err => |failure| self.sendError(
                failure.id,
                failure.code.message(),
            ) catch |err| {
                log.warn("failed to send IPC error response: {}", .{err});
            },
        }
    }

    /// Write one response as a single pipe message. Thread-safe: the
    /// write mutex serializes concurrent senders, and overlapped I/O
    /// keeps writes independent of the pipe thread's pending ReadFile.
    fn writeAll(
        self: *Server,
        bytes: []const u8,
    ) error{ NotConnected, WriteFailed }!void {
        if (!self.connected.load(.acquire)) return error.NotConnected;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.write_event;
        _ = ResetEvent(self.write_event);

        if (kernel32.WriteFile(
            self.pipe,
            bytes.ptr,
            @intCast(bytes.len),
            null,
            &ov,
        ) == 0) {
            switch (windows.GetLastError()) {
                .IO_PENDING => {},
                else => return error.WriteFailed,
            }
        }
        var n: windows.DWORD = 0;
        if (GetOverlappedResult(self.pipe, &ov, &n, windows.TRUE) == 0) {
            return error.WriteFailed;
        }
        if (n != bytes.len) return error.WriteFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests: protocol layer
// ---------------------------------------------------------------------------

test "ipc: framer splits multiple lines in one chunk" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "{\"a\":1}\n{\"b\":2}\n");
    try testing.expectEqualStrings("{\"a\":1}", framer.next().?);
    try testing.expectEqualStrings("{\"b\":2}", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer accumulates partial chunks" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "{\"id\":1,");
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\"cmd\":\"open\"}");
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\n{\"id\":2}\n{");
    try testing.expectEqualStrings("{\"id\":1,\"cmd\":\"open\"}", framer.next().?);
    try testing.expectEqualStrings("{\"id\":2}", framer.next().?);
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "}\n");
    try testing.expectEqualStrings("{}", framer.next().?);
}

test "ipc: framer strips CRLF line endings" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "a\r\nb\n\r\n");
    try testing.expectEqualStrings("a", framer.next().?);
    try testing.expectEqualStrings("b", framer.next().?);
    try testing.expectEqualStrings("", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer rejects oversized lines" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    const big = try alloc.alloc(u8, max_line_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    try testing.expectError(error.MessageTooLong, framer.feed(alloc, big));
}

test "ipc: parse request round-trips id, cmd, and args" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":42,\"cmd\":\"open\",\"args\":{\"url\":\"https://example.com\"}}",
    );
    const req = result.ok;
    defer req.destroy();

    try testing.expectEqual(@as(u64, 42), req.id);
    try testing.expectEqual(Command.open, req.cmd);
    try testing.expectEqualStrings(
        "https://example.com",
        req.args.object.get("url").?.string,
    );
}

test "ipc: parse request without args" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":1,\"cmd\":\"snapshot\"}",
    );
    const req = result.ok;
    defer req.destroy();

    try testing.expectEqual(@as(u64, 1), req.id);
    try testing.expectEqual(Command.snapshot, req.cmd);
    try testing.expectEqual(std.json.Value.null, req.args);
}

test "ipc: parse bad JSON yields parse_error with id 0" {
    const result = try parseLine(testing.allocator, "{\"id\":3,, nope");
    try testing.expectEqual(ErrorCode.parse_error, result.err.code);
    try testing.expectEqual(@as(u64, 0), result.err.id);
}

test "ipc: parse non-object yields invalid_request" {
    const result = try parseLine(testing.allocator, "[1,2,3]");
    try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
}

test "ipc: parse missing or malformed id yields invalid_request" {
    {
        const result = try parseLine(testing.allocator, "{\"cmd\":\"open\"}");
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
        try testing.expectEqual(@as(u64, 0), result.err.id);
    }
    {
        const result = try parseLine(
            testing.allocator,
            "{\"id\":\"seven\",\"cmd\":\"open\"}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
    {
        const result = try parseLine(
            testing.allocator,
            "{\"id\":-1,\"cmd\":\"open\"}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
}

test "ipc: parse unknown cmd preserves the request id" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":7,\"cmd\":\"frobnicate\"}",
    );
    try testing.expectEqual(ErrorCode.unknown_command, result.err.code);
    try testing.expectEqual(@as(u64, 7), result.err.id);
}

test "ipc: parse non-object args yields invalid_request" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":1,\"cmd\":\"open\",\"args\":4}",
    );
    try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    try testing.expectEqual(@as(u64, 1), result.err.id);
}

test "ipc: serialize ok response" {
    const out = try serializeOk(testing.allocator, 5, "{\"title\":\"hi\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"id\":5,\"ok\":true,\"data\":{\"title\":\"hi\"}}\n",
        out,
    );
}

test "ipc: serialize ok response without data" {
    const out = try serializeOk(testing.allocator, 12, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"id\":12,\"ok\":true,\"data\":null}\n", out);
}

test "ipc: serialize error response escapes the message" {
    const out = try serializeError(testing.allocator, 0, "bad \"quote\"\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"id\":0,\"ok\":false,\"error\":\"bad \\\"quote\\\"\\n\"}\n",
        out,
    );
}

test "ipc: response id round-trips through JSON" {
    const alloc = testing.allocator;
    const out = try serializeOk(alloc, 4294967295, "true");
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        // Strip the trailing newline; it's framing, not JSON.
        std.mem.trimRight(u8, out, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(
        @as(i64, 4294967295),
        parsed.value.object.get("id").?.integer,
    );
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expect(parsed.value.object.get("data").?.bool);
}

// ---------------------------------------------------------------------------
// Tests: end-to-end over a real named pipe (Windows only)
// ---------------------------------------------------------------------------

test "ipc: end-to-end request and response over a named pipe" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "ghostty-ipc-test-{d}",
        .{windows.GetCurrentProcessId()},
    );

    const TestCtx = struct {
        server: ?*Server = null,

        fn onRequest(ctx_ptr: ?*anyopaque, req: *Request) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            const server = ctx.server.?;
            defer req.destroy();
            if (req.cmd != .open) {
                server.sendError(req.id, "expected open") catch {};
                return;
            }
            server.sendOk(req.id, "\"opened\"") catch {};
        }
    };
    var ctx: TestCtx = .{};

    const server = try Server.start(alloc, name, TestCtx.onRequest, &ctx);
    defer server.stop();
    // Safe: no client can connect (and thus no callback can fire)
    // until we CreateFileW below.
    ctx.server = server;

    // --- client side, plain synchronous CreateFileW like the CLI ---
    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
    defer alloc.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    const client = kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    try testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(client);

    var framer: LineFramer = .{};
    defer framer.deinit(alloc);
    var read_buf: [1024]u8 = undefined;

    // Round 1: valid request → ok response with data.
    {
        const request =
            "{\"id\":7,\"cmd\":\"open\",\"args\":{\"url\":\"https://example.com\"}}\n";
        var written: windows.DWORD = 0;
        try testing.expect(kernel32.WriteFile(
            client,
            request.ptr,
            request.len,
            &written,
            null,
        ) != 0);
        try testing.expectEqual(@as(windows.DWORD, request.len), written);

        const line = line: while (true) {
            var n: windows.DWORD = 0;
            try testing.expect(kernel32.ReadFile(
                client,
                @ptrCast(&read_buf),
                read_buf.len,
                &n,
                null,
            ) != 0);
            try framer.feed(alloc, read_buf[0..n]);
            if (framer.next()) |l| break :line l;
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
        try testing.expect(parsed.value.object.get("ok").?.bool);
        try testing.expectEqualStrings(
            "opened",
            parsed.value.object.get("data").?.string,
        );
    }

    // Round 2: malformed JSON → in-band error response from the server.
    {
        const request = "this is not json\n";
        var written: windows.DWORD = 0;
        try testing.expect(kernel32.WriteFile(
            client,
            request.ptr,
            request.len,
            &written,
            null,
        ) != 0);

        const line = line: while (true) {
            if (framer.next()) |l| break :line l;
            var n: windows.DWORD = 0;
            try testing.expect(kernel32.ReadFile(
                client,
                @ptrCast(&read_buf),
                read_buf.len,
                &n,
                null,
            ) != 0);
            try framer.feed(alloc, read_buf[0..n]);
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(i64, 0), parsed.value.object.get("id").?.integer);
        try testing.expect(!parsed.value.object.get("ok").?.bool);
        try testing.expectEqualStrings(
            ErrorCode.parse_error.message(),
            parsed.value.object.get("error").?.string,
        );
    }
}

test "ipc: stop unblocks a pending read while a client is connected" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "ghostty-ipc-stoptest-{d}",
        .{windows.GetCurrentProcessId()},
    );

    const handler = struct {
        fn onRequest(ctx: ?*anyopaque, req: *Request) void {
            _ = ctx;
            req.destroy();
        }
    };

    const server = try Server.start(alloc, name, handler.onRequest, null);

    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
    defer alloc.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    const client = kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    try testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(client);

    // Give the pipe thread time to park inside the overlapped ReadFile
    // wait, then stop with the client still attached. stop() must not
    // hang: the stop event + CancelIoEx aborts the pending read.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    server.stop();
}
