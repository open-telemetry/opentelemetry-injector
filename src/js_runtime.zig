// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const auxv = @import("auxv.zig");
const elf = @import("elf.zig");
const print = @import("print.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

/// The JavaScript runtimes the injector can tell apart.
pub const JsRuntime = enum {
    nodejs,
    /// Not a JavaScript runtime at all, or one the injector does not recognize.
    unknown,
};

/// Node.js exports its embedder and native addon API from the executable, so that addons loaded at runtime can bind to
/// it. node::Start(int, char**) is the function the node executable's main function calls to run Node.js, and it has
/// been part of that API since the early days of Node.js. The symbol is the Itanium C++ ABI mangled name, which all
/// Linux toolchains use.
///
/// Runtimes that mimic Node.js (Deno et. al) only provide the parts of the API that native addons call, and node::Star
/// is not one of them. Note that node_module_register, the function addons built with the NODE_MODULE macro call to
/// register themselves, does not work for this purpose: Bun (since at least 1.2) and Deno (since at least 2.9) export
/// it.
const nodejs_symbol = "_ZN4node5StartEiPPc";

/// Linux distributions (Debian, Ubuntu, Fedora, ...) build Node.js as a shared library, with a small node executable
/// that links against it. In that case, the executable exports nothing, and libnode.so.<ABI version> does.
const libnode_prefix = "libnode.so";

/// Determines the JavaScript runtime of the current process by inspecting the dynamic symbol table and the dependencies
/// of its main executable. The executable is already mapped into memory when the injector runs, so this does not read
/// any file except /proc/self/auxv, and is cheap enough to run for every process.
///
/// A program that loads Node.js later at runtime, via dlopen, is not recognized: when the injector runs, it does not
/// have Node.js loaded yet.
pub fn detect() JsRuntime {
    const program_headers_address = auxv.getauxval(std.elf.AT.PHDR);
    const program_headers_count = auxv.getauxval(std.elf.AT.PHNUM);
    const executable = elf.ElfDynLib.openMainExecutable(program_headers_address, program_headers_count) catch |err| {
        print.printDebug("JavaScript runtime detection: cannot inspect the executable: {}", .{err});
        return .unknown;
    };
    return detectFromExecutable(&executable);
}

fn detectFromExecutable(executable: *const elf.ElfDynLib) JsRuntime {
    if (executable.exportsSymbol(nodejs_symbol)) {
        print.printDebug("JavaScript runtime detection: the executable exports \"{s}\", this is Node.js.", .{nodejs_symbol});
        return .nodejs;
    }
    if (executable.needsLibraryWithPrefix(libnode_prefix)) {
        print.printDebug("JavaScript runtime detection: the executable depends on \"{s}\", this is Node.js.", .{libnode_prefix});
        return .nodejs;
    }
    return .unknown;
}

fn detectFromTestImage(options: test_util.ElfTestImage.Options) !JsRuntime {
    var image: test_util.ElfTestImage = undefined;
    image.init(options);
    const executable = try elf.ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len);
    return detectFromExecutable(&executable);
}

test "detectFromExecutable: recognizes an executable that exports node::Start as Node.js" {
    // The official Node.js builds: non-relocatable on glibc, position-independent on musl (Alpine).
    try testing.expectEqual(JsRuntime.nodejs, try detectFromTestImage(.{
        .relocated = false,
        .absolute_dynamic_entries = false,
        .exported_symbol = "_ZN4node5StartEiPPc",
    }));
    try testing.expectEqual(JsRuntime.nodejs, try detectFromTestImage(.{
        .relocated = true,
        .absolute_dynamic_entries = false,
        .exported_symbol = "_ZN4node5StartEiPPc",
    }));
}

test "detectFromExecutable: recognizes an executable that depends on libnode.so as Node.js" {
    try testing.expectEqual(JsRuntime.nodejs, try detectFromTestImage(.{ .needed_library = "libnode.so.108" }));
    try testing.expectEqual(JsRuntime.nodejs, try detectFromTestImage(.{ .needed_library = "libnode.so" }));
}

test "detectFromExecutable: does not recognize other executables as Node.js" {
    // An executable without any exports or dependencies, like a statically linked shell.
    try testing.expectEqual(JsRuntime.unknown, try detectFromTestImage(.{}));
    // Deno and Bun export the Node-API functions and node_module_register, but not node::Start.
    try testing.expectEqual(JsRuntime.unknown, try detectFromTestImage(.{ .exported_symbol = "napi_module_register" }));
    try testing.expectEqual(JsRuntime.unknown, try detectFromTestImage(.{ .exported_symbol = "node_module_register" }));
    try testing.expectEqual(JsRuntime.unknown, try detectFromTestImage(.{ .needed_library = "libc.so.6" }));
    try testing.expectEqual(JsRuntime.unknown, try detectFromTestImage(.{ .needed_library = "libnodejs-helper.so" }));
}
