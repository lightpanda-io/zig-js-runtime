// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const builtin = @import("builtin");

pub const IO = @import("tigerbeetle-io").IO;

const public = @import("api.zig");
const JSCallback = public.Callback;

const log = std.log.scoped(.loop);

fn report(comptime fmt: []const u8, args: anytype) void {
    const max_len = 200;
    var buf: [max_len]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0..], fmt, args) catch |err| @panic(@errorName(err));
    const report_fmt = "[Thread {d}] {s}\n";
    std.debug.print(report_fmt, .{ std.Thread.getCurrentId(), s });
}

// SingleThreaded I/O Loop based on Tigerbeetle io_uring loop.
// On Linux it's using io_uring.
// On MacOS and Windows it's using kqueue/IOCP with a ring design.
// This is a thread-unsafe version without any lock on shared resources,
// use it only on a single thread.
// The loop provides I/O APIs based on callbacks.
// I/O APIs based on async/await might be added in the future.
pub const SingleThreaded = struct {
    alloc: std.mem.Allocator, // TODO: unmanaged version ?
    io: *IO,
    events_nb: *usize,
    cbk_error: bool = false,

    // js_ctx_id is incremented each time the loop is reset for JS.
    // All JS callbacks store an initial js_ctx_id and compare before execution.
    // If a ctx is outdated, the callback is ignored.
    // This is a weak way to cancel all future JS callbacks.
    js_ctx_id: u32 = 0,

    // zig_ctx_id is incremented each time the loop is reset for Zig.
    // All Zig callbacks store an initial zig_ctx_id and compare before execution.
    // If a ctx is outdated, the callback is ignored.
    // This is a weak way to cancel all future Zig callbacks.
    zig_ctx_id: u32 = 0,

    const Self = @This();
    pub const Completion = IO.Completion;

    pub const ConnectError = IO.ConnectError;
    pub const RecvError = IO.RecvError;
    pub const SendError = IO.SendError;

    pub fn init(alloc: std.mem.Allocator) !Self {
        const io = try alloc.create(IO);
        errdefer alloc.destroy(io);

        io.* = try IO.init(32, 0);
        const events_nb = try alloc.create(usize);
        events_nb.* = 0;
        return Self{ .alloc = alloc, .io = io, .events_nb = events_nb };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAll();
        self.io.deinit();
        self.alloc.destroy(self.io);
        self.alloc.destroy(self.events_nb);
    }

    // Retrieve all registred I/O events completed by OS kernel,
    // and execute sequentially their callbacks.
    // Stops when there is no more I/O events registered on the loop.
    // Note that I/O events callbacks might register more I/O events
    // on the go when they are executed (ie. nested I/O events).
    pub fn run(self: *Self) !void {
        while (self.eventsNb() > 0) {
            try self.io.run_for_ns(10 * std.time.ns_per_ms);
            // at each iteration we might have new events registred by previous callbacks
        }
        // TODO: return instead immediatly on the first JS callback error
        // and let the caller decide what to do next
        // (typically retrieve the exception through the TryCatch and
        // continue the execution of callbacks with a new call to loop.run)
        if (self.cbk_error) {
            return error.JSExecCallback;
        }
    }

    // Register events atomically
    // - add 1 event and return previous value
    fn addEvent(self: *Self) usize {
        return @atomicRmw(usize, self.events_nb, .Add, 1, .acq_rel);
    }
    // - remove 1 event and return previous value
    fn removeEvent(self: *Self) usize {
        return @atomicRmw(usize, self.events_nb, .Sub, 1, .acq_rel);
    }
    // - get the number of current events
    fn eventsNb(self: *Self) usize {
        return @atomicLoad(usize, self.events_nb, .seq_cst);
    }
    fn resetEvents(self: *Self) void {
        @atomicStore(usize, self.events_nb, 0, .unordered);
    }

    fn freeCbk(self: *Self, completion: *IO.Completion, ctx: anytype) void {
        self.alloc.destroy(completion);
        self.alloc.destroy(ctx);
    }

    // JS callbacks APIs
    // -----------------

    // Timeout

    const ContextTimeout = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        js_ctx_id: u32,
    };

    fn timeoutCallback(
        ctx: *ContextTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        defer ctx.loop.freeCbk(completion, ctx);

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.js_ctx_id != ctx.loop.js_ctx_id) return;

        const old_events_nb = ctx.loop.removeEvent();
        if (builtin.is_test) {
            report("timeout done, remaining events: {d}", .{old_events_nb - 1});
        }

        // TODO: return the error to the callback
        result catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.err("timeout callback: {any}", .{err}),
            }
            return;
        };

        // js callback
        if (ctx.js_cbk) |*js_cbk| {
            defer js_cbk.deinit(ctx.loop.alloc);
            js_cbk.call(null) catch {
                ctx.loop.cbk_error = true;
            };
        }
    }

    pub fn timeout(self: *Self, nanoseconds: u63, js_cbk: ?JSCallback) usize {
        const completion = self.alloc.create(IO.Completion) catch unreachable;
        completion.* = undefined;
        const ctx = self.alloc.create(ContextTimeout) catch unreachable;
        ctx.* = ContextTimeout{
            .loop = self,
            .js_cbk = js_cbk,
            .js_ctx_id = self.js_ctx_id,
        };
        const old_events_nb = self.addEvent();
        self.io.timeout(*ContextTimeout, ctx, timeoutCallback, completion, nanoseconds);
        if (builtin.is_test) {
            report("start timeout {d} for {d} nanoseconds", .{ old_events_nb + 1, nanoseconds });
        }

        return @intFromPtr(completion);
    }

    const ContextCancel = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        js_ctx_id: u32,
    };

    fn cancelCallback(
        ctx: *ContextCancel,
        completion: *IO.Completion,
        result: IO.CancelOneError!void,
    ) void {
        defer ctx.loop.freeCbk(completion, ctx);

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.js_ctx_id != ctx.loop.js_ctx_id) return;

        const old_events_nb = ctx.loop.removeEvent();
        if (builtin.is_test) {
            report("cancel done, remaining events: {d}", .{old_events_nb - 1});
        }

        // TODO: return the error to the callback
        result catch |err| {
            switch (err) {
                error.NotFound => log.debug("cancel callback: {any}", .{err}),
                else => log.err("cancel callback: {any}", .{err}),
            }
            return;
        };

        // js callback
        if (ctx.js_cbk) |*js_cbk| {
            defer js_cbk.deinit(ctx.loop.alloc);
            js_cbk.call(null) catch {
                ctx.loop.cbk_error = true;
            };
        }
    }

    pub fn cancel(self: *Self, id: usize, js_cbk: ?JSCallback) void {
        const comp_cancel: *IO.Completion = @ptrFromInt(id);

        const completion = self.alloc.create(IO.Completion) catch unreachable;
        completion.* = undefined;
        const ctx = self.alloc.create(ContextCancel) catch unreachable;
        ctx.* = ContextCancel{
            .loop = self,
            .js_cbk = js_cbk,
            .js_ctx_id = self.js_ctx_id,
        };

        const old_events_nb = self.addEvent();
        self.io.cancel_one(*ContextCancel, ctx, cancelCallback, completion, comp_cancel);
        if (builtin.is_test) {
            report("cancel {d}", .{old_events_nb + 1});
        }
    }

    pub fn cancelAll(self: *Self) void {
        self.resetEvents();
        self.io.cancel_all();
    }

    // Reset all existing JS callbacks.
    pub fn resetJS(self: *Self) void {
        self.js_ctx_id += 1;
        self.resetEvents();
    }

    // Reset all existing Zig callbacks.
    pub fn resetZig(self: *Self) void {
        self.zig_ctx_id += 1;
        self.resetEvents();
    }

    // IO callbacks APIs
    // -----------------

    // Connect

    pub fn connect(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, _: *Completion, res: ConnectError!void) void,
        socket: std.posix.socket_t,
        address: std.net.Address,
    ) void {
        const old_events_nb = self.addEvent();
        self.io.connect(*Ctx, ctx, cbk, completion, socket, address);
        if (builtin.is_test) {
            report("start connect {d}", .{old_events_nb + 1});
        }
    }

    pub fn onConnect(self: *Self, _: ConnectError!void) void {
        const old_events_nb = self.removeEvent();
        if (builtin.is_test) {
            report("connect done, remaining events: {d}", .{old_events_nb - 1});
        }
    }

    // Send

    pub fn send(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, completion: *Completion, res: SendError!usize) void,
        socket: std.posix.socket_t,
        buf: []const u8,
    ) void {
        const old_events_nb = self.addEvent();
        self.io.send(*Ctx, ctx, cbk, completion, socket, buf);
        if (builtin.is_test) {
            report("start send {d}", .{old_events_nb + 1});
        }
    }

    pub fn onSend(self: *Self, _: SendError!usize) void {
        const old_events_nb = self.removeEvent();
        if (builtin.is_test) {
            report("send done, remaining events: {d}", .{old_events_nb - 1});
        }
    }

    // Recv

    pub fn recv(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, completion: *Completion, res: RecvError!usize) void,
        socket: std.posix.socket_t,
        buf: []u8,
    ) void {
        const old_events_nb = self.addEvent();
        self.io.recv(*Ctx, ctx, cbk, completion, socket, buf);
        if (builtin.is_test) {
            report("start recv {d}", .{old_events_nb + 1});
        }
    }

    pub fn onRecv(self: *Self, _: RecvError!usize) void {
        const old_events_nb = self.removeEvent();
        if (builtin.is_test) {
            report("recv done, remaining events: {d}", .{old_events_nb - 1});
        }
    }

    // Zig timeout

    const ContextZigTimeout = struct {
        loop: *Self,
        zig_ctx_id: u32,

        context: *anyopaque,
        callback: *const fn (
            context: ?*anyopaque,
        ) void,
    };

    fn zigTimeoutCallback(
        ctx: *ContextZigTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        defer ctx.loop.freeCbk(completion, ctx);

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.zig_ctx_id != ctx.loop.zig_ctx_id) return;

        // We don't remove event here b/c we don't want the main loop to wait for
        // the timeout is done.
        // This is mainly due b/c the usage of zigTimeout is used to process
        // background tasks.
        //_ = ctx.loop.removeEvent();

        result catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.err("zig timeout callback: {any}", .{err}),
            }
            return;
        };

        // callback
        ctx.callback(ctx.context);
    }

    // zigTimeout performs a timeout but the callback is a zig function.
    pub fn zigTimeout(
        self: *Self,
        nanoseconds: u63,
        comptime Context: type,
        context: Context,
        comptime callback: fn (context: Context) void,
    ) void {
        const completion = self.alloc.create(IO.Completion) catch unreachable;
        completion.* = undefined;
        const ctxtimeout = self.alloc.create(ContextZigTimeout) catch unreachable;
        ctxtimeout.* = ContextZigTimeout{
            .loop = self,
            .zig_ctx_id = self.zig_ctx_id,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque) void {
                    callback(@ptrCast(@alignCast(ctx)));
                }
            }.wrapper,
        };

        // We don't add event here b/c we don't want the main loop to wait for
        // the timeout is done.
        // This is mainly due b/c the usage of zigTimeout is used to process
        // background tasks.
        // _ = self.addEvent();

        self.io.timeout(*ContextZigTimeout, ctxtimeout, zigTimeoutCallback, completion, nanoseconds);
    }
};
