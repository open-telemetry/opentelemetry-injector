// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;

const max_version_length = 128;
const hotspot_version_marker = " JRE (";
const openj9_version_marker = "-Xinternalversion\x00";
const zing_version_marker = "-zing_";
// OpenJ9 ships a dummy libjvm.so that forwards to its VM in libj9vmNNN.so. These two strings identify it.
const openj9_options_marker = "IBM_JAVA_OPTIONS\x00";
const openj9_vm_selection_marker = "-Xjvm:\x00";
const max_openj9_prefix_length = 128;
const scan_overlap = openj9_version_marker.len + max_openj9_prefix_length + max_version_length;

pub const BinaryVersion = struct {
    major: ?u32,
    openj9_forwarder: bool,
};

/// Reports whether `path` is a regular file, so that callers can refuse to open anything else.
///
/// Opening a named pipe blocks until a writer appears, and every file this module and the launcher detection read
/// is opened from the constructor, before the application's main runs. A pipe planted anywhere we look would
/// therefore hang the process at startup, and no read limit bounds that wait: the limit caps how much is read, not
/// how long the open takes. The path can in principle be swapped between this check and the open that follows, but
/// anyone able to do that inside a Java home can also replace libjvm.so itself, so the window buys them nothing.
pub fn isRegularFile(io: std.Io, path: []const u8) bool {
    const file_stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return file_stat.kind == .file;
}

/// Reads ELF load segments on disk, including binaries with no section table.
/// Positional reads avoid loading the VM or mapping mutable files into memory.
pub fn inspectBinary(io: std.Io, path: []const u8) !BinaryVersion {
    if (!isRegularFile(io, path)) {
        return error.NotARegularFile;
    }

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    const header = try std.elf.Header.read(&reader.interface);

    // We check defensively for 64bit (just in case we found somehow the wrong file). We cap
    // the number of segments we scan to 128.
    if (!header.is_64 or header.phentsize != @sizeOf(std.elf.Elf64.Phdr) or header.phnum > 128) {
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
        if (segment.type != .LOAD or !segment.flags.R or segment.flags.W) {
            continue;
        }

        // Check for invalid segments.
        if (segment.offset > size or segment.filesz > size - segment.offset) {
            return error.InvalidJvmElf;
        }

        // Keep the OpenJ9 marker, intervening strings, and version together across reads.
        var buffer: [32 * 1024 + scan_overlap]u8 = undefined;
        var carry: usize = 0;
        var offset = segment.offset;

        // Read the segment 32K at a time.
        const end = offset + segment.filesz;
        while (offset < end) {
            const count: usize = @intCast(@min(end - offset, 32 * 1024));
            if (try file.readPositionalAll(io, buffer[carry .. carry + count], offset) != count) {
                return error.EndOfStream;
            }

            const bytes = buffer[0 .. carry + count];
            const scan = scanChunk(bytes);
            if (scan.major) |major| {
                return .{ .major = major, .openj9_forwarder = false };
            }

            // OpenJ9 ships dummy libjvm.so, it's VM code (and version) is really in libj9vmNNN.so.
            // We try few symbols in the library that will speak for sure that this is J9, and then stop
            // scanning this JVM binary.
            ibm_options = ibm_options or scan.ibm_options;
            jvm_selection = jvm_selection or scan.jvm_selection;
            if (ibm_options and jvm_selection) {
                return .{ .major = null, .openj9_forwarder = true };
            }

            // Preserve the marker, intervening OpenJ9 strings, and version across reads.
            carry = @min(bytes.len, scan_overlap);
            std.mem.copyForwards(u8, buffer[0..carry], bytes[bytes.len - carry ..]);
            offset += count;
        }
    }

    return .{ .major = null, .openj9_forwarder = false };
}

const ChunkScan = struct {
    major: ?u32 = null,
    ibm_options: bool = false,
    jvm_selection: bool = false,
};

