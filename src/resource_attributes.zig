// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const alloc = @import("allocator.zig");
const print = @import("print.zig");
const types = @import("types.zig");

pub const modification_happened_msg = "adding additional OpenTelemetry resources attributes via {s}";

/// A type for a rule to map an environment variable to a resource attribute. The result of applying these rules (via
/// getResourceAttributes) is a string of key-value pairs, where each pair is of the form key=value, and pairs are
/// separated by commas. If resource_attributes_key is not null, we append a key-value pair
/// (that is, ${resource_attributes_key}=${value of environment variable}). If resource_attributes_key is null, the
/// value of the enivronment variable is expected to already be a key-value pair (or a comma separated list of key-value
/// pairs), and the value of the enivronment variable is appended as is.
const EnvToResourceAttributeMapping = struct {
    environement_variable_name: []const u8,
    resource_attributes_key: ?[]const u8,
};

pub const otel_resource_attributes_env_var_name = "OTEL_RESOURCE_ATTRIBUTES";

/// A list of mappings from environment variables to resource attributes.
const mappings: [8]EnvToResourceAttributeMapping =
    .{
        // Kubernetes-related resource attributes:
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_K8S_NAMESPACE_NAME",
            .resource_attributes_key = "k8s.namespace.name",
        },
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_K8S_POD_NAME",
            .resource_attributes_key = "k8s.pod.name",
        },
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_K8S_POD_UID",
            .resource_attributes_key = "k8s.pod.uid",
        },
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_K8S_CONTAINER_NAME",
            .resource_attributes_key = "k8s.container.name",
        },

        // Service-related resource attributes:
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_SERVICE_NAME",
            .resource_attributes_key = "service.name",
        },
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_SERVICE_VERSION",
            .resource_attributes_key = "service.version",
        },
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_SERVICE_NAMESPACE",
            .resource_attributes_key = "service.namespace",
        },

        // General purpose mapping from a comma-separated list (OTEL_INJECTOR_RESOURCE_ATTRIBUTES) to individual
        // resource attributes.
        EnvToResourceAttributeMapping{
            .environement_variable_name = "OTEL_INJECTOR_RESOURCE_ATTRIBUTES",
            .resource_attributes_key = null,
        },
    };

/// Derive the modified value for OTEL_RESOURCE_ATTRIBUTES based on the original value, and on other resource attributes
/// provided via the OTEL_INJECTOR_* environment variables.
pub fn getModifiedOtelResourceAttributesValue(original_value_optional: ?[:0]const u8) ?types.NullTerminatedString {
    if (getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);

        if (original_value_optional) |original_value| {
            if (original_value.len == 0) {
                // Note: We must never free the return_buffer, or we may cause a USE_AFTER_FREE memory corruption in the
                // parent process.
                const return_buffer = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}", .{resource_attributes}, 0) catch |err| {
                    print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ otel_resource_attributes_env_var_name, err });
                    return original_value;
                };
                print.printMessage(modification_happened_msg, .{otel_resource_attributes_env_var_name});
                return return_buffer.ptr;
            }

            // Prepend our resource attributes to the already existing key-value pairs.
            // Note: We must never free the return_buffer, or we may cause a USE_AFTER_FREE memory corruption in the
            // parent process.
            const return_buffer = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s},{s}", .{ resource_attributes, original_value }, 0) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ otel_resource_attributes_env_var_name, err });
                return original_value;
            };
            print.printMessage(modification_happened_msg, .{otel_resource_attributes_env_var_name});
            return return_buffer.ptr;
        } else {
            // Note: We must never free the return_buffer, or we may cause a USE_AFTER_FREE memory corruption in the
            // parent process.
            const return_buffer = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}", .{resource_attributes}, 0) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ otel_resource_attributes_env_var_name, err });
                return null;
            };
            print.printMessage(modification_happened_msg, .{otel_resource_attributes_env_var_name});
            return return_buffer.ptr;
        }
    } else {
        // No resource attributes to add. Return a pointer to the current value, or null if there is no current value.
        if (original_value_optional) |original_value| {
            // Note: We must never free the return_buffer, or we may cause a USE_AFTER_FREE memory corruption in the
            // parent process.
            const return_buffer = std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}", .{original_value}, 0) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ otel_resource_attributes_env_var_name, err });
                return original_value;
            };
            return return_buffer.ptr;
        } else {
            // There is no original value, and also nothing to add, return null.
            return null;
        }
    }
}

/// Maps the OTEL_INJECTOR_* environment variables to a string that can be used for the value of OTEL_RESOURCE_ATTRIBUTES or
/// -Dotel.resource.attributes (for adding to JAVA_TOOL_OPTIONS for JVMs).
///
/// Important: The caller must free the returned []u8 array, if a non-null value is returned.
pub fn getResourceAttributes() ?[]u8 {
    var final_len: usize = 0;

    for (mappings) |mapping| {
        if (std.posix.getenv(mapping.environement_variable_name)) |value| {
            if (value.len > 0) {
                if (final_len > 0) {
                    final_len += 1; // ","
                }

                if (mapping.resource_attributes_key) |attribute_key| {
                    final_len += std.fmt.count("{s}={s}", .{ attribute_key, value });
                } else {
                    final_len += value.len;
                }
            }
        }
    }

    if (final_len < 1) {
        return null;
    }

    const resource_attributes = alloc.page_allocator.alloc(u8, final_len) catch |err| {
        print.printError("Cannot allocate memory to prepare the resource attributes (len: {d}): {}", .{ final_len, err });
        return null;
    };

    var fbs = std.io.fixedBufferStream(resource_attributes);

    var is_first_token = true;
    for (mappings) |mapping| {
        const env_var_name = mapping.environement_variable_name;
        if (std.posix.getenv(env_var_name)) |value| {
            if (value.len > 0) {
                if (is_first_token) {
                    is_first_token = false;
                } else {
                    std.fmt.format(fbs.writer(), ",", .{}) catch |err| {
                        print.printError("Cannot append \",\" delimiter to resource attributes: {}", .{err});
                        return null;
                    };
                }

                if (mapping.resource_attributes_key) |attribute_key| {
                    std.fmt.format(fbs.writer(), "{s}={s}", .{ attribute_key, value }) catch |err| {
                        print.printError("Cannot append \"{s}={s}\" from env var \"{s}\" to resource attributes: {}", .{ attribute_key, value, env_var_name, err });
                        return null;
                    };
                } else {
                    std.fmt.format(fbs.writer(), "{s}", .{value}) catch |err| {
                        print.printError("Cannot append \"{s}\" from env var \"{s}\" to resource attributes: {}", .{ value, env_var_name, err });
                        return null;
                    };
                }
            }
        }
    }

    return resource_attributes;
}
