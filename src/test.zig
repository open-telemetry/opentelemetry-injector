// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// All files with unit tests need to be referenced here:
pub const arg_parser = @import("args_parser.zig");
pub const config = @import("config.zig");
pub const dotnet = @import("dotnet.zig");
pub const libc = @import("libc.zig");
pub const jvm = @import("jvm.zig");
pub const nodejs = @import("nodejs.zig");
pub const patterns_matcher = @import("patterns_matcher.zig");
pub const patterns_util = @import("patterns_util.zig");
pub const print = @import("print.zig");
pub const res_attrs_test = @import("resource_attributes_test.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
