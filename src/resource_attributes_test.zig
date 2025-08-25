// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const alloc = @import("allocator.zig");
const res_attrs = @import("resource_attributes.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

// Note on having tests embedded in the actual source files versus having them in a separate *_test.zig file: Proper
// pure unit tests are usually directly in the source file of the production function they are testing. More invasive
// tests that need to change the environment variables (for example) should go in a separate file, so we never run the
// risk of even compiling the test mechanism to modify the environment.

test "getModifiedOtelResourceAttributesValue: no original value, no new resource attributes (null)" {
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue(null);
    try testing.expect(modified_value == null);
}

test "getModifiedOtelResourceAttributesValue: no original value, no new resource attributes (empty string)" {
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue("") orelse "-";
    try testing.expect(modified_value[0] == 0);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), only new resource attributes" {
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue(null) orelse "-";
    try testing.expectEqualStrings("k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid", std.mem.span(modified_value));
}

test "getModifiedOtelResourceAttributesValue: no original value (empty string), only new resource attributes" {
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue("") orelse "-";
    try testing.expectEqualStrings("k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid", std.mem.span(modified_value));
}

test "getModifiedOtelResourceAttributesValue: original value existss, no new resource attributes" {
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue("aaa=bbb,ccc=ddd") orelse "-";
    try testing.expectEqualStrings("aaa=bbb,ccc=ddd", std.mem.span(modified_value));
}

test "getModifiedOtelResourceAttributesValue: original value and new resource attributes" {
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = res_attrs.getModifiedOtelResourceAttributesValue("aaa=bbb,ccc=ddd") orelse "-";
    try testing.expectEqualStrings("k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid,aaa=bbb,ccc=ddd", std.mem.span(modified_value));
}

test "getResourceAttributes: empty environment" {
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        // we expect getResourceAttributes() to return null
        defer alloc.page_allocator.free(resource_attributes);
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: namespace only" {
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace"});
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings("k8s.namespace.name=namespace", resource_attributes);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: pod name only" {
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_POD_NAME=pod"});
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings("k8s.pod.name=pod", resource_attributes);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: pod uid only" {
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_POD_UID=uid"});
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings("k8s.pod.uid=uid", resource_attributes);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: container name only" {
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_CONTAINER_NAME=container"});
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings("k8s.container.name=container", resource_attributes);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: free-form resource attributes only" {
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_RESOURCE_ATTRIBUTES=aaa=bbb,ccc=ddd"});
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings("aaa=bbb,ccc=ddd", resource_attributes);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "getResourceAttributes: everything is set" {
    const original_environ = try test_util.setStdCEnviron(&[8][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
        "OTEL_INJECTOR_K8S_CONTAINER_NAME=container",
        "OTEL_INJECTOR_SERVICE_NAME=service",
        "OTEL_INJECTOR_SERVICE_VERSION=version",
        "OTEL_INJECTOR_SERVICE_NAMESPACE=servicenamespace",
        "OTEL_INJECTOR_RESOURCE_ATTRIBUTES=aaa=bbb,ccc=ddd",
    });
    defer test_util.resetStdCEnviron(original_environ);
    if (res_attrs.getResourceAttributes()) |resource_attributes| {
        defer alloc.page_allocator.free(resource_attributes);
        try testing.expectEqualStrings(
            "k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid,k8s.container.name=container,service.name=service,service.version=version,service.namespace=servicenamespace,aaa=bbb,ccc=ddd",
            resource_attributes,
        );
    } else {
        return error.TestUnexpectedResult;
    }
}