/// Looks for every marker in a single pass over `bytes`, instead of searching it once per marker: on a runtime
/// without a release file, this runs over tens of megabytes before the application's main. The pass stops at the
/// first version that parses, so the OpenJ9 forwarder markers are only complete for a chunk without one.
fn scanChunk(bytes: []const u8) ChunkScan {
    var scan: ChunkScan = .{};
    var candidates: MarkerCandidates = .{ .bytes = bytes };

    while (candidates.next()) |index| {
        const rest = bytes[index..];
        const major = if (std.mem.startsWith(u8, rest, hotspot_version_marker))
            hotSpotVersionAt(bytes, index)
        else if (std.mem.startsWith(u8, rest, openj9_version_marker))
            openJ9VersionAt(bytes, index)
        else if (std.mem.startsWith(u8, rest, zing_version_marker))
            zingVersionAt(bytes, index)
        else blk: {
            scan.ibm_options = scan.ibm_options or std.mem.startsWith(u8, rest, openj9_options_marker);
            scan.jvm_selection = scan.jvm_selection or std.mem.startsWith(u8, rest, openj9_vm_selection_marker);
            break :blk null;
        };

        if (major) |found| {
            scan.major = found;
            return scan;
        }
    }

    return scan;
}

/// Returns every position in `bytes` where a VM version marker can start. Each marker begins with one of
/// `marker_starts`, and a whole block of positions is compared against those byte pairs at once. Pairs are rare
/// enough, even in machine code full of spaces and dashes, that checking the positions that match costs little.
const MarkerCandidates = struct {
    bytes: []const u8,
    position: usize = 0,
    block_start: usize = 0,
    pending: Mask = 0,

    const block_length = std.simd.suggestVectorLength(u8) orelse 16;
    const Block = @Vector(block_length, u8);
    const Mask = @Int(.unsigned, block_length);

    const marker_starts = [_]*const [2]u8{
        hotspot_version_marker[0..2],
        openj9_version_marker[0..2],
        zing_version_marker[0..2],
        openj9_options_marker[0..2],
        openj9_vm_selection_marker[0..2],
    };

    fn next(self: *MarkerCandidates) ?usize {
        while (self.pending == 0) {
            // A block needs the byte after it too, to see a pair that starts on its last position.
            if (self.position + block_length + 1 > self.bytes.len) {
                return self.nextInTail();
            }
            self.block_start = self.position;
            self.pending = startsInBlock(self.bytes[self.position..][0 .. block_length + 1]);
            self.position += block_length;
        }

        const offset = @ctz(self.pending);
        self.pending &= self.pending - 1;
        return self.block_start + offset;
    }

    fn nextInTail(self: *MarkerCandidates) ?usize {
        while (self.position + 1 < self.bytes.len) {
            const index = self.position;
            self.position += 1;
            inline for (marker_starts) |start| {
                if (self.bytes[index] == start[0] and self.bytes[index + 1] == start[1]) return index;
            }
        }
        return null;
    }

    fn startsInBlock(window: *const [block_length + 1]u8) Mask {
        const first: Block = window[0..block_length].*;
        const second: Block = window[1..].*;
        var matches: @Vector(block_length, bool) = @splat(false);
        inline for (marker_starts) |start| {
            matches = matches | ((first == @as(Block, @splat(start[0]))) & (second == @as(Block, @splat(start[1]))));
        }
        return @bitCast(matches);
    }
};

fn hotSpotVersionAt(bytes: []const u8, index: usize) ?u32 {
    // HotSpot, including GraalVM's JVM, embeds its complete banner in the binary.
    return parseTerminatedVersion(bytes[index + hotspot_version_marker.len ..], ')');
}

fn openJ9VersionAt(bytes: []const u8, index: usize) ?u32 {
    // OpenJ9 formats its banner at runtime. Its Java version follows the
    // internal-version and OS strings, with intervening labels and NULL padding
    // on ARM. This observed layout is a best effort heuristic.
    const os_marker = "\x00linux\x00";

    // Include the marker's final NULL so linux must begin at a string boundary.
    const tail = bytes[index + openj9_version_marker.len - 1 ..];
    const prefix = tail[0..@min(tail.len, max_openj9_prefix_length)];
    const os_index = std.mem.indexOf(u8, prefix, os_marker) orelse return null;

    var version_start = os_index + os_marker.len;
    while (version_start < prefix.len and prefix[version_start] == 0) {
        version_start += 1;
    }

    if (version_start == prefix.len) return null;

    return parseTerminatedVersion(tail[version_start..], 0);
}

fn zingVersionAt(bytes: []const u8, index: usize) ?u32 {
    // Zing has NULL delimited string like this: "1.8.0_481-zing_26.01.0.0-b11".
    // The Java version comes before "-zing_", the numbers after it identify the Zing product release.
    const previous_terminator = std.mem.lastIndexOfScalar(u8, bytes[0..index], 0) orelse return null;
    return parseTerminatedVersion(bytes[previous_terminator + 1 ..], 0);
}

