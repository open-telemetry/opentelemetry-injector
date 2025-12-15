const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const auxv = @import("auxv.zig");
const elf = @import("elf.zig");
const print = @import("print.zig");
const test_util = @import("test_util.zig");
const types = @import("types.zig");

const proc_self_exe_path = "/proc/self/exe";
const proc_self_maps_path = "/proc/self/maps";

const glibc_name = "libc.so.6";
const musl_name_part = "musl";

const readable_executable_private = "r-xp";
const readable_private = "r--p";
const dlsym_function_name = "dlsym";
const setenv_function_name = "setenv";
const environ_symbol_name = "__environ";

const reader_buffer_len = 4096;
const empty_string = @constCast("");

const LibCNameAndFlavor = struct {
    flavor: types.LibCFlavor,
    name: []const u8,
};

const LibCError = error{
    CannotAllocateMemory,
    CannotFindAtBase,
    CannotFindElfDynamicSymbolTableOffset,
    CannotFindElfDynamicSymbolTableSize,
    CannotFindDlSymSymbol,
    CannotFindEnvironSymbol,
    CannotFindLibcMemoryRange,
    CannotFindSetenvSymbol,
    CannotOpenLibc,
    UnknownLibCFlavor,
};

const UnknownLibC = LibCNameAndFlavor{
    .flavor = types.LibCFlavor.UNKNOWN,
    .name = "",
};

const DlsymLookupResult = struct {
    found: bool,
    libc_info: types.LibCInfo,
};

const AuxiliaryPointers = struct {
    base: usize,
    phdr: usize,
};

pub const DlsymLookupFn = *const fn (LibCNameAndFlavor, usize, usize) @typeInfo(@typeInfo(@TypeOf(tryToFindSymbolsInMemoryRange)).@"fn".return_type.?).error_union.error_set!types.LibCInfo;

/// Look up which libc flavor (glibc vs. musl) is used (if any), and the memory addresses of key libc facilities we need
/// (i.e. __environ, setenv).
///
/// This is performed in three steps:
/// 1. Inspect the ELF metadata of the program's executable ("/proc/self/exe"), using the DT_NEEDED symbols for the
///    libraries that must be linked.
/// 2. Look up pointer to the `dlsym` function in the libc loaded by the program, as springboard for the next look ups.
///    We use a simplified version of the ELF support in Zig's std library (`dynamic_library`) because we do not want to
///    have to support the infinite number of corner cases of the various libc flavors and versions.
/// 3. Use the loaded libc's `dlsym` function to look up the symbols we need (__environ, setenv).
pub fn getLibCInfo(gpa: std.mem.Allocator) !types.LibCInfo {
    const libc_name_and_flavor = try getLibCNameAndFlavor(gpa, proc_self_exe_path);
    const libc_info = getLibCMemoryLocations(
        proc_self_maps_path,
        libc_name_and_flavor,
        tryToFindSymbolsInMemoryRange,
    ) catch |err| {
        if (err == error.CannotFindLibcMemoryRange and print.isDebug()) {
            // The error will be properly logged in the code calling getLibCInfo, but for this specific error, let's
            // include a dump of /proc/self/maps in the log output if the log level is debug.
            print.printDebug("printing content of {s} below as debugging information", .{proc_self_maps_path});
            logProcSelfMaps(proc_self_maps_path) catch {
                // ignore errors from logProcSelfMaps deliberately
            };
        }
        return err;
    };
    return libc_info;
}

