// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const page_allocator: std.mem.Allocator = std.heap.page_allocator;
