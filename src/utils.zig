const std = @import("std");
const v8 = @import("v8");

// TODO: using global allocator, not sure it's the best way
// better allocator ?
pub var allocator: std.mem.Allocator = undefined;

pub const ExecuteResult = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    result: ?[]const u8,
    err: ?[]const u8,
    success: bool,

    pub fn deinit(self: Self) void {
        if (self.result) |result| {
            self.alloc.free(result);
        }
        if (self.err) |err| {
            self.alloc.free(err);
        }
    }
};

pub fn executeString(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, src: []const u8, src_origin: v8.String, result: *ExecuteResult) void {
    var try_catch: v8.TryCatch = undefined;
    try_catch.init(isolate);
    defer try_catch.deinit();

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
        .result = valueToUtf8(alloc, script_res, isolate, context),
        .err = null,
        .success = true,
    };
}

fn setResultError(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, try_catch: v8.TryCatch, result: *ExecuteResult) void {
    result.* = .{
        .alloc = alloc,
        .result = null,
        .err = getTryCatchErrorString(alloc, isolate, context, try_catch),
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

pub fn valueToUtf8(alloc: std.mem.Allocator, value: v8.Value, isolate: v8.Isolate, ctx: v8.Context) []u8 {
    const str = value.toString(ctx) catch unreachable;
    const len = str.lenUtf8(isolate);
    const buf = alloc.alloc(u8, len) catch unreachable;
    _ = str.writeUtf8(isolate, buf);
    return buf;
}

pub fn getTryCatchErrorString(alloc: std.mem.Allocator, isolate: v8.Isolate, ctx: v8.Context, try_catch: v8.TryCatch) []const u8 {
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    if (try_catch.getMessage()) |message| {
        var buf = std.ArrayList(u8).init(alloc);
        const writer = buf.writer();

        // Append source line.
        const source_line = message.getSourceLine(ctx).?;
        _ = appendValueAsUtf8(&buf, isolate, ctx, source_line);
        writer.writeAll("\n") catch unreachable;

        // Print wavy underline.
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

        return buf.toOwnedSlice();
    } else {
        // V8 didn't provide any extra information about this error, just get exception str.
        const exception = try_catch.getException().?;
        return valueToUtf8(alloc, exception, isolate, ctx);
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
