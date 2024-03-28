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
const builtin = @import("builtin");

const pkgs = packages("");

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
pub const recommended_zig_version = "0.12.0-dev.3439+31a7f22b8";

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
        .name = "zig-js-runtime-bench",
        .root_source_file = .{ .path = "src/main_bench.zig" },
        .single_threaded = true,
        .target = target,
        .optimize = mode,
    });

    try common(bench, mode, options);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        bench.root_module.strip = true;
    }
    b.installArtifact(bench);

    // run
    const bench_cmd = b.addRunArtifact(bench);
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
        .name = "zig-js-runtime-shell",
        .root_source_file = .{ .path = "src/main_shell.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(shell, mode, options);
    try pkgs.add_shell(shell);
    if (mode == .ReleaseSafe) {
        // remove debug info
        // TODO: check if mandatory in release-safe
        shell.root_module.strip = true;
    }
    // do not install shell binary
    // b.installArtifact(shell);

    // run
    const shell_cmd = b.addRunArtifact(shell);
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
    tests.root_module.single_threaded = true;
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
    opts: *std.Build.Step.Options,
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
    step: *std.Build.Step.Compile,
    mode: std.builtin.Mode,
    options: Options,
) !void {
    step.root_module.addOptions("jsruntime_build_options", options.opts);
    step.root_module.addImport("tigerbeetle-io", pkgs.tigerbeetle_io(step));
    if (options.engine == .v8) {
        try pkgs.v8(step, mode);
        step.root_module.addImport("v8", pkgs.zig_v8(step));
    }
}

pub fn packages(comptime vendor_path: []const u8) type {
    return struct {
        const Self = @This();

        const vendor = vendor_path ++ "vendor";

        fn tigerbeetle_io(step: *std.Build.Step.Compile) *std.Build.Module {
            return step.step.owner.createModule(.{
                .root_source_file = .{ .path = vendor ++ "/tigerbeetle-io/io.zig" },
            });
        }

        fn zig_v8(step: *std.Build.Step.Compile) *std.Build.Module {
            const mod = step.step.owner.createModule(.{
                .root_source_file = .{ .path = vendor ++ "/zig-v8/src/v8.zig" },
                .link_libc = false,
                .link_libcpp = false,
            });

            mod.addIncludePath(.{ .path = vendor ++ "/zig-v8/src" });

            return mod;
        }

        fn v8(step: *std.Build.Step.Compile, mode: std.builtin.Mode) !void {
            const mode_str: []const u8 = if (mode == .Debug) "debug" else "release";
            // step.linkLibC(); // TODO: do we need to link libc?

            // FIXME: we are tied to native v8 builds, currently:
            // - aarch64-macos
            // - x86_64-linux
            const os = step.root_module.resolved_target.?.result.os.tag;
            const arch = step.root_module.resolved_target.?.result.cpu.arch;
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

        pub fn add_shell(step: *std.Build.Step.Compile) !void {
            step.addIncludePath(.{ .path = vendor ++ "/linenoise-mob" });
            const lib = step.step.owner.addStaticLibrary(.{
                .name = "linenoise",
                .target = step.root_module.resolved_target.?,
                .optimize = step.root_module.optimize.?,
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
            step: *std.Build.Step.Compile,
            options: Options,
        ) !void {
            const jsruntime_mod = step.step.owner.createModule(.{
                .root_source_file = .{ .path = vendor_path ++ "/src/api.zig" },
                .imports = &[_]std.Build.Module.Import{
                    .{ .name = "jsruntime_build_options", .module = options.opts.createModule() },
                    .{ .name = "tigerbeetle-io", .module = Self.tigerbeetle_io(step) },
                    .{ .name = "v8", .module = Self.zig_v8(step) },
                },
            });
            try Self.v8(step, step.root_module.optimize.?);

            step.root_module.addImport("jsruntime", jsruntime_mod);
        }
    };
}