/// Inspect the ELF metadata of the program's executable ("/proc/self/exe"), using the DT_NEEDED symbols for the
/// libraries that must be linked. We use the executable's file instead of its in-memory mapping to avoid annoyances
/// with looking up the in-memory location of the ELF header (it is never in memory at location 0 is the virtual memory
/// space of the program, is is usually offset by 40 bytes).
fn getLibCNameAndFlavor(gpa: std.mem.Allocator, self_exe_path: []const u8) !LibCNameAndFlavor {
    // TODO MM: Rewrite this to use in-memory, finding u=out the ELF header location using auxv? If that would work, we
    // could make this logic allocation-free.
    const self_exe_file =
        std.fs.openFileAbsolute(self_exe_path, .{ .mode = .read_only }) catch |err| {
            print.printError("Cannot open \"{s}\": {}", .{ self_exe_path, err });
            return UnknownLibC;
        };
    defer self_exe_file.close();

    var reader_buf: [reader_buffer_len]u8 = undefined;
    var reader = self_exe_file.reader(&reader_buf);
    const elf_header = std.elf.Header.read(&reader.interface) catch |err| {
        print.printError("Cannot read ELF header from  \"{s}\": {}", .{ self_exe_path, err });
        return UnknownLibC;
    };

    if (!elf_header.is_64) {
        print.printError("ELF header from \"{s}\" seems to not be from a 64 bit binary", .{self_exe_path});
        return error.ElfNot64Bit;
    }

    var dynamic_symbols_table_offset: u64 = 0;
    var dynamic_symbols_table_size: u64 = 0;

    try self_exe_file.seekTo(elf_header.shoff);
    const section_headers = try gpa.alloc(std.elf.Elf64_Shdr, elf_header.shnum);
    defer gpa.free(section_headers);
    _ = try self_exe_file.read(std.mem.sliceAsBytes(section_headers));

    for (section_headers) |section_header| {
        switch (section_header.sh_type) {
            std.elf.SHT_DYNAMIC => {
                dynamic_symbols_table_offset = section_header.sh_offset;
                dynamic_symbols_table_size = section_header.sh_size;
            },
            else => {
                // Ignore this section
            },
        }
    }

    if (dynamic_symbols_table_offset == 0) {
        print.printError("No dynamic section found in ELF metadata when inspecting \"{s}\"", .{self_exe_path});
        return error.ElfDynamicSymbolTableNotFound;
    }

    // Look for DT_NEEDED entries in the dynamic table, they state which libraries were used when the binary has been
    // compiled. Some Examples:
    //
    // JVM with GNU libc
    // -----------------
    // $ readelf -Wd /usr/bin/java
    // Dynamic section at offset 0xfd28 contains 30 entries:
    //   Tag        Type                         Name/Value
    //  0x0000000000000001 (NEEDED)             Shared library: [libz.so.1]
    //  0x0000000000000001 (NEEDED)             Shared library: [libjli.so]
    //  0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
    //
    // JVM with musl libc
    // ------------------
    // $ readelf -Wd /usr/bin/java
    // Dynamic section at offset 0xfd18 contains 33 entries:
    //   Tag        Type                         Name/Value
    //  0x0000000000000001 (NEEDED)             Shared library: [libjli.so]
    //  0x0000000000000001 (NEEDED)             Shared library: [libc.musl-aarch64.so.1]

    // read dynamic section
    try self_exe_file.seekTo(dynamic_symbols_table_offset);
    const dynamic_symbol_count = dynamic_symbols_table_size / @sizeOf(std.elf.Elf64_Dyn);
    const dynamic_symbols = try gpa.alloc(std.elf.Elf64_Dyn, dynamic_symbol_count);
    defer gpa.free(dynamic_symbols);
    _ = try self_exe_file.read(std.mem.sliceAsBytes(dynamic_symbols));

    // find string table address (DT_STRTAB)
    var strtab_addr: u64 = 0;
    for (dynamic_symbols) |dyn| {
        if (dyn.d_tag == std.elf.DT_STRTAB) {
            strtab_addr = dyn.d_val;
            break;
        }
    }
    if (strtab_addr == 0) {
        print.printError("No string table found when inspecting ELF binary \"{s}\"", .{self_exe_path});
        return error.ElfStringsTableNotFound;
    }

    var string_table_offset: u64 = 0;
    var string_table_size: u64 = 0;
    for (section_headers) |shdr| {
        if (shdr.sh_type == std.elf.SHT_STRTAB and shdr.sh_addr == strtab_addr) {
            string_table_offset = shdr.sh_offset;
            string_table_size = shdr.sh_size;
            break;
        }
    }

    if (string_table_offset == 0) {
        // Fallback: Use program headers if section headers don’t map it
        try self_exe_file.seekTo(elf_header.phoff);
        const phdrs = try gpa.alloc(std.elf.Elf64_Phdr, elf_header.phnum);
        defer gpa.free(phdrs);
        _ = try self_exe_file.read(std.mem.sliceAsBytes(phdrs));
        for (phdrs) |phdr| {
            if (phdr.p_type == std.elf.PT_LOAD and phdr.p_vaddr <= strtab_addr and strtab_addr < phdr.p_vaddr + phdr.p_filesz) {
                string_table_offset = phdr.p_offset + (strtab_addr - phdr.p_vaddr);
                break;
            }
        }
        if (string_table_offset == 0) {
            print.printError("Could not map string table address when inspecting ELF binary \"{s}\"", .{self_exe_path});
            return error.ElfStringsTableNotFound;
        }
    }

    for (dynamic_symbols) |dynamic_symbol| {
        if (dynamic_symbol.d_tag == std.elf.DT_NULL) {
            // End of the dynamic symbols
            break;
        }

        if (dynamic_symbol.d_tag == std.elf.DT_NEEDED) {
            const string_offset = string_table_offset + dynamic_symbol.d_val;
            try self_exe_file.seekTo(string_offset);

            var lib_name_buf: [256]u8 = undefined;
            var len: usize = 0;
            while (len < lib_name_buf.len) : (len += 1) {
                const bytes_read = try self_exe_file.read(lib_name_buf[len .. len + 1]);
                if (bytes_read == 0 or lib_name_buf[len] == 0) break;
            }
            const lib_name = lib_name_buf[0..len];
            if (lib_name.len > 0) {
                if (std.mem.indexOf(u8, lib_name, musl_name_part)) |_| {
                    // lib_name exists on the stack, we need to allocate a string with the same content on the heap
                    const lib_name_owned = std.fmt.allocPrint(gpa, "{s}", .{lib_name}) catch |err| {
                        print.printError("Failed to allocate memory for libc name: {}", .{err});
                        return error.CannotAllocateMemory;
                    };
                    return LibCNameAndFlavor{ .flavor = types.LibCFlavor.MUSL, .name = lib_name_owned };
                }

                if (std.mem.indexOf(u8, lib_name, glibc_name)) |_| {
                    print.printDebug("found a libc: {s}", .{lib_name});
                    // lib_name exists on the stack, we need to allocate a string with the same content on the heap
                    const lib_name_owned = std.fmt.allocPrint(gpa, "{s}", .{lib_name}) catch |err| {
                        print.printError("Failed to allocate memory for libc name: {}", .{err});
                        return error.CannotAllocateMemory;
                    };
                    return LibCNameAndFlavor{ .flavor = types.LibCFlavor.GNU, .name = lib_name_owned };
                }
            }
        }
    }
    return UnknownLibC;
}

