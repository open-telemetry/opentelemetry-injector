// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// All files with unit tests need to be referenced here:
pub const arg_parser = @import("args_parser.zig");
pub const config = @import("config.zig");
pub const dotnet = @import("dotnet.zig");
pub const jvm = @import("jvm.zig");
pub const node_js = @import("node_js.zig");
pub const patterns_matcher = @import("patterns_matcher.zig");
pub const patterns_util = @import("patterns_util.zig");
pub const print_test_ = @import("print_test.zig");
pub const res_attrs_test = @import("resource_attributes_test.zig");

// Provide a C-style `char **environ` variable to the linker, to satisfy the
//   extern var __environ: [*]u8;
// declaration in `root.zig`.
var ___environ: [100]u8 = [_]u8{0} ** 100;
const ___environ_ptr: *[100]u8 = &___environ;
export var __environ: [*]u8 = ___environ_ptr;

test {
    @import("std").testing.refAllDecls(@This());
}
