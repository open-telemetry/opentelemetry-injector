// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

pub const NullTerminatedString = [*:0]const u8;

pub const DlSymFn = *const fn (handle: ?*anyopaque, symbol: NullTerminatedString) ?*anyopaque;

pub const SetenvFnPtr = *const fn (name: NullTerminatedString, value: NullTerminatedString, overwrite: bool) c_int;

pub const EnvironPtr = *[*c][*c]const u8;

pub const LibCFlavor = enum { UNKNOWN, GNU, MUSL };

pub const LibCInfo = struct {
    flavor: LibCFlavor,
    name: []const u8,
    environ_ptr: EnvironPtr,
    setenv_fn_ptr: SetenvFnPtr,
};
