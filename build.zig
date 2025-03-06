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
const EngineType = @import("src/api.zig").EngineType;

const pkgs = packages("");

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
pub const recommended_zig_version = "0.14.0";

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

    const options = buildOptions(b);

    // bench
    // -----

    // compile and install
    const bench = b.addExecutable(.{
        .name = "zig-js-runtime-bench",
        .root_source_file = b.path("src/main_bench.zig"),

        // Threads are now required to compile using libc++.
        // This change happens when upgrading to zig 0.13.0
        //
        // With Single thread, I have the following error:
        // > error: sub-compilation of libcxx failed
        // > /usr/local/zig-0.13.0/lib/libcxx/include/future:368:4: note:
        // >"<future> is not supported since libc++ has been configured without
        // > support for threads."
        //
        // see https://github.com/llvm/llvm-project/issues/76588
        .single_threaded = false,

        .target = target,
        .optimize = mode,
    });

    try common(b, bench.root_module, options);
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
        .root_source_file = b.path("src/main_shell.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, shell.root_module, options);
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
        .root_source_file = b.path("src/run_tests.zig"),
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        .target = target,
        .optimize = mode,
    });
    try common(b, tests.root_module, options);
    const run_tests = b.addRunArtifact(tests);

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

pub const Options = struct {
    engine: EngineType,
    opts: *std.Build.Step.Options,
};

pub fn buildOptions(b: *std.Build) Options {
    const engine = b.option(EngineType, "engine", "JS engine (v8)") orelse .v8;
    const options = b.addOptions();
    options.addOption(EngineType, "engine", engine);
    return .{ .engine = engine, .opts = options };
}

fn common(
    b: *std.Build,
    m: *std.Build.Module,
    options: Options,
) !void {
    m.addOptions("jsruntime_build_options", options.opts);
    m.addImport("tigerbeetle-io", pkgs.tigerbeetle_io(b));
    switch (options.engine) {
        .v8 => {
            try pkgs.v8(m);
            m.addImport("v8", pkgs.zig_v8(b));
        },
    }
}

pub fn packages(comptime vendor_path: []const u8) type {
    return struct {
        const Self = @This();

        const vendor = vendor_path ++ "vendor";

        fn tigerbeetle_io(b: *std.Build) *std.Build.Module {
            return b.createModule(.{
                .root_source_file = b.path(vendor ++ "/tigerbeetle-io/io.zig"),
            });
        }

        fn zig_v8(b: *std.Build) *std.Build.Module {
            const mod = b.createModule(.{
                .root_source_file = b.path(vendor ++ "/zig-v8/src/v8.zig"),
                .link_libc = false,
                .link_libcpp = false,
            });

            mod.addIncludePath(b.path(vendor ++ "/zig-v8/src"));

            return mod;
        }

        fn v8(mod: *std.Build.Module) !void {
            const mode_str: []const u8 = if (mod.optimize.? == .Debug) "debug" else "release";
            // FIXME: we are tied to native v8 builds, currently:
            // - aarch64-macos
            // - x86_64-linux
            const os = mod.resolved_target.?.result.os.tag;
            const arch = mod.resolved_target.?.result.cpu.arch;
            switch (os) {
                .linux => blk: {
                    // TODO: why do we need it? It should be linked already when we built v8
                    mod.link_libcpp = true;
                    break :blk;
                },
                .macos => blk: {
                    break :blk;
                },
                else => return error.OsNotSupported,
            }

            const lib_path = try std.fmt.allocPrint(
                mod.owner.allocator,
                "{s}vendor/v8/{s}-{s}/{s}/libc_v8.a",
                .{ vendor_path, @tagName(arch), @tagName(os), mode_str },
            );
            mod.addObjectFile(mod.owner.path(lib_path));
        }

        pub fn add_shell(step: *std.Build.Step.Compile) !void {
            const lib = step.step.owner.addStaticLibrary(.{
                .name = "linenoise",
                .target = step.root_module.resolved_target.?,
                .optimize = step.root_module.optimize.?,
                .link_libc = true,
            });
            // TODO: use mode to add debug/release flags
            const cflags = &.{};
            lib.addCSourceFile(.{
                .file = step.root_module.owner.path(vendor ++ "/linenoise-mob/linenoise.c"),
                .flags = cflags,
            });
            step.linkLibrary(lib);
        }

        pub fn module(
            b: *std.Build,
            options: Options,
            mode: std.builtin.Mode,
            target: std.Build.ResolvedTarget,
        ) !*std.Build.Module {
            const mod = b.createModule(.{
                .root_source_file = b.path(vendor_path ++ "/src/api.zig"),
                .optimize = mode,
                .target = target,
                .imports = &[_]std.Build.Module.Import{
                    .{ .name = "jsruntime_build_options", .module = options.opts.createModule() },
                    .{ .name = "tigerbeetle-io", .module = Self.tigerbeetle_io(b) },
                    .{ .name = "v8", .module = Self.zig_v8(b) },
                },
            });
            try Self.v8(mod);

            return mod;
        }
    };
}
