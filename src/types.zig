// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

pub const DlSymFn = *const fn (handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

pub const GetenvFnPtr = *const fn (name: [*:0]const u8) ?[*:0]const u8;

pub const SetenvFnPtr = *const fn (name: [*:0]const u8, value: [*:0]const u8, overwrite: bool) c_int;

pub const LibCFlavor = enum { UNKNOWN, GNU, MUSL };

pub const LibCInfo = struct {
    flavor: LibCFlavor,
    getenv_fn_ptr: GetenvFnPtr,
    setenv_fn_ptr: SetenvFnPtr,
};
