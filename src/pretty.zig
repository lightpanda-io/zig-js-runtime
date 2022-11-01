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
    inline for (row_shape) |T, i| {
        if (@TypeOf(T) != type) {
            @compileError("columns elements should be of type 'type'");
        }
        var buf: [1]u8 = undefined;
        const name = try std.fmt.bufPrint(buf[0..], "{d}", .{i});
        fields[i] = std.builtin.Type.StructField{
            .name = name,
            .field_type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    const decls: [0]std.builtin.Type.Declaration = undefined;
    const shape_info = std.builtin.Type.Struct{
        .layout = std.builtin.Type.ContainerLayout.Auto,
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
            var self = Self{ .title = title, .head = header };
            return self;
        }

        pub fn addRow(self: *Self, row: anytype) !void {
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
            // TODO: non-ascii is not supported
            // ie. 1 byte == 1 char (which is the case only for ascii)
            var max_sizes: [columns_nb]usize = undefined;
            var column_pos: usize = 0;
            while (column_pos < columns_nb) {
                const head_col = self.head[column_pos];
                max_sizes[column_pos] = try utf8Size(head_col);
                // max_sizes[column_pos] = head_col.len;
                for (self.rows) |row| {
                    inline for (row) |arg, pos| {
                        if (pos == column_pos) {
                            const str = try argStr(arg, conf.max_row_length);
                            const size = str.len;
                            if (size > max_sizes[column_pos]) {
                                max_sizes[column_pos] = size;
                            }
                            break;
                        }
                    }
                }
                column_pos += 1;
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
                if (conf.margin_left != null) {
                    try w.print(conf.margin_left.?, .{});
                }
                try w.print(conf.line_edge_delimiter, .{});
                try drawRepeat(w, conf.line_delimiter, total - 2);
                try w.print(conf.line_edge_delimiter, .{});
                try w.print("\n", .{});
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
            if (conf.margin_left != null) {
                try w.print(conf.margin_left.?, .{});
            }
            try w.print(conf.line_edge_delimiter, .{});
            try drawRepeat(w, conf.line_delimiter, total - 2);
            try w.print(conf.line_edge_delimiter, .{});
            try w.print("\n", .{});
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
            var column_pos: usize = 0;
            if (conf.margin_left != null) {
                try w.print(conf.margin_left.?, .{});
            }
            while (column_pos < columns_nb) {
                if (column_pos == 0) {
                    try w.print(conf.row_delimiter, .{});
                }
                inline for (row) |value, i| {
                    if (column_pos == i) {
                        const str = try argStr(value, conf.max_row_length);

                        // as we are on a inline for loop
                        // we need to copy the str to a new buffer
                        if (str.len > conf.max_row_length) {
                            return error.TableValueMaxRowLength;
                        }
                        var buf: [conf.max_row_length]u8 = undefined;
                        std.mem.copy(u8, &buf, str);

                        // alignment
                        const str_len = try utf8Size(str);
                        const diff = max_sizes[column_pos] - str_len;
                        switch (@TypeOf(value)) {
                            // align left strings
                            []u8, []const u8 => blk: {
                                try w.print(" {s}", .{buf});
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
                                try w.print("{s} ", .{buf});
                                break :blk;
                            },
                        }
                        break;
                    }
                }
                try w.print(" {s}", .{conf.row_delimiter});
                column_pos += 1;
            }
            try w.print("\n", .{});
            if (conf.margin_left != null) {
                try w.print(conf.margin_left.?, .{});
            }
            try w.print(conf.line_edge_delimiter, .{});
            try drawRepeat(w, conf.line_delimiter, total - 2);
            try w.print(conf.line_edge_delimiter, .{});
            try w.print("\n", .{});
        }
    };
}

// Utils
// -----

fn bufArgStr(
    comptime fmt: []const u8,
    arg: anytype,
    comptime length: usize,
) ![]const u8 {
    var buf: [length]u8 = undefined;
    return try std.fmt.bufPrint(buf[0..], fmt, arg);
}

fn argStr(arg: anytype, comptime length: usize) ![]const u8 {
    const T = @TypeOf(arg);
    return switch (T) {

        // slice of bytes, eg. string
        []u8, [:0]u8, []const u8, [:0]const u8 => arg,

        // int unsigned
        u8, u16, u32, u64, usize => try bufArgStr("{d}", .{arg}, length),

        // int signed
        i8, i16, i32, i64, isize, comptime_int => try bufArgStr("{d}", .{arg}, length),

        // float
        f16, f32, f64, comptime_float => try bufArgStr("{d:.2}", .{arg}, length),

        // bool
        bool => if (arg) "true" else "false",

        // measure
        Measure => try bufArgStr("{d}{s}", .{ arg.value, arg.unit }, length),

        else => try bufArgStr("{any}", .{arg}, length),
    };
}

test "arg str" {
    const max = 50;

    const str: []const u8 = "ok";
    try std.testing.expectEqualStrings(try argStr(str, max), "ok");

    // comptime int
    try std.testing.expectEqualStrings(try argStr(8, max), "8");
    try std.testing.expectEqualStrings(try argStr(-8, max), "-8");

    // int unsigned
    const int_unsigned: u8 = 8;
    try std.testing.expectEqualStrings(try argStr(int_unsigned, max), "8");

    // int signed
    const int_signed: i32 = -8;
    try std.testing.expectEqualStrings(try argStr(int_signed, max), "-8");

    // float
    const f: f16 = 3.22;
    try std.testing.expectEqualStrings(try argStr(f, max), "3.22");

    // bool
    const b = true;
    try std.testing.expectEqualStrings(try argStr(b, max), "true");

    // error, value too long
    try std.testing.expectError(error.NoSpaceLeft, argStr(int_signed, 1));
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
    try std.testing.expect(try utf8Size("test é") == 6); // latin
    try std.testing.expect(try utf8Size("test 鿍") == 7); // chinese
    try std.testing.expect(try utf8Size("test ✅") == 7); // small emoji
    try std.testing.expect(try utf8Size("test 🚀") == 7); // big emoji
    try std.testing.expect(try utf8Size("🚀 test ✅") == 10); // mulitple utf-8 points
}

fn drawRepeat(w: anytype, comptime fmt: []const u8, nb: usize) !void {
    var i: usize = 0;
    while (i < nb) {
        try w.print(fmt, .{});
        i += 1;
    }
}
