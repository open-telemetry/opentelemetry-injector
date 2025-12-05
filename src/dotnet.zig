// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const alloc = @import("allocator.zig");
const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

// Note: The CLR bootstrapping code (implemented in C++) uses getenv, but when doing
// Environment.GetEnvironmentVariable from within a .NET application, it will apparently bypass getenv.
// That is, while we can inject the OTel auto instrumentation and activate tracing for a .NET application, overriding
// the getenv function is probably not suitable for overriding environment variables that the .NET OTel SDK looks up
// from within the CLR via Environment.GetEnvironmentVariable (like OTEL_DOTNET_AUTO_HOME, OTEL_RESOURCE_ATTRIBUTES,
// etc.).
//
// Here is an example for the lookup of DOTNET_SHARED_STORE, which happens at runtime startup, via getenv:
// https://github.com/dotnet/runtime/blob/v9.0.5/src/native/corehost/hostpolicy/shared_store.cpp#L16
// -> https://github.com/dotnet/runtime/blob/v9.0.5/src/native/corehost/hostmisc/pal.unix.cpp#L954.
//
// In contrast to that, the implementation of Environment.GetEnvironmentVariable reads __environ into a dictionary
// and then uses that dictionary for all lookups, see here:
// https://github.com/dotnet/runtime/blob/v9.0.5/src/libraries/System.Private.CoreLib/src/System/Environment.cs#L66 ->
// - https://github.com/dotnet/runtime/blob/v9.0.5/src/libraries/System.Private.CoreLib/src/System/Environment.Variables.Unix.cs#L15-L32,
// - https://github.com/dotnet/runtime/blob/v9.0.5/src/libraries/System.Private.CoreLib/src/System/Environment.Variables.Unix.cs#L85-L91, and
// https://github.com/dotnet/runtime/blob/v9.0.5/src/libraries/System.Private.CoreLib/src/System/Environment.Variables.Unix.cs#L93-L166

pub const DotnetValues = struct {
    coreclr_enable_profiling: types.NullTerminatedString,
    coreclr_profiler: types.NullTerminatedString,
    coreclr_profiler_path: types.NullTerminatedString,
    additional_deps: types.NullTerminatedString,
    shared_store: types.NullTerminatedString,
    startup_hooks: types.NullTerminatedString,
    otel_auto_home: types.NullTerminatedString,
};

const DotnetError = error{
    UnknownLibCFlavor,
    UnsupportedCpuArchitecture,
    OutOfMemory,
};

const LibCFlavor = enum { UNKNOWN, GNU_LIBC, MUSL };

var cached_dotnet_values: ?DotnetValues = null;
var cached_libc_flavor: ?LibCFlavor = null;

const injection_happened_msg = "injecting the .NET OpenTelemetry instrumentation";
var injection_happened_msg_has_been_printed = false;

pub fn getDotnetValues(configuration: config.InjectorConfiguration) ?DotnetValues {
    return doGetDotnetValues(configuration.dotnet_auto_instrumentation_agent_path_prefix);
}

fn doGetDotnetValues(dotnet_path_prefix: []u8) ?DotnetValues {
    if (dotnet_path_prefix.len == 0) {
        print.printMessage("Skipping the injection of the .NET OpenTelemetry instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    if (cached_dotnet_values) |val| {
        return val;
    }

    if (cached_libc_flavor == null) {
        cached_libc_flavor = getLibCFlavor();
    }

    if (cached_libc_flavor == LibCFlavor.UNKNOWN) {
        print.printError("Skipping the injection of the .NET OpenTelemetry instrumentation, cannot determine the LibC flavor.", .{});
        return null;
    }

    if (cached_libc_flavor) |flavor| {
        const dotnet_values = determineDotnetValues(
            dotnet_path_prefix,
            flavor,
            builtin.cpu.arch,
        ) catch |err| {
            print.printError("Cannot determine .NET environment variables: {}", .{err});
            return null;
        };

        const paths_to_check = [_]types.NullTerminatedString{
            dotnet_values.coreclr_profiler_path,
            dotnet_values.additional_deps,
            dotnet_values.otel_auto_home,
            dotnet_values.shared_store,
            dotnet_values.startup_hooks,
        };
        for (paths_to_check) |p| {
            std.fs.cwd().access(std.mem.span(p), .{}) catch |err| {
                print.printError("Skipping the injection of the .NET OpenTelemetry instrumentation because of an issue accessing \"{s}\": {}", .{ p, err });
                return null;
            };
        }

        cached_dotnet_values = dotnet_values;
        return cached_dotnet_values;
    }

    unreachable;
}

test "doGetDotnetValues: should return null value if the profiler path cannot be accessed" {
    const dotnet_values = doGetDotnetValues(try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}));
    try testing.expect(dotnet_values == null);
}

