// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const optimize = std.builtin.OptimizeMode.ReleaseSafe;
    const target_cpu = b.option(SupportedCpuArch, "cpu-arch", "The system architecture to compile the injector for; valid options are 'amd64' and 'arm64' (default)") orelse .arm64;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = target_cpu.arch(),
        // Skip cpu model detection because the automatic detection for transpiling fails in build
        .cpu_model = .{ .explicit = target_cpu.model() },
        .os_tag = .linux,
    });

    // Creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .pic = true,
        .strip = false,
    });

    // Create a dynamically linked library based on the module created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "injector",
        .root_module = lib_mod,
    });
    lib.setVersionScript(b.path("src/injector.exports.map"));

    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "." } } }).step);

    var copy_injector_to_bin = b.step("copy_file", "Copy injector file");
    copy_injector_to_bin.makeFn = copyInjectorFile;

    // make the copy step depend in the install step, which then makes it transitively depend on the compile step
    copy_injector_to_bin.dependOn(b.getInstallStep());

    // Make copying the injector shared library binary to its final location the default step. This wil also implictly
    // trigger building the library as a dependent build step.
    b.default_step = copy_injector_to_bin;

    // TESTING
    const test_filters = b.option([][]const u8, "test-filter", "Match tests to execute");
    const testTarget = b.standardTargetOptions(.{});
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = testTarget,
        .optimize = optimize,
        // For some reason, setting link_libc = false does not seem to be effective on Darwin, and the tests run with
        // builtin.link_libc=true anyway. This in turn makes makes std.posix.getenv use std.c.environ under the hood
        // instead of std.os.environ.
        // Also, on Linux (that is, on CI or with the development Docker container (devel.Dockerfile)) the tests crash
        // with
        //   /opt/hostedtoolcache/zig/0.14.0/x64/lib/std/c.zig:1:1: error: dependency on libc must be explicitly
        //   specified in the build command
        // when accessing std.c.environ and link_libc is set to false here. This needs more investigation. For now, we
        // simply always set .link_libc = true for the tests, even if the production code is built with
        // .link_libc = false.
        .link_libc = true,
        .pic = true,
        .strip = false,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = test_filters orelse &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn copyInjectorFile(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    const source_path = step.owner.pathFromRoot("./zig-out/libinjector.so");
    const dest_path = step.owner.pathFromRoot("so/libotelinject.so");
    try std.fs.copyFileAbsolute(source_path, dest_path, .{});
}

const SupportedCpuArch = enum {
    amd64,
    arm64,

    const Self = @This();

    fn arch(self: Self) std.Target.Cpu.Arch {
        return switch (self) {
            .amd64 => std.Target.Cpu.Arch.x86_64,
            .arm64 => std.Target.Cpu.Arch.aarch64,
        };
    }
    fn model(self: Self) *const std.Target.Cpu.Model {
        return switch (self) {
            .amd64 => std.Target.Cpu.Model.generic(std.Target.Cpu.Arch.x86_64),
            .arm64 => std.Target.Cpu.Model.generic(std.Target.Cpu.Arch.aarch64),
        };
    }
};
