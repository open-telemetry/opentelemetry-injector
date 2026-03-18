const std = @import("std");

const print = @import("print.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const proc_self_auxv_path: []const u8 = "/proc/self/auxv";

// Need to implement and export this symbol to prevent an unwanted dependency on the `getauxval` symbol from libc, which
// will not be fulfilled when linking to a process that does not include libc itself. It is safe to export this, since
// we do not export any _global_ symbols, only local symbols, and in particular, getauxval is only exported locally.
// Executables requiring getauxval will bind to libc's getauxval, not the symbol exported here.
pub export fn getauxval(auxv_type: u32) callconv(.c) usize {
    return readAuxValFromFile(auxv_type, proc_self_auxv_path);
}

fn readAuxValFromFile(auxv_type: u32, auxv_path: []const u8) usize {
    var auxv_file = std.fs.openFileAbsolute(auxv_path, .{}) catch |err| {
        print.printError("Failed to open {s}: {}", .{ auxv_path, err });
        return 0;
    };
    defer auxv_file.close();

    while (true) {
        var auxv_symbol: std.elf.Elf64_auxv_t = undefined;
        const bytes_read = auxv_file.read(std.mem.asBytes(&auxv_symbol)) catch |err| {
            print.printError("Failed to read from {s}: {}", .{ auxv_path, err });
            return 0;
        };

        if (bytes_read == 0) {
            break;
        }

        if (bytes_read < @sizeOf(std.elf.Elf64_auxv_t)) {
            print.printError("Short read from {s}", .{auxv_path});
            return 0;
        }

        if (auxv_symbol.a_type == auxv_type) {
            return auxv_symbol.a_un.a_val;
        } else if (auxv_symbol.a_type == std.elf.AT_NULL) {
            break;
        }
    }

    return 0;
}

test "readAuxValFromFile: should read value" {
    const auxv_files = [_][]const u8{
        "unit-test-assets/proc-self-auxv/auxv-glibc-arm64",
        "unit-test-assets/proc-self-auxv/auxv-glibc-x86_64",
        "unit-test-assets/proc-self-auxv/auxv-musl-arm64",
        "unit-test-assets/proc-self-auxv/auxv-musl-x86_64",
    };

    for (auxv_files) |auxv_file| {
        const allocator = std.testing.allocator;
        const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd_path);
        const absolute_path_to_auxv_file = try std.fs.path.resolve(allocator, &.{
            cwd_path,
            auxv_file,
        });
        defer allocator.free(absolute_path_to_auxv_file);
        const auxv_result = readAuxValFromFile(std.elf.AT_BASE, absolute_path_to_auxv_file);
        try test_util.expectWithMessage(auxv_result > 0, "readAuxValFromFile(AT_BASE) should return > 0");
    }
}