fn parseTerminatedVersion(bytes: []const u8, terminator: u8) ?u32 {
    const bounded = bytes[0..@min(bytes.len, max_version_length)];
    const end = std.mem.indexOfScalar(u8, bounded, terminator) orelse return null;
    return parseJavaMajorVersion(bounded[0..end]);
}

pub fn parseJavaMajorVersion(version: []const u8) ?u32 {
    // Callers scanning binaries bound their slices before getting here, but the release file parser hands over
    // whatever the file holds, so reject anything longer than a version string can plausibly be.
    if (version.len == 0 or version.len >= max_version_length) {
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

test "JVM version: HotSpot and GraalVM banners from JDK 6, 8 and 21" {
    try testing.expectEqual(@as(?u32, 6), scanChunk("Java HotSpot(TM) 64-Bit Server VM (20.45-b01) for linux-amd64 JRE (1.6.0_45-b06), built on Mar 26 2013").major);
    try testing.expectEqual(@as(?u32, 8), scanChunk("OpenJDK 64-Bit Server VM (25.472-b08) for linux-amd64 JRE (1.8.0_472-b08), built on Oct 22 2025").major);
    try testing.expectEqual(@as(?u32, 21), scanChunk("OpenJDK 64-Bit Server VM (21.0.10+7-LTS) for linux-aarch64 JRE (21.0.10+7-LTS), built on 2026-01-20").major);

    const graalvm_banner = "OpenJDK 64-Bit Server VM (21.0.2+13-jvmci-23.1-b30) " ++
        "for linux-amd64 JRE (21.0.2+13-jvmci-23.1-b30), built on 2024-01-06T13:12:14Z";
    try testing.expectEqual(@as(?u32, 21), scanChunk(graalvm_banner).major);
}

test "JVM version: Zing uses the Java major rather than the product release" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    const binary = try std.fs.path.join(testing.allocator, &.{ path, "libjvm.so" });
    defer testing.allocator.free(binary);

    const Case = struct { version: []const u8, major: u32 };
    for ([_]Case{
        .{ .version = "1.8.0_481-zing_26.01.0.0-b11\x00", .major = 8 },
        .{ .version = "21.0.9.0.101-zing_26.01.0.0-b11\x00", .major = 21 },
    }) |case| {
        const content = try std.mem.concat(testing.allocator, u8, &.{ "26.01.0.0\x00", case.version });
        defer testing.allocator.free(content);

        try test_util.writeElf(tmp.dir, "libjvm.so", content, std.elf.PF_R);
        try testing.expectEqual(@as(?u32, case.major), (try inspectBinary(testing.io, binary)).major);
    }
}

test "JVM version: Zing requires a complete version string and skips format placeholders" {
    const test_util = @import("test_util.zig");

    for ([_][]const u8{
        "",
        "\x0026.01.0.0\x00",
        "\x00%s-zing_%s\x00",
        "\x00-zing_26.01.0.0-b11\x00",
        "\x0021garbage-zing_26.01.0.0-b11\x00",
        "\x0021.0.9-zing_26.01.0.0-b11",
        "21.0.9-zing_26.01.0.0-b11\x00",
        "\x0021." ++ test_util.repeat('0', max_version_length) ++ "-zing_26.01.0.0-b11\x00",
    }) |bytes| {
        try testing.expectEqual(@as(?u32, null), scanChunk(bytes).major);
    }

    const content = "\x00%s-zing_%s\x00" ++
        "21.0.9.0.101-zing_26.01.0.0-b11\x00" ++
        "1.8.0_481-zing_26.01.0.0-b11\x00";

    try testing.expectEqual(@as(?u32, 21), scanChunk(content).major);
}

test "JVM version: OpenJ9 uses the Java build, not shared JRE labels or the VM release" {
    try testing.expectEqual(@as(?u32, 8), scanChunk("-Xinternalversion\x00linux\x001.8.0_181-b13\x00OpenJDK\x00JRE 1.6.0\x00JRE 1.8.0\x00JRE 9\x00JRE 12\x00openj9-0.9.0\x00").major);
    try testing.expectEqual(@as(?u32, 21), scanChunk("-Xinternalversion\x00linux\x0021.0.9+10-LTS\x00admin\x00JRE 21\x00").major);
    try testing.expectEqual(@as(?u32, null), scanChunk("JRE 1.6.0\x00JRE 1.8.0\x00openj9-0.9.0\x00").major);
}

test "JVM version: OpenJ9 ARM version strings allow labels and NULL padding" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Captured from the ARM Semeru Java 21 image used in CI.
    const arm_version = "-Xinternalversion\x00" ++ test_util.repeat('\x00', 7) ++
        "Extensions for OpenJDK for Eclipse OpenJ9" ++ test_util.repeat('\x00', 7) ++
        "aarch64\x00linux\x00" ++ test_util.repeat('\x00', 2) ++
        "21.0.12.1+1-LTS\x00IBM Semeru Runtime Open Edition\x00";

    // Exercise the maximum supported prefix and version across a read boundary.
    const prefix_padding = max_openj9_prefix_length - "\x00linux\x00".len - 1;
    const long_version = openj9_version_marker ++ "linux\x00" ++ test_util.repeat('\x00', prefix_padding) ++
        "21." ++ test_util.repeat('0', max_version_length - 4) ++ "\x00";
    const split_long_version = test_util.repeat('x', 32 * 1024 - long_version.len + 1) ++ long_version;
    try test_util.writeElf(tmp.dir, "libj9vm29.so", arm_version, std.elf.PF_R | std.elf.PF_X);

    const path = try tmp.dir.realPathFileAlloc(testing.io, "libj9vm29.so", testing.allocator);
    defer testing.allocator.free(path);

    for ([_][]const u8{
        arm_version,
        test_util.repeat('x', 32 * 1024 - 3) ++ arm_version,
        split_long_version,
    }) |content| {
        try test_util.writeElf(tmp.dir, "libj9vm29.so", content, std.elf.PF_R | std.elf.PF_X);
        const result = try inspectBinary(testing.io, path);
        try testing.expectEqual(@as(?u32, 21), result.major);
        try testing.expect(!result.openj9_forwarder);
    }
}

