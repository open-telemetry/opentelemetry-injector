// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

fn eqlString(a: [:0]const u8, b: [:0]const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn hashString(s: [:0]const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

pub const NullTerminatedStringContext = struct {
    pub fn hash(self: @This(), s: [:0]const u8) u64 {
        _ = self;
        return hashString(s);
    }
    pub fn eql(self: @This(), a: [:0]const u8, b: [:0]const u8) bool {
        _ = self;
        return eqlString(a, b);
    }
};

pub const NullTerminatedStringHashMap = std.HashMap([:0]const u8, [:0]const u8, NullTerminatedStringContext, std.hash_map.default_max_load_percentage);
