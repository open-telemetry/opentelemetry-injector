// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const print = @import("print.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

// Note on having tests embedded in the actual source files versus having them in a separate *_test.zig file: Proper
// pure unit tests are usually directly in the source file of the production function they are testing. More invasive
// tests that need to change the environment variables (for example) should go in a separate file, so we never run the
// risk of even compiling the test mechanism to modify the environment.

test "initDebugFlag: not set" {
    print._resetIsDebug();
    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);
    print.initDebugFlag();
    try testing.expect(!print.isDebug());
}

test "initDebugFlag: false" {
    print._resetIsDebug();
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_DEBUG=false"});
    defer test_util.resetStdCEnviron(original_environ);

    print.initDebugFlag();
    try testing.expect(!print.isDebug());
}

test "initDebugFlag: true" {
    print._resetIsDebug();
    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{"OTEL_INJECTOR_DEBUG=true"});
    defer test_util.resetStdCEnviron(original_environ);

    print.initDebugFlag();
    try testing.expect(print.isDebug());
}
