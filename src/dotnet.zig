// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const args_parser = @import("args_parser.zig");
const config = @import("config.zig");
const libc = @import("libc.zig");
const print = @import("print.zig");
const test_util = @import("test_util.zig");
const types = @import("types.zig");

const testing = std.testing;

pub const DotnetValues = struct {
    coreclr_enable_profiling: [:0]const u8,
    coreclr_profiler: [:0]const u8,
    coreclr_profiler_path: [:0]u8,
    additional_deps: [:0]u8,
    shared_store: [:0]u8,
    startup_hooks: [:0]u8,
    otel_auto_home: [:0]u8,

    pub fn freeAll(self: DotnetValues, allocator: std.mem.Allocator) void {
        allocator.free(self.coreclr_profiler_path);
        allocator.free(self.additional_deps);
        allocator.free(self.shared_store);
        allocator.free(self.startup_hooks);
        allocator.free(self.otel_auto_home);
    }
};

const coreclr_enable_profiling_value = "1";
// See https://opentelemetry.io/docs/zero-code/dotnet/configuration/#net-clr-profiler.
const coreclr_profiler_value = "{918728DD-259F-4A6A-AC2B-B85E1B658318}";
const dotnet_host_name = "dotnet";
const max_dotnet_metadata_file_size = 1024 * 1024;
const opentelemetry_dependency_prefix = "OpenTelemetry";

pub const CachedDotnetValues = struct {
    values: ?DotnetValues,
    done: bool,
};

const DotnetError = error{
    UnknownLibCFlavor,
    UnsupportedCpuArchitecture,
    OutOfMemory,
};

const DotnetMetadataPaths = struct {
    deps_path: []u8,

    fn freeAll(self: DotnetMetadataPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.deps_path);
    }
};

pub const coreclr_enable_profiling_env_var_name = "CORECLR_ENABLE_PROFILING";
pub const coreclr_profiler_env_var_name = "CORECLR_PROFILER";
pub const coreclr_profiler_path_env_var_name = "CORECLR_PROFILER_PATH";
pub const dotnet_additional_deps_env_var_name = "DOTNET_ADDITIONAL_DEPS";
pub const dotnet_shared_store_env_var_name = "DOTNET_SHARED_STORE";
pub const dotnet_startup_hooks_env_var_name = "DOTNET_STARTUP_HOOKS";
pub const otel_dotnet_auto_home_env_var_name = "OTEL_DOTNET_AUTO_HOME";

// We usually do not cache any values for environment variable modifications (i.e. we do not cache the modified
// NODE_OPTIONS value or the modified OTEL_RESOURCE_ATTRIBUTES) because we are only called once, on startup via
// root.zig#initEnviron. For .NET we deviate from this pattern a bit - we calculate all .NET-related environment
// variables once based on CPU architecture and libc flavor, and then call getDotnetValues multiple times from
// root.zig#initEnviron for eaech .NET-related env var. This is simply because .NET requires multiple environment
// variables to be set.
var cached_dotnet_values = CachedDotnetValues{
    .values = null,
    .done = false,
};
var libc_flavor: ?types.LibCFlavor = null;

pub fn setLibcFlavor(lf: types.LibCFlavor) void {
    libc_flavor = lf;
}

/// Returns the values for .NET-profiler related environment variables.
///
/// The caller is responsible for freeing the returned strings (unless the results are passed on to setenv and need to
/// stay in memory).
pub fn getDotnetValues(
    gpa: std.mem.Allocator,
    configuration: config.InjectorConfiguration,
) ?DotnetValues {
    return doGetDotnetValues(gpa, configuration.dotnet_auto_instrumentation_agent_path_prefix, configuration.dotnet_instrumentation_disabled);
}

