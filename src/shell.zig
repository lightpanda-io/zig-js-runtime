const std = @import("std");
const builtin = @import("builtin");

const v8 = @import("v8");
const c = @cImport({
    @cInclude("linenoise.h");
});

const utils = @import("utils.zig");
const eng = @import("engine.zig");
const gen = @import("generate.zig");

const Loop = @import("loop.zig").SingleThreaded;
const IO = @import("loop.zig").IO;

const Console = @import("console.zig").Console;

var socket_p: []const u8 = undefined;

// I/O connection context
const ConnContext = struct {
    socket: std.os.socket_t,

    cmdContext: *CmdContext,
};

// I/O connection callback
fn connCallback(
    ctx: *ConnContext,
    completion: *IO.Completion,
    result: IO.AcceptError!std.os.socket_t,
) void {
    ctx.cmdContext.socket = result catch |err| @panic(@errorName(err));

    // launch receving messages asynchronously
    ctx.cmdContext.loop.io.recv(
        *CmdContext,
        ctx.cmdContext,
        cmdCallback,
        completion,
        ctx.cmdContext.socket,
        ctx.cmdContext.buf,
    );
}

// I/O input command context
const CmdContext = struct {
    loop: *Loop,
    socket: std.os.socket_t,
    buf: []u8,
    close: bool = false,

    isolate: v8.Isolate,
    js_ctx: v8.Context,
    try_catch: *v8.TryCatch,
};

// I/O input command callback
fn cmdCallback(
    ctx: *CmdContext,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const size = result catch |err| {
        ctx.close = true;
        std.debug.print("recv error: {s}\n", .{@errorName(err)});
        return;
    };

    const input = ctx.buf[0..size];

    // close on exit command
    if (std.mem.eql(u8, input, "exit")) {
        ctx.close = true;
        return;
    }

    // JS execute
    const res = eng.jsExecScript(
        utils.allocator,
        ctx.isolate,
        ctx.js_ctx,
        input,
        "shell.js",
        ctx.try_catch.*,
    );
    defer res.deinit();

    // JS print result
    var success = if (res.success) "<- " else "";
    printStdout("{s}{s}\n", .{ success, res.result });

    // acknowledge to repl result has been printed
    _ = std.os.write(ctx.socket, "ok") catch unreachable;

    // continue receving messages asynchronously
    ctx.loop.io.recv(
        *CmdContext,
        ctx,
        cmdCallback,
        completion,
        ctx.socket,
        ctx.buf,
    );
}

fn shellExec(
    loop: *Loop,
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    tpls: []gen.ProtoTpl,
    comptime apis: []gen.API,
) !eng.ExecRes {

    // create internal server listening on a unix socket
    var addr = try std.net.Address.initUnix(socket_p);
    var server = std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(addr);

    // launch repl in a separate detached thread
    var repl_thread = try std.Thread.spawn(.{}, repl, .{});
    repl_thread.detach();

    // create JS context
    var js_ctx = v8.Context.init(isolate, globals, null);
    js_ctx.enter();
    defer js_ctx.exit();

    // add console
    const console = Console{};
    try eng.createV8Object(
        utils.allocator,
        apis[0].T_refl,
        console,
        tpls[0].tpl,
        js_ctx.getGlobal(),
        js_ctx,
        isolate,
    );

    // JS try cache
    var try_catch: v8.TryCatch = undefined;
    try_catch.init(isolate);
    defer try_catch.deinit();

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var input: [1024]u8 = undefined;
    var cmd_ctx = CmdContext{
        .loop = loop,
        .socket = undefined,
        .buf = &input,
        .isolate = isolate,
        .js_ctx = js_ctx,
        .try_catch = &try_catch,
    };
    var conn_ctx = ConnContext{
        .socket = server.sockfd.?,
        .cmdContext = &cmd_ctx,
    };
    var completion: IO.Completion = undefined;

    // launch accepting connection asynchronously on internal server
    loop.io.accept(
        *ConnContext,
        &conn_ctx,
        connCallback,
        &completion,
        server.sockfd.?,
    );

    // infinite loop on I/O events, either:
    // - user input command from repl
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            if (try_catch.getException()) |msg| {
                const except = try utils.valueToUtf8(
                    utils.allocator,
                    msg,
                    isolate,
                    js_ctx,
                );
                printStdout("\n\rUncaught {s}\n\r", .{except});
                utils.allocator.free(except);
            }
            loop.cbk_error = false;
        }
        if (cmd_ctx.close) {
            break;
        }
    }

    return eng.ExecOK;
}

fn repl() !void {

    // greetings
    printStdout(
        \\JS Repl
        \\exit with Ctrl+D or "exit"
        \\
    , .{});

    // create a socket client connected to the internal server
    const socket = try std.net.connectUnixSocket(socket_p);

    var ack: [2]u8 = undefined;

    // infinite loop
    while (true) {

        // linenoise lib
        const line = c.linenoise("> ");

        if (line != null) {
            const input = std.mem.sliceTo(line.?, 0);

            // continue if input empty
            if (input.len == 0) {
                // free the line
                c.linenoiseFree(line);
                continue;
            }

            // stop loop on exit input
            if (std.mem.eql(u8, input, "exit") or
                std.mem.eql(u8, input, "exit;"))
            {
                // free the line
                c.linenoiseFree(line);
                break;
            }

            // send the input command to the internal server
            _ = try socket.write(input);

            // free the line
            c.linenoiseFree(line);

            // aknowledge response from the internal server
            // before giving back the input to the user
            _ = socket.read(&ack) catch |err| {
                std.debug.print("ack error: {s}\n", .{@errorName(err)});
                // stop loop on ack read error
                break;
            };
        } else {

            // stop loop on Ctrl+D
            break;
        }
    }

    // send the exit command to the internal server
    _ = try socket.write("exit");
    printStdout("Goodbye...\n", .{});
}

pub fn shell(alloc: std.mem.Allocator, comptime apis: []gen.API, socket_path: []const u8) !void {
    socket_p = socket_path;

    // remove socket file of internal server
    // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // see: https://gavv.net/articles/unix-socket-reuse/
    // TODO: use a lock file instead
    std.os.unlink(socket_p) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // load v8
    _ = try eng.Load(alloc, false, shellExec, apis);
}

fn printStdout(comptime format: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch unreachable;
}
