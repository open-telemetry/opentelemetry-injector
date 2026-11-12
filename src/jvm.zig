// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const options = @import("config_generated.zig");
const jvm_launcher = @import("jvm_launcher.zig");
const environ = @import("proc_self_environ_parser.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const java_tool_options_env_var_name = "JAVA_TOOL_OPTIONS";
pub const java_extension_paths_env_var_name = options.javaagent_extensions.env_name.?;
pub const javaagent_extensions_env_var_name = "OTEL_JAVAAGENT_EXTENSIONS";

/// Returns the modified value for OTEL_JAVAAGENT_EXTENSIONS, based on the original value of OTEL_JAVAAGENT_EXTENSIONS
/// and the extension paths provided via OTEL_INJECTOR_JAVAAGENT_EXTENSIONS.
///
/// The value is only modified when the JVM auto-instrumentation is enabled in the injector configuration: without the
/// Java agent, nothing would read OTEL_JAVAAGENT_EXTENSIONS, so rewriting a user-provided value would have no upside.
/// Note that, unlike the -javaagent injection, this does not check whether the agent Jar is actually accessible.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    injected_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
        gpa,
        original_value_optional,
        injected_value_optional,
        configuration.jvm_auto_instrumentation_agent_path,
        configuration.auto_instrumentation_disabled.jvm,
    );
}

fn doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    injected_value_optional: ?[:0]const u8,
    jvm_auto_instrumentation_agent_path: []u8,
    jvm_instrumentation_disabled: bool,
) ?[:0]u8 {
    // Check whether there is anything to inject before evaluating whether the JVM auto-instrumentation is enabled, so
    // that processes which have not been given any extension paths do not emit a "skipping" message on every start.
    const injected_value = injected_value_optional orelse return null;
    if (injected_value.len == 0) return null;

    if (jvm_instrumentation_disabled or jvm_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the Java agent extension paths in \"{s}\" because the JVM auto-instrumentation is not enabled for this process.", .{javaagent_extensions_env_var_name});
        return null;
    }

    return getModifiedJavaAgentExtensionsValue(gpa, original_value_optional, injected_value);
}

test "Java agent extension catalog: preserves whitespace and uses the configured JVM gate" {
    var configuration = config.InjectorConfiguration.initEmpty(testing.allocator);
    defer configuration.deinit(testing.allocator);
    configuration.jvm_auto_instrumentation_agent_path = try testing.allocator.dupe(u8, "/missing/agent.jar");
    configuration.jvm_auto_instrumentation_minimum_java_major_version = std.math.maxInt(u32);

    const paths = " /extensions/custom.jar ,/extensions/another.jar";
    try testing.expectEqualStrings(paths, options.javaagent_extensions.environmentString(paths));
    try testing.expectEqualStrings("", options.javaagent_extensions.environmentString(""));

    const value = checkJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
        testing.allocator,
        "user-a",
        paths,
        configuration,
    ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("user-a, /extensions/custom.jar ,/extensions/another.jar", value);

    configuration.auto_instrumentation_disabled.jvm = true;
    try testing.expect(checkJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(testing.allocator, "user-a", paths, configuration) == null);
}

test "doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue: should return null if jvm_instrumentation_disabled is true" {
    const path = try std.fmt.allocPrint(testing.allocator, "/some/valid/path", .{});
    defer testing.allocator.free(path);
    try test_util.expectWithMessage(
        doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
            testing.allocator,
            "user-a",
            "/extensions/a",
            path,
            true,
        ) == null,
        "modified OTEL_JAVAAGENT_EXTENSIONS == null",
    );
}

test "doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue: should return null if jvm_auto_instrumentation_agent_path is the empty string" {
    const path = try std.fmt.allocPrint(testing.allocator, "", .{});
    defer testing.allocator.free(path);
    try test_util.expectWithMessage(
        doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
            testing.allocator,
            "user-a",
            "/extensions/a",
            path,
            false,
        ) == null,
        "modified OTEL_JAVAAGENT_EXTENSIONS == null",
    );
}