test "getLibCNameAndFlavor: should return libc flavor unknown when file does not exist" {
    const allocator = std.testing.allocator;
    const lib_c = try getLibCNameAndFlavor(allocator, "/does/not/exist");
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.UNKNOWN, lib_c.flavor);
}

test "getLibCNameAndFlavor: should return libc flavor unknown when file is not an ELF binary" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/libc/not-an-elf-binary" });
    defer allocator.free(absolute_path_to_binary);
    const lib_c = try getLibCNameAndFlavor(allocator, absolute_path_to_binary);
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.UNKNOWN, lib_c.flavor);
}

test "getLibCNameAndFlavor: should identify glibc libc flavor (x86_64)" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/libc/dotnet-app-x86_64-glibc" });
    defer allocator.free(absolute_path_to_binary);
    const lib_c = try getLibCNameAndFlavor(allocator, absolute_path_to_binary);
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.GNU, lib_c.flavor);
}

test "getLibCNameAndFlavor: should identify glibc libc flavor (arm64)" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/libc/dotnet-app-arm64-glibc" });
    defer allocator.free(absolute_path_to_binary);
    const lib_c = try getLibCNameAndFlavor(allocator, absolute_path_to_binary);
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.GNU, lib_c.flavor);
}

test "getLibCNameAndFlavor: should identify musl libc flavor (x86_64)" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/libc/dotnet-app-x86_64-musl" });
    defer allocator.free(absolute_path_to_binary);
    const lib_c = try getLibCNameAndFlavor(allocator, absolute_path_to_binary);
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.MUSL, lib_c.flavor);
}

test "getLibCNameAndFlavor: should identify musl libc flavor (arm64)" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/libc/dotnet-app-arm64-musl" });
    defer allocator.free(absolute_path_to_binary);
    const lib_c = try getLibCNameAndFlavor(allocator, absolute_path_to_binary);
    defer allocator.free(lib_c.name);
    try testing.expectEqual(.MUSL, lib_c.flavor);
}

fn getLibCMemoryLocations(self_maps_path: []const u8, libc_name_and_flavor: LibCNameAndFlavor, dlsym_lookup_fn: DlsymLookupFn) !types.LibCInfo {
    switch (libc_name_and_flavor.flavor) {
        types.LibCFlavor.GNU => {
            return findGlibcMemoryRangeAndLookupMemoryLocations(
                self_maps_path,
                libc_name_and_flavor,
                dlsym_lookup_fn,
            );
        },
        types.LibCFlavor.MUSL => {
            const at_base = auxv.getauxval(std.elf.AT_BASE);
            if (at_base == 0) {
                print.printError("cannot find AT_BASE in /proc/self/auxv", .{});
                return error.CannotFindAtBase;
            }
            return findMuslMemoryRangeAndLookupMemoryLocations(
                self_maps_path,
                libc_name_and_flavor,
                at_base,
                dlsym_lookup_fn,
            );
        },
        else => return error.UnknownLibCFlavor,
    }
}