fn doGetDotnetValues(gpa: std.mem.Allocator, dotnet_path_prefix: []u8, dotnet_instrumentation_disabled: bool) ?DotnetValues {
    if (dotnet_instrumentation_disabled or dotnet_path_prefix.len == 0) {
        print.printInfo("Skipping the injection of the .NET OpenTelemetry instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    if (libc_flavor == null) {
        print.printError("invariant violated: libc flavor has not been set prior to calling getDotnetValues().", .{});
        return null;
    }
    if (libc_flavor == types.LibCFlavor.UNKNOWN) {
        print.printError("Cannot determine libc flavor", .{});
        return null;
    }

    if (cached_dotnet_values.done) {
        return cached_dotnet_values.values;
    }

    if (!shouldInjectDotnet(gpa)) {
        cached_dotnet_values = .{
            .values = null,
            .done = true,
        };
        return null;
    }

    if (libc_flavor) |libc_f| {
        const dotnet_values = determineDotnetValues(
            gpa,
            dotnet_path_prefix,
            libc_f,
            builtin.cpu.arch,
        ) catch |err| {
            print.printError("Cannot determine .NET environment variables: {}", .{err});
            cached_dotnet_values = .{
                .values = null,
                // do not try to determine the .NET values again
                .done = true,
            };
            return null;
        };

        const paths_to_check = [_][:0]const u8{
            dotnet_values.coreclr_profiler_path,
            dotnet_values.additional_deps,
            dotnet_values.otel_auto_home,
            dotnet_values.shared_store,
            dotnet_values.startup_hooks,
        };
        for (paths_to_check) |p| {
            std.fs.cwd().access(p, .{}) catch |err| {
                print.printError("Skipping injection of the .NET OpenTelemetry instrumentation because of an issue accessing {s}: {}", .{ p, err });
                cached_dotnet_values = .{
                    .values = null,
                    // do not try to determine the .NET values again
                    .done = true,
                };
                // free strings allocated in determineDotnetValues
                dotnet_values.freeAll(gpa);
                return null;
            };
        }

        cached_dotnet_values = .{
            .values = dotnet_values,
            .done = true,
        };
        return dotnet_values;
    }

    unreachable;
}

fn shouldInjectDotnet(allocator: std.mem.Allocator) bool {
    const cmdline_args = args_parser.cmdLineForPID(allocator) catch |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not read the process command line: {}", .{err});
        return true;
    };
    defer {
        for (cmdline_args) |arg| allocator.free(arg);
        allocator.free(cmdline_args);
    }

    const self_exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not resolve the executable path: {}", .{err});
        return true;
    };
    defer allocator.free(self_exe_path);

    const maybe_app_path = resolveManagedApplicationPath(allocator, cmdline_args, self_exe_path) catch |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not determine the managed application path: {}", .{err});
        return true;
    };
    const app_path = maybe_app_path orelse {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. The process does not look like a recognized .NET application startup.", .{});
        return true;
    };
    defer allocator.free(app_path);

    const metadata_paths = createDotnetMetadataPaths(allocator, app_path) catch |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not determine the application metadata paths: {}", .{err});
        return true;
    };
    defer metadata_paths.freeAll(allocator);

    const deps_content = readSmallTextFileAlloc(allocator, metadata_paths.deps_path) catch |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not read {s}: {}", .{ metadata_paths.deps_path, err });
        return true;
    };
    defer allocator.free(deps_content);

    if (depsJsonContainsOpenTelemetryDependency(allocator, deps_content)) |contains_opentelemetry| {
        if (contains_opentelemetry) {
            print.printInfo("Skipping the injection of the .NET OpenTelemetry instrumentation because {s} already references OpenTelemetry packages.", .{metadata_paths.deps_path});
            return false;
        }
    } else |err| {
        print.printDebug("Proceeding with the injection of the .NET OpenTelemetry instrumentation. Could not parse {s} safely: {}", .{ metadata_paths.deps_path, err });
        return true;
    }

    return true;
}

fn resolveManagedApplicationPath(
    allocator: std.mem.Allocator,
    cmdline_args: []const []const u8,
    self_exe_path: []const u8,
) !?[]u8 {
    if (cmdline_args.len == 0) {
        return null;
    }

    if (std.mem.eql(u8, std.fs.path.basename(cmdline_args[0]), dotnet_host_name)) {
        for (cmdline_args[1..]) |arg| {
            if (arg.len == 0 or arg[0] == '-') {
                continue;
            }
            if (std.mem.endsWith(u8, arg, ".dll") or std.mem.endsWith(u8, arg, ".exe")) {
                return try allocator.dupe(u8, arg);
            }
        }
        return null;
    }

    return try allocator.dupe(u8, self_exe_path);
}