test "doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue: should append the extension paths if the JVM auto-instrumentation is enabled" {
    const path = try std.fmt.allocPrint(testing.allocator, "/some/valid/path", .{});
    defer testing.allocator.free(path);
    const value = doCheckJvmInstrumentationAndGetModifiedJavaAgentExtensionsValue(
        testing.allocator,
        "user-a",
        "/extensions/a",
        path,
        false,
    ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("user-a,/extensions/a", value);
}

/// Appends injector-provided extension paths to the Java agent's extension path.
/// Existing user-provided entries are kept in order and are not duplicated.
pub fn getModifiedJavaAgentExtensionsValue(
    gpa: std.mem.Allocator,
    existing: ?[:0]const u8,
    injected: ?[:0]const u8,
) ?[:0]u8 {
    const paths = injected orelse return null;
    if (paths.len == 0) return null;

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);

    if (existing) |value| {
        var existing_iterator = std.mem.splitScalar(u8, value, ',');
        while (existing_iterator.next()) |path| {
            if (path.len == 0 or containsPath(result.items, path)) continue;
            appendPath(gpa, &result, path) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ javaagent_extensions_env_var_name, err });
                return null;
            };
        }
    }

    var appended_any = false;
    var iterator = std.mem.splitScalar(u8, paths, ',');
    while (iterator.next()) |path| {
        if (path.len == 0 or containsPath(result.items, path)) continue;
        appendPath(gpa, &result, path) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ javaagent_extensions_env_var_name, err });
            return null;
        };
        appended_any = true;
    }

    // If all injected paths are already present, leave the existing value alone instead of writing back a value that
    // only differs in the entries we have normalized away.
    if (!appended_any) return null;

    return gpa.dupeSentinel(u8, result.items, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ javaagent_extensions_env_var_name, err });
        return null;
    };
}

fn appendPath(gpa: std.mem.Allocator, result: *std.ArrayList(u8), path: []const u8) !void {
    if (result.items.len > 0) try result.append(gpa, ',');
    try result.appendSlice(gpa, path);
}

fn containsPath(value: []const u8, path: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, value, ',');
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
}

test "getModifiedJavaAgentExtensionsValue: appends new paths and preserves existing paths" {
    const value = getModifiedJavaAgentExtensionsValue(
        testing.allocator,
        "user-a,user-b",
        "/extensions/a,/extensions/b",
    ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("user-a,user-b,/extensions/a,/extensions/b", value);
}

test "getModifiedJavaAgentExtensionsValue: deduplicates existing and incoming paths" {
    const value = getModifiedJavaAgentExtensionsValue(
        testing.allocator,
        "user-a,/extensions/a",
        "/extensions/a,/extensions/b,/extensions/b",
    ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("user-a,/extensions/a,/extensions/b", value);
}

test "getModifiedJavaAgentExtensionsValue: removes empty entries" {
    const value = getModifiedJavaAgentExtensionsValue(
        testing.allocator,
        "user-a,,/extensions/a,",
        "/extensions/a,/extensions/b",
    ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("user-a,/extensions/a,/extensions/b", value);
}

test "getModifiedJavaAgentExtensionsValue: returns null when no path needs appending" {
    try testing.expect(getModifiedJavaAgentExtensionsValue(testing.allocator, "user-a", null) == null);
    try testing.expect(getModifiedJavaAgentExtensionsValue(testing.allocator, "user-a", "") == null);
    try testing.expect(getModifiedJavaAgentExtensionsValue(testing.allocator, "user-a", "user-a") == null);
}

test "getModifiedJavaAgentExtensionsValue: leaves the existing value alone if there is nothing to append" {
    // The existing value has entries that would be normalized away, but since all injected paths are already present,
    // we must not rewrite the value the user has provided.
    try testing.expect(getModifiedJavaAgentExtensionsValue(
        testing.allocator,
        ",user-a,,user-b,",
        "user-a,user-b",
    ) == null);
}

/// Returns the modified value for JAVA_TOOL_OPTIONS, including the -javaagent flag; based on the original value of
/// JAVA_TOOL_OPTIONS.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
    get_env: environ.GetenvFn,
) ?[:0]u8 {
    return doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
        io,
        gpa,
        original_value_optional,
        configuration.jvm_auto_instrumentation_agent_path,
        configuration.auto_instrumentation_disabled.jvm,
        configuration.jvm_auto_instrumentation_minimum_java_major_version,
        get_env,
        getJavaMajorVersion, // Passed in for testing reasons.
    );
}

fn doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    jvm_auto_instrumentation_agent_path: []u8,
    jvm_instrumentation_disabled: bool,
    minimum_java_major_version: u32,
    get_env: environ.GetenvFn,
    comptime get_java_major_version: fn (std.Io, std.mem.Allocator, environ.GetenvFn) anyerror!?u32,
) ?[:0]u8 {
    if (jvm_instrumentation_disabled or jvm_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the OpenTelemetry Java agent in \"JAVA_TOOL_OPTIONS\" because it has been explicitly disabled.", .{});
        return null;
    }

    // Check the existence of the Jar file: by passing a `-javaagent` to a
    // jar file that does not exist or cannot be opened will crash the JVM
    std.Io.Dir.cwd().access(io, jvm_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the OpenTelemetry Java agent in \"JAVA_TOOL_OPTIONS\" because of an issue accessing the Jar file at \"{s}\": {}", .{ jvm_auto_instrumentation_agent_path, err });
        return null;
    };

    const javaagent_flag_value = std.fmt.allocPrintSentinel(gpa, "-javaagent:{s}", .{jvm_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
        return null;
    };

    if (original_value_optional) |original_java_tool_options_env_var_value| {
        if (std.mem.indexOf(u8, original_java_tool_options_env_var_value, javaagent_flag_value)) |_| {
            // If our "-javaagent ..." flag is already present in JAVA_TOOL_OPTIONS, do nothing. This is particularly
            // important to avoid double injection, for example if we are injecting into a container which has a shell
            // executable as its entry point (into which we inject env var modifications), and then this shell starts
            // the JVM executable as a child process, which inherits the environment from the already injected shell.
            gpa.free(javaagent_flag_value);
            return null;
        }
    }

    // Detecting the runtime version is the expensive part of this function, so it runs last: the checks above can
    // rule out injection on their own, and they cost a stat and a substring search.
    if (!javaVersionAllowsInjection(io, gpa, minimum_java_major_version, get_env, get_java_major_version)) {
        gpa.free(javaagent_flag_value);
        return null;
    }

    return getModifiedJavaToolOptionsValue(
        gpa,
        original_value_optional,
        javaagent_flag_value,
    );
}