fn getLibCFlavor() LibCFlavor {
    const proc_self_exe_path = "/proc/self/exe";
    return doGetLibCFlavor(proc_self_exe_path) catch |err| {
        print.printError("Cannot determine LibC flavor from ELF metadata of \"{s}\": {}", .{ proc_self_exe_path, err });
        return LibCFlavor.UNKNOWN;
    };
}

fn doGetLibCFlavor(proc_self_exe_path: []const u8) !LibCFlavor {
    const proc_self_exe_file = std.fs.openFileAbsolute(proc_self_exe_path, .{ .mode = .read_only }) catch |err| {
        print.printError("Cannot open \"{s}\": {}", .{ proc_self_exe_path, err });
        return LibCFlavor.UNKNOWN;
    };
    defer proc_self_exe_file.close();
    var headers_buf: [4096]u8 = undefined;
    var reader = proc_self_exe_file.reader(&headers_buf);
    const elf_header = std.elf.Header.read(&reader.interface) catch |err| {
        print.printError("Cannot read ELF header from  \"{s}\": {}", .{ proc_self_exe_path, err });
        return LibCFlavor.UNKNOWN;
    };

    if (!elf_header.is_64) {
        print.printError("ELF header from \"{s}\" seems to not be from a  64 bit binary", .{proc_self_exe_path});
        return error.ElfNot64Bit;
    }

    var sections_buf: [8192]u8 = undefined;
    var section_reader = proc_self_exe_file.reader(&sections_buf);
    var sections_header_iterator = elf_header.iterateSectionHeaders(&section_reader);

    var dynamic_symbols_table_offset: u64 = 0;
    var dynamic_symbols_table_size: u64 = 0;

    while (try sections_header_iterator.next()) |section_header| {
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
        print.printError("No dynamic section found in ELF metadata when inspecting \"{s}\"", .{proc_self_exe_path});
        return error.ElfDynamicSymbolTableNotFound;
    }

    // Look for DT_NEEDED entries in the Dynamic table, they state which libraries were
    // used at compilation step. Examples:
    //
    // Java + GNU LibC
    //
    // $ readelf -Wd /usr/bin/java
    // Dynamic section at offset 0xfd28 contains 30 entries:
    //   Tag        Type                         Name/Value
    //  0x0000000000000001 (NEEDED)             Shared library: [libz.so.1]
    //  0x0000000000000001 (NEEDED)             Shared library: [libjli.so]
    //  0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
    //
    // Java + musl
    //
    // $ readelf -Wd /usr/bin/java
    // Dynamic section at offset 0xfd18 contains 33 entries:
    //   Tag        Type                         Name/Value
    //  0x0000000000000001 (NEEDED)             Shared library: [libjli.so]
    //  0x0000000000000001 (NEEDED)             Shared library: [libc.musl-aarch64.so.1]

    // Read dynamic section
    // Read dynamic section
    try proc_self_exe_file.seekTo(dynamic_symbols_table_offset);
    const dynamic_symbol_count = dynamic_symbols_table_size / @sizeOf(std.elf.Elf64_Dyn);
    const dynamic_symbols = try alloc.page_allocator.alloc(std.elf.Elf64_Dyn, dynamic_symbol_count);
    defer alloc.page_allocator.free(dynamic_symbols);
    _ = try proc_self_exe_file.read(std.mem.sliceAsBytes(dynamic_symbols));

    // Find string table address (DT_STRTAB)
    var strtab_addr: u64 = 0;
    for (dynamic_symbols) |dyn| {
        if (dyn.d_tag == std.elf.DT_STRTAB) {
            strtab_addr = dyn.d_val;
            break;
        }
    }
    if (strtab_addr == 0) {
        print.printError("No string table found when inspecting ELF binary \"{s}\"", .{proc_self_exe_path});
        return error.ElfStringsTableNotFound;
    }

    sections_header_iterator.index = 0;
    var string_table_offset: u64 = 0;
    while (try sections_header_iterator.next()) |shdr| {
        if (shdr.sh_type == std.elf.SHT_STRTAB and shdr.sh_addr == strtab_addr) {
            string_table_offset = shdr.sh_offset;
            break;
        }
    }

    if (string_table_offset == 0) {
        // Fallback: Use program headers if section headers don’t map it
        try proc_self_exe_file.seekTo(elf_header.phoff);
        const phdrs = try std.heap.page_allocator.alloc(std.elf.Elf64_Phdr, elf_header.phnum);
        defer std.heap.page_allocator.free(phdrs);
        _ = try proc_self_exe_file.read(std.mem.sliceAsBytes(phdrs));
        for (phdrs) |phdr| {
            if (phdr.p_type == std.elf.PT_LOAD and phdr.p_vaddr <= strtab_addr and strtab_addr < phdr.p_vaddr + phdr.p_filesz) {
                string_table_offset = phdr.p_offset + (strtab_addr - phdr.p_vaddr);
                break;
            }
        }
        if (string_table_offset == 0) {
            print.printError("Could not map string table address when inspecting ELF binary \"{s}\"", .{proc_self_exe_path});
            return error.ElfStringsTableNotFound;
        }
    }

    for (dynamic_symbols) |dynamic_symbol| {
        if (dynamic_symbol.d_tag == std.elf.DT_NULL) {
            break;
        }

        if (dynamic_symbol.d_tag == std.elf.DT_NEEDED) {
            const string_offset = string_table_offset + dynamic_symbol.d_val;
            try proc_self_exe_file.seekTo(string_offset);

            // Read null-terminated string (up to 256 bytes max for simplicity)
            var buffer: [256]u8 = undefined;
            const bytes_read = try proc_self_exe_file.read(&buffer);
            const lib_name = buffer[0..bytes_read];

            if (std.mem.indexOf(u8, lib_name, "musl")) |_| {
                print.printDebug("Identified libc flavor \"musl\" from inspecting \"{s}\"", .{proc_self_exe_path});
                return LibCFlavor.MUSL;
            }

            if (std.mem.indexOf(u8, lib_name, "libc.so.6")) |_| {
                print.printDebug("Identified libc flavor \"glibc\" from inspecting \"{s}\"", .{proc_self_exe_path});
                return LibCFlavor.GNU_LIBC;
            }
        }
    }

    print.printDebug("No libc flavor could be identified from inspecting \"{s}\"", .{proc_self_exe_path});
    return LibCFlavor.UNKNOWN;
}