fn createDotnetMetadataPaths(allocator: std.mem.Allocator, app_path: []const u8) !DotnetMetadataPaths {
    const app_base_path =
        if (std.mem.endsWith(u8, app_path, ".dll") or std.mem.endsWith(u8, app_path, ".exe"))
            app_path[0 .. app_path.len - 4]
        else
            app_path;

    return .{
        .deps_path = try std.fmt.allocPrint(allocator, "{s}.deps.json", .{app_base_path}),
    };
}

fn readSmallTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file =
        if (std.fs.path.isAbsolute(path))
            try std.fs.openFileAbsolute(path, .{})
        else
            try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return file.readToEndAlloc(allocator, max_dotnet_metadata_file_size);
}

fn depsJsonContainsOpenTelemetryDependency(allocator: std.mem.Allocator, content: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    return jsonContainsOpenTelemetryDependency(parsed.value);
}

fn jsonContainsOpenTelemetryDependency(value: std.json.Value) bool {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (jsonObjectKeyLooksLikeOpenTelemetryDependency(entry.key_ptr.*)) {
                    return true;
                }
                if (jsonContainsOpenTelemetryDependency(entry.value_ptr.*)) {
                    return true;
                }
            }
            return false;
        },
        .array => |array| {
            for (array.items) |item| {
                if (jsonContainsOpenTelemetryDependency(item)) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn jsonObjectKeyLooksLikeOpenTelemetryDependency(key: []const u8) bool {
    const dependency_name =
        if (std.mem.indexOfScalar(u8, key, '/')) |slash_index|
            key[0..slash_index]
        else
            key;

    return std.mem.startsWith(u8, dependency_name, opentelemetry_dependency_prefix);
}

fn getJsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

test "doGetDotnetValues: should return null value if the libc flavor has not been set" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path = try std.fmt.allocPrint(allocator, "", .{});
    defer allocator.free(path);

    libc_flavor = null;
    const dotnet_values = doGetDotnetValues(allocator, path, false);
    try test_util.expectWithMessage(dotnet_values == null, "dotnet_values == null");
}

test "doGetDotnetValues: should return null value if dotnet_instrumentation_disabled is true" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path = try std.fmt.allocPrint(allocator, "/some/valid/path", .{});
    defer allocator.free(path);

    libc_flavor = .GNU;
    const dotnet_values = doGetDotnetValues(allocator, path, true);
    try test_util.expectWithMessage(dotnet_values == null, "dotnet_values == null");
}

test "doGetDotnetValues: should return null value if dotnet_path_prefix is the empty string" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path = try std.fmt.allocPrint(allocator, "", .{});
    defer allocator.free(path);

    libc_flavor = .GNU;
    const dotnet_values = doGetDotnetValues(allocator, path, false);
    try test_util.expectWithMessage(dotnet_values == null, "dotnet_values == null");
}

test "doGetDotnetValues: should return null value if the profiler path cannot be accessed" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path = try std.fmt.allocPrintSentinel(allocator, "/invalid/path", .{}, 0);
    defer allocator.free(path);

    libc_flavor = .GNU;
    const dotnet_values = doGetDotnetValues(allocator, path, false);
    try test_util.expectWithMessage(dotnet_values == null, "dotnet_values == null");
}

test "resolveManagedApplicationPath: dotnet host uses managed assembly argument" {
    const allocator = testing.allocator;

    const cmdline_args = [_][]const u8{
        "/usr/bin/dotnet",
        "/app/MyApp.dll",
        "--urls",
        "http://localhost:8080",
    };

    const app_path = (try resolveManagedApplicationPath(allocator, &cmdline_args, "/usr/bin/dotnet")) orelse return error.Unexpected;
    defer allocator.free(app_path);

    try testing.expectEqualStrings("/app/MyApp.dll", app_path);
}

test "resolveManagedApplicationPath: direct apphost launch uses executable path" {
    const allocator = testing.allocator;

    const cmdline_args = [_][]const u8{
        "/app/MyApp",
        "--urls",
        "http://localhost:8080",
    };

    const app_path = (try resolveManagedApplicationPath(allocator, &cmdline_args, "/app/MyApp")) orelse return error.Unexpected;
    defer allocator.free(app_path);

    try testing.expectEqualStrings("/app/MyApp", app_path);
}

test "resolveManagedApplicationPath: dotnet host without managed assembly returns null" {
    const cmdline_args = [_][]const u8{
        "/usr/bin/dotnet",
        "--info",
    };

    try test_util.expectWithMessage((try resolveManagedApplicationPath(testing.allocator, &cmdline_args, "/usr/bin/dotnet")) == null, "app path should be null");
}

