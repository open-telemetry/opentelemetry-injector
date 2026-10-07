// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;

const Vm = enum { hotspot, openj9 };
const max_version_length = 128;

pub const BinaryVersion = struct {
    major: ?u32,
    openj9_forwarder: bool,
};

/// Reads ELF load segments on disk, including binaries with no section table.
/// Positional reads avoid loading the VM or mapping mutable files into memory.
pub fn inspectBinary(io: std.Io, path: []const u8) !BinaryVersion {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    const header = try std.elf.Header.read(&reader.interface);

    // We check defensively for 64bit (just in case we found somehow the wrong file). We cap
    // the number of segments we scan to 128.
    if (!header.is_64 or header.phentsize != @sizeOf(std.elf.Elf64_Phdr) or header.phnum > 128) {
        return error.InvalidJvmElf;
    }

    // Check if we can read the whole program header table.
    const table_size = @as(u64, header.phnum) * header.phentsize;
    if (header.phoff > size or table_size > size - header.phoff) {
        return error.InvalidJvmElf;
    }

    var ibm_options = false;
    var jvm_selection = false;

    var headers = header.iterateProgramHeaders(&reader);

    while (try headers.next()) |segment| {
        // Skip segment we shouldn't be looking at, e.g. writeable segments that may have constants that would confuse us.
        if (segment.p_type != std.elf.PT_LOAD or segment.p_flags & std.elf.PF_R == 0 or segment.p_flags & std.elf.PF_W != 0) {
            continue;
        }

        // Check for invalid segments.
        if (segment.p_offset > size or segment.p_filesz > size - segment.p_offset) {
            return error.InvalidJvmElf;
        }

        // 32K for the chunk, 256B on top to handle overlap.
        var buffer: [32 * 1024 + 256]u8 = undefined;
        var carry: usize = 0;
        var offset = segment.p_offset;

        // Read the segment 32K at a time.
        const end = offset + segment.p_filesz;
        while (offset < end) {
            const count: usize = @intCast(@min(end - offset, 32 * 1024));
            if (try file.readPositionalAll(io, buffer[carry .. carry + count], offset) != count) {
                return error.EndOfStream;
            }

            const bytes = buffer[0 .. carry + count];
            if (scanBytes(bytes, .hotspot) orelse scanBytes(bytes, .openj9)) |major| {
                return .{ .major = major, .openj9_forwarder = false };
            }

            // OpenJ9 ships dummy libjvm.so, it's VM code (and version) is really in libj9vmNNN.so.
            // We try few symbols in the library that will speak for sure that this is J9, and then stop
            // scanning this JVM binary.
            ibm_options = ibm_options or std.mem.indexOf(u8, bytes, "IBM_JAVA_OPTIONS\x00") != null;
            jvm_selection = jvm_selection or std.mem.indexOf(u8, bytes, "-Xjvm:\x00") != null;
            if (ibm_options and jvm_selection) {
                return .{ .major = null, .openj9_forwarder = true };
            }

            // Keep enough overlap for a marker plus the maximum version length. This ensures we can handle
            // split version strings with out chunking logic.
            carry = @min(bytes.len, 256);
            std.mem.copyForwards(u8, buffer[0..carry], bytes[bytes.len - carry ..]);
            offset += count;
        }
    }

    return .{ .major = null, .openj9_forwarder = false };
}

fn scanBytes(bytes: []const u8, vm: Vm) ?u32 {
    // HotSpot embeds its complete banner in the binary. OpenJ9 on the other hand formats its banner at runtime,
    // and its code can contain labels for several Java versions, i.e. they show the VM version and the
    // java classes version. OpenJ9 builds (at least for Java 8+) have a NULL
    // terminated OpenJDK version immediately after these internal-version/OS
    // strings. This is a conservative best effort layout heuristic, not an attempt to replicate the OpenJ9 ABI.
    const marker = switch (vm) {
        .hotspot => " JRE (",
        .openj9 => "-Xinternalversion\x00linux\x00",
    };
    const terminator: u8 = switch (vm) {
        .hotspot => ')',
        .openj9 => 0,
    };

    var position: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, position, marker)) |index| {
        position = index + marker.len;
        const tail = bytes[position..];
        const bounded = tail[0..@min(tail.len, max_version_length)];
        const end = std.mem.indexOfScalar(u8, bounded, terminator) orelse continue;

        if (parseJavaMajorVersion(bounded[0..end])) |major| return major;
    }

    return null;
}

fn parseJavaMajorVersion(version: []const u8) ?u32 {
    std.debug.assert(version.len < max_version_length);
    if (version.len == 0) {
        return null;
    }

    var position: usize = 0;
    const first = readNumber(version, &position) orelse return null;

    if (first == 0) {
        return null;
    }

    var major = first;

    // Legacy versions such as 1.6.0, 1.8.0 use the second number as the Java major.
    if (first == 1) {
        if (position == version.len or version[position] != '.') {
            return null;
        }
        position += 1;

        const second = readNumber(version, &position) orelse return null;
        if (second != 0) {
            major = second;
        }
    }

    // The major must end at a version separator or the end of the string.
    if (position < version.len) {
        switch (version[position]) {
            '.', '_', '-', '+' => {},
            else => return null,
        }
    }

    return major;
}

fn readNumber(version: []const u8, position: *usize) ?u32 {
    const start = position.*;
    while (position.* < version.len and std.ascii.isDigit(version[position.*])) {
        position.* += 1;
    }

    if (position.* == start) {
        return null;
    }

    return std.fmt.parseUnsigned(u32, version[start..position.*], 10) catch null;
}

