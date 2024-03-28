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

fn checkArgs(args: anytype) void {
    comptime {
        const info = @typeInfo(@TypeOf(args));
        if (info != .Struct or !info.Struct.is_tuple) {
            @compileError("should be a tuple");
        }
    }
}

pub const Measure = struct {
    unit: []const u8,
    value: u64,
};

pub const TableConf = struct {
    max_row_length: usize = 50,
    margin_left: ?[]const u8 = " ",
    row_delimiter: []const u8 = "|",
    line_delimiter: []const u8 = "-",
    line_edge_delimiter: []const u8 = "+",
};

pub fn GenerateTable(
    comptime rows_nb: usize,
    comptime row_shape: anytype,
    comptime table_conf: ?TableConf,
) !type {
    checkArgs(row_shape);

    const columns_nb = row_shape.len;
    if (columns_nb > 9) {
        @compileError("columns should have less then 10 rows");
    }

    var fields: [columns_nb]std.builtin.Type.StructField = undefined;
    inline for (row_shape, 0..) |T, i| {
        if (@TypeOf(T) != type) {
            @compileError("columns elements should be of type 'type'");
        }
        var buf: [1]u8 = undefined;
        const name = try std.fmt.bufPrint(buf[0..], "{d}", .{i});
        fields[i] = std.builtin.Type.StructField{
            // StructField.name expect a null terminated string.
            // concatenate the `[]const u8` string with an empty string
            // literal (`name ++ ""`) to explicitly coerce it to `[:0]const
            // u8`.
            .name = name ++ "",
            .type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    const decls: [0]std.builtin.Type.Declaration = undefined;
    const shape_info = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &fields,
        .decls = &decls,
        .is_tuple = true,
    };
    const shape = @Type(std.builtin.Type{ .Struct = shape_info });

    var table_c: TableConf = undefined;
    if (table_conf != null) {
        table_c = table_conf.?;
    } else {
        table_c = TableConf{};
    }
    const conf = table_c;

    return struct {
        title: ?[]const u8,
        head: [columns_nb][]const u8 = undefined,
        rows: [rows_nb]shape = undefined,

        last_row: usize = 0,

        const Self = @This();

        pub fn init(title: ?[]const u8, header: anytype) Self {
            checkArgs(header);
            if (header.len != columns_nb) {
                @compileError("header elements should be equal to table columns_nb");
            }
            const self = Self{ .title = title, .head = header };
            return self;
        }

        pub fn addRow(self: *Self, row: shape) !void {
            checkArgs(row);
            if (row.len != columns_nb) {
                @compileError("row elements should be equal to table columns_nb");
            }
            if (self.last_row >= rows_nb) {
                return error.TableWrongRowNb;
            }
            self.rows[self.last_row] = row;
            self.last_row += 1;
        }

        // render the table on a writer
        pub fn render(self: Self, writer: anytype) !void {
            if (self.last_row < rows_nb) {
                return error.TableNotComplete;
            }

            // calc max size for each column
            // looking for size value in header and each row
            var max_sizes: [columns_nb]usize = undefined;
            for (self.head, 0..) |header, i| {
                max_sizes[i] = try utf8Size(header);
            }
            for (self.rows, 0..) |_, row_i| {
                comptime var col_i: usize = 0;
                inline while (col_i < columns_nb) {
                    const arg = self.rows[row_i][col_i];
                    var buf: [conf.max_row_length]u8 = undefined;
                    // stage1: we should catch err (or use try)
                    // but compiler give us:
                    // 'control flow attempts to use compile-time variable at runtime'
                    const str = argStr(buf[0..], arg) catch unreachable;
                    const size = utf8Size(str) catch unreachable;
                    if (size > max_sizes[col_i]) {
                        max_sizes[col_i] = size;
                    }
                    col_i += 1;
                }
            }

            // total size for a row
            var total: usize = 0;
            // we had 3 chars for each column: <spc>value<spc><delimiter>
            const extra_per_row = 3;
            for (max_sizes) |size| {
                total += size + extra_per_row;
            }
            total += 1; // we had 1 char for the begining of the line: <delimiter>

            // buffered writer
            var buf = std.io.bufferedWriter(writer);
            const w = buf.writer();

            // title
            try w.print("\n", .{});
            if (self.title != null) {
                try drawLine(w, conf, total);
                if (conf.margin_left != null) {
                    try w.print(conf.margin_left.?, .{});
                }
                const title_len = try utf8Size(self.title.?);
                try w.print("{s} {s}", .{ conf.row_delimiter, self.title.? });
                const title_extra = 3; // value<spc><delimiter>
                const diff = total - title_extra - title_len;
                if (diff > 0) {
                    try drawRepeat(w, " ", diff);
                }
                try w.print("{s}\n", .{conf.row_delimiter});
            }

            // head
            try drawLine(w, conf, total);
            try drawRow(w, max_sizes, self.head, total);

            // rows
            for (self.rows) |row| {
                try drawRow(w, max_sizes, row, total);
            }

            try w.print("\n", .{});

            try buf.flush();
        }

        fn drawRow(
            w: anytype,
            max_sizes: [columns_nb]usize,
            row: anytype,
            total: usize,
        ) !void {

            // start of the row
            if (conf.margin_left != null) {
                try w.print(conf.margin_left.?, .{});
            }

            comptime var i: usize = 0;
            inline while (i < row.len) {

                // left delimiter
                if (i == 0) {
                    try w.print(conf.row_delimiter, .{});
                }

                // string value
                const value = row[i];
                var buf_str: [conf.max_row_length]u8 = undefined;
                // stage1: we should catch err (or use try)
                // but compiler give us an infinite loop
                const str = argStr(buf_str[0..], value) catch unreachable;

                // align string and print
                const str_len = try utf8Size(str);
                const diff = max_sizes[i] - str_len;
                switch (@TypeOf(value)) {
                    // align left strings
                    []u8, []const u8 => blk: {
                        try w.print(" {s}", .{str});
                        if (diff > 0) {
                            try drawRepeat(w, " ", diff);
                        }
                        break :blk;
                    },
                    // otherwhise align right
                    else => blk: {
                        if (diff > 0) {
                            try drawRepeat(w, " ", diff);
                        }
                        try w.print("{s} ", .{str});
                        break :blk;
                    },
                }

                // right delimiter
                try w.print(" {s}", .{conf.row_delimiter});

                i += 1;
            }

            // end of the row
            try w.print("\n", .{});
            try drawLine(w, conf, total);
        }
    };
}

// Utils
// -----

fn argStr(buf: []u8, arg: anytype) ![]const u8 {
    const T = @TypeOf(arg);
    return switch (T) {

        // slice of bytes, eg. string
        []u8, [:0]u8, []const u8, [:0]const u8 => arg,

        // int unsigned
        u8, u16, u32, u64, usize => try std.fmt.bufPrint(buf[0..], "{d}", .{arg}),

        // int signed
        i8, i16, i32, i64, isize, comptime_int => try std.fmt.bufPrint(buf[0..], "{d}", .{arg}),

        // float
        f16, f32, f64, comptime_float => try std.fmt.bufPrint(buf[0..], "{d:.2}", .{arg}),

        // bool
        bool => if (arg) "true" else "false",

        // measure
        Measure => try std.fmt.bufPrint(buf[0..], "{d}{s}", .{ arg.value, arg.unit }),

        else => try std.fmt.bufPrint(buf[0..], "{any}", .{arg}),
    };
}

test "arg str" {
    const max = 50;

    // string
    const str: []const u8 = "ok";
    var buf1: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf1, str), "ok");

    // comptime int
    var buf2: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf2, 8), "8");
    var buf3: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf3, -8), "-8");

    // int unsigned
    const int_unsigned: u8 = 8;
    var buf4: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf4, int_unsigned), "8");

    // int signed
    const int_signed: i32 = -8;
    var buf5: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf5, int_signed), "-8");

    // float
    const f: f16 = 3.22;
    var buf6: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf6, f), "3.22");

    // bool
    const b = true;
    var buf7: [max]u8 = undefined;
    try std.testing.expectEqualStrings(try argStr(&buf7, b), "true");

    // measure
    const m = Measure{ .value = 972, .unit = "us" };
    var buf_m: [max]u8 = undefined;
    try std.testing.expectEqualStrings("972us", try argStr(&buf_m, m));

    // error, value too long
    var buf_e: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, argStr(&buf_e, int_signed));
}