test "createDotnetMetadataPaths: managed dll path produces deps path" {
    const allocator = testing.allocator;

    const metadata_paths = try createDotnetMetadataPaths(allocator, "/app/MyApp.dll");
    defer metadata_paths.freeAll(allocator);

    try testing.expectEqualStrings("/app/MyApp.deps.json", metadata_paths.deps_path);
}

test "createDotnetMetadataPaths: apphost path produces deps path" {
    const allocator = testing.allocator;

    const metadata_paths = try createDotnetMetadataPaths(allocator, "/app/MyApp");
    defer metadata_paths.freeAll(allocator);

    try testing.expectEqualStrings("/app/MyApp.deps.json", metadata_paths.deps_path);
}

test "depsJsonContainsOpenTelemetryDependency: false when no OpenTelemetry packages are present" {
    const content =
        \\{
        \\  "libraries": {
        \\    "Newtonsoft.Json/13.0.3": {
        \\      "type": "package"
        \\    }
        \\  }
        \\}
    ;

    try test_util.expectWithMessage(!(try depsJsonContainsOpenTelemetryDependency(testing.allocator, content)), "deps should not contain OpenTelemetry");
}

test "depsJsonContainsOpenTelemetryDependency: true when OpenTelemetry package is present" {
    const content =
        \\{
        \\  "libraries": {
        \\    "OpenTelemetry/1.11.0": {
        \\      "type": "package"
        \\    }
        \\  }
        \\}
    ;

    try test_util.expectWithMessage(try depsJsonContainsOpenTelemetryDependency(testing.allocator, content), "deps should contain OpenTelemetry");
}

test "depsJsonContainsOpenTelemetryDependency: true when OpenTelemetry target entry is present" {
    const content =
        \\{
        \\  "targets": {
        \\    ".NETCoreApp,Version=v9.0": {
        \\      "OpenTelemetry.Extensions.Hosting/1.11.0": {
        \\        "runtime": {}
        \\      }
        \\    }
        \\  }
        \\}
    ;

    try test_util.expectWithMessage(try depsJsonContainsOpenTelemetryDependency(testing.allocator, content), "deps should contain OpenTelemetry");
}

test "depsJsonContainsOpenTelemetryDependency: rejects malformed json" {
    try testing.expectError(error.UnexpectedEndOfInput, depsJsonContainsOpenTelemetryDependency(testing.allocator, "{"));
}

fn determineDotnetValues(
    gpa: std.mem.Allocator,
    dotnet_path_prefix: []u8,
    libc_f: types.LibCFlavor,
    architecture: std.Target.Cpu.Arch,
) DotnetError!DotnetValues {
    const libc_flavor_prefix =
        switch (libc_f) {
            .GNU => "glibc",
            .MUSL => "musl",
            else => return error.UnknownLibCFlavor,
        };
    const platform =
        switch (libc_f) {
            .GNU => switch (architecture) {
                .x86_64 => "linux-x64",
                .aarch64 => "linux-arm64",
                else => return error.UnsupportedCpuArchitecture,
            },
            .MUSL => switch (architecture) {
                .x86_64 => "linux-musl-x64",
                .aarch64 => "linux-musl-arm64",
                else => return error.UnsupportedCpuArchitecture,
            },
            else => return error.UnknownLibCFlavor,
        };
    const coreclr_profiler_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}/OpenTelemetry.AutoInstrumentation.Native.so", .{
        dotnet_path_prefix, libc_flavor_prefix, platform,
    }, 0);

    const additional_deps = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/AdditionalDeps", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    const otel_auto_home = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dotnet_path_prefix, libc_flavor_prefix }, 0);

    const shared_store = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/store", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    const startup_hooks = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    return .{
        .coreclr_enable_profiling = coreclr_enable_profiling_value,
        .coreclr_profiler = coreclr_profiler_value,
        .coreclr_profiler_path = coreclr_profiler_path,
        .additional_deps = additional_deps,
        .otel_auto_home = otel_auto_home,
        .shared_store = shared_store,
        .startup_hooks = startup_hooks,
    };
}