test "JVM version: extracts legacy and modern majors and rejects invalid prefixes" {
    const Case = struct { text: []const u8, major: ?u32 };
    for ([_]Case{
        .{ .text = "1.6.0_45-b06", .major = 6 },
        .{ .text = "1.7.0_80-b15", .major = 7 },
        .{ .text = "1.8.0_472-b08", .major = 8 },
        .{ .text = "1.7", .major = 7 },
        .{ .text = "9", .major = 9 },
        .{ .text = "11.0.1+13", .major = 11 },
        .{ .text = "21.0", .major = 21 },
        .{ .text = "21.0.10+7-LTS", .major = 21 },
        .{ .text = "27-ea+24", .major = 27 },
        .{ .text = "", .major = null },
        .{ .text = "0", .major = null },
        .{ .text = "1", .major = null },
        .{ .text = "1.", .major = null },
        .{ .text = "1.0.0", .major = 1 },
        .{ .text = "1.7garbage", .major = null },
        .{ .text = "21garbage", .major = null },
        // Suffixes are ignored after a separator, even when incomplete.
        .{ .text = "1.7.", .major = 7 },
        .{ .text = "1.7.0_", .major = 7 },
        .{ .text = "1.7.0_80-", .major = 7 },
        .{ .text = "7+", .major = 7 },
        .{ .text = "-7", .major = null },
        .{ .text = "7\x00junk", .major = null },
        .{ .text = "4294967296.0.1", .major = null },
        .{ .text = "1.4294967296.0", .major = null },
    }) |case| try testing.expectEqual(case.major, parseJavaMajorVersion(case.text));
}

test "JVM version: HotSpot banners from JDK 6, 8 and 21" {
    try testing.expectEqual(@as(?u32, 6), scanBytes("Java HotSpot(TM) 64-Bit Server VM (20.45-b01) for linux-amd64 JRE (1.6.0_45-b06), built on Mar 26 2013", .hotspot));
    try testing.expectEqual(@as(?u32, 8), scanBytes("OpenJDK 64-Bit Server VM (25.472-b08) for linux-amd64 JRE (1.8.0_472-b08), built on Oct 22 2025", .hotspot));
    try testing.expectEqual(@as(?u32, 21), scanBytes("OpenJDK 64-Bit Server VM (21.0.10+7-LTS) for linux-aarch64 JRE (21.0.10+7-LTS), built on 2026-01-20", .hotspot));
}

test "JVM version: OpenJ9 uses the Java build, not shared JRE labels or the VM release" {
    try testing.expectEqual(@as(?u32, 8), scanBytes("-Xinternalversion\x00linux\x001.8.0_181-b13\x00OpenJDK\x00JRE 1.6.0\x00JRE 1.8.0\x00JRE 9\x00JRE 12\x00openj9-0.9.0\x00", .openj9));
    try testing.expectEqual(@as(?u32, 21), scanBytes("-Xinternalversion\x00linux\x0021.0.9+10-LTS\x00admin\x00JRE 21\x00", .openj9));
    try testing.expectEqual(@as(?u32, null), scanBytes("JRE 1.6.0\x00JRE 1.8.0\x00openj9-0.9.0\x00", .openj9));
}

test "JVM version: skips invalid banners and returns the first valid version" {
    for ([_][]const u8{ "", "JRE (%s)", " JRE (1.6.0", " JRE (1.7garbage)", " JRE (1.7\x00)", " JRE (1.)" }) |memory| {
        try testing.expectEqual(@as(?u32, null), scanBytes(memory, .hotspot));
    }
    try testing.expectEqual(@as(?u32, null), scanBytes("-Xinternalversion\x00linux\x001.7.0", .openj9));
    try testing.expectEqual(@as(?u32, 7), scanBytes(" JRE (1.7.0)\x00 JRE (21.0.1)", .hotspot));
    try testing.expectEqual(@as(?u32, 8), scanBytes(" JRE (1.7garbage)\x00 JRE (1.8.0)\x00 JRE (21.0.1)", .hotspot));
    try testing.expectEqual(@as(?u32, 21), scanBytes("-Xinternalversion\x00linux\x00invalid\x00-Xinternalversion\x00linux\x0021.0.9+10-LTS\x00-Xinternalversion\x00linux\x001.8.0_181-b13\x00", .openj9));
}

test "JVM version: reads stripped ELF binaries and versions crossing file read boundaries" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Test normal happy path.
    const content = "x" ** (32 * 1024 - 3) ++ " JRE (1.6.0_45-b06)\x00" ++ "x" ** (32 * 1024) ++ " JRE (21.0.10+7-LTS)\x00";
    try test_util.writeElf(tmp.dir, "libjvm.so", content, std.elf.PF_R | std.elf.PF_X);

    const path = try tmp.dir.realPathFileAlloc(testing.io, "libjvm.so", testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u32, 6), (try inspectBinary(testing.io, path)).major);

    // Test without version signature
    try test_util.writeElf(tmp.dir, "libjvm.so", "no version signature", std.elf.PF_R);

    const unknown = try inspectBinary(testing.io, path);
    try testing.expectEqual(@as(?u32, null), unknown.major);
    try testing.expect(!unknown.openj9_forwarder);

    // Test proper elf, but in a writeable segment.
    try test_util.writeElf(tmp.dir, "libjvm.so", content, std.elf.PF_R | std.elf.PF_W);
    try testing.expectEqual(@as(?u32, null), (try inspectBinary(testing.io, path)).major);

    // Test bad elf header.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libjvm.so", .data = "x" ** 64 });
    try testing.expectError(error.InvalidElfMagic, inspectBinary(testing.io, path));
}
