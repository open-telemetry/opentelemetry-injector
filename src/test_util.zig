// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// **Note: This file must only be imported from *_test.zig files, never from actual production code zig files.**

const std = @import("std");
const types = @import("types.zig");

const _print = @import("print.zig");

const testing = std.testing;
// An allocator just for clearStdCEnviron/setStdCEnviron. Since this is never part of production code but only used in
// tests, it is not a concern whether we leak memory in these two helper functions, so there is no need to use
// std.test.allocator here.
const environ_allocator = std.heap.page_allocator;

/// Clears all entries from std.c.environ, i.e. all environment variables are discarded. The original content before
/// making any changes is returned. The caller is expected to reset std.c.environ to the return value of this function
/// when the test is done, for example by calling `defer resetStdCEnviron(original_environ);` directly after calling
/// this function (where original_environ is the return value of this function).
pub fn clearStdCEnviron() anyerror![*:null]?[*:0]u8 {
    const original_environ = std.c.environ;
    const new_environ = try environ_allocator.allocSentinel(?[*:0]u8, 0, null);
    std.c.environ = new_environ;
    return original_environ;
}

/// Sets the given key-value pairs as the only content of std.c.environ. Everything else in std.c.environ is discarded.
/// The original content before making any changes is returned. The caller is expected to reset std.c.environ to
/// the return value of this function when the test is done, for example by calling
/// `defer resetStdCEnviron(original_environ);` directly after calling this function (where original_environ is the
/// return value of this function).
pub fn setStdCEnviron(env_vars: []const []const u8) anyerror![*:null]?[*:0]u8 {
    const original_environ = std.c.environ;

    // Tests read environment variables via cEnvironGet, which scans std.c.environ. Hence, for tests that require
    // certain environment variables to be set, we mess around with std.c.environ.
    const new_environ = try environ_allocator.allocSentinel(?[*:0]u8, env_vars.len, null);
    for (env_vars, 0..) |env_var, i| {
        new_environ[i] = try std.fmt.allocPrintSentinel(
            environ_allocator,
            "{s}",
            .{env_var},
            0,
        );
    }
    std.c.environ = new_environ;

    return original_environ;
}

/// Resets std.c.environ to the given value. This function is meant to be used after doing clearStdCEnviron or
/// setStdCEnviron earlier, to restore the original environment after the test is done.
pub fn resetStdCEnviron(original_environ: [*:null]?[*:0]u8) void {
    std.c.environ = original_environ;
}

/// Looks up an environment variable in std.c.environ, which tests manipulate via setStdCEnviron/clearStdCEnviron.
pub fn cEnvironGet(name: []const u8) ?[:0]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry_ptr| : (i += 1) {
        const entry = std.mem.span(entry_ptr);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

/// A GetenvFn-compatible wrapper around cEnvironGet for use in tests.
pub fn posixGetenv(_: std.Io, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const val = cEnvironGet(name) orelse return null;
    return allocator.dupe(u8, val) catch unreachable;
}

/// A GetenvFnPtr-compatible wrapper around cEnvironGet for use in tests.
pub fn testGetenvFnPtr(name: [*:0]const u8) ?[*:0]const u8 {
    const val = cEnvironGet(std.mem.span(name)) orelse return null;
    return val.ptr;
}

fn testNoopSetenvFnPtr(name: [*:0]const u8, value: [*:0]const u8, overwrite: bool) c_int {
    _ = name;
    _ = value;
    _ = overwrite;
    return 0;
}

/// Returns a LibCInfo suitable for unit tests. The setenv function pointer is a no-op
/// since tests that use this helper do not exercise the actual setenv path.
pub fn testLibcInfo(flavor: types.LibCFlavor) types.LibCInfo {
    return .{
        .flavor = flavor,
        .getenv_fn_ptr = testGetenvFnPtr,
        .setenv_fn_ptr = testNoopSetenvFnPtr,
    };
}

/// An extended version of std.testing.expect that prints a message in case of failure. Useful for tests that have
/// multiple expects; this version should generally be used in favor of the original std.testing.expect function.
pub fn expectWithMessage(
    ok: bool,
    comptime message: []const u8,
) !void {
    if (!ok) {
        print("\n====== assertion failed: =========\n", .{});
        print(message, .{});
        print("\n==================================\n", .{});
        return error.TestUnexpectedResult;
    }
}

pub fn expectStringStartAndEnd(actual: []const u8, prefix: []const u8, suffix: []const u8) !void {
    try testing.expectStringStartsWith(actual, prefix);
    try testing.expectStringEndsWith(actual, suffix);
}

pub fn expectStringContains(actual: []const u8, expected_needle: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_needle) != null) {
        return;
    }
    print("\n====== expected to contain: =========\n", .{});
    printWithVisibleNewlines(expected_needle);
    print("\n========= full output: ==============\n", .{});
    printWithVisibleNewlines(actual);
    print("\n======================================\n", .{});

    return error.TestExpectedContains;
}

