// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const res_attrs = @import("resource_attributes.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

// Note on having tests embedded in the actual source files versus having them in a separate *_test.zig file: Proper
// pure unit tests are usually directly in the source file of the production function they are testing. More invasive
// tests that need to change the environment variables (for example) should go in a separate file, so we never run the
// risk of even compiling the test mechanism to modify the environment.

test "getModifiedOtelResourceAttributesValue: no original value, no new resource attributes (null)" {
    const allocator = testing.allocator;
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null);
    try test_util.expectWithMessage(modified_value == null, "modified_value == null");
}

test "getModifiedOtelResourceAttributesValue: no original value, no new resource attributes (empty string)" {
    const allocator = testing.allocator;
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "");
    try test_util.expectWithMessage(modified_value == null, "modified_value == null");
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: namespace only" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace"});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.namespace.name=namespace", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: pod name only" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_POD_NAME=pod"});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.pod.name=pod", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: pod uid only" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_POD_UID=uid"});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.pod.uid=uid", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: container name only" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_K8S_CONTAINER_NAME=container"});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.container.name=container", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: OTEL_INJECTOR_RESOURCE_ATTRIBUTES only" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_RESOURCE_ATTRIBUTES=aaa=bbb,ccc=ddd"});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("aaa=bbb,ccc=ddd", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), several new resource attributes" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (empty string), several new resource attributes" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "") orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid", modified_value);
}

test "getModifiedOtelResourceAttributesValue: no original value (null), new resource attributes: everything is set" {
    const allocator = testing.allocator;
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
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid,k8s.container.name=container,service.name=service,service.version=version,service.namespace=servicenamespace",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: original value exists, no new resource attributes" {
    const allocator = testing.allocator;
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "aaa=bbb,ccc=ddd");
    try test_util.expectWithMessage(modified_value == null, "modified_value == null");
}

test "getModifiedOtelResourceAttributesValue: original value and new resource attributes" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[3][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace",
        "OTEL_INJECTOR_K8S_POD_NAME=pod",
        "OTEL_INJECTOR_K8S_POD_UID=uid",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "aaa=bbb,ccc=ddd") orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace,k8s.pod.name=pod,k8s.pod.uid=uid",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: key-value pairs in original value have higher precedence than OTEL_INJECTOR_*" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[7][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace-otel-injector",
        "OTEL_INJECTOR_K8S_POD_NAME=pod-otel-injector",
        "OTEL_INJECTOR_K8S_POD_UID=uid-otel-injector",
        "OTEL_INJECTOR_K8S_CONTAINER_NAME=container-otel-injector",
        "OTEL_INJECTOR_SERVICE_NAME=service-otel-injector",
        "OTEL_INJECTOR_SERVICE_VERSION=version-otel-injector",
        "OTEL_INJECTOR_SERVICE_NAMESPACE=servicenamespace-otel-injector",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace-original,k8s.pod.name=pod-original,service.name=service-original,service.version=version-original,service.namespace=servicenamespace-original") orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace-original,k8s.pod.name=pod-original,service.name=service-original,service.version=version-original,service.namespace=servicenamespace-original,k8s.pod.uid=uid-otel-injector,k8s.container.name=container-otel-injector",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: key-value pairs in original value have higher precedence than OTEL_INJECTOR_RESOURCE_ATTRIBUTES" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_RESOURCE_ATTRIBUTES=k8s.namespace.name=namespace-otel-injector,k8s.pod.name=pod-otel-injector,service.name=service-otel-injector,k8s.pod.uid=uid-otel-injector,k8s.container.name=container-otel-injector",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace-original,k8s.pod.name=pod-original,service.name=service-original,service.version=version-original,service.namespace=servicenamespace-original") orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "aaa=bbb,ccc=ddd,k8s.namespace.name=namespace-original,k8s.pod.name=pod-original,service.name=service-original,service.version=version-original,service.namespace=servicenamespace-original,k8s.pod.uid=uid-otel-injector,k8s.container.name=container-otel-injector",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: OTEL_INJECTOR_RESOURCE_ATTRIBUTES key-value pairs have higher precedence than other OTEL_INJECTOR_* attributes" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[8][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_POD_NAME=pod-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_POD_UID=uid-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_CONTAINER_NAME=container-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_RESOURCE_ATTRIBUTES=k8s.namespace.name=namespace-from-otel-injector-resource-attributes,k8s.pod.name=pod-from-otel-injector-resource-attributes,service.name=service-from-otel-injector-resource-attributes,k8s.pod.uid=uid-from-otel-injector-resource-attributes,k8s.container.name=container-from-otel-injector-resource-attributes",
        "OTEL_INJECTOR_SERVICE_NAME=service-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_SERVICE_VERSION=version-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_SERVICE_NAMESPACE=servicenamespace-from-otel-injector_*-env-var",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "k8s.namespace.name=namespace-from-otel-injector-resource-attributes,k8s.pod.name=pod-from-otel-injector-resource-attributes,service.name=service-from-otel-injector-resource-attributes,k8s.pod.uid=uid-from-otel-injector-resource-attributes,k8s.container.name=container-from-otel-injector-resource-attributes,service.version=version-from-otel-injector_*-env-var,service.namespace=servicenamespace-from-otel-injector_*-env-var",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: mixing key-value pairs from the original value, OTEL_INJECTOR_RESOURCE_ATTRIBUTES and OTEL_INJECTOR_*" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[8][]const u8{
        "OTEL_INJECTOR_K8S_NAMESPACE_NAME=namespace-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_POD_NAME=pod-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_POD_UID=uid-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_K8S_CONTAINER_NAME=container-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_RESOURCE_ATTRIBUTES=k8s.namespace.name=namespace-from-otel-injector-resource-attributes,service.name=service-from-otel-injector-resource-attributes,k8s.pod.name=pod-from-otel-injector-resource-attributes",
        "OTEL_INJECTOR_SERVICE_NAME=service-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_SERVICE_VERSION=version-from-otel-injector_*-env-var",
        "OTEL_INJECTOR_SERVICE_NAMESPACE=servicenamespace-from-otel-injector_*-env-var",
    });
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, "k8s.namespace.name=namespace-original,service.name=service-original") orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings(
        "k8s.namespace.name=namespace-original,service.name=service-original,k8s.pod.name=pod-from-otel-injector-resource-attributes,k8s.pod.uid=uid-from-otel-injector_*-env-var,k8s.container.name=container-from-otel-injector_*-env-var,service.version=version-from-otel-injector_*-env-var,service.namespace=servicenamespace-from-otel-injector_*-env-var",
        modified_value,
    );
}

test "getModifiedOtelResourceAttributesValue: trims keys and drops empty OTEL_INJECTOR_RESOURCE_ATTRIBUTES key-value pairs" {
    const allocator = testing.allocator;
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_RESOURCE_ATTRIBUTES=aaa=bbb,,  ccc=ddd,  , eee = fff "});
    defer test_util.resetStdCEnviron(original_environ);
    const modified_value = try res_attrs.getModifiedOtelResourceAttributesValue(allocator, null) orelse return error.Unexpected;
    defer allocator.free(modified_value);
    try testing.expectEqualStrings("aaa=bbb,ccc=ddd,eee= fff ", modified_value);
}
