const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // compile and install
    const exe = b.addExecutable("jsengine", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.single_threaded = true;
    try linkV8(exe, mode);
    addDeps(exe);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        exe.strip = true;
    }
    exe.install();

    // run
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // test
    const test_exe = b.addTest("src/main.zig");
    test_exe.setTarget(target);
    test_exe.setBuildMode(mode);
    test_exe.single_threaded = true;
    try linkV8(test_exe, mode);
    addDeps(test_exe);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_exe.step);
}

fn addDeps(step: *std.build.LibExeObjStep) void {
    // tigerbeetle IO loop
    // incompatible stage1 and stage2 versions
    if (step.builder.use_stage1 != null and step.builder.use_stage1.?) {
        step.addPackagePath("tigerbeetle-io", "deps/tigerbeetle-io/io_stage1.zig");
    } else {
        step.addPackagePath("tigerbeetle-io", "deps/tigerbeetle-io/io.zig");
    }
}

fn linkV8(step: *std.build.LibExeObjStep, mode: std.builtin.Mode) !void {
    const mode_str: []const u8 = if (mode == .Debug) "debug" else "release";
    // step.linkLibC(); // TODO: do we need to link libc?

    // v8 library
    // FIXME: we are tied to native v8 builds, currently:
    // - aarch64-macos
    // - x86_64-linux
    const os = step.target.getOsTag();
    const arch = step.target.getCpuArch();
    switch (os) {
        .linux => blk: {
            if (arch != .x86_64) {
                std.debug.print("only x86_64 are supported on linux builds\n", .{});
                return error.ArchNotSupported;
            }
            // TODO: why do we need it? It should be linked already when we built v8
            step.linkLibCpp();
            break :blk;
        },
        .macos => blk: {
            if (arch != .aarch64) {
                std.debug.print("only aarch64 are supported on macos builds\n", .{});
                return error.ArchNotSupported;
            }
            break :blk;
        },
        else => return error.OsNotSupported,
    }
    const lib_path = try std.fmt.allocPrint(
        step.builder.allocator,
        "../zig-v8/v8-build/{s}-{s}/{s}/ninja/obj/zig/libc_v8.a",
        .{ @tagName(arch), @tagName(os), mode_str },
    );
    step.addObjectFile(lib_path);

    // v8 bindings
    // stage2 is using int (0/1) from C bool
    // while stage1 uses bool
    if (step.builder.use_stage1 != null and step.builder.use_stage1.?) {
        step.addPackagePath("v8", "deps/zig-v8/v8_stage1.zig");
    } else {
        step.addPackagePath("v8", "deps/zig-v8/v8.zig");
    }
    step.addIncludePath("deps/zig-v8");
}