test "getLibCMemoryLocations: glibc" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-x86_64" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try getLibCMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2e6000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff43c000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

// Note: Tests for getLibCMemoryLocations for musl are deliberately omitted because for that we would also have to mock
// the auxv.getauxval() function. There are tests for findMuslMemoryRangeAndLookupMemoryLocations, see below.

fn findGlibcMemoryRangeAndLookupMemoryLocations(
    self_maps_path: []const u8,
    libc_name_and_flavor: LibCNameAndFlavor,
    dlsym_lookup_fn: DlsymLookupFn,
) !types.LibCInfo {
    var maps_file = try std.fs.openFileAbsolute(self_maps_path, .{});
    defer maps_file.close();

    // Find the end of the memory range of the linker using /proc/self/maps
    var reader_buf: [reader_buffer_len]u8 = undefined;
    var reader = maps_file.reader(&reader_buf);

    // On a lot of modern distributions, the name returned by getLibCNameAndFlavor (e.g. "libc.so.6") will appear
    // verbatim in /proc/self/maps. But on other (older) distributions (Debian Bullseye for example), libc.so.6
    // is a symbolic link to the actual file, i.e. a link to libc-2.31.so or similar; and /proc/self/maps has no entry
    // for "libc.so.6", only one for libc-2.31.so. The linker has resolved the symbolic link libc.so.6 by finding that
    // file system entry in its standard libary search paths before /proc/self/maps is provided. To avoid having to
    // reimplement the library search path logic of the linker, we will first try to find a /proc/self/maps entry for
    // the exact name (e.g. libc.so.6) and look for dlsym in the associcated memory range. If that fails, we will try
    // to find dlsym in all memory ranges referenced by an /proc/self/maps entry that has the correct permissions.
    //
    // First pass/fast path: look for an entry in /proc/self/maps that matches the libc name.
    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |line| {
        if (try processOneGlibcProcSelfMapsLine(
            self_maps_path,
            libc_name_and_flavor,
            dlsym_lookup_fn,
            line,
            true,
            "via libc name",
        )) |libc_info| {
            return libc_info;
        }
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printWarn("Failed to read {s}", .{self_maps_path});
            return error.CannotFindLibcMemoryRange;
        },
        // If the file does not end with a newline, we still need to read and process the last line until EOF.
        error.EndOfStream => {
            var buffer: [reader_buffer_len]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            const line = buffer[0..chars];
            if (try processOneGlibcProcSelfMapsLine(
                self_maps_path,
                libc_name_and_flavor,
                dlsym_lookup_fn,
                line,
                true,
                "via libc name",
            )) |libc_info| {
                return libc_info;
            }
        },
    }

    // Second pass: try the dlsym lookup for all /proc/self/maps memory ranges with matching permissions and file names
    // that could be shared objects.
    try maps_file.seekTo(0);
    reader = maps_file.reader(&reader_buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |line| {
        if (try processOneGlibcProcSelfMapsLine(
            self_maps_path,
            libc_name_and_flavor,
            dlsym_lookup_fn,
            line,
            false,
            "in second pass",
        )) |libc_info| {
            return libc_info;
        }
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printWarn("Failed to read {s}", .{self_maps_path});
            return error.CannotFindLibcMemoryRange;
        },
        // If the file does not end with a newline, we still need to read and process the last line until EOF.
        error.EndOfStream => {
            var buffer: [reader_buffer_len]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            const line = buffer[0..chars];
            if (try processOneGlibcProcSelfMapsLine(
                self_maps_path,
                libc_name_and_flavor,
                dlsym_lookup_fn,
                line,
                false,
                "in second pass",
            )) |libc_info| {
                return libc_info;
            }
        },
    }

    return error.CannotFindLibcMemoryRange;
}

