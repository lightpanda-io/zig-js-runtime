const std = @import("std");
const builtin = @import("builtin");

pub const IO = @import("tigerbeetle-io").IO;

const public = @import("api.zig");
const JSCallback = public.Callback;

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
        var io = try alloc.create(IO);
        io.* = try IO.init(32, 0);
        var events_nb = try alloc.create(usize);
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
            try self.io.tick();
            // at each iteration we might have new events registred by previous callbacks
        }
        if (self.cbk_error) {
            return error.JSCallback;
        }
    }

    // Register events atomically
    // - add 1 event and return previous value
    fn addEvent(self: *Self) usize {
        return @atomicRmw(usize, self.events_nb, .Add, 1, .AcqRel);
    }
    // - remove 1 event and return previous value
    fn removeEvent(self: *Self) usize {
        return @atomicRmw(usize, self.events_nb, .Sub, 1, .AcqRel);
    }
    // - get the number of current events
    fn eventsNb(self: *Self) usize {
        return @atomicLoad(usize, self.events_nb, .SeqCst);
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

        // TODO: return the error to the callback
        result catch |err| @panic(@errorName(err));

        const old_events_nb = ctx.loop.removeEvent();
        if (builtin.is_test) {
            report("timeout done, remaining events: {d}", .{old_events_nb - 1});
        }

        // js callback
        if (ctx.js_cbk != null) {
            ctx.js_cbk.?.call(ctx.loop.alloc) catch {
                ctx.loop.cbk_error = true;
            };
        }
    }

    pub fn timeout(self: *Self, nanoseconds: u63, js_cbk: ?JSCallback) void {
        var completion = self.alloc.create(IO.Completion) catch unreachable;
        completion.* = undefined;
        var ctx = self.alloc.create(ContextTimeout) catch unreachable;
        ctx.* = ContextTimeout{
            .loop = self,
            .js_cbk = js_cbk,
        };
        const old_events_nb = self.addEvent();
        self.io.timeout(*ContextTimeout, ctx, timeoutCallback, completion, nanoseconds);
        if (builtin.is_test) {
            report("start timeout {d} for {d} nanoseconds", .{ old_events_nb + 1, nanoseconds });
        }
    }
};
