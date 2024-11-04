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

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !Self {
        const io = try alloc.create(IO);
        io.* = try IO.init(32, 0);
        const events_nb = try alloc.create(usize);
        events_nb.* = 0;
        return Self{ .alloc = alloc, .io = io, .events_nb = events_nb };
    }

    pub fn deinit(self: Self) void {
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
            try self.io.run_for_ns(10 * std.time.ns_per_ms); // 10ms
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

    fn freeCbk(self: *Self, completion: *IO.Completion, ctx: anytype) void {
        self.alloc.destroy(completion);
        self.alloc.destroy(ctx);
    }

    // Callback-based APIs
    // -------------------

    // Timeout

    const ContextTimeout = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
    };

    fn timeoutCallback(
        ctx: *ContextTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        defer ctx.loop.freeCbk(completion, ctx);

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
        if (ctx.js_cbk) |js_cbk| {
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
    };

    fn cancelCallback(
        ctx: *ContextCancel,
        completion: *IO.Completion,
        result: IO.CancelError!void,
    ) void {
        defer ctx.loop.freeCbk(completion, ctx);

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
        if (ctx.js_cbk) |js_cbk| {
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
        };

        const old_events_nb = self.addEvent();
        self.io.cancel(*ContextCancel, ctx, cancelCallback, completion, comp_cancel);
        if (builtin.is_test) {
            report("cancel {d}", .{old_events_nb + 1});
        }
    }

    // Yield
    pub fn Yield(comptime Ctx: type) type {
        // TODO check ctx interface funcs:
        // - onYield(ctx: *Ctx, ?anyerror) void
        return struct {
            const YieldImpl = @This();
            const Loop = Self;

            loop: *Loop,
            ctx: *Ctx,
            completion: IO.Completion,

            pub fn init(loop: *Loop) YieldImpl {
                return .{
                    .loop = loop,
                    .completion = undefined,
                    .ctx = undefined,
                };
            }

            pub fn tick(self: *YieldImpl) !void {
                return try self.loop.io.run_for_ns(10 * std.time.ns_per_us); // 10µs
            }

            pub fn yield(self: *YieldImpl, ctx: *Ctx) void {
                self.ctx = ctx;
                _ = self.loop.addEvent();
                self.loop.io.timeout(*YieldImpl, self, YieldImpl.yieldCbk, &self.completion, 0);
            }

            fn yieldCbk(self: *YieldImpl, _: *IO.Completion, result: IO.TimeoutError!void) void {
                _ = self.loop.removeEvent();
                _ = result catch |err| return self.ctx.onYield(err);
                return self.ctx.onYield(null);
            }
        };
    }

    // Network
    pub fn Network(comptime Ctx: type) type {

        // TODO check ctx interface funcs:
        // - onConnect(ctx: *Ctx, ?anyerror) void
        // - onReceive(ctx: *Ctx, usize, ?anyerror) void
        // - onSend(ctx: *Ctx, usize, ?anyerror) void

        return struct {
            const NetworkImpl = @This();
            const Loop = Self;

            loop: *Loop,
            ctx: *Ctx,
            completion: IO.Completion,

            pub fn init(loop: *Loop) NetworkImpl {
                return .{
                    .loop = loop,
                    .completion = undefined,
                    .ctx = undefined,
                };
            }

            pub fn tick(self: *NetworkImpl) !void {
                return try self.loop.io.run_for_ns(10 * std.time.ns_per_us); // 10µs
            }

            pub fn connect(self: *NetworkImpl, ctx: *Ctx, socket: std.posix.socket_t, address: std.net.Address) void {
                self.ctx = ctx;
                _ = self.loop.addEvent();
                self.loop.io.connect(*NetworkImpl, self, NetworkImpl.connectCbk, &self.completion, socket, address);
            }

            fn connectCbk(self: *NetworkImpl, _: *IO.Completion, result: IO.ConnectError!void) void {
                _ = self.loop.removeEvent();
                _ = result catch |err| return self.ctx.onConnect(err);
                return self.ctx.onConnect(null);
            }

            pub fn receive(self: *NetworkImpl, ctx: *Ctx, socket: std.posix.socket_t, buffer: []u8) void {
                self.ctx = ctx;
                _ = self.loop.addEvent();
                self.loop.io.recv(*NetworkImpl, self, NetworkImpl.receiveCbk, &self.completion, socket, buffer);
            }

            fn receiveCbk(self: *NetworkImpl, _: *IO.Completion, result: IO.RecvError!usize) void {
                _ = self.loop.removeEvent();
                const ln = result catch |err| return self.ctx.onReceive(0, err);
                return self.ctx.onReceive(ln, null);
            }

            pub fn send(self: *NetworkImpl, ctx: *Ctx, socket: std.posix.socket_t, buffer: []const u8) void {
                self.ctx = ctx;
                _ = self.loop.addEvent();
                self.loop.io.send(*NetworkImpl, self, NetworkImpl.sendCbk, &self.completion, socket, buffer);
            }

            fn sendCbk(self: *NetworkImpl, _: *IO.Completion, result: IO.SendError!usize) void {
                _ = self.loop.removeEvent();
                const ln = result catch |err| return self.ctx.onSend(0, err);
                return self.ctx.onSend(ln, null);
            }
        };
    }
};