test "JVM version: OpenJ9 requires a bounded prefix and a complete Linux string" {
    const test_util = @import("test_util.zig");

    for ([_][]const u8{
        "-Xinternalversion\x00not-linux\x0021.0.12.1+1-LTS\x00",
        "-Xinternalversion\x00linux-other\x0021.0.12.1+1-LTS\x00",
        "-Xinternalversion\x00" ++ test_util.repeat('\x00', max_openj9_prefix_length) ++ "linux\x0021.0.12.1+1-LTS\x00",
        "-Xinternalversion\x00linux\x00" ++ test_util.repeat('\x00', max_openj9_prefix_length) ++ "21.0.12.1+1-LTS\x00",
    }) |bytes| {
        try testing.expectEqual(@as(?u32, null), scanChunk(bytes).major);
    }
}

test "JVM version: skips invalid banners and returns the first valid version" {
    for ([_][]const u8{ "", "JRE (%s)", " JRE (1.6.0", " JRE (1.7garbage)", " JRE (1.7\x00)", " JRE (1.)" }) |memory| {
        try testing.expectEqual(@as(?u32, null), scanChunk(memory).major);
    }
    try testing.expectEqual(@as(?u32, null), scanChunk("-Xinternalversion\x00linux\x001.7.0").major);
    try testing.expectEqual(@as(?u32, 7), scanChunk(" JRE (1.7.0)\x00 JRE (21.0.1)").major);
    try testing.expectEqual(@as(?u32, 8), scanChunk(" JRE (1.7garbage)\x00 JRE (1.8.0)\x00 JRE (21.0.1)").major);
    try testing.expectEqual(@as(?u32, 21), scanChunk("-Xinternalversion\x00linux\x00invalid\x00-Xinternalversion\x00linux\x0021.0.9+10-LTS\x00-Xinternalversion\x00linux\x001.8.0_181-b13\x00").major);
}

