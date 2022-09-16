const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // run
    const exe = b.addExecutable("jsengine", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    linkV8(exe);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        exe.strip = true;
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // test
    const test_exe = b.addTest("src/tests.zig");
    test_exe.setTarget(target);
    test_exe.setBuildMode(mode);
    linkV8(test_exe);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_exe.step);
}

fn linkV8(step: *std.build.LibExeObjStep) void {
    step.linkLibC();
    // link the static v8 library built with zig-v8
    // FIXME: we are tied to the native v8 build (aarch64-macos)
    step.addAssemblyFile("../zig-v8/v8-build/aarch64-macos/release/ninja/obj/zig/libc_v8.a");
    step.addPackagePath("v8", "deps/zig-v8/v8.zig");
    step.addIncludeDir("deps/zig-v8");
}