fn processOneGlibcProcSelfMapsLine(
    self_maps_path: []const u8,
    libc_name_and_flavor: LibCNameAndFlavor,
    dlsym_lookup_fn: DlsymLookupFn,
    line: []u8,
    check_lib_name: bool,
    debug_label: []const u8,
) !?types.LibCInfo {
    if (std.mem.trim(u8, line, " ").len == 0) {
        return null;
    }

    // Parse the address range (e.g., "55b3e9c1a000-55b3e9e1a000 ...")
    // address           perms offset  dev   inode   pathname
    // aaaac5560000-aaaaca1fd000 r-xp 00000000 00:11e 8682241 /usr/local/bin/node
    var slices = std.mem.splitAny(u8, line, " ");
    const memory_range = slices.first();

    const permissions = slices.next() orelse return null;
    if (!memoryRangeHasMatchingPermissions(permissions)) {
        return null;
    }
    if (check_lib_name) {
        if (!std.mem.endsWith(u8, slices.rest(), libc_name_and_flavor.name)) {
            return null;
        }
    } else {
        // If check_lib_name is false, we are in the second pass over the /proc/self/maps file where we not only inspect
        // the shared object that looks like the libc that is used, but instead inspect every shared object. Filter the
        // memory ranges where the path ends with a string that matches ".so([.0-9]+)?".

        // First, consume the remaining parts from the slices spliterator via .next() to get the file system path of the
        // shared object.
        _ = slices.next() orelse return null; // offset
        _ = slices.next() orelse return null; // device
        _ = slices.next() orelse return null; // inode
        if (!pathLooksLikeSharedObject(slices.rest())) {
            return null;
        }
    }

    if (std.mem.indexOf(u8, memory_range, "-")) |range_separator_index| {
        const start_memory_range_hex = memory_range[0..range_separator_index];
        const end_memory_range_hex = memory_range[range_separator_index + 1 ..];
        const start_memory_range = try std.fmt.parseInt(usize, start_memory_range_hex, 16);
        const end_memory_range = try std.fmt.parseInt(usize, end_memory_range_hex, 16);
        print.printDebug(
            "attempting dlsym lookup {s} for {s} line: {s}",
            .{ debug_label, self_maps_path, line },
        );
        if (dlsym_lookup_fn(
            libc_name_and_flavor,
            start_memory_range,
            end_memory_range,
        )) |libc_info| {
            print.printDebug(
                "dlsym lookup {s} succeeded for {s} line: {s}",
                .{ debug_label, self_maps_path, line },
            );
            return libc_info;
        } else |err| {
            print.printDebug(
                "dlsym lookup {s} failed for {s} line: {s} -- {}",
                .{ debug_label, self_maps_path, line, err },
            );
            return null;
        }
    }
    return null;
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: x86_64" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-x86_64" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2e6000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff43c000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: arm64" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-arm64" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(absolute_path_to_maps_file, .{
        .flavor = .GNU,
        .name = glibc_name,
    }, mockFindSymbolsInMemoryRange);
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0xffff88c50000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0xffff88ddb000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocation: x86_64/Debian 11" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-x86_64-bullseye" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2c9000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff422000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: arm64/Debian 11" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-arm64-bullseye" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(absolute_path_to_maps_file, .{
        .flavor = .GNU,
        .name = glibc_name,
    }, mockFindSymbolsInMemoryRange);
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0xffffa72b3000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0xffffa740f000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: continue to read after discarding overly long line in first pass" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-first-pass-overly-long-line" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2e6000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff43c000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: continue to read after discarding overly long line in second pass" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-second-pass-overly-long-line" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2c9000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff422000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: read last line if not terminated by newline in first pass" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-first-pass-no-terminating-newline" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2e6000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff43c000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findGlibcMemoryRangeAndLookupMemoryLocations: read last line if not terminated by newline in second pass" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-glibc-second-pass-no-terminating-newline" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 2;
    const libc_info = try findGlibcMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .GNU,
            .name = glibc_name,
        },
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.GNU, libc_info.flavor);
    try testing.expectEqual(glibc_name, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7fffff2c9000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7fffff422000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

fn findMuslMemoryRangeAndLookupMemoryLocations(
    self_maps_path: []const u8,
    libc_name_and_flavor: LibCNameAndFlavor,
    at_base: usize,
    dlsym_lookup_fn: DlsymLookupFn,
) !types.LibCInfo {
    // musl bundles the linker and the libc itself in the same .so and it gets mapped in the same memory region. We can
    // find where the linker is, and so also the libc, we can look up the AT_BASE location in /proc/self/auxv.
    var maps_file = try std.fs.openFileAbsolute(self_maps_path, .{});
    defer maps_file.close();

    // Find the end of the memory range of the linker using /proc/self/maps
    var reader_buf: [reader_buffer_len]u8 = undefined;
    var reader = maps_file.reader(&reader_buf);

    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |line| {
        if (try processOneMuslProcSelfMapsLine(
            self_maps_path,
            libc_name_and_flavor,
            dlsym_lookup_fn,
            at_base,
            line,
        )) |libc_info| {
            return libc_info;
        }
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printWarn("Failed to read {s}", .{self_maps_path});
            return error.CannotFindLibcMemoryRange;
        },
        // If the file does not end with a newline, we still need to read and process the last line until EOF.
        error.EndOfStream => {
            var buffer: [reader_buffer_len]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            const line = buffer[0..chars];
            if (try processOneMuslProcSelfMapsLine(
                self_maps_path,
                libc_name_and_flavor,
                dlsym_lookup_fn,
                at_base,
                line,
            )) |libc_info| {
                return libc_info;
            }
        },
    }

    return error.CannotFindLibcMemoryRange;
}