fn javaVersionAllowsInjection(
    io: std.Io,
    gpa: std.mem.Allocator,
    minimum_java_major_version: u32,
    get_env: environ.GetenvFn,
    comptime get_java_major_version: fn (std.Io, std.mem.Allocator, environ.GetenvFn) anyerror!?u32,
) bool {
    // A minimum of zero turns the version gate off entirely: no detection runs and every process is injected, which
    // is how the injector behaved before the gate existed. Besides being the cheapest way to opt out of the scan,
    // this is the only way to keep instrumenting JVMs the launcher detection cannot see. A VM created through the
    // JNI Invocation API (jsvc and other embedded launchers) dlopens libjvm.so long after our constructor has run,
    // so at detection time the process looks like any other non-Java process, even though the VM it later starts
    // does read JAVA_TOOL_OPTIONS.
    if (minimum_java_major_version == 0) {
        print.printDebug("Skipping JVM version detection because the minimum Java major version is set to 0.", .{});
        return true;
    }

    // Beyond this point the agent is injected only into a runtime whose version we have established to be
    // supported. Anything we cannot verify is left alone: an unchecked injection can stop an application from
    // starting at all, while a skipped one costs telemetry from a workload that keeps running. Whoever would
    // rather have the telemetry can say so with a minimum of 0 above.
    const major = get_java_major_version(io, gpa, get_env) catch |err| {
        // We need to ignore processes that don't have Java because we'll inject into any shell that wraps a Java
        // process, and then, like it or not, this environment variable will propagate to the JVM process.
        if (err == error.JvmLauncherNotFound) {
            print.printDebug("Skipping Java agent injection because no Java launcher is loaded.", .{});
        } else {
            print.printInfo("Skipping the injection of the OpenTelemetry Java agent because the Java version could not be determined: {}", .{err});
        }
        return false;
    };

    const java_major = major orelse {
        print.printInfo("Skipping the injection of the OpenTelemetry Java agent because no Java version was detected.", .{});
        return false;
    };

    if (java_major < minimum_java_major_version) {
        print.printInfo(
            "Skipping the injection of the OpenTelemetry Java agent because Java {d} is older than the minimum supported version {d}.",
            .{ java_major, minimum_java_major_version },
        );
        return false;
    }

    print.printDebug("Detected Java {d}.", .{java_major});
    return true;
}

fn getJavaMajorVersion(io: std.Io, allocator: std.mem.Allocator, get_env: environ.GetenvFn) !?u32 {
    return jvm_launcher.getJavaMajorVersion(io, allocator, get_env);
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return null if jvm_instrumentation_disabled is true" {
    const path = try std.fmt.allocPrint(testing.allocator, "/some/valid/path", .{});
    defer testing.allocator.free(path);
    const modified_java_tool_options =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            true,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            getJavaMajorVersion,
        );
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return null if jvm_auto_instrumentation_agent_path the empty string" {
    const path = try std.fmt.allocPrint(testing.allocator, "", .{});
    defer testing.allocator.free(path);
    const modified_java_tool_options =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            getJavaMajorVersion,
        );
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return null if the Java agent cannot be accessed (original value not set)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_java_tool_options =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            getJavaMajorVersion,
        );
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return null if the Java agent cannot be accessed (original value present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_java_tool_options =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            "original value",
            path,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            getJavaMajorVersion,
        );
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
}

