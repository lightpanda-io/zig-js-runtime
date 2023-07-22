const std = @import("std");

const pkgs = packages("");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // TODO: install only bench or shell with zig build <cmd>

    const options = buildOptions(b);

    // bench
    // -----

    // compile and install
    const bench = b.addExecutable("jsruntime-bench", "src/main_bench.zig");
    try common(bench, mode, target, options);
    bench.single_threaded = true;
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        bench.strip = true;
    }
    bench.install();

    // run
    const bench_cmd = bench.run();
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // step
    const bench_step = b.step("bench", "Run basic benchmark");
    bench_step.dependOn(&bench_cmd.step);

    // shell
    // -----

    // compile and install
    const shell = b.addExecutable("jsruntime-shell", "src/main_shell.zig");
    try common(shell, mode, target, options);
    try pkgs.add_shell(shell, mode);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        shell.strip = true;
    }
    // do not install shell binary
    // shell.install();

    // run
    const shell_cmd = shell.run();
    shell_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        shell_cmd.addArgs(args);
    }

    // step
    const shell_step = b.step("shell", "Run JS shell");
    shell_step.dependOn(&shell_cmd.step);

    // test
    // ----

    // compile
    const test_exe = b.addTest("src/run_tests.zig");
    try common(test_exe, mode, target, options);
    test_exe.single_threaded = true;

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_exe.step);
}

pub fn buildOptions(b: *std.build.Builder) *std.build.OptionsStep {
    const options = b.addOptions();
    const engine = b.option([]const u8, "engine", "JS engine (v8)");
    options.addOption(?[]const u8, "engine", engine);
    return options;
}

fn common(
    step: *std.build.LibExeObjStep,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
    options: *std.build.OptionsStep,
) !void {
    step.setTarget(target);
    step.setBuildMode(mode);
    step.addOptions("jsruntime_build_options", options);
    step.addPackage(try pkgs.tigerbeetle_io(step));
    step.addPackage(try pkgs.zig_v8(step));
    try pkgs.v8(step, mode);
}

pub fn packages(comptime vendor_path: []const u8) type {
    return struct {
        const Self = @This();

        fn tigerbeetle_io(step: *std.build.LibExeObjStep) !std.build.Pkg {
            const lib_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}vendor/tigerbeetle-io/io.zig",
                .{vendor_path},
            );
            return std.build.Pkg{
                .name = "tigerbeetle-io",
                .source = .{ .path = lib_path },
            };
        }

        fn zig_v8(step: *std.build.LibExeObjStep) !std.build.Pkg {
            const include_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}vendor/zig-v8/src",
                .{vendor_path},
            );
            step.addIncludePath(include_path);

            const lib_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}vendor/zig-v8/src/v8.zig",
                .{vendor_path},
            );
            return std.build.Pkg{
                .name = "v8",
                .source = .{ .path = lib_path },
            };
        }

        fn v8(step: *std.build.LibExeObjStep, mode: std.builtin.Mode) !void {
            const mode_str: []const u8 = if (mode == .Debug) "debug" else "release";
            // step.linkLibC(); // TODO: do we need to link libc?

            // FIXME: we are tied to native v8 builds, currently:
            // - aarch64-macos
            // - x86_64-linux
            const os = step.target.getOsTag();
            const arch = step.target.getCpuArch();
            switch (os) {
                .linux => blk: {
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
                "{s}vendor/v8/{s}-{s}/{s}/libc_v8.a",
                .{ vendor_path, @tagName(arch), @tagName(os), mode_str },
            );
            step.addObjectFile(lib_path);
        }

        pub fn add_shell(step: *std.build.LibExeObjStep, _: std.builtin.Mode) !void {
            const include_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}vendor/linenoise-mob",
                .{vendor_path},
            );
            step.addIncludePath(include_path);

            const lib_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}vendor/linenoise-mob/linenoise.c",
                .{vendor_path},
            );
            const lib = step.builder.addStaticLibrary("linenoise", null);
            // TODO: use mode to add debug/release flags
            lib.linkLibC();
            const cflags = [_][]const u8{};
            lib.addCSourceFile(lib_path, &cflags);
            step.linkLibrary(lib);
        }

        pub fn add(
            step: *std.build.LibExeObjStep,
            mode: std.builtin.Mode,
            options: *std.build.OptionsStep,
        ) !void {
            const tigerbeetle_io_pkg = try Self.tigerbeetle_io(step);
            const zig_v8_pkg = try Self.zig_v8(step);
            try Self.v8(step, mode);

            const lib_path = try std.fmt.allocPrint(
                step.builder.allocator,
                "{s}src/api.zig",
                .{vendor_path},
            );
            const lib = std.build.Pkg{
                .name = "jsruntime",
                .source = .{ .path = lib_path },
                .dependencies = &[_]std.build.Pkg{
                    tigerbeetle_io_pkg,
                    zig_v8_pkg,
                    options.getPackage("jsruntime_build_options"),
                },
            };
            step.addPackage(lib);
        }
    };
}
