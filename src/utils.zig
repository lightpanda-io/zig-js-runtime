const std = @import("std");

const v8 = @import("v8");

const Loop = @import("loop.zig").SingleThreaded;

// TODO: using global allocator, not sure it's the best way
// better allocator ?
pub var allocator: std.mem.Allocator = undefined;

pub var loop: *Loop = undefined;

pub const ExecuteResult = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    result: []const u8,
    stack: ?[]const u8 = null,
    success: bool,

    pub fn deinit(self: Self) void {
        self.alloc.free(self.result);
        if (self.stack) |stack| {
            self.alloc.free(stack);
        }
    }
};

pub fn executeString(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, src: []const u8, src_origin: v8.String, result: *ExecuteResult, try_catch: v8.TryCatch) void {
    var origin = v8.ScriptOrigin.initDefault(isolate, src_origin.toValue());

    const js_src = v8.String.initUtf8(isolate, src);

    const script = v8.Script.compile(context, js_src, origin) catch {
        setResultError(alloc, isolate, context, try_catch, result);
        return;
    };
    const script_res = script.run(context) catch {
        setResultError(alloc, isolate, context, try_catch, result);
        return;
    };
    result.* = .{
        .alloc = alloc,
        .result = valueToUtf8(alloc, script_res, isolate, context) catch unreachable,
        .success = true,
    };
}

fn setResultError(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, try_catch: v8.TryCatch, result: *ExecuteResult) void {
    const err_details = getTryCatchErrorString(alloc, isolate, context, try_catch);
    result.* = .{
        .alloc = alloc,
        .result = err_details.msg,
        .stack = err_details.stack,
        .success = false,
    };
}

pub fn logString(isolate: v8.Isolate, ctx: v8.Context, value: v8.Value) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();
    const s = valueToUtf8(alloc, value, isolate, ctx);
    std.log.debug("{s}", .{s});
    alloc.free(s);
}

pub fn valueToUtf8(alloc: std.mem.Allocator, value: v8.Value, isolate: v8.Isolate, ctx: v8.Context) ![]u8 {
    const str = try value.toString(ctx);
    const len = str.lenUtf8(isolate);
    const buf = try alloc.alloc(u8, len);
    _ = str.writeUtf8(isolate, buf);
    return buf;
}

const ErrorDetails = struct {
    msg: []u8,
    stack: ?[]u8 = null,
};

pub fn getTryCatchErrorString(alloc: std.mem.Allocator, isolate: v8.Isolate, ctx: v8.Context, try_catch: v8.TryCatch) ErrorDetails {
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    if (try_catch.getMessage()) |message| {

        // Message
        const msg = valueToUtf8(alloc, message.getMessage().toValue(), isolate, ctx) catch unreachable;

        // Stack trace
        var buf = std.ArrayList(u8).init(alloc);
        const writer = buf.writer();

        // append source line.
        const source_line = message.getSourceLine(ctx).?;
        _ = appendValueAsUtf8(&buf, isolate, ctx, source_line);
        writer.writeAll("\n") catch unreachable;

        // print wavy underline.
        const col_start = message.getStartColumn().?;
        const col_end = message.getEndColumn().?;

        var i: u32 = 0;
        while (i < col_start) : (i += 1) {
            writer.writeByte(' ') catch unreachable;
        }
        while (i < col_end) : (i += 1) {
            writer.writeByte('^') catch unreachable;
        }
        writer.writeByte('\n') catch unreachable;

        if (try_catch.getStackTrace(ctx)) |trace| {
            _ = appendValueAsUtf8(&buf, isolate, ctx, trace);
            writer.writeByte('\n') catch unreachable;
        }
        const stack = buf.toOwnedSlice();

        return .{ .msg = msg, .stack = stack };
    } else {
        // V8 didn't provide any extra information about this error, just get exception str.
        const exception = try_catch.getException().?;
        const msg = valueToUtf8(alloc, exception, isolate, ctx) catch unreachable;
        return .{ .msg = msg };
    }
}

pub fn appendValueAsUtf8(arr: *std.ArrayList(u8), isolate: v8.Isolate, ctx: v8.Context, any_value: anytype) []const u8 {
    const val = v8.getValue(any_value);
    const str = val.toString(ctx) catch unreachable;
    const len = str.lenUtf8(isolate);
    const start = arr.items.len;
    arr.resize(start + len) catch unreachable;
    _ = str.writeUtf8(isolate, arr.items[start..arr.items.len]);
    return arr.items[start..];
}
