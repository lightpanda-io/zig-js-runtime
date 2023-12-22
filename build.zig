const std = @import("std");
const builtin = @import("builtin");

const pkgs = packages("");

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
pub const recommended_zig_version = "0.12.0-dev.1773+8a8fd47d2";

pub fn build(b: *std.Build) !void {
    switch (comptime builtin.zig_version.order(std.SemanticVersion.parse(recommended_zig_version) catch unreachable)) {
        .eq => {},
        .lt => {
            @compileError("The minimum version of Zig required to compile is '" ++ recommended_zig_version ++ "', found '" ++ builtin.zig_version_string ++ "'.");
        },
        .gt => {
            std.debug.print(
                "WARNING: Recommended Zig version '{s}', but found '{s}', build may fail...\n\n",
                .{ recommended_zig_version, builtin.zig_version_string },
            );
        },
    }

    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    // TODO: install only bench or shell with zig build <cmd>

    const options = try buildOptions(b);

    // bench
    // -----

    // compile and install
    const bench = b.addExecutable(.{
        .name = "jsruntime-bench",
        .root_source_file = .{ .path = "src/main_bench.zig" },
        .single_threaded = true,
        .target = target,
        .optimize = mode,
    });

    try common(bench, mode, options);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        bench.strip = true;
    }
    b.installArtifact(bench);

    // run
    const bench_cmd = b.addRunArtifact(bench);
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
    const shell = b.addExecutable(.{
        .name = "jsruntime-shell",
        .root_source_file = .{ .path = "src/main_shell.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(shell, mode, options);
    try pkgs.add_shell(shell);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        shell.strip = true;
    }
    // do not install shell binary
    // shell.install();

    // run
    const shell_cmd = b.addRunArtifact(shell);
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
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/run_tests.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(tests, mode, options);
    tests.single_threaded = true;
    tests.test_runner = "src/test_runner.zig";
    const run_tests = b.addRunArtifact(tests);

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

const Engine = enum {
    v8,
};

pub const Options = struct {
    engine: Engine,
    opts: *std.Build.OptionsStep,
};

pub fn buildOptions(b: *std.Build) !Options {
    const options = b.addOptions();
    const engine = b.option([]const u8, "engine", "JS engine (v8)");
    var eng: Engine = undefined;
    if (engine == null) {
        // default
        eng = .v8;
    } else {
        if (std.mem.eql(u8, engine.?, "v8")) {
            eng = .v8;
        } else {
            return error.EngineUnknown;
        }
    }
    options.addOption(?[]const u8, "engine", engine);
    return .{ .engine = eng, .opts = options };
}

fn common(
    step: *std.Build.CompileStep,
    mode: std.builtin.Mode,
    options: Options,
) !void {
    step.addOptions("jsruntime_build_options", options.opts);
    step.addModule("tigerbeetle-io", pkgs.tigerbeetle_io(step));
    if (options.engine == .v8) {
        try pkgs.v8(step, mode);
        step.addModule("v8", pkgs.zig_v8(step));
    }
}

pub fn packages(comptime vendor_path: []const u8) type {
    return struct {
        const Self = @This();

        const vendor = vendor_path ++ "vendor";

        fn tigerbeetle_io(step: *std.Build.CompileStep) *std.Build.Module {
            return step.step.owner.createModule(.{
                .source_file = .{ .path = vendor ++ "/tigerbeetle-io/io.zig" },
            });
        }

        fn zig_v8(step: *std.Build.CompileStep) *std.Build.Module {
            step.addIncludePath(.{ .path = vendor ++ "/zig-v8/src" });

            return step.step.owner.createModule(.{
                .source_file = .{ .path = vendor ++ "/zig-v8/src/v8.zig" },
            });
        }

        fn v8(step: *std.Build.CompileStep, mode: std.builtin.Mode) !void {
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
                step.step.owner.allocator,
                "{s}vendor/v8/{s}-{s}/{s}/libc_v8.a",
                .{ vendor_path, @tagName(arch), @tagName(os), mode_str },
            );
            step.addObjectFile(.{ .path = lib_path });
        }

        pub fn add_shell(step: *std.Build.CompileStep) !void {
            step.addIncludePath(.{ .path = vendor ++ "/linenoise-mob" });
            const lib = step.step.owner.addStaticLibrary(.{
                .name = "linenoise",
                .target = step.target,
                .optimize = step.optimize,
                .link_libc = true,
            });
            // TODO: use mode to add debug/release flags
            const cflags = &.{};
            lib.addCSourceFile(.{
                .file = .{ .path = vendor ++ "/linenoise-mob/linenoise.c" },
                .flags = cflags,
            });
            step.linkLibrary(lib);
        }

        pub fn add(
            step: *std.build.CompileStep,
            options: Options,
        ) !void {
            const jsruntime_mod = step.step.owner.createModule(.{
                .source_file = .{ .path = vendor_path ++ "/src/api.zig" },
                .dependencies = &[_]std.build.ModuleDependency{
                    .{ .name = "jsruntime_build_options", .module = options.opts.createModule() },
                    .{ .name = "tigerbeetle-io", .module = Self.tigerbeetle_io(step) },
                    .{ .name = "v8", .module = Self.zig_v8(step) },
                },
            });
            try Self.v8(step, step.optimize);

            step.addModule("jsruntime", jsruntime_mod);
        }
    };
}
