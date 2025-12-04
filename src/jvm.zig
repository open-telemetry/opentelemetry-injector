// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const alloc = @import("allocator.zig");
const config = @import("config.zig");
const print = @import("print.zig");
const res_attrs = @import("resource_attributes.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const java_tool_options_env_var_name = "JAVA_TOOL_OPTIONS";
const injection_happened_msg = "injecting the Java OpenTelemetry agent";

pub fn checkOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?types.NullTerminatedString {
    return doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
        original_value_optional,
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

fn doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
    original_value_optional: ?[:0]const u8,
    jvm_auto_instrumentation_agent_path: []u8,
) ?types.NullTerminatedString {
    if (jvm_auto_instrumentation_agent_path.len == 0) {
        print.printMessage("Skipping the injection of the OpenTelemetry Java agent in \"JAVA_TOOL_OPTIONS\" because it has been explicitly disabled.", .{});
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    }

    // Check the existence of the Jar file: by passing a `-javaagent` to a
    // jar file that does not exist or cannot be opened will crash the JVM
    std.fs.cwd().access(jvm_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the OpenTelemetry Java agent in \"JAVA_TOOL_OPTIONS\" because of an issue accessing the Jar file at \"{s}\": {}", .{ jvm_auto_instrumentation_agent_path, err });
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    };

    const javaagent_flag_value = std.fmt.allocPrintSentinel(alloc.page_allocator, "-javaagent:{s}", .{jvm_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    };

    const original_otel_resource_attributes_env_var_value_optional =
        std.posix.getenv(res_attrs.otel_resource_attributes_env_var_name);
    const resource_attributes_optional: ?[]u8 = res_attrs.getResourceAttributes();
    return getModifiedJavaToolOptionsValue(
        original_value_optional,
        original_otel_resource_attributes_env_var_value_optional,
        resource_attributes_optional,
        javaagent_flag_value,
    );
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return null value if the Java agent cannot be accessed" {
    const modifiedJavaToolOptions =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            null,
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expect(modifiedJavaToolOptions == null);
}

test "doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue: should return the original value if the Java agent cannot be accessed" {
    const modifiedJavaToolOptions =
        doCheckOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            "original value",
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expectEqualStrings(
        "original value",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

/// Returns the modified value for JAVA_TOOL_OPTIONS, including the -javaagent flag; based on the original value of
/// JAVA_TOOL_OPTIONS and the provided resource attributes that should be added.
///
/// Do no deallocate the return value, or we may cause a USE_AFTER_FREE memory corruption in the parent process.
///
/// getModifiedJavaToolOptionsValue will free the new_resource_attributes_optional parameter if it is not null
fn getModifiedJavaToolOptionsValue(
    original_java_tool_options_env_var_value_optional: ?[:0]const u8,
    original_otel_resource_attributes_env_var_value_optional: ?[:0]const u8,
    new_resource_attributes_optional: ?[]u8,
    javaagent_flag_value: types.NullTerminatedString,
) ?types.NullTerminatedString {
    var original_otel_resource_attributes_env_var_key_value_pairs_prefix: [:0]const u8 = "";
    if (original_otel_resource_attributes_env_var_value_optional) |original_otel_resource_attributes_env_var_value| {
        // For cases where we also need to merge the key-value pairs from the OTEL_RESOURCE_ATTRIBUTES environment
        // variable (in contrast to key-value pairs from JAVA_TOOL_OPTIONS' -Dotel.resource.attributes Java system
        // property), we compile a prefix here already that can simply be prepended to the new
        // -Dotel.resource.attributes value we return. It is either an empty string if OTEL_RESOURCE_ATTRIBUTES is not
        // set, or it is the OTEL_RESOURCE_ATTRIBUTES with a trailing comma. If we need to merge this in, there always
        // other key-value pairs, so having a trailing comma here is safe.
        original_otel_resource_attributes_env_var_key_value_pairs_prefix =
            std.fmt.allocPrintSentinel(
                alloc.page_allocator,
                "{s},",
                .{original_otel_resource_attributes_env_var_value},
                0,
            ) catch |err| {
                print.printError("Cannot allocate memory to prepare the original_otel_resource_attributes_env_var_key_value_pairs_prefix for the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                return null;
            };
    }

    // For auto-instrumentation, we inject the -javaagent flag into the JAVA_TOOL_OPTIONS environment variable. In
    // addition, we use JAVA_TOOL_OPTIONS to supply addtional resource attributes. The Java runtime does not look up the
    // OTEL_RESOURCE_ATTRIBUTES environment variable using getenv(), instead it parses the environment block
    // /proc/<pid>/environ directly. We cannot hook into this mechanism to introduce additional resource attributes.
    // Instead, we add them together with the -javaagent flag as the -Dotel.resource.attributes Java system property to
    // JAVA_TOOL_OPTIONS. If the -Dotel.resource.attributes system property already exists in the original
    // JAVA_TOOL_OPTIONS value, we need to merge the two list of key-value pairs. If -Dotel.resource.attributes is
    // supplied via other means (for example via the command line), the value from the command line will override the
    // value we add here to JAVA_TOOL_OPTIONS, which can be verified as follows:
    //     % JAVA_TOOL_OPTIONS="-Dprop=B" jshell -R -Dprop=A
    //     Picked up JAVA_TOOL_OPTIONS: -Dprop=B
    //     jshell> System.getProperty("prop")
    //     $1 ==> "A"
    //
    // Last but not least, if the original value of JAVA_TOOL_OPTIONS is not set, or did not contain
    // -Dotel.resource.attributes, but OTEL_RESOURCE_ATTRIBUTES was set originally, we need to merge the key-value pairs
    // from that environment variable as well, since the OTel Java SDK will prefer -Dotel.resource.attributes over
    // OTEL_RESOURCE_ATTRIBUTES, so us adding -Dotel.resource.attributes would discard the user-provied
    // OTEL_RESOURCE_ATTRIBUTES. We do deliberately not merge in OTEL_RESOURCE_ATTRIBUTES if the original
    // JAVA_TOOL_OPTIONS is set and has -Dotel.resource.attributes, because that would change the behavior -- if not
    // instrumented by us, the OTel Java SDK will would _also_ ignore OTEL_RESOURCE_ATTRIBUTES, so to keep that
    // behavior, we refrain from merging OTEL_RESOURCE_ATTRIBUTES in that scenario.
    if (original_java_tool_options_env_var_value_optional) |original_java_tool_options_env_var_value| {
        // If JAVA_TOOL_OPTIONS is already set, append our values.
        if (new_resource_attributes_optional) |new_resource_attributes| {
            defer alloc.page_allocator.free(new_resource_attributes);

            if (std.mem.indexOf(u8, original_java_tool_options_env_var_value, "-Dotel.resource.attributes=")) |startIdx| {
                // JAVA_TOOL_OPTIONS already contains -Dotel.resource.attribute, we need to merge the existing with the new key-value list.
                var actualStartIdx = startIdx + 27;
                // By default, we assume the -Dotel.resource.attribute value is terminated by a space or by the end of
                // the string (-Dotel.resource.attribute=a=b,c=d).
                var terminating_character = " ";
                var key_value_pairs_are_quoted = false;
                // The -Dotel.resource.attribute value could also be quoted (-Dotel.resource.attribute="a=b,c=d"), which
                // we can detect by inspecting the first character of the value.
                if (original_java_tool_options_env_var_value[actualStartIdx] == '"') {
                    key_value_pairs_are_quoted = true;
                    terminating_character = "\"";
                    actualStartIdx += 1;
                }
                var originalKvPairs: []const u8 = "";
                var remainingJavaToolOptions: []const u8 = "";
                if (std.mem.indexOfPos(u8, original_java_tool_options_env_var_value, actualStartIdx, terminating_character)) |endIdx| {
                    originalKvPairs = original_java_tool_options_env_var_value[actualStartIdx..endIdx];
                    remainingJavaToolOptions = original_java_tool_options_env_var_value[endIdx..];
                } else {
                    originalKvPairs = original_java_tool_options_env_var_value[actualStartIdx..];
                    remainingJavaToolOptions = "";
                }

                const mergedKvPairs = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s},{s}", .{
                    originalKvPairs,
                    new_resource_attributes,
                }, 0) catch |err| {
                    print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                    return original_java_tool_options_env_var_value;
                };
                defer alloc.page_allocator.free(mergedKvPairs);
                const return_buffer =
                    std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}-Dotel.resource.attributes={s}{s}{s} {s}", .{
                        original_java_tool_options_env_var_value[0..startIdx],
                        (if (key_value_pairs_are_quoted) "\"" else ""),
                        mergedKvPairs,
                        remainingJavaToolOptions,
                        javaagent_flag_value,
                    }, 0) catch |err| {
                        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                        return original_java_tool_options_env_var_value;
                    };
                print.printMessage(injection_happened_msg, .{});
                print.printMessage(res_attrs.modification_happened_msg, .{java_tool_options_env_var_name});
                return return_buffer.ptr;
            }

            // JAVA_TOOL_OPTIONS is set but does not contain -Dotel.resource.attributes yet. New resource attributes
            // have been provided. Add -javaagent and -Dotel.resource.attributes.
            const return_buffer =
                std.fmt.allocPrintSentinel(alloc.page_allocator, "{s} {s} -Dotel.resource.attributes={s}{s}", .{
                    original_java_tool_options_env_var_value,
                    javaagent_flag_value,
                    original_otel_resource_attributes_env_var_key_value_pairs_prefix,
                    new_resource_attributes,
                }, 0) catch |err| {
                    print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                    return original_java_tool_options_env_var_value;
                };
            print.printMessage(res_attrs.modification_happened_msg, .{java_tool_options_env_var_name});
            print.printMessage(injection_happened_msg, .{});
            return return_buffer.ptr;
        } else {
            // JAVA_TOOL_OPTIONS is set, but no new resource attributes have been provided.
            const return_buffer =
                std.fmt.allocPrintSentinel(alloc.page_allocator, "{s} {s}", .{
                    original_java_tool_options_env_var_value,
                    javaagent_flag_value,
                }, 0) catch |err| {
                    print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                    return original_java_tool_options_env_var_value;
                };
            print.printMessage(injection_happened_msg, .{});
            return return_buffer.ptr;
        }
    } else {
        // JAVA_TOOL_OPTIONS is not set, but new resource attributes have been provided.
        if (new_resource_attributes_optional) |new_resource_attributes| {
            defer alloc.page_allocator.free(new_resource_attributes);
            const return_buffer = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s} -Dotel.resource.attributes={s}{s}", .{
                javaagent_flag_value,
                original_otel_resource_attributes_env_var_key_value_pairs_prefix,
                new_resource_attributes,
            }, 0) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ java_tool_options_env_var_name, err });
                return null;
            };
            print.printMessage(res_attrs.modification_happened_msg, .{java_tool_options_env_var_name});
            print.printMessage(injection_happened_msg, .{});
            return return_buffer.ptr;
        } else {
            // JAVA_TOOL_OPTIONS is not set, and no new resource attributes have been provided. Simply return the -javaagent flag.
            print.printMessage(injection_happened_msg, .{});
            return javaagent_flag_value[0..];
        }
    }
}