test "JVM version: reads stripped ELF binaries and versions crossing file read boundaries" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Test normal happy path.
    const content = test_util.repeat('x', 32 * 1024 - 3) ++ " JRE (1.6.0_45-b06)\x00" ++ test_util.repeat('x', 32 * 1024) ++ " JRE (21.0.10+7-LTS)\x00";
    try test_util.writeElf(tmp.dir, "libjvm.so", content, std.elf.PF_R | std.elf.PF_X);

    const path = try tmp.dir.realPathFileAlloc(testing.io, "libjvm.so", testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u32, 6), (try inspectBinary(testing.io, path)).major);

    const zing = test_util.repeat('x', 32 * 1024 - 16) ++ "\x0021.0.9.0.101-zing_26.01.0.0-b11\x00";
    try test_util.writeElf(tmp.dir, "libjvm.so", zing, std.elf.PF_R | std.elf.PF_X);
    try testing.expectEqual(@as(?u32, 21), (try inspectBinary(testing.io, path)).major);

    try test_util.writeElf(tmp.dir, "libjvm.so", zing, std.elf.PF_R | std.elf.PF_W);
    try testing.expectEqual(@as(?u32, null), (try inspectBinary(testing.io, path)).major);

    // Test without version signature
    try test_util.writeElf(tmp.dir, "libjvm.so", "no version signature", std.elf.PF_R);

    const unknown = try inspectBinary(testing.io, path);
    try testing.expectEqual(@as(?u32, null), unknown.major);
    try testing.expect(!unknown.openj9_forwarder);

    // Test proper elf, but in a writeable segment.
    try test_util.writeElf(tmp.dir, "libjvm.so", content, std.elf.PF_R | std.elf.PF_W);
    try testing.expectEqual(@as(?u32, null), (try inspectBinary(testing.io, path)).major);

    // Test bad elf header.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libjvm.so", .data = test_util.repeat('x', 64) });
    try testing.expectError(error.InvalidElfMagic, inspectBinary(testing.io, path));
}

test "JVM version: finds every marker wherever it falls in the chunk" {
    // The pass compares whole blocks of positions at once and finishes the chunk byte by byte, so place each marker
    // at every offset across a few blocks: straddling a block boundary, in the tail, and right at the end.
    const Case = struct { text: []const u8, major: ?u32 };
    const cases = [_]Case{
        .{ .text = " JRE (21.0.10+7-LTS)", .major = 21 },
        .{ .text = "-Xinternalversion\x00linux\x0021.0.9+10-LTS\x00", .major = 21 },
        .{ .text = "\x0021.0.9.0.101-zing_26.01.0.0-b11\x00", .major = 21 },
        .{ .text = "IBM_JAVA_OPTIONS\x00-Xjvm:\x00", .major = null },
    };

    for (cases) |case| {
        for (0..3 * MarkerCandidates.block_length) |offset| {
            for ([_]usize{ 0, 1, MarkerCandidates.block_length }) |trailing| {
                const bytes = try testing.allocator.alloc(u8, offset + case.text.len + trailing);
                defer testing.allocator.free(bytes);
                // Near misses for every marker's first two bytes, so that only a full match counts.
                for (bytes, 0..) |*byte, index| byte.* = " j-xIb"[index % 6];
                @memcpy(bytes[offset..][0..case.text.len], case.text);

                const scan = scanChunk(bytes);
                try testing.expectEqual(case.major, scan.major);
                try testing.expectEqual(case.major == null, scan.ibm_options and scan.jvm_selection);
            }
        }
    }
}

test "JVM version: the first valid version in a chunk wins, whichever VM it belongs to" {
    // The same rule holds across chunks, where the first one with a version answers, so a chunk follows it too.
    try testing.expectEqual(@as(?u32, 8), scanChunk("\x001.8.0_481-zing_26.01.0.0-b11\x00 JRE (21.0.1)").major);
    try testing.expectEqual(@as(?u32, 21), scanChunk(" JRE (21.0.1)\x001.8.0_481-zing_26.01.0.0-b11\x00").major);
}

// mkfifo is not in the Zig standard library; the tests link libc, so it is declared here for the one test below.
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "JVM version: refuses to inspect anything that is not a regular file" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);

    const fifo_path = try std.fs.path.joinZ(testing.allocator, &.{ directory, "libjvm.so" });
    defer testing.allocator.free(fifo_path);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo_path.ptr, 0o600));

    // Only the predicate is exercised on the pipe: stat never blocks, while an open would wait for a writer that
    // never comes, so calling inspectBinary here would hang the test suite instead of failing it if the guard
    // ever went away. The directory below stands in for that assertion, since opening one fails fast.
    try testing.expect(!isRegularFile(testing.io, fifo_path));

    try testing.expect(!isRegularFile(testing.io, directory));
    try testing.expectError(error.NotARegularFile, inspectBinary(testing.io, directory));
    try testing.expect(!isRegularFile(testing.io, "/does/not/exist"));

    try test_util.writeElf(tmp.dir, "regular.so", " JRE (21.0.10+7-LTS)\x00", std.elf.PF_R);
    const regular_path = try tmp.dir.realPathFileAlloc(testing.io, "regular.so", testing.allocator);
    defer testing.allocator.free(regular_path);
    try testing.expect(isRegularFile(testing.io, regular_path));
}
