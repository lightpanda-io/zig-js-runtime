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

    const Loop = @This();

    pub fn init(alloc: std.mem.Allocator) !Loop {
        const io = try alloc.create(IO);
        io.* = try IO.init(32, 0);
        const events_nb = try alloc.create(usize);
        events_nb.* = 0;
        return Loop{ .alloc = alloc, .io = io, .events_nb = events_nb };
    }

    pub fn deinit(self: Loop) void {
        self.io.deinit();
        self.alloc.destroy(self.io);
        self.alloc.destroy(self.events_nb);
    }

    // Retrieve all registred I/O events completed by OS kernel,
    // and execute sequentially their callbacks.
    // Stops when there is no more I/O events registered on the loop.
    // Note that I/O events callbacks might register more I/O events
    // on the go when they are executed (ie. nested I/O events).
    pub fn run(self: *Loop) !void {
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
    fn addEvent(self: *Loop) usize {
        return @atomicRmw(usize, self.events_nb, .Add, 1, .AcqRel);
    }
    // - remove 1 event and return previous value
    fn removeEvent(self: *Loop) usize {
        return @atomicRmw(usize, self.events_nb, .Sub, 1, .AcqRel);
    }
    // - get the number of current events
    fn eventsNb(self: *Loop) usize {
        return @atomicLoad(usize, self.events_nb, .SeqCst);
    }

    fn freeCbk(self: *Loop, completion: *IO.Completion, ctx: anytype) void {
        self.alloc.destroy(completion);
        self.alloc.destroy(ctx);
    }

    // Callback-based APIs
    // -------------------

    // Network

    pub fn Impl(comptime Ctx: type) type {

        // TODO: check interfaces of Ctx:
        // - loop, socket fields
        // - connected, sent, reveived methods

        return struct {
            const Self = @This();

            pub fn connect(
                ctx: *Ctx,
                address: std.net.Address,
            ) !void {

                // TODO: free completion
                const completion = try ctx.loop.alloc.create(IO.Completion);
                completion.* = undefined;

                const old_events_nb = ctx.loop.addEvent();
                ctx.loop.io.connect(
                    *Ctx,
                    ctx,
                    Self.connect_callback,
                    completion,
                    ctx.socket,
                    address,
                );

                if (builtin.is_test) {
                    report("start connect {d} on {any} at {any}", .{
                        old_events_nb + 1,
                        ctx.socket,
                        address,
                    });
                }
            }

            fn connect_callback(
                ctx: *Ctx,
                completion: *IO.Completion,
                result: IO.ConnectError!void,
            ) void {

                // TODO: return the error to the callback
                result catch |err| @panic(@errorName(err));

                const old_events_nb = ctx.loop.removeEvent();
                if (builtin.is_test) {
                    report("connect done, remaining events: {d}", .{old_events_nb - 1});
                }

                ctx.connected(Self, completion);
            }

            fn send(
                ctx: *Ctx,
                completion: *IO.Completion,
                buf: []const u8,
            ) void {
                const old_events_nb = ctx.loop.addEvent();
                ctx.loop.io.send(
                    *Ctx,
                    ctx,
                    Self.send_callback,
                    completion,
                    ctx.socket,
                    buf,
                );

                if (builtin.is_test) {
                    report("start send {d} on {any} with buf len {d}", .{
                        old_events_nb + 1,
                        ctx.socket,
                        buf.len,
                    });
                }
            }

            fn send_callback(
                ctx: *Ctx,
                completion: *IO.Completion,
                result: IO.SendError!usize,
            ) void {

                // TODO: return the error to the callback
                const sent_nb = result catch |err| @panic(@errorName(err));

                const old_events_nb = ctx.loop.removeEvent();
                if (builtin.is_test) {
                    report("send done, remaining events: {d}", .{old_events_nb - 1});
                }

                ctx.sent(Self, completion, sent_nb);
            }
        };
    }

    pub const TCPClient = struct {
        alloc: std.mem.Allocator,
        loop: *Loop,
        socket: std.os.socket_t,
        buf: []const u8,

        pub fn init(alloc: std.mem.Allocator, loop: *Loop) !TCPClient {
            const msg: []const u8 = "OK\n";
            return .{
                .alloc = alloc,
                .loop = loop,
                .socket = undefined,
                .buf = try std.mem.Allocator.dupe(alloc, u8, msg),
            };
        }

        pub fn start(
            self: *TCPClient,
            comptime impl: anytype,
            host: []const u8,
            port: u16,
        ) !void {
            const addr = try std.net.Address.parseIp4(host, port);
            self.socket = try self.loop.io.open_socket(
                addr.any.family,
                std.os.SOCK.STREAM,
                std.os.IPPROTO.TCP,
            );
            try impl.connect(self, addr);
        }

        fn connected(
            self: *TCPClient,
            comptime impl: anytype,
            completion: *IO.Completion,
        ) void {
            impl.send(self, completion, self.buf);
        }

        fn sent(
            self: *TCPClient,
            comptime _: anytype,
            completion: *IO.Completion,
            nb: usize,
        ) void {

            // TODO: handle nb == ctx.buf.len
            // ie: all data has not been sent
            std.debug.print("sent {d} bytes\n", .{nb});

            // TODO: IO receive
            self.deinit(completion);
        }

        fn received(
            self: *TCPClient,
            comptime _: anytype,
            completion: *IO.Completion,
            nb: usize,
        ) void {
            _ = completion;

            std.debug.print("recv {d} bytes\n", .{nb});
            if (nb > 0) {
                const d = self.buf.?[0..nb];
                std.debug.print("recv data: {s}\n", .{d});
            }
            // TODO: handle nb == ctx.buf.len
            // ie: EOF
        }

        fn deinit(
            self: *TCPClient,
            completion: *IO.Completion,
        ) void {
            defer self.loop.freeCbk(completion, self);
            std.os.closeSocket(self.socket);
            self.alloc.free(self.buf);
        }
    };

    // Timeout

    const ContextTimeout = struct {
        loop: *Loop,
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
        if (ctx.js_cbk) |js_cbk| {
            defer js_cbk.deinit(ctx.loop.alloc);
            js_cbk.call(null) catch {
                ctx.loop.cbk_error = true;
            };
        }
    }

    pub fn timeout(self: *Loop, nanoseconds: u63, js_cbk: ?JSCallback) void {
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
    }
};
