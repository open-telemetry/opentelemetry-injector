// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// We need to allocate memory only to manipulate and return the few environment variables we want to modify. Unmodified
// values are returned as pointers to the original `__environ` memory.
pub const page_allocator: std.mem.Allocator = std.heap.page_allocator;