test "determineDotnetValues: should return error for unsupported CPU architecture" {
    try testing.expectError(error.UnsupportedCpuArchitecture, determineDotnetValues(
        testing.allocator,
        "",
        .GNU,
        .powerpc64le,
    ));
}

test "determineDotnetValues: should return error for unknown libc flavor" {
    try testing.expectError(error.UnknownLibCFlavor, determineDotnetValues(
        testing.allocator,
        "",
        .UNKNOWN,
        .x86_64,
    ));
}

test "determineDotnetValues: should return values for glibc/x86_64" {
    const allocator = testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/dotnet", .{});
    defer allocator.free(path);

    const dotnet_values =
        try determineDotnetValues(
            allocator,
            path,
            .GNU,
            .x86_64,
        );
    defer dotnet_values.freeAll(allocator);

    try testing.expectEqualStrings(
        coreclr_enable_profiling_value,
        dotnet_values.coreclr_enable_profiling,
    );
    try testing.expectEqualStrings(
        coreclr_profiler_value,
        dotnet_values.coreclr_profiler,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so",
        dotnet_values.coreclr_profiler_path,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/AdditionalDeps",
        dotnet_values.additional_deps,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc",
        dotnet_values.otel_auto_home,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/store",
        dotnet_values.shared_store,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        dotnet_values.startup_hooks,
    );
}

test "determineDotnetValues: should return values for glibc/arm64" {
    const allocator = testing.allocator;
    const path =
        try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/dotnet", .{});
    defer allocator.free(path);

    const dotnet_values =
        try determineDotnetValues(
            allocator,
            path,
            .GNU,
            .aarch64,
        );
    defer dotnet_values.freeAll(allocator);

    try testing.expectEqualStrings(
        coreclr_enable_profiling_value,
        dotnet_values.coreclr_enable_profiling,
    );
    try testing.expectEqualStrings(
        coreclr_profiler_value,
        dotnet_values.coreclr_profiler,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/linux-arm64/OpenTelemetry.AutoInstrumentation.Native.so",
        dotnet_values.coreclr_profiler_path,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/AdditionalDeps",
        dotnet_values.additional_deps,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc",
        dotnet_values.otel_auto_home,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/store",
        dotnet_values.shared_store,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        dotnet_values.startup_hooks,
    );
}

test "determineDotnetValues: should return values for musl/x86_64" {
    const allocator = testing.allocator;
    const path =
        try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/dotnet", .{});
    defer allocator.free(path);

    const dotnet_values =
        try determineDotnetValues(
            allocator,
            path,
            .MUSL,
            .x86_64,
        );
    defer dotnet_values.freeAll(allocator);

    try testing.expectEqualStrings(
        coreclr_enable_profiling_value,
        dotnet_values.coreclr_enable_profiling,
    );
    try testing.expectEqualStrings(
        coreclr_profiler_value,
        dotnet_values.coreclr_profiler,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/linux-musl-x64/OpenTelemetry.AutoInstrumentation.Native.so",
        dotnet_values.coreclr_profiler_path,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/AdditionalDeps",
        dotnet_values.additional_deps,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl",
        dotnet_values.otel_auto_home,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/store",
        dotnet_values.shared_store,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        dotnet_values.startup_hooks,
    );
}

test "determineDotnetValues: should return values for musl/arm64" {
    const allocator = testing.allocator;
    const path =
        try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/dotnet", .{});
    defer allocator.free(path);

    const dotnet_values =
        try determineDotnetValues(
            allocator,
            path,
            .MUSL,
            .aarch64,
        );
    defer dotnet_values.freeAll(allocator);

    try testing.expectEqualStrings(
        coreclr_enable_profiling_value,
        dotnet_values.coreclr_enable_profiling,
    );
    try testing.expectEqualStrings(
        coreclr_profiler_value,
        dotnet_values.coreclr_profiler,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/linux-musl-arm64/OpenTelemetry.AutoInstrumentation.Native.so",
        dotnet_values.coreclr_profiler_path,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/AdditionalDeps",
        dotnet_values.additional_deps,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl",
        dotnet_values.otel_auto_home,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/store",
        dotnet_values.shared_store,
    );
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        dotnet_values.startup_hooks,
    );
}

/// Only used for unit tests.
fn _resetState() void {
    cached_dotnet_values = CachedDotnetValues{
        .values = null,
        .done = false,
    };
    libc_flavor = null;
}