test "doGetLibCFlavor: should return libc flavor unknown when file does not exist" {
    const libc_flavor = try doGetLibCFlavor("/does/not/exist");
    try testing.expectEqual(libc_flavor, .UNKNOWN);
}

test "doGetLibCFlavor: should return libc flavor unknown when file is not an ELF binary" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/dotnet/not-an-elf-binary" });
    defer allocator.free(absolute_path_to_binary);
    const libc_flavor = try doGetLibCFlavor(absolute_path_to_binary);
    try testing.expectEqual(libc_flavor, .UNKNOWN);
}

test "doGetLibCFlavor: should identify musl libc flavor (arm64)" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/dotnet/dotnet-app-arm64-musl" });
    defer allocator.free(absolute_path_to_binary);
    const libc_flavor = try doGetLibCFlavor(absolute_path_to_binary);
    try testing.expectEqual(libc_flavor, .MUSL);
}

test "doGetLibCFlavor: should identify musl libc flavor (x86_64)" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/dotnet/dotnet-app-x86_64-musl" });
    defer allocator.free(absolute_path_to_binary);
    const libc_flavor = try doGetLibCFlavor(absolute_path_to_binary);
    try testing.expectEqual(libc_flavor, .MUSL);
}

test "doGetLibCFlavor: should identify glibc libc flavor (arm64)" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/dotnet/dotnet-app-arm64-glibc" });
    defer allocator.free(absolute_path_to_binary);
    const libc_flavor = try doGetLibCFlavor(absolute_path_to_binary);
    try testing.expectEqual(libc_flavor, .GNU_LIBC);
}