test "JVM version gate: skips Java 6 and 7 while preserving existing options" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    inline for (.{ 6, 7 }) |major| {
        const Detector = struct {
            fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
                return major;
            }
        };
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            "-Dexisting=preserved",
            jar,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            Detector.detect,
        );
        try testing.expectEqual(@as(?[:0]u8, null), result);
    }
}

test "JVM version gate: injects for Java 8+" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const expected = try std.fmt.allocPrint(testing.allocator, "-Dexisting=preserved -javaagent:{s}", .{jar});
    defer testing.allocator.free(expected);

    inline for (.{ @as(?u32, 8), @as(?u32, 21) }) |major| {
        const Detector = struct {
            fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
                return major;
            }
        };
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            "-Dexisting=preserved",
            jar,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            Detector.detect,
        ).?;
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(expected, result);
    }
}

test "JVM version gate: skips injection when the Java version cannot be established" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);

    // A detector that reports no version, and one that fails outright: in both cases the runtime about to be
    // loaded is unknown, so the agent stays out and whatever JAVA_TOOL_OPTIONS already carries is left alone.
    const Undetected = struct {
        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return null;
        }
    };
    const Failing = struct {
        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.AccessDenied;
        }
    };

    inline for (.{ Undetected.detect, Failing.detect }) |detect| {
        inline for (.{ @as(?[:0]const u8, null), @as(?[:0]const u8, "-Dexisting=preserved") }) |original| {
            try testing.expectEqual(
                @as(?[:0]u8, null),
                doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
                    testing.io,
                    testing.allocator,
                    original,
                    jar,
                    false,
                    config.default_jvm_auto_instrumentation_minimum_java_major_version,
                    test_util.posixGetenv,
                    detect,
                ),
            );
        }
    }
}

test "JVM version gate: leaves existing agents unchanged on Java 6 and 7" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);

    // Agents of the user's own only: with ours in the value already, the duplicate check would answer before the
    // version gate is ever reached.
    const original = "-Dexisting=preserved -Dmessage=\"hello world\" -javaagent:/another.jar";

    inline for (.{ 6, 7 }) |major| {
        const Detector = struct {
            fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
                return major;
            }
        };
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            original,
            jar,
            false,
            config.default_jvm_auto_instrumentation_minimum_java_major_version,
            test_util.posixGetenv,
            Detector.detect,
        );
        defer if (result) |value| testing.allocator.free(value);
        try testing.expectEqual(@as(?[:0]u8, null), result);
    }
}

fn getModifiedJavaToolOptionsValue(
    gpa: std.mem.Allocator,
    original_java_tool_options_env_var_value_optional: ?[:0]const u8,
    javaagent_flag_value: [:0]u8,
) ?[:0]u8 {
    // For auto-instrumentation, we inject the -javaagent flag into the JAVA_TOOL_OPTIONS environment variable.
    // The caller has already established that our flag is not in the original value yet.
    if (original_java_tool_options_env_var_value_optional) |original_java_tool_options_env_var_value| {
        // If JAVA_TOOL_OPTIONS is already set, prepend the "-javaagent ..." flag to the original value.
        // Since we copy over javaagent_flag_value into newly allocated memory, we can free the parameter here.
        defer gpa.free(javaagent_flag_value);
        return std.fmt.allocPrintSentinel(gpa, "{s} {s}", .{
            original_java_tool_options_env_var_value,
            javaagent_flag_value,
        }, 0) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
            return null;
        };
    }

    // JAVA_TOOL_OPTIONS is not set, simply return the -javaagent flag.
    return javaagent_flag_value[0..];
}

test "getModifiedJavaToolOptionsValue: should return -javaagent if original value is unset" {
    const javaagent_flag_value = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "-javaagent:/usr/lib/opentelemetry/jvm/javaagent.jar",
        .{},
        0,
    );
    const modified_java_tool_options = getModifiedJavaToolOptionsValue(
        testing.allocator,
        null,
        javaagent_flag_value,
    );
    defer (if (modified_java_tool_options) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "-javaagent:/usr/lib/opentelemetry/jvm/javaagent.jar",
        modified_java_tool_options orelse "-",
    );
}