pub inline fn expectMemoryRangeLimit(expected: comptime_int, actual: anytype) !void {
    testing.expectEqual(expected, @intFromPtr(actual)) catch |err| {
        std.debug.print("expected memory range limit {x:0>8}, found {x:0>8}\n", .{ expected, @intFromPtr(actual) });
        return err;
    };
}

// Copied from Zig's std.testing module.
fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (testing.backend_can_print) {
        std.debug.print(fmt, args);
    }
}

// Copied from Zig's std.testing module.
fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i..][0..nl]);
    }
    print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}

// Copied from Zig's std.testing module.
fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    print("{s}\n", .{line});
}

/// A comptime string made of `count` copies of `byte`, for padding test fixtures.
/// Zig 0.17 no longer has the `**` array repeat operator.
pub fn repeat(comptime byte: u8, comptime count: usize) *const [count]u8 {
    const bytes: [count]u8 = @splat(byte);
    return &bytes;
}

/// A small ELF64 VM fixture without section headers. Tests use real program
/// headers so they exercise the same file scanning as installed JVM binaries.
pub fn writeElf(dir: std.Io.Dir, path: []const u8, content: []const u8, flags: u32) !void {
    var header = std.mem.zeroes(std.elf.Elf64_Ehdr);
    header.e_ident[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    header.e_ident[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    header.e_ident[std.elf.EI.DATA] = if (@import("builtin").cpu.arch.endian() == .little) std.elf.ELFDATA2LSB else std.elf.ELFDATA2MSB;
    header.e_ident[std.elf.EI.VERSION] = 1;
    header.e_type = .DYN;
    header.e_machine = .X86_64;
    header.e_version = 1;
    header.e_ehsize = @sizeOf(std.elf.Elf64_Ehdr);
    header.e_phoff = @sizeOf(std.elf.Elf64_Ehdr);
    header.e_phentsize = @sizeOf(std.elf.Elf64.Phdr);
    header.e_phnum = 1;
    var segment = std.mem.zeroes(std.elf.Elf64.Phdr);
    segment.type = .LOAD;
    segment.flags = @bitCast(flags);
    segment.offset = @sizeOf(std.elf.Elf64_Ehdr) + @sizeOf(std.elf.Elf64.Phdr);
    segment.filesz = content.len;
    segment.memsz = content.len;
    const file = try dir.createFile(testing.io, path, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, std.mem.asBytes(&header));
    try file.writeStreamingAll(testing.io, std.mem.asBytes(&segment));
    try file.writeStreamingAll(testing.io, content);
}

/// A minimal, synthetic in-memory image of a dynamically linked ELF executable: program headers, a dynamic section, a
/// hash table (DT_HASH or DT_GNU_HASH), a symbol table and a string table. It stands in for the main executable of a
/// process, as elf.ElfDynLib.openMainExecutable sees it, without the need for a real executable.
///
/// The image can be initialized at any address, also at one that does not have the natural alignment of the ELF
/// structures (see init), to imitate executables that have been rewritten after linking, for example by postject.
pub const ElfTestImage = extern struct {
    program_headers: [2]std.elf.Elf64.Phdr,
    dynamic: [6]std.elf.Elf64_Dyn,
    // DT_HASH: nbucket, nchain. The symbol lookup only uses nchain, which is the number of symbols.
    hash: [2]u32,
    // DT_GNU_HASH: the header (nbuckets, symoffset, bloom_size, bloom_shift), one 64 bit bloom filter word, one bucket
    // and one chain entry, for the one symbol after the null symbol.
    gnu_hash: [8]u32,
    symbols: [2]std.elf.Elf64_Sym,
    strings: [128]u8,

    pub const exported_symbol_value = 0x1234;

    pub const Options = struct {
        /// With relocated set, the image is a position-independent executable whose load bias is its own address, and
        /// it says so via PT_PHDR. Without it, it is a non-relocatable executable (ET_EXEC): its virtual addresses are
        /// absolute and it has no PT_PHDR.
        relocated: bool = true,
        /// Whether the address entries in the dynamic section have already been relocated (as glibc does in the
        /// loaded image) or are left as plain virtual addresses (as musl does).
        absolute_dynamic_entries: bool = true,
        /// The name of the one defined symbol in the symbol table, if any.
        exported_symbol: ?[]const u8 = null,
        /// The name of the one DT_NEEDED entry, if any.
        needed_library: ?[]const u8 = null,
        /// Which hash table the dynamic section refers to. Only one of them is referred to, so that symbol lookups
        /// are guaranteed to go through it.
        hash_table: enum { sysv, gnu } = .sysv,
    };

    /// Initializes the image at the address of self. All addresses in the image are derived from it, so the image is
    /// valid at any address, also at one that is not aligned (pass a pointer into a byte buffer at an odd offset).
    pub fn init(self: *align(1) ElfTestImage, options: Options) void {
        self.* = std.mem.zeroes(ElfTestImage);
        const base = @intFromPtr(self);
        const load_bias: usize = if (options.relocated) base else 0;
        const dynamic_entry_bias: usize = if (options.absolute_dynamic_entries) load_bias else 0;

        if (options.relocated) {
            self.program_headers[0].type = std.elf.PT.PHDR;
            self.program_headers[0].vaddr = self.virtualAddress("program_headers", load_bias);
        } else {
            // A non-relocatable executable has its program headers inside its first PT_LOAD segment.
            self.program_headers[0].type = std.elf.PT.LOAD;
            self.program_headers[0].vaddr = base;
            self.program_headers[0].memsz = @sizeOf(ElfTestImage);
        }
        self.program_headers[1].type = std.elf.PT.DYNAMIC;
        self.program_headers[1].vaddr = self.virtualAddress("dynamic", load_bias);
        self.program_headers[1].memsz = @sizeOf(@TypeOf(self.dynamic));

        // Offset 0 of the string table is the empty string, by convention.
        var string_offset: usize = 1;
        const exported_symbol_offset = string_offset;
        if (options.exported_symbol) |name| {
            @memcpy(self.strings[string_offset .. string_offset + name.len], name);
            string_offset += name.len + 1;
        }
        const needed_library_offset = string_offset;
        if (options.needed_library) |name| {
            @memcpy(self.strings[string_offset .. string_offset + name.len], name);
            string_offset += name.len + 1;
        }

        var i: usize = 0;
        self.dynamic[i] = switch (options.hash_table) {
            .sysv => .{ .d_tag = std.elf.DT_HASH, .d_val = self.virtualAddress("hash", load_bias) + dynamic_entry_bias },
            .gnu => .{ .d_tag = std.elf.DT_GNU_HASH, .d_val = self.virtualAddress("gnu_hash", load_bias) + dynamic_entry_bias },
        };
        i += 1;
        self.dynamic[i] = .{ .d_tag = std.elf.DT_STRTAB, .d_val = self.virtualAddress("strings", load_bias) + dynamic_entry_bias };
        i += 1;
        self.dynamic[i] = .{ .d_tag = std.elf.DT_SYMTAB, .d_val = self.virtualAddress("symbols", load_bias) + dynamic_entry_bias };
        i += 1;
        if (options.needed_library != null) {
            self.dynamic[i] = .{ .d_tag = std.elf.DT_NEEDED, .d_val = needed_library_offset };
            i += 1;
        }
        self.dynamic[i] = .{ .d_tag = std.elf.DT_NULL, .d_val = 0 };
        i += 1;
        // Whatever follows DT_NULL must be ignored, even if it looks like a DT_NEEDED entry.
        self.dynamic[i] = .{ .d_tag = std.elf.DT_NEEDED, .d_val = exported_symbol_offset };

        self.hash = .{ 1, self.symbols.len };
        // One bucket, symbols from index 1 on are in the GNU hash table, a bloom filter of one word, shift 6.
        self.gnu_hash[0..4].* = .{ 1, 1, 1, 6 };
        // Symbol 0 is the mandatory undefined null symbol.
        if (options.exported_symbol) |name| {
            const gnu_hash = std.elf.gnu_hash.calculate(name);
            const bloom = (@as(u64, 1) << @intCast(gnu_hash % 64)) | (@as(u64, 1) << @intCast((gnu_hash >> 6) % 64));
            self.gnu_hash[4..6].* = @bitCast(bloom);
            // The bucket points to symbol 1, its chain entry holds the upper 31 bits of the hash and ends the chain.
            self.gnu_hash[6] = 1;
            self.gnu_hash[7] = gnu_hash | 1;
            self.symbols[1] = .{
                .st_name = @intCast(exported_symbol_offset),
                .st_info = (@as(u8, std.elf.STB_GLOBAL) << 4) | std.elf.STT_FUNC,
                .st_other = 0,
                .st_shndx = 1,
                .st_value = exported_symbol_value,
                .st_size = 0,
            };
        }
    }

    pub fn programHeadersAddress(self: *align(1) const ElfTestImage) usize {
        return @intFromPtr(&self.program_headers);
    }

    /// The virtual address of a part of the image, as the executable file would state it.
    fn virtualAddress(self: *align(1) const ElfTestImage, comptime field: []const u8, load_bias: usize) usize {
        return @intFromPtr(self) + @offsetOf(ElfTestImage, field) - load_bias;
    }
};