test "getModifiedJavaToolOptionsValue: should return -javaagent if original value is unset and no resource attributes are provided" {
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(
        null,
        null,
        null,
        "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
    );
    try testing.expectEqualStrings(
        "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should ignore OTEL_RESOURCE_ATTRIBUTES env var if if JAVA_TOOL_OPTIONS is unset and no resource attributes are provided" {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(null, otel_resource_attributes_env_var_value, null, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES should be ignored here because we are not adding -Dotel.resource.attributes, so the
    // Java OTel SDK will pick up OTEL_RESOURCE_ATTRIBUTES.
    try testing.expectEqualStrings(
        "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should return -javaagent and -Dotel.resource.attributes if original value is unset and resource attributes are provided" {
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(null, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar -Dotel.resource.attributes=aaa=bbb,ccc=ddd",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge OTEL_RESOURCE_ATTRIBUTES env var if JAVA_TOOL_OPTIONS is unset and resource attributes are provided" {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(null, otel_resource_attributes_env_var_value, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES must be merged into -Dotel.resource.attributes because we are adding this system
    // property and it will make the Java OTel SDK ignore the OTEL_RESOURCE_ATTRIBUTES env var.
    // Java OTel SDK will pick up OTEL_RESOURCE_ATTRIBUTES.
    try testing.expectEqualStrings(
        "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar -Dotel.resource.attributes=from_env_var_1=value1,from_env_var_2=value2,aaa=bbb,ccc=ddd",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should append -javaagent if original value exists and no resource attributes are provided" {
    const original_value: [:0]const u8 = "-Dsome.property=value"[0.. :0];
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, null, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dsome.property=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should ignore OTEL_RESOURCE_ATTRIBUTES env var if JAVA_TOOL_OPTIONS is set and no resource attributes are provided" {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const original_value: [:0]const u8 = "-Dsome.property=value"[0.. :0];
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, otel_resource_attributes_env_var_value, null, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES should be ignored here because we are not adding -Dotel.resource.attributes, so the
    // Java OTel SDK will pick up OTEL_RESOURCE_ATTRIBUTES.
    try testing.expectEqualStrings(
        "-Dsome.property=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should append -javaagent if original value exists and has -Dotel.resource.attributes but no new resource attributes are provided, " {
    const original_value: [:0]const u8 = "-Dsome.property=value -Dotel.resource.attributes=www=xxx,yyy=zzz"[0.. :0];
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, null, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dsome.property=value -Dotel.resource.attributes=www=xxx,yyy=zzz -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should ignore OTEL_RESOURCE_ATTRIBUTES env var if JAVA_TOOL_OPTIONS is set and has -Dotel.resource.attributes but no new resource attributes are provided, " {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const original_value: [:0]const u8 = "-Dsome.property=value -Dotel.resource.attributes=www=xxx,yyy=zzz"[0.. :0];
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, otel_resource_attributes_env_var_value, null, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES should be ignored here because we are not _adding_ -Dotel.resource.attributes, it was
    // there already. The Java OTel SDK will ignore the OTEL_RESOURCE_ATTRIBUTES env var, but it would have ignored
    // it anyway, also without the injector. We deliberately avoid changing that behavior.
    try testing.expectEqualStrings(
        "-Dsome.property=value -Dotel.resource.attributes=www=xxx,yyy=zzz -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should append -javaagent and -Dotel.resource.attributes if original value exists and resource attributes are provided" {
    const original_value: [:0]const u8 = "-Dsome.property=value"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dsome.property=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar -Dotel.resource.attributes=aaa=bbb,ccc=ddd",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge OTEL_RESOURCE_ATTRIBUTES env var if JAVA_TOOL_OPTIONS is set, but has no -Dotel.resource.attributes, and resource attributes are provided" {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const original_value: [:0]const u8 = "-Dsome.property=value"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, otel_resource_attributes_env_var_value, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES must be merged into -Dotel.resource.attributes because we are adding this system
    // property and it will make the Java OTel SDK ignore the OTEL_RESOURCE_ATTRIBUTES env var.
    // Java OTel SDK will pick up OTEL_RESOURCE_ATTRIBUTES.
    try testing.expectEqualStrings(
        "-Dsome.property=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar -Dotel.resource.attributes=from_env_var_1=value1,from_env_var_2=value2,aaa=bbb,ccc=ddd",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge new and existing -Dotel.resource.attributes (only property)" {
    const original_value: [:0]const u8 = "-Dotel.resource.attributes=eee=fff,ggg=hhh"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dotel.resource.attributes=eee=fff,ggg=hhh,aaa=bbb,ccc=ddd -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge new and existing -Dotel.resource.attributes (at the start)" {
    const original_value: [:0]const u8 = "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh,aaa=bbb,ccc=ddd -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge new and existing -Dotel.resource.attributes (in the middle)" {
    const original_value: [:0]const u8 = "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh -Dproperty2=value"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh,aaa=bbb,ccc=ddd -Dproperty2=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge new and existing -Dotel.resource.attributes (at the end)" {
    const original_value: [:0]const u8 = "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh,aaa=bbb,ccc=ddd -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should merge new and existing -Dotel.resource.attributes (with quotes)" {
    const original_value: [:0]const u8 = "-Dproperty1=\"value\" -Dotel.resource.attributes=\"eee=fff,ggg=hhh\" -Dproperty2=\"value\""[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, null, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    try testing.expectEqualStrings(
        "-Dproperty1=\"value\" -Dotel.resource.attributes=\"eee=fff,ggg=hhh,aaa=bbb,ccc=ddd\" -Dproperty2=\"value\" -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}

test "getModifiedJavaToolOptionsValue: should ignore OTEL_RESOURCE_ATTRIBUTES env var when merging new and existing -Dotel.resource.attributes" {
    const otel_resource_attributes_env_var_value: [:0]const u8 = "from_env_var_1=value1,from_env_var_2=value2"[0.. :0];
    const original_value: [:0]const u8 = "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh -Dproperty2=value"[0.. :0];
    const resource_attributes: []u8 = try alloc.page_allocator.alloc(u8, 15);
    var fbs = std.io.fixedBufferStream(resource_attributes);
    _ = try fbs.writer().write("aaa=bbb,ccc=ddd");
    const modifiedJavaToolOptions = getModifiedJavaToolOptionsValue(original_value, otel_resource_attributes_env_var_value, resource_attributes, "-javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar");
    // OTEL_RESOURCE_ATTRIBUTES should be ignored here because we are not _adding_ -Dotel.resource.attributes, it was
    // there already. The Java OTel SDK will ignore the OTEL_RESOURCE_ATTRIBUTES env var, but it would have ignored
    // it anyway, also without the injector. We deliberately avoid changing that behavior.
    try testing.expectEqualStrings(
        "-Dproperty1=value -Dotel.resource.attributes=eee=fff,ggg=hhh,aaa=bbb,ccc=ddd -Dproperty2=value -javaagent:/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar",
        std.mem.span(modifiedJavaToolOptions orelse "-"),
    );
}
