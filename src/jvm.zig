// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const jvm_launcher = @import("jvm_launcher.zig");
const environ = @import("proc_self_environ_parser.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const java_tool_options_env_var_name = "JAVA_TOOL_OPTIONS";

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
        configuration.jvm_instrumentation_disabled,
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

    var major: ?u32 = null;
    if (get_java_major_version(io, gpa, get_env)) |detected_major| {
        major = detected_major;
    } else |err| {
        // We need to ignore processes that don't have Java because we'll inject into any shell that wraps a Java
        // process, and then, like it or not, this environment variable will propagate to the JVM process.
        if (err == error.JvmLauncherNotFound) {
            print.printDebug("Skipping Java agent injection because no Java launcher is loaded.", .{});
            return false;
        }
        print.printDebug("Cannot detect the JVM's Java version, allowing Java agent injection: {}", .{err});
    }

    const java_major = major orelse {
        print.printDebug("No JVM version detected, allowing Java agent injection.", .{});
        return true;
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

test "JVM version gate: injects for Java 8+, unknown versions and detection errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const expected = try std.fmt.allocPrint(testing.allocator, "-Dexisting=preserved -javaagent:{s}", .{jar});
    defer testing.allocator.free(expected);

    inline for (.{ @as(?u32, 8), @as(?u32, 21), @as(?u32, null) }) |major| {
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
    const FailedDetector = struct {
        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.AccessDenied;
        }
    };
    const on_error = doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
        testing.io,
        testing.allocator,
        "-Dexisting=preserved",
        jar,
        false,
        config.default_jvm_auto_instrumentation_minimum_java_major_version,
        test_util.posixGetenv,
        FailedDetector.detect,
    ).?;
    defer testing.allocator.free(on_error);
    try testing.expectEqualStrings(expected, on_error);
}

test "JVM version gate: leaves existing agents unchanged on Java 6 and 7" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agent.jar", .data = "" });
    const jar = try tmp.dir.realPathFileAlloc(testing.io, "agent.jar", testing.allocator);
    defer testing.allocator.free(jar);
    const expected = try std.fmt.allocPrint(testing.allocator, "-Dexisting=preserved -javaagent:{s} -Dmessage=\"hello world\" -javaagent:/another.jar", .{jar});
    defer testing.allocator.free(expected);
    const original = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{expected}, 0);
    defer testing.allocator.free(original);

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
        try testing.expectEqual(@as(?[:0]u8, null), result);
        try testing.expectEqualStrings(expected, original);
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
    // JAVA_TOOL_OPTIONS has to short-circuit before it: this detector fails the test if it is ever reached.
    const Detector = struct {
        fn detect(_: std.Io, _: std.mem.Allocator, _: environ.GetenvFn) anyerror!?u32 {
            return error.TestDetectorMustNotBeCalled;
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
    try test_util.expectWithMessage(modified_java_tool_options == null, "modified_java_tool_options == null");
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
