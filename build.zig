const std = @import("std");

const pkgs = packages("");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // TODO: install only bench or shell with zig build <cmd>

    const options = try buildOptions(b);

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

const Engine = enum {
    quickjs,
    v8,
};

pub const Options = struct {
    engine: Engine,
    opts: *std.build.OptionsStep,
};

pub fn buildOptions(b: *std.build.Builder) !Options {
    const options = b.addOptions();
    const engine = b.option([]const u8, "engine", "JS engine (quickjs, v8)");
    var eng: Engine = undefined;
    if (engine == null) {
        // default
        eng = .quickjs;
    } else {
        if (std.mem.eql(u8, engine.?, "quickjs")) {
            eng = .quickjs;
        } else if (std.mem.eql(u8, engine.?, "v8")) {
            eng = .v8;
        } else {
            return error.EngineUnknown;
        }
    }
    options.addOption(?[]const u8, "engine", engine);
    return .{ .engine = eng, .opts = options };
}

fn common(
    step: *std.build.LibExeObjStep,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
    options: Options,
) !void {
    step.setTarget(target);
    step.setBuildMode(mode);
    step.addOptions("jsruntime_build_options", options.opts);
    step.addPackage(try pkgs.tigerbeetle_io(step));
    if (options.engine == .quickjs) {
        try pkgs.quickjs(step, mode);
    } else if (options.engine == .v8) {
        try pkgs.v8(step, mode);
        step.addPackage(try pkgs.zig_v8(step));
    }
}

pub fn packages(comptime vendor_path: []const u8) type {
    return struct {
        const Self = @This();

        const vendor = vendor_path ++ "vendor/";

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

        const QuickJS_VERSION = "2021-03-27";

        // build QuickJS from source and link it
        fn quickjs(step: *std.build.LibExeObjStep, mode: std.builtin.Mode) !void {

            // define library
            const lib = step.builder.addStaticLibrary("quickjs", null);
            // lib.linkLibC(); // TODO: do we need to link libc?

            // common defines
            lib.defineCMacro("_GNU_SOURCE", null);
            lib.defineCMacro("CONFIG_BIGNUM", null);
            lib.defineCMacro("CONFIG_VERSION", "\"" ++ Self.QuickJS_VERSION ++ "\"");

            // common compiler flags
            var cflags_common = [_][]const u8{};
            // NOTE: QuickJS Makefile uses thoses flags for Clang, not sure if it matters
            //     "-Wall",
            //     "-Wextra",
            //     "-Wno-sign-compare",
            //     "-Wno-missing-field-initializers",
            //     "-Wunused",
            //     "-Wno-unused-parameter",
            //     "-Wwrite-strings",
            //     "-Wno-unused-variable",
            //     "-Wchar-subscripts",
            //     "-funsigned-char",

            // use mode to add debug/release defines and flags
            var cflags: [][]const u8 = undefined;
            if (mode == .Debug) {
                lib.defineCMacro("DUMP_LEAKS", null);
                cflags = &cflags_common;
            } else {
                var cflags_release: [cflags_common.len + 1][]const u8 = undefined;
                for (cflags_common) |flag, i| {
                    cflags_release[i] = flag;
                }
                cflags_release[cflags_common.len] = "-O2";
                cflags = &cflags_release;
            }

            // source files
            const cfiles = [_][]const u8{
                Self.vendor ++ "quickjs/cutils.c",
                Self.vendor ++ "quickjs/libbf.c", // CONFIG_BIGNUM
                Self.vendor ++ "quickjs/libregexp.c",
                Self.vendor ++ "quickjs/libunicode.c",
                Self.vendor ++ "quickjs/quickjs.c",
            };
            lib.addCSourceFiles(&cfiles, cflags);

            step.linkLibrary(lib);
            step.addIncludePath(Self.vendor ++ "quickjs");
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
            options: Options,
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
                    options.opts.getPackage("jsruntime_build_options"),
                },
            };
            step.addPackage(lib);
        }
    };
}
