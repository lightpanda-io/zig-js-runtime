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

pub const Callback = struct {};
