const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("linenoise.h");
});

const public = @import("api.zig");

const IO = @import("loop.zig").IO;

// Global variables
var socket_fd: std.os.socket_t = undefined;
var conf: Config = undefined;

// Config
pub const Config = struct {
    app_name: []const u8,

    // if not provided will be /tmp/{app_name}.sock
    socket_path: ?[]const u8 = null,
    p: []const u8 = undefined,

    history: bool = true,
    history_max: ?u8 = null,
    history_path: ?[]const u8 = null,

    const socket_path_default = "/tmp/{s}.sock"; // with app_name
    const history_max_default = 50; // if history is true
    const history_path_default = "{s}/.cache/{s}/history.txt"; // with $HOME, app_anme

    fn populate(self: *Config, socket_path_buf: []u8, history_path_buf: []u8) !void {
        if (self.socket_path == null) {
            self.socket_path = try std.fmt.bufPrint(
                socket_path_buf,
                socket_path_default,
                .{self.app_name},
            );
        }
        if (self.history) {
            if (self.history_max == null) {
                self.history_max = history_max_default;
            }
            if (self.history_path == null) {
                const home = std.os.getenv("HOME").?;
                // NOTE: we are using bufPrintZ as we need a null-terminated slice
                // to translate as c char
                self.history_path = try std.fmt.bufPrintZ(
                    history_path_buf,
                    history_path_default,
                    .{ home, self.app_name },
                );
                const f = try openOrCreateFile(self.history_path.?);
                f.close();
            }
        }
    }
};

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
    ctx.cmdContext.js_env.nat_ctx.loop.io.recv(
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
    alloc: std.mem.Allocator,
    js_env: *public.Env,
    socket: std.os.socket_t,
    buf: []u8,
    close: bool = false,

    try_catch: public.TryCatch,
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
    const res = ctx.js_env.exec(
        ctx.alloc,
        input,
        "shell.js",
        ctx.try_catch,
    ) catch |err| {
        ctx.close = true;
        std.debug.print("JS exec error: {s}\n", .{@errorName(err)});
        return;
    };
    defer res.deinit(ctx.alloc);

    // JS print result
    if (res.success) {
        if (std.mem.eql(u8, res.result, "undefined")) {
            printStdout("<- \x1b[38;5;242m{s}\x1b[0m\n", .{res.result});
        } else {
            printStdout("<- \x1b[33m{s}\x1b[0m\n", .{res.result});
        }
    } else {
        printStdout("{s}\n", .{res.result});
    }

    // acknowledge to repl result has been printed
    _ = std.os.write(ctx.socket, "ok") catch unreachable;

    // continue receving messages asynchronously
    ctx.js_env.nat_ctx.loop.io.recv(
        *CmdContext,
        ctx,
        cmdCallback,
        completion,
        ctx.socket,
        ctx.buf,
    );
}

fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    try shellExec(alloc, js_env);
}

pub fn shellExec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) !void {

    // alias global as self
    try js_env.attachObject(try js_env.getGlobal(), "self", null);

    // add console object
    const console = public.Console{};
    _ = try js_env.addObject(console, "console");

    // JS try cache
    var try_catch = public.TryCatch.init(js_env.*);
    defer try_catch.deinit();

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var input: [1024]u8 = undefined;
    var cmd_ctx = CmdContext{
        .alloc = alloc,
        .js_env = js_env,
        .socket = undefined,
        .buf = &input,
        .try_catch = try_catch,
    };
    var conn_ctx = ConnContext{
        .socket = socket_fd,
        .cmdContext = &cmd_ctx,
    };
    var completion: IO.Completion = undefined;

    // launch accepting connection asynchronously on internal server
    const loop = js_env.nat_ctx.loop;
    loop.io.accept(
        *ConnContext,
        &conn_ctx,
        connCallback,
        &completion,
        socket_fd,
    );

    // infinite loop on I/O events, either:
    // - user input command from repl
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            if (try try_catch.exception(alloc, js_env.*)) |msg| {
                printStdout("\n\rUncaught {s}\n\r", .{msg});
                alloc.free(msg);
            }
            loop.cbk_error = false;
        }
        if (cmd_ctx.close) {
            break;
        }
    }
}

pub fn shell(
    arena_alloc: *std.heap.ArenaAllocator,
    comptime ctxExecFn: ?public.ContextExecFn,
    comptime config: Config,
) !void {

    // set config
    var cf = config;
    var socket_path_buf: [100]u8 = undefined;
    var history_path_buf: [100]u8 = undefined;
    try cf.populate(&socket_path_buf, &history_path_buf);
    conf = cf;

    // remove socket file of internal server
    // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // see: https://gavv.net/articles/unix-socket-reuse/
    // TODO: use a lock file instead
    std.os.unlink(conf.socket_path.?) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // create internal server listening on a unix socket
    const addr = try std.net.Address.initUnix(conf.socket_path.?);
    var server = std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(addr);
    socket_fd = server.sockfd.?;

    // launch repl in a separate detached thread
    var repl_thread = try std.Thread.spawn(.{}, repl, .{});
    repl_thread.detach();

    // load JS environement
    comptime var do_fn: public.ContextExecFn = exec;
    if (ctxExecFn) |func| {
        do_fn = func;
    }
    try public.loadEnv(arena_alloc, do_fn);
}

fn repl() !void {

    // greetings
    printStdout(
        \\JS Repl
        \\exit with Ctrl+D or "exit"
        \\
    , .{});

    // create a socket client connected to the internal server
    const socket = try std.net.connectUnixSocket(conf.socket_path.?);

    var ack: [2]u8 = undefined;

    // history load
    if (conf.history) {
        if (c.linenoiseHistoryLoad(conf.history_path.?.ptr) != 0) {
            return error.LinenoiseHistoryLoad;
        }
        if (c.linenoiseHistorySetMaxLen(conf.history_max.?) != 1) {
            return error.LinenoiseHistorySetMaxLen;
        }
    }

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

            // add line in history
            if (conf.history) {
                if (c.linenoiseHistoryAdd(line) == 1) {
                    // save only if line has been added
                    // (ie. not on duplicated line)
                    if (c.linenoiseHistorySave(conf.history_path.?.ptr) != 0) {
                        return error.LinenoiseHistorySave;
                    }
                }
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

fn printStdout(comptime format: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch unreachable;
}

// Utils
// -----

fn openOrCreateFile(path: []const u8) !std.fs.File {
    var file: std.fs.File = undefined;
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        file = f;
    } else |err| switch (err) {
        error.FileNotFound => {

            // file does not exists, let's check the dir
            const dir_path = std.fs.path.dirname(path);
            if (dir_path != null) {
                var dir: std.fs.Dir = undefined;
                if (std.fs.openDirAbsolute(dir_path.?, .{})) |d| {
                    dir = d;
                    dir.close();
                } else |dir_err| switch (dir_err) {
                    // create dir if not exists
                    error.FileNotFound => {
                        try std.fs.makeDirAbsolute(dir_path.?);
                    },
                    else => return dir_err,
                }
            }

            // create the file
            file = try std.fs.createFileAbsolute(path, .{ .read = true });
        },
        else => return err,
    }
    return file;
}
