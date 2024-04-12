const std = @import("std");

// UserContext is a type defined by the user optionally passed to the native
// API.
// The type is defined via a root declaration.
// Request a UserContext parameter in your native implementation to get the
// context.
pub const UserContext = blk: {
    const root = @import("root");
    if (@hasDecl(root, "UserContext")) {
        break :blk root.UserContext;
    }

    // when no declaration is given, UserContext is define with an empty struct.
    break :blk struct {};
};
