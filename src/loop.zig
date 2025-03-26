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
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.loop);

// SingleThreaded I/O Loop based on Tigerbeetle io_uring loop.
// On Linux it's using io_uring.
// On MacOS and Windows it's using kqueue/IOCP with a ring design.
// This is a thread-unsafe version without any lock on shared resources,
// use it only on a single thread.
// The loop provides I/O APIs based on callbacks.
// I/O APIs based on async/await might be added in the future.
pub const SingleThreaded = struct {
    io: IO,
    // number of in-flight events
    events_nb: usize,
    allocator: Allocator,
    cbk_error: bool = false,

    // ctx_id is incremented each time the loop is reset.
    // All context are
    ctx_id: u32 = 0,
    cancel_pool: std.heap.MemoryPool(ContextCancel),
    timeout_pool: std.heap.MemoryPool(ContextTimeout),
    completion_pool: std.heap.MemoryPool(Completion),
    event_callback_pool: std.heap.MemoryPool(EventCallbackContext),

    const Self = @This();
    pub const RecvError = IO.RecvError;
    pub const SendError = IO.SendError;
    pub const Completion = IO.Completion;
    pub const ConnectError = IO.ConnectError;

    pub fn init(allocator: Allocator) !Self {
        return .{
            .events_nb = 0,
            .allocator = allocator,
            .io = try IO.init(32, 0),
            .cancel_pool = std.heap.MemoryPool(ContextCancel).init(allocator),
            .timeout_pool = std.heap.MemoryPool(ContextTimeout).init(allocator),
            .completion_pool = std.heap.MemoryPool(Completion).init(allocator),
            .event_callback_pool = std.heap.MemoryPool(EventCallbackContext).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAll();
        self.io.deinit();
        self.cancel_pool.deinit();
        self.timeout_pool.deinit();
        self.completion_pool.deinit();
        self.event_callback_pool.deinit();
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
    fn addEvent(self: *Self) void {
        _ = @atomicRmw(usize, &self.events_nb, .Add, 1, .acq_rel);
    }
    // Deregister events atomically
    fn removeEvent(self: *Self) void {
        _ = @atomicRmw(usize, &self.events_nb, .Sub, 1, .acq_rel);
    }
    // Get the number of current events
    fn eventsNb(self: *Self) usize {
        return @atomicLoad(usize, &self.events_nb, .seq_cst);
    }
    fn resetEvents(self: *Self) void {
        @atomicStore(usize, &self.events_nb, 0, .unordered);
    }

    // JS callbacks APIs
    // -----------------

    // Timeout

    const ContextTimeout = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        ctx_id: u32,
    };

    fn timeoutCallback(
        ctx: *ContextTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        const loop = ctx.loop;
        defer {
            loop.timeout_pool.destroy(ctx);
            loop.completion_pool.destroy(completion);
        }

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.ctx_id != loop.ctx_id) return;

        loop.removeEvent();

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
            defer js_cbk.deinit(loop.allocator);
            js_cbk.call(null) catch {
                loop.cbk_error = true;
            };
        }
    }

    pub fn timeout(self: *Self, nanoseconds: u63, js_cbk: ?JSCallback) !usize {
        const completion = try self.completion_pool.create();
        errdefer self.completion_pool.destroy(completion);
        completion.* = undefined;

        const ctx = try self.timeout_pool.create();
        errdefer self.timeout_pool.destroy(ctx);
        ctx.* = ContextTimeout{
            .loop = self,
            .js_cbk = js_cbk,
            .ctx_id = self.ctx_id,
        };

        self.addEvent();
        self.io.timeout(*ContextTimeout, ctx, timeoutCallback, completion, nanoseconds);
        return @intFromPtr(completion);
    }

    const ContextCancel = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        ctx_id: u32,
    };

    fn cancelCallback(
        ctx: *ContextCancel,
        completion: *IO.Completion,
        result: IO.CancelOneError!void,
    ) void {
        const loop = ctx.loop;
        defer {
            ctx.loop.timeout_pool.destroy(ctx);
            ctx.loop.completion_pool.destroy(completion);
        }

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.ctx_id != loop.ctx_id) return;

        loop.removeEvent();

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
            defer js_cbk.deinit(loop.allocator);
            js_cbk.call(null) catch {
                loop.cbk_error = true;
            };
        }
    }

    pub fn cancel(self: *Self, id: usize, js_cbk: ?JSCallback) !void {
        const comp_cancel: *IO.Completion = @ptrFromInt(id);

        const completion = try self.completion_pool.create();
        errdefer self.completion_pool.destroy(completion);
        completion.* = undefined;

        const ctx = try self.cancel_pool.create();
        errdefer self.cancel_pool.destroy(ctx);
        ctx.* = ContextCancel{
            .loop = self,
            .js_cbk = js_cbk,
            .ctx_id = self.ctx_id,
        };

        self.addEvent();
        self.io.cancel_one(*ContextCancel, ctx, cancelCallback, completion, comp_cancel);
    }

    pub fn cancelAll(self: *Self) void {
        self.resetEvents();
        self.io.cancel_all();
    }

    // Reset all existing callbacks.
    pub fn reset(self: *Self) void {
        self.ctx_id += 1;
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
    ) !void {
        const onConnect = struct {
            fn onConnect(callback: *EventCallbackContext, completion_: *Completion, res: ConnectError!void) void {
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent();
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onConnect;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent();
        self.io.connect(*EventCallbackContext, callback, onConnect, completion, socket, address);
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
    ) !void {
        const onSend = struct {
            fn onSend(callback: *EventCallbackContext, completion_: *Completion, res: SendError!usize) void {
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent();
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onSend;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent();
        self.io.send(*EventCallbackContext, callback, onSend, completion, socket, buf);
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
    ) !void {
        const onRecv = struct {
            fn onRecv(callback: *EventCallbackContext, completion_: *Completion, res: RecvError!usize) void {
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent();
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onRecv;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent();
        self.io.recv(*EventCallbackContext, callback, onRecv, completion, socket, buf);
    }
};

const EventCallbackContext = struct {
    ctx: *anyopaque,
    loop: *SingleThreaded,
};