fn processOneMuslProcSelfMapsLine(
    self_maps_path: []const u8,
    libc_name_and_flavor: LibCNameAndFlavor,
    dlsym_lookup_fn: DlsymLookupFn,
    at_base: usize,
    line: []u8,
) !?types.LibCInfo {
    if (std.mem.trim(u8, line, " ").len == 0) {
        return null;
    }

    // Parse the address range (e.g., "55b3e9c1a000-55b3e9e1a000 ...")
    // address           perms offset  dev   inode   pathname
    // aaaac5560000-aaaaca1fd000 r-xp 00000000 00:11e 8682241 /usr/local/bin/node
    var slices = std.mem.splitAny(u8, line, " ");
    const memory_range = slices.first();

    const permissions = slices.next() orelse return null;
    if (!memoryRangeHasMatchingPermissions(permissions)) {
        return null;
    }

    // In contrast to the logic for glibc we are deliberately not checking for the name of the libarary here for musl,
    // the start_memory_range == at_base check below will only let one specific memory range got into the
    // dlsym_lookup_fn, so no further checks are necessary.
    // This is also the reason why there is no second-pass over /proc/self/maps where we try to find the correct
    // musl memory range by attempting dlsym_lookup_fn for every entry with matching permissions.
    if (std.mem.indexOf(u8, memory_range, "-")) |range_separator_index| {
        const start_memory_range_hex = memory_range[0..range_separator_index];
        const end_memory_range_hex = memory_range[range_separator_index + 1 ..];
        const start_memory_range = try std.fmt.parseInt(usize, start_memory_range_hex, 16);
        if (start_memory_range == at_base) {
            const memory_range_end = try std.fmt.parseInt(usize, end_memory_range_hex, 16);
            if (dlsym_lookup_fn(
                libc_name_and_flavor,
                at_base,
                memory_range_end,
            )) |libc_info| {
                print.printDebug(
                    "dlsym lookup (musl) succeeded for {s} line: {s}",
                    .{ self_maps_path, line },
                );
                return libc_info;
            } else |err| {
                print.printDebug(
                    "dlsym lookup (musl) failed for {s} line: {s} -- {}",
                    .{ self_maps_path, line, err },
                );
                return null;
            }
        }
    }
    return null;
}