test "doGetLibCFlavor: should identify glibc libc flavor (x86_64)" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_binary = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/dotnet/dotnet-app-x86_64-glibc" });
    defer allocator.free(absolute_path_to_binary);
    const libc_flavor = try doGetLibCFlavor(absolute_path_to_binary);
    try testing.expectEqual(libc_flavor, .GNU_LIBC);
}

fn determineDotnetValues(
    dotnet_path_prefix: []const u8,
    libc_flavor: LibCFlavor,
    architecture: std.Target.Cpu.Arch,
) DotnetError!DotnetValues {
    const libc_flavor_prefix =
        switch (libc_flavor) {
            .GNU_LIBC => "glibc",
            .MUSL => "musl",
            else => return error.UnknownLibCFlavor,
        };
    const platform =
        switch (libc_flavor) {
            .GNU_LIBC => switch (architecture) {
                .x86_64 => "linux-x64",
                .aarch64 => "linux-arm64",
                else => return error.UnsupportedCpuArchitecture,
            },
            .MUSL => switch (architecture) {
                .x86_64 => "linux-musl-x64",
                .aarch64 => "linux-musl-arm64",
                else => return error.UnsupportedCpuArchitecture,
            },
            else => return error.UnknownLibCFlavor,
        };
    const coreclr_profiler_path = try std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}/{s}/{s}/OpenTelemetry.AutoInstrumentation.Native.so", .{
        dotnet_path_prefix, libc_flavor_prefix, platform,
    }, 0);

    const additional_deps = try std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}/{s}/AdditionalDeps", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    const otel_auto_home = try std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}/{s}", .{ dotnet_path_prefix, libc_flavor_prefix }, 0);

    const shared_store = try std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}/{s}/store", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    const startup_hooks = try std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}/{s}/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll", .{
        dotnet_path_prefix, libc_flavor_prefix,
    }, 0);

    if (!injection_happened_msg_has_been_printed) {
        print.printMessage(injection_happened_msg, .{});
        injection_happened_msg_has_been_printed = true;
    }
    return .{
        .coreclr_enable_profiling = "1",
        .coreclr_profiler = "{918728DD-259F-4A6A-AC2B-B85E1B658318}",
        .coreclr_profiler_path = coreclr_profiler_path,
        .additional_deps = additional_deps,
        .otel_auto_home = otel_auto_home,
        .shared_store = shared_store,
        .startup_hooks = startup_hooks,
    };
}

test "determineDotnetValues: should return error for unsupported CPU architecture" {
    try testing.expectError(error.UnsupportedCpuArchitecture, determineDotnetValues(
        "",
        .GNU_LIBC,
        .powerpc64le,
    ));
}

test "determineDotnetValues: should return error for unknown libc flavor" {
    try testing.expectError(error.UnknownLibCFlavor, determineDotnetValues(
        "",
        .UNKNOWN,
        .x86_64,
    ));
}