fn utf8Size(s: []const u8) !usize {
    const points = try std.unicode.utf8CountCodepoints(s);
    if (points == s.len) {
        return s.len;
    }
    const view = try std.unicode.Utf8View.init(s);
    var iter = view.iterator();
    var size: usize = 0;
    while (iter.nextCodepointSlice()) |next| {
        if (next.len == 1) {
            // ascii
            size += 1;
        } else {
            // non-ascii
            // TODO: list cases, this does not seems very solid
            if (next.len < 3) {
                size += 1;
            } else {
                size += 2;
            }
        }
    }
    return size;
}

test "utf8 size" {
    // stage 1: we can't but try inside equality

    const res1 = try utf8Size("test é");
    try std.testing.expect(res1 == 6); // latin

    const res2 = try utf8Size("test 鿍");
    try std.testing.expect(res2 == 7); // chinese

    const res3 = try utf8Size("test ✅");
    try std.testing.expect(res3 == 7); // small emoji

    const res4 = try utf8Size("test 🚀");
    try std.testing.expect(res4 == 7); // big emoji

    const res5 = try utf8Size("🚀 test ✅");
    try std.testing.expect(res5 == 10); // mulitple utf-8 points
}

fn drawLine(w: anytype, comptime conf: TableConf, total: usize) !void {
    if (conf.margin_left != null) {
        try w.print(conf.margin_left.?, .{});
    }
    try w.print(conf.line_edge_delimiter, .{});
    try drawRepeat(w, conf.line_delimiter, total - 2);
    try w.print(conf.line_edge_delimiter, .{});
    try w.print("\n", .{});
}

fn drawRepeat(w: anytype, comptime fmt: []const u8, nb: usize) !void {
    var i: usize = 0;
    while (i < nb) {
        try w.print(fmt, .{});
        i += 1;
    }
}