test "findMuslMemoryRangeAndLookupMemoryLocations: x86_64" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-musl-x86_64" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findMuslMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .MUSL,
            .name = musl_name_part,
        },
        0x7ffffff6e000,
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.MUSL, libc_info.flavor);
    try testing.expectEqual(musl_name_part, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7ffffff6e000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7ffffffc5000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findMuslMemoryRangeAndLookupMemoryLocations: arm64" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-musl-arm64" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findMuslMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .MUSL,
            .name = musl_name_part,
        },
        0xffffb3670000,
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.MUSL, libc_info.flavor);
    try testing.expectEqual(musl_name_part, libc_info.name);
    try test_util.expectMemoryRangeLimit(0xffffb3670000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0xffffb3712000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findMuslMemoryRangeAndLookupMemoryLocations: continue to read after discarding overly long line" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-musl-overly-long-line" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findMuslMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .MUSL,
            .name = musl_name_part,
        },
        0x7ffffff6e000,
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.MUSL, libc_info.flavor);
    try testing.expectEqual(musl_name_part, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7ffffff6e000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7ffffffc5000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

test "findMuslMemoryRangeAndLookupMemoryLocations: read last line if not terminated by newline" {
    const allocator = std.testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_maps_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-maps/maps-musl-no-terminating-newline" });
    defer allocator.free(absolute_path_to_maps_file);

    __test_find_symbol_actual_attempts = 0;
    __test_find_symbol_succeed_on_attempt = 1;
    const libc_info = try findMuslMemoryRangeAndLookupMemoryLocations(
        absolute_path_to_maps_file,
        .{
            .flavor = .MUSL,
            .name = musl_name_part,
        },
        0x7ffffff6e000,
        mockFindSymbolsInMemoryRange,
    );
    try testing.expectEqual(.MUSL, libc_info.flavor);
    try testing.expectEqual(musl_name_part, libc_info.name);
    try test_util.expectMemoryRangeLimit(0x7ffffff6e000, libc_info.environ_ptr);
    try test_util.expectMemoryRangeLimit(0x7ffffffc5000, libc_info.setenv_fn_ptr);
    try testing.expectEqual(__test_find_symbol_succeed_on_attempt, __test_find_symbol_actual_attempts);
}

/// Checks whether a given permission string (e.g. "r-xp") matches the permissions signature of a memory region that
/// might potentially contain the dlsym symbol.
fn memoryRangeHasMatchingPermissions(permissions: []const u8) bool {
    // Intuitively, one might thing that looking for dlsym in /proc/self/maps memory ranges with permission flags r-xp
    // (readable, not writable, executable & private i.e., copy-on-write) would be enough. But in some scenarios, the
    // memory range that actually contains dlsym has "r--p" instead. Two known cases:
    // - Node.js on x86_64/glibc with base image node:22.15.0-bookworm-slim.
    // - JVM & Node.js on Debian Bullseye (glibc), in particular when iterating over all /proc/self/maps entries in the
    //   second pass (which is necessary because the maps entry is not named "libc.so.6", but dlsym is mapped from the
    //   shared object "libdl-2.31.so" instead).
    //
    // Apparently allowing entries in /proc/self/maps with "r--p" permissions can be required for looking up dlsym,
    // because the _symbols_ (i.e., the names and metadata about functions) exist in the binary's read-only sections;
    // specifically, in the ELF file's .rodata and symbol tables, which are not part of the executable segment, even if
    // the actual executable code for those functions then resides in the "r-xp" segment.
    return std.mem.eql(u8, permissions, readable_executable_private) or
        std.mem.eql(u8, permissions, readable_private);
}

test "memoryRangeHasMatchingPermissions" {
    try test_util.expectWithMessage(memoryRangeHasMatchingPermissions("r-xp"), "memoryRangeHasMatchingPermissions(\"r-xp\")");
    try test_util.expectWithMessage(memoryRangeHasMatchingPermissions("r--p"), "memoryRangeHasMatchingPermissions(\"r--p\")");
    try test_util.expectWithMessage(!memoryRangeHasMatchingPermissions("rw-p"), "!memoryRangeHasMatchingPermissions(\"rw-p\")");
    try test_util.expectWithMessage(!memoryRangeHasMatchingPermissions("rwxp"), "!memoryRangeHasMatchingPermissions(\"rwxp\")");
    try test_util.expectWithMessage(!memoryRangeHasMatchingPermissions("rw-s"), "!memoryRangeHasMatchingPermissions(\"rw-s\")");
    try test_util.expectWithMessage(!memoryRangeHasMatchingPermissions("r--s"), "!memoryRangeHasMatchingPermissions(\"r--s\")");
    try test_util.expectWithMessage(!memoryRangeHasMatchingPermissions("----"), "!memoryRangeHasMatchingPermissions(\"----\")");
}

/// Checks whether the given path ends with something that matches ".so([.0-9]+)?".
fn pathLooksLikeSharedObject(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "libotelinject")) |_| {
        // never match the injector itself
        return false;
    }
    if (std.mem.lastIndexOf(u8, path, ".so")) |dot_so_index| {
        const after_dot_so = path[dot_so_index + 3 ..];
        if (after_dot_so.len == 0) {
            return true;
        }
        if (after_dot_so[0] != '.') {
            return false;
        }
        // after_dot_so starts with a '.', check that the rest is only digits and dots
        for (after_dot_so[1..]) |c| {
            if (!std.ascii.isDigit(c) and c != '.') {
                return false;
            }
        }
        return true;
    }
    return false;
}

test "pathLooksLikeSharedObject" {
    try test_util.expectWithMessage(pathLooksLikeSharedObject("/lib/x86_64-linux-gnu/libc.so.6"), "pathLooksLikeSharedObject(\"/lib/x86_64-linux-gnu/libc.so.6\")");
    try test_util.expectWithMessage(pathLooksLikeSharedObject("/lib/aarch64-linux-gnu/libc.so.1"), "pathLooksLikeSharedObject(\"/lib/aarch64-linux-gnu/libc.so.1\")");
    try test_util.expectWithMessage(pathLooksLikeSharedObject("/lib/libc.so"), "pathLooksLikeSharedObject(\"/lib/libc.so\")");
    try test_util.expectWithMessage(pathLooksLikeSharedObject("/usr/lib/libc.so.2.31"), "pathLooksLikeSharedObject(\"/usr/lib/libc.so.2.31\")");
    try test_util.expectWithMessage(pathLooksLikeSharedObject("/usr/lib/libc.so.2.31.1"), "pathLooksLikeSharedObject(\"/usr/lib/libc.so.2.31.1\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/libc.so.backup"), "!pathLooksLikeSharedObject(\"/usr/lib/libc.so.backup\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/path/to/app.o"), "!pathLooksLikeSharedObject(\"/path/to/app.o\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/libc.s"), "!pathLooksLikeSharedObject(\"/usr/lib/libc.s\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/libc.a"), "!pathLooksLikeSharedObject(\"/usr/lib/libc.a\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/libc.dylib"), "!pathLooksLikeSharedObject(\"/usr/lib/libc.dylib\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/libc.dll"), "!pathLooksLikeSharedObject(\"/usr/lib/libc.dll\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/usr/lib/not-a-lib.txt"), "!pathLooksLikeSharedObject(\"/usr/lib/not-a-lib.txt\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/some/path/libotelinject_amd64.so"), "!pathLooksLikeSharedObject(\"/some/path/libotelinject_amd64.so\")");
    try test_util.expectWithMessage(!pathLooksLikeSharedObject("/some/path/libotelinject_arm64.so"), "!pathLooksLikeSharedObject(\"/some/path/libotelinject_arm64.so\")");
}