test "determineDotnetValues: should return values for glibc/x86_64" {
    const dotnet_values =
        try determineDotnetValues(
            "/__otel_auto_instrumentation/dotnet",
            .GNU_LIBC,
            .x86_64,
        );
    try testing.expectEqualStrings(
        "1",
        std.mem.span(dotnet_values.coreclr_enable_profiling),
    );
    try testing.expectEqualStrings(
        "{918728DD-259F-4A6A-AC2B-B85E1B658318}",
        std.mem.span(dotnet_values.coreclr_profiler),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so",
        std.mem.span(dotnet_values.coreclr_profiler_path),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/AdditionalDeps",
        std.mem.span(dotnet_values.additional_deps),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc",
        std.mem.span(dotnet_values.otel_auto_home),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/store",
        std.mem.span(dotnet_values.shared_store),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        std.mem.span(dotnet_values.startup_hooks),
    );
}

test "determineDotnetValues: should return values for glibc/arm64" {
    const dotnet_values =
        try determineDotnetValues(
            "/__otel_auto_instrumentation/dotnet",
            .GNU_LIBC,
            .aarch64,
        );
    try testing.expectEqualStrings(
        "1",
        std.mem.span(dotnet_values.coreclr_enable_profiling),
    );
    try testing.expectEqualStrings(
        "{918728DD-259F-4A6A-AC2B-B85E1B658318}",
        std.mem.span(dotnet_values.coreclr_profiler),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/linux-arm64/OpenTelemetry.AutoInstrumentation.Native.so",
        std.mem.span(dotnet_values.coreclr_profiler_path),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/AdditionalDeps",
        std.mem.span(dotnet_values.additional_deps),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc",
        std.mem.span(dotnet_values.otel_auto_home),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/store",
        std.mem.span(dotnet_values.shared_store),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        std.mem.span(dotnet_values.startup_hooks),
    );
}

test "determineDotnetValues: should return values for musl/x86_64" {
    const dotnet_values =
        try determineDotnetValues(
            "/__otel_auto_instrumentation/dotnet",
            .MUSL,
            .x86_64,
        );
    try testing.expectEqualStrings(
        "1",
        std.mem.span(dotnet_values.coreclr_enable_profiling),
    );
    try testing.expectEqualStrings(
        "{918728DD-259F-4A6A-AC2B-B85E1B658318}",
        std.mem.span(dotnet_values.coreclr_profiler),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/linux-musl-x64/OpenTelemetry.AutoInstrumentation.Native.so",
        std.mem.span(dotnet_values.coreclr_profiler_path),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/AdditionalDeps",
        std.mem.span(dotnet_values.additional_deps),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl",
        std.mem.span(dotnet_values.otel_auto_home),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/store",
        std.mem.span(dotnet_values.shared_store),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        std.mem.span(dotnet_values.startup_hooks),
    );
}

test "determineDotnetValues: should return values for musl/arm64" {
    const dotnet_values =
        try determineDotnetValues(
            "/__otel_auto_instrumentation/dotnet",
            .MUSL,
            .aarch64,
        );
    try testing.expectEqualStrings(
        "1",
        std.mem.span(dotnet_values.coreclr_enable_profiling),
    );
    try testing.expectEqualStrings(
        "{918728DD-259F-4A6A-AC2B-B85E1B658318}",
        std.mem.span(dotnet_values.coreclr_profiler),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/linux-musl-arm64/OpenTelemetry.AutoInstrumentation.Native.so",
        std.mem.span(dotnet_values.coreclr_profiler_path),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/AdditionalDeps",
        std.mem.span(dotnet_values.additional_deps),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl",
        std.mem.span(dotnet_values.otel_auto_home),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/store",
        std.mem.span(dotnet_values.shared_store),
    );
    try testing.expectEqualStrings(
        "/__otel_auto_instrumentation/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll",
        std.mem.span(dotnet_values.startup_hooks),
    );
}