test "getModifiedJavaToolOptionsValue: should append -javaagent if original value exists" {
    const original_value: [:0]const u8 = "-Dsome.property=value"[0.. :0];
    const javaagent_flag_value = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "-javaagent:/usr/lib/opentelemetry/jvm/javaagent.jar",
        .{},
        0,
    );
    const modified_java_tool_options = getModifiedJavaToolOptionsValue(
        testing.allocator,
        original_value,
        javaagent_flag_value,
    );
    defer (if (modified_java_tool_options) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "-Dsome.property=value -javaagent:/usr/lib/opentelemetry/jvm/javaagent.jar",
        modified_java_tool_options orelse "-",
    );
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should do nothing if our -javaagent is already present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const original = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "-Dsome.property=value -javaagent:{s} -Dsome.other.property=value",
        .{jar},
        0,
    );
    defer testing.allocator.free(original);

    // Detecting the version is the expensive part of the injection decision, so an already injected
    // JAVA_TOOL_OPTIONS has to short-circuit before it. An error from the detector would only turn into a skip, the
    // same null this test expects, so the detector records that it was called instead. It also reports a supported
    // version, so that reaching it would add our agent a second time.
    const Detector = struct {
        var called = false;

        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            called = true;
            return 21;
        }
    };

    const modified_java_tool_options = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
        testing.io,
        testing.allocator,
        original,
        jar,
        false,
        config.default_jvm_auto_instrumentation_minimum_java_major_version,
        test_util.posixGetenv,
        Detector.detect,
    );
    defer if (modified_java_tool_options) |value| testing.allocator.free(value);
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
    try test_util.expectWithMessage(!Detector.called, "the version detector was not called");
}

test "JVM version gate: does not add a Java agent to a non-Java parent process" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const NonJavaDetector = struct {
        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.JvmLauncherNotFound;
        }
    };
    const original = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{"-Dexisting=preserved -javaagent:/user-agent.jar"}, 0);
    defer testing.allocator.free(original);
    for ([_]u32{ 6, 8 }) |minimum| {
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            original,
            jar,
            false,
            minimum,
            test_util.posixGetenv,
            NonJavaDetector.detect,
        );
        defer if (result) |value| testing.allocator.free(value);
        try testing.expectEqual(@as(?[:0]u8, null), result);
        try testing.expectEqualStrings("-Dexisting=preserved -javaagent:/user-agent.jar", original);
    }
}

test "JVM version gate: a minimum of zero injects without detecting the runtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const expected = try std.fmt.allocPrint(testing.allocator, "-Dexisting=preserved -javaagent:{s}", .{jar});
    defer testing.allocator.free(expected);

    // Detection must not run at all when the gate is off, so every detector outcome has to inject: a process that
    // does not look like a JVM (an embedded launcher such as jsvc, or a shell that goes on to exec java), a JVM too
    // old for the agent, and a detector that fails outright.
    const Detector = struct {
        fn notJava(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.JvmLauncherNotFound;
        }
        fn failing(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.AccessDenied;
        }
        fn java6(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return 6;
        }
        fn unreachableDetector(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.TestDetectorMustNotBeCalled;
        }
    };

    inline for (.{ Detector.notJava, Detector.failing, Detector.java6, Detector.unreachableDetector }) |detect| {
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            "-Dexisting=preserved",
            jar,
            false,
            0,
            test_util.posixGetenv,
            detect,
        );
        defer if (result) |value| testing.allocator.free(value);
        try testing.expectEqualStrings(expected, result orelse return error.TestUnexpectedResult);
    }
}

test "JVM version gate: respects the configured minimum Java major version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const expected = try std.fmt.allocPrint(testing.allocator, "-Dexisting=preserved -javaagent:{s}", .{jar});
    defer testing.allocator.free(expected);
    const Case = struct { major: u32, minimum: u32, inject: bool };
    inline for (.{
        Case{ .major = 6, .minimum = 0, .inject = true },
        Case{ .major = 6, .minimum = 6, .inject = true },
        Case{ .major = 6, .minimum = 7, .inject = false },
        Case{ .major = 8, .minimum = 8, .inject = true },
        Case{ .major = 8, .minimum = 9, .inject = false },
        Case{ .major = 11, .minimum = 11, .inject = true },
        Case{ .major = 11, .minimum = 21, .inject = false },
        Case{ .major = 21, .minimum = 17, .inject = true },
    }) |case| {
        const Detector = struct {
            fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
                return case.major;
            }
        };
        const result = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            testing.io,
            testing.allocator,
            "-Dexisting=preserved",
            jar,
            false,
            case.minimum,
            test_util.posixGetenv,
            Detector.detect,
        );
        defer if (result) |value| testing.allocator.free(value);
        if (case.inject) {
            try testing.expectEqualStrings(expected, result orelse return error.TestUnexpectedResult);
        } else {
            try testing.expectEqual(@as(?[:0]u8, null), result);
        }
    }
}