/// Reads the given memory range via elf.ElfDynLib.open and tries to lookup the dlsym function via elf.ElfDynLib#lookup.
/// If that succeeds, proceeds to try to lookup the setenv function and the __environ symbol using dlsym.
fn tryToFindSymbolsInMemoryRange(
    libc_name_and_flavor: LibCNameAndFlavor,
    start: usize,
    end: usize,
) !types.LibCInfo {
    const linker = elf.ElfDynLib.open(start, end) catch |err| {
        print.printWarn("cannot open libc mapped range {x}-{x} as ELF library: {}", .{ start, end, err });
        return error.CannotOpenLibc;
    };

    const dlsym_fn =
        linker.lookup(types.DlSymFn, dlsym_function_name) orelse return error.CannotFindDlSymSymbol;

    // look up the symbols we need from the current program (handle = null)
    const maybe_setenv_fn = dlsym_fn(null, setenv_function_name);
    const maybe_environ_ptr = dlsym_fn(null, environ_symbol_name);

    const setenv_fn_ptr: types.SetenvFnPtr =
        @ptrCast(@alignCast(maybe_setenv_fn orelse return error.CannotFindSetenvSymbol));
    const environ_ptr: types.EnvironPtr =
        @ptrCast(@alignCast(maybe_environ_ptr orelse return error.CannotFindEnvironSymbol));

    return .{
        .flavor = libc_name_and_flavor.flavor,
        .name = libc_name_and_flavor.name,
        .environ_ptr = environ_ptr,
        .setenv_fn_ptr = setenv_fn_ptr,
    };
}

var __test_find_symbol_actual_attempts: u32 = 0;
var __test_find_symbol_succeed_on_attempt: u32 = 0;

fn mockFindSymbolsInMemoryRange(
    libc_name_and_flavor: LibCNameAndFlavor,
    start: usize,
    end: usize,
) !types.LibCInfo {
    __test_find_symbol_actual_attempts += 1;
    if (__test_find_symbol_actual_attempts == __test_find_symbol_succeed_on_attempt) {
        return .{
            .flavor = libc_name_and_flavor.flavor,
            .name = libc_name_and_flavor.name,
            .environ_ptr = @ptrFromInt(start),
            .setenv_fn_ptr = @ptrFromInt(end),
        };
    }
    return error.CannotFindDlSymSymbol;
}

fn takeSentinelOrDiscardOverlyLongLine(reader: *std.fs.File.Reader) ![]u8 {
    if (reader.interface.takeSentinel('\n')) |slice| {
        return slice;
    } else |err| switch (err) {
        error.StreamTooLong => {
            // Ignore lines that are too long for the buffer; advance the the read positon to the next delimiter to
            // avoid stream corruption.
            _ = try reader.interface.discardDelimiterInclusive('\n');
            return empty_string;
        },
        else => |leftover_err| return leftover_err,
    }
}

fn logProcSelfMaps(self_maps_path: []const u8) !void {
    var maps_file = try std.fs.openFileAbsolute(self_maps_path, .{});
    defer maps_file.close();
    var reader_buf: [reader_buffer_len]u8 = undefined;
    var reader = maps_file.reader(&reader_buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |line| {
        print.printDebug("{s}", .{line});
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printDebug("Failed to read {s} in logProcSelfMaps", .{self_maps_path});
            // ignore error in function only used for logging debug output
        },
        // If the file does not end with a newline, we still want to print the last line until EOF.
        error.EndOfStream => {
            var buffer: [reader_buffer_len]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            const line = buffer[0..chars];
            print.printDebug("{s}", .{line});
        },
    }
}
