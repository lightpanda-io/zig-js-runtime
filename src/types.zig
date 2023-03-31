pub const i64Num = struct {
    value: i64,

    pub fn init(value: i64) i64Num {
        return .{ .value = value };
    }

    pub fn get(self: i64Num) i64 {
        return self.value;
    }
};

pub const u64Num = struct {
    value: u64,

    pub fn init(value: u64) u64Num {
        return .{ .value = value };
    }

    pub fn get(self: u64Num) u64 {
        return self.value;
    }
};

// TODO: we could avoid allocate on heap the Iterable instance
// by removing the internal state (index) from the struct
// and instead store it directly in the JS object as an internal field
pub fn Iterable(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        index: usize = 0,

        pub fn init(items: []T) Self {
            return .{ .items = items };
        }

        pub const Return = struct {
            value: ?T,
            done: bool,
        };

        pub fn _next(self: *Self) Return {
            if (self.items.len > self.index) {
                const val = self.items[self.index];
                self.index += 1;
                return .{ .value = val, .done = false };
            } else {
                return .{ .value = null, .done = true };
            }
        }
    };
}
