// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const environ = @import("proc_self_environ_parser.zig");
const version = @import("jvm_version.zig");
const testing = std.testing;

/// The launcher maps libjli.so before our constructor, but loads libjvm afterwards.
/// Find its native library directory and inspect bundled VMs on disk before
/// JAVA_TOOL_OPTIONS is changed. The first recognized Java version wins.
/// Once the launcher has been found, we skip detection when -XXaltjvm= appears in the command line or
/// JDK_ALTERNATE_VM is set, since the VM that will actually be loaded is not the bundled one we would inspect.
/// Dealing with this would require adding logic to parse command line options for not just java, but the java
/// tools (which prefix with -J).
pub fn getJavaMajorVersion(io: std.Io, allocator: std.mem.Allocator, get_env: environ.GetenvFn) !?u32 {
    return getJavaMajorVersionFromFiles(io, allocator, get_env, "/proc/self/cmdline", "/proc/self/maps");
}

fn getJavaMajorVersionFromFiles(io: std.Io, allocator: std.mem.Allocator, get_env: environ.GetenvFn, cmdline_path: []const u8, maps_path: []const u8) !?u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    // Look for the launcher first. It is the decisive test for "is this process a JVM at all", and it has to run
    // before the alternate VM check for two reasons: a process that is not a JVM must report JvmLauncherNotFound
    // instead of being waved through by an inherited JDK_ALTERNATE_VM or by a command line that merely contains
    // the string "-XXaltjvm=" somewhere; and since the injector is preloaded into every process on the host, the
    // non-JVM majority must not pay for reading and allocating the command line.
    const launcher = try findLauncher(io, gpa, maps_path) orelse return error.JvmLauncherNotFound;

    if (try hasAlternateVm(io, gpa, get_env, cmdline_path)) {
        return null;
    }

    const library_dir = try runtimeLibraryDirectory(io, gpa, launcher);

    // Prefer the release file of the Java home the launcher belongs to. Every runtime image built since JDK 8
    // ships one, including jlink and jpackage images, so this answers the question with a single read of about a
    // kilobyte. Scanning libjvm.so is the fallback: correct everywhere, but it reads tens of megabytes (the
    // version banner sits roughly two thirds into a 26 MB libjvm.so on a current JDK) at every JVM start. The
    // runtimes that lack a release file are the pre-8 ones this check exists to catch, so the expensive path is
    // taken exactly where it has to be. An alternate VM selection would make the release file describe a VM other
    // than the one being loaded, but hasAlternateVm has already returned above in that case.
    if (try javaHomeVersion(io, gpa, library_dir)) |major| {
        return major;
    }

    return detectLauncherVersion(io, gpa, library_dir);
}

const release_file_name = "release";
const java_version_key = "JAVA_VERSION=";
const max_release_file_size = 64 * 1024;
// From the native library directory the Java home is one level up on a modern image (<home>/lib) and three on a
// legacy one (<home>/jre/lib/<arch>); JDK 8 also keeps a release file in <home>/jre, two levels up.
const max_java_home_depth = 4;

/// Reads the Java major version from the release file of the Java home that owns `library_dir`, walking up from the
/// native library directory until a release file turns up. Returns null when there is none, or when it carries no
/// usable JAVA_VERSION entry.
fn javaHomeVersion(io: std.Io, allocator: std.mem.Allocator, library_dir: []const u8) !?u32 {
    var directory = library_dir;

    for (0..max_java_home_depth) |_| {
        directory = std.fs.path.dirname(directory) orelse return null;

        const release_path = try std.fs.path.join(allocator, &.{ directory, release_file_name });
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            release_path,
            allocator,
            .limited(max_release_file_size),
        ) catch continue;

        if (releaseFileVersion(content)) |major| {
            return major;
        }
    }

    return null;
}

fn releaseFileVersion(content: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        // Match the key on a line of its own, so that JAVA_VERSION_DATE and friends cannot be mistaken for it.
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, java_version_key)) {
            continue;
        }

        const value = std.mem.trim(u8, trimmed[java_version_key.len..], "\"");
        return version.parseJavaMajorVersion(value);
    }

    return null;
}

fn hasAlternateVm(io: std.Io, allocator: std.mem.Allocator, get_env: environ.GetenvFn, cmdline_path: []const u8) !bool {
    if (get_env(io, allocator, "JDK_ALTERNATE_VM") != null) {
        return true;
    }

    const cmdline_file = try std.Io.Dir.openFileAbsolute(io, cmdline_path, .{});
    defer cmdline_file.close(io);

    var cmdline_reader = cmdline_file.readerStreaming(io, &.{});
    const cmdline = try cmdline_reader.interface.allocRemaining(allocator, .limited(64 * 1024));

    return std.mem.indexOf(u8, cmdline, "-XXaltjvm=") != null;
}

// Find libjli.so which is always the one thing we should have loaded in the maps when the injector initializes.
fn findLauncher(io: std.Io, allocator: std.mem.Allocator, maps_path: []const u8) !?Launcher {
    const file = try std.Io.Dir.openFileAbsolute(io, maps_path, .{});
    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        const launcher = launcherFromMapsLine(line) orelse continue;

        return .{
            .directory = try allocator.dupe(u8, launcher.directory),
            .legacy = launcher.legacy,
        };
    }

    return null;
}

const Launcher = struct { directory: []const u8, legacy: bool };

fn launcherFromMapsLine(line: []const u8) ?Launcher {
    // Skip the first five fields: address range, permissions, file offset, device, and inode.
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    for (0..5) |_| _ = fields.next() orelse return null;

    // Check if it's our only loaded module libjli.so.
    const path = std.mem.trim(u8, fields.rest(), " \t\r");
    if (!std.fs.path.isAbsolute(path) or !std.mem.eql(u8, std.fs.path.basename(path), "libjli.so")) {
        return null;
    }

    const parent = std.fs.path.dirname(path) orelse return null;
    var directory = parent;
    if (std.mem.eql(u8, std.fs.path.basename(parent), "jli")) {
        directory = std.fs.path.dirname(parent) orelse return null;
    }

    // Older JVMs keep the JVM binaries in .../jre/lib/<arch>, new ones
    // keep the binaries in .../jre/lib.
    const legacy = !std.mem.eql(u8, std.fs.path.basename(directory), "lib");
    return .{ .directory = directory, .legacy = legacy };
}

// runtimeLibraryDirectory finds the directory where libjava.so is. This isn't the library we need, we
// need libjvm.so, but that one can be in a subdirectory, for example: server/, client/, j9vm/.
fn runtimeLibraryDirectory(io: std.Io, allocator: std.mem.Allocator, launcher: Launcher) ![]const u8 {
    if (!launcher.legacy) {
        return launcher.directory;
    }

    const libjava = try std.fs.path.join(allocator, &.{ launcher.directory, "libjava.so" });
    std.Io.Dir.cwd().access(io, libjava, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Some JDK 8 launchers link JDK/lib/<arch>/jli/libjli.so,
            // while their VM is in JDK/jre/lib/<arch>.
            const lib = std.fs.path.dirname(launcher.directory) orelse return err;
            const home = std.fs.path.dirname(lib) orelse return err;
            const runtime = try std.fs.path.join(allocator, &.{ home, "jre", "lib", std.fs.path.basename(launcher.directory) });
            const runtime_libjava = try std.fs.path.join(allocator, &.{ runtime, "libjava.so" });
            try std.Io.Dir.cwd().access(io, runtime_libjava, .{});

            return runtime;
        },
        else => return err,
    };

    return launcher.directory;
}

fn detectLauncherVersion(io: std.Io, allocator: std.mem.Allocator, library_dir: []const u8) !?u32 {
    const root_major = inspectVmDirectory(io, allocator, library_dir) catch null;
    if (root_major) |major| return major;

    const dir = try std.Io.Dir.openDirAbsolute(io, library_dir, .{ .iterate = true });
    defer dir.close(io);

    // Collect the candidate directories before inspecting any of them. Directory iteration yields entries in
    // whatever order the filesystem keeps them, so on an image that bundles more than one VM the answer would
    // otherwise depend on the filesystem rather than on the image.
    var vm_directories: std.ArrayList([]const u8) = try .initCapacity(allocator, 8);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const name = try allocator.dupe(u8, entry.name);
        try vm_directories.append(allocator, name);
    }

    std.mem.sort([]const u8, vm_directories.items, {}, vmDirectoryLessThan);

    for (vm_directories.items) |name| {
        const directory = try std.fs.path.join(allocator, &.{ library_dir, name });
        const candidate_major = inspectVmDirectory(io, allocator, directory) catch null;
        if (candidate_major) |major| return major;
    }

    return null;
}

// The VM HotSpot and OpenJ9 images actually boot by default, ahead of the alternatives they ship alongside it.
const preferred_vm_directories = [_][]const u8{ "server", "client", "default", "compressedrefs", "j9vm" };

fn vmDirectoryRank(name: []const u8) usize {
    for (preferred_vm_directories, 0..) |preferred, index| {
        if (std.mem.eql(u8, name, preferred)) return index;
    }
    return preferred_vm_directories.len;
}

fn vmDirectoryLessThan(_: void, a: []const u8, b: []const u8) bool {
    const rank_a = vmDirectoryRank(a);
    const rank_b = vmDirectoryRank(b);
    if (rank_a != rank_b) return rank_a < rank_b;
    return std.mem.order(u8, a, b) == .lt;
}

fn inspectVmDirectory(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !?u32 {
    const binary = try std.fs.path.join(allocator, &.{ directory, "libjvm.so" });

    const vm_version = try version.inspectBinary(io, binary);

    if (vm_version.major) |major| {
        return major;
    }

    if (!vm_version.openj9_forwarder) {
        return null;
    }

    // OpenJ9's libjvm is just a forwarder. Its actual VM can live in
    // default or compressedrefs, alongside the server/j9vm launcher directory.
    const base = std.fs.path.dirname(directory) orelse return null;
    const default_directory = try std.fs.path.join(allocator, &.{ base, "default" });
    const compressedrefs_directory = try std.fs.path.join(allocator, &.{ base, "compressedrefs" });
    const candidates = [_][]const u8{
        directory,
        default_directory,
        compressedrefs_directory,
    };

    for (candidates) |candidate| {
        const dir = std.Io.Dir.openDirAbsolute(io, candidate, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const name = entry.name;
            if (!std.mem.startsWith(u8, name, "libj9vm") or !std.mem.endsWith(u8, name, ".so")) {
                continue;
            }

            const path = try std.fs.path.join(allocator, &.{ candidate, name });
            if ((try version.inspectBinary(io, path)).major) |major| {
                return major;
            }
        }
    }
    return null;
}

test "JVM launcher: maps identify old and modern native library directories" {
    const old = launcherFromMapsLine("1000-2000 r-xp 0 00:01 1 /jdk 6/jre/lib/amd64/jli/libjli.so").?;
    try testing.expectEqualStrings("/jdk 6/jre/lib/amd64", old.directory);
    try testing.expect(old.legacy);

    const modern = launcherFromMapsLine("1000-2000 r-xp 0 00:01 1 /jdk/lib/libjli.so").?;
    try testing.expectEqualStrings("/jdk/lib", modern.directory);
    try testing.expect(!modern.legacy);
    try testing.expectEqual(@as(?Launcher, null), launcherFromMapsLine("1000-2000 r-xp 0 00:01 1 /jdk/lib/libother.so"));
}

test "JVM release file: reads the Java major version from the vendors we support" {
    const test_util = @import("test_util.zig");
    // Verbatim excerpts from the release files of eclipse-temurin:8-jre, eclipse-temurin:21-jre,
    // ibm-semeru-runtimes:open-21-jre-jammy, ghcr.io/graalvm/jdk-community:21 and azul/prime:21.
    const Case = struct { content: []const u8, major: ?u32 };
    for ([_]Case{
        .{ .content = "JAVA_VERSION=\"1.8.0_504\"\nOS_NAME=\"Linux\"\nFULL_VERSION=\"1.8.0_504-b01\"\n", .major = 8 },
        .{ .content = "IMPLEMENTOR=\"Eclipse Adoptium\"\nJAVA_VERSION=\"21.0.9\"\nJAVA_VERSION_DATE=\"2026-10-21\"\n", .major = 21 },
        .{ .content = "IMPLEMENTOR=\"IBM Corporation\"\nJAVA_VERSION=\"21.0.12.1\"\n", .major = 21 },
        .{ .content = "IMPLEMENTOR=\"GraalVM Community\"\nJAVA_VERSION=\"21.0.2\"\n", .major = 21 },
        .{ .content = "IMPLEMENTOR=\"Azul Systems, Inc.\"\nJAVA_VERSION=\"21.0.9.0.101\"\n", .major = 21 },
        // JAVA_VERSION_DATE must not be mistaken for the version itself.
        .{ .content = "JAVA_VERSION_DATE=\"2026-10-21\"\nOS_ARCH=\"aarch64\"\n", .major = null },
        // A value too long to be a version string, a malformed one, and a file without the key at all.
        .{ .content = "JAVA_VERSION=\"21." ++ test_util.repeat('0', 200) ++ "\"\n", .major = null },
        .{ .content = "JAVA_VERSION=\"not-a-version\"\n", .major = null },
        .{ .content = "OS_NAME=\"Linux\"\n", .major = null },
        .{ .content = "", .major = null },
        // A release file without a trailing newline, and one with CRLF line endings.
        .{ .content = "JAVA_VERSION=\"11.0.22\"", .major = 11 },
        .{ .content = "OS_NAME=\"Linux\"\r\nJAVA_VERSION=\"17.0.9\"\r\n", .major = 17 },
    }) |case| {
        try testing.expectEqual(case.major, releaseFileVersion(case.content));
    }
}

test "JVM release file: is found from modern and legacy native library directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A modern image keeps the launcher library in <home>/lib, a legacy one in <home>/jre/lib/<arch>.
    try tmp.dir.createDirPath(testing.io, "modern/lib");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "modern/release", .data = "JAVA_VERSION=\"21.0.9\"\n" });
    try tmp.dir.createDirPath(testing.io, "legacy/jre/lib/amd64");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "legacy/release", .data = "JAVA_VERSION=\"1.8.0_504\"\n" });
    // A Java home without a release file, as shipped by Oracle JDK 6, must fall through to the binary scan.
    try tmp.dir.createDirPath(testing.io, "no-release/jre/lib/amd64");

    const modern = try tmp.dir.realPathFileAlloc(testing.io, "modern/lib", gpa);
    try testing.expectEqual(@as(?u32, 21), try javaHomeVersion(testing.io, gpa, modern));

    const legacy = try tmp.dir.realPathFileAlloc(testing.io, "legacy/jre/lib/amd64", gpa);
    try testing.expectEqual(@as(?u32, 8), try javaHomeVersion(testing.io, gpa, legacy));

    const without = try tmp.dir.realPathFileAlloc(testing.io, "no-release/jre/lib/amd64", gpa);
    try testing.expectEqual(@as(?u32, null), try javaHomeVersion(testing.io, gpa, without));
}

test "JVM release file: the Java home version wins over the bundled VM binary" {
    const test_util = @import("test_util.zig");
    const original = try test_util.setStdCEnviron(&.{});
    defer test_util.resetStdCEnviron(original);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try tmp.dir.createDirPath(testing.io, "lib/server");
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cmdline", .data = "java\x00Main\x00" });

    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    const maps = try std.fmt.allocPrint(gpa, "1000-2000 r--p 00000000 08:01 1 {s}/lib/libjli.so\n", .{directory});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "maps", .data = maps });

    const cmdline_path = try std.fs.path.join(gpa, &.{ directory, "cmdline" });
    const maps_path = try std.fs.path.join(gpa, &.{ directory, "maps" });

    // Without a release file the bundled VM binary is scanned.
    try testing.expectEqual(
        @as(?u32, 6),
        try getJavaMajorVersionFromFiles(testing.io, gpa, test_util.posixGetenv, cmdline_path, maps_path),
    );

    // With one, it answers instead of the Java 6 banner in the bundled VM.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "release", .data = "JAVA_VERSION=\"21.0.9\"\n" });
    try testing.expectEqual(
        @as(?u32, 21),
        try getJavaMajorVersionFromFiles(testing.io, gpa, test_util.posixGetenv, cmdline_path, maps_path),
    );

    // An unusable release file falls back to the binary rather than reporting an unknown version.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "release", .data = "OS_NAME=\"Linux\"\n" });
    try testing.expectEqual(
        @as(?u32, 6),
        try getJavaMajorVersionFromFiles(testing.io, gpa, test_util.posixGetenv, cmdline_path, maps_path),
    );
}

test "JVM launcher: resolves a JDK 8 launcher library to its bundled JRE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "jdk/lib/amd64/jli");
    try tmp.dir.createDirPath(testing.io, "jdk/jre/lib/amd64");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "jdk/jre/lib/amd64/libjava.so", .data = "" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const sdk_lib = try tmp.dir.realPathFileAlloc(testing.io, "jdk/lib/amd64", gpa);
    const runtime_lib = try tmp.dir.realPathFileAlloc(testing.io, "jdk/jre/lib/amd64", gpa);

    try testing.expectEqualStrings(
        runtime_lib,
        try runtimeLibraryDirectory(testing.io, gpa, .{ .directory = sdk_lib, .legacy = true }),
    );
    try testing.expectEqualStrings(
        runtime_lib,
        try runtimeLibraryDirectory(testing.io, gpa, .{ .directory = runtime_lib, .legacy = true }),
    );
}

test "JVM launcher: finds the VM in a subdirectory, whatever jvm.cfg says" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Detection no longer reads jvm.cfg, because vendors such as Azul Zing do not follow its conventions. One
    // naming a different directory must not steer the search away from the VM that is actually there.
    try tmp.dir.createDirPath(testing.io, "lib/server");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "lib/jvm.cfg",
        .data = "-custom KNOWN\n-server IGNORE\n-client IGNORE\n",
    });
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (21.0.9+1-LTS)\x00", std.elf.PF_R);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);

    try testing.expectEqual(@as(?u32, 21), try detectLauncherVersion(testing.io, gpa, library_dir));
}

test "JVM launcher: scans immediate directories without jvm.cfg and skips unknown binaries" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "lib/empty");
    try tmp.dir.createDirPath(testing.io, "lib/unknown");
    try tmp.dir.createDirPath(testing.io, "lib/nested/server");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/libjvm.so", .data = "invalid ELF" });
    try test_util.writeElf(tmp.dir, "lib/unknown/libjvm.so", "no version banner\x00", std.elf.PF_R);
    try test_util.writeElf(tmp.dir, "lib/nested/server/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);
    try testing.expectEqual(@as(?u32, null), try detectLauncherVersion(testing.io, gpa, library_dir));

    try tmp.dir.createDirPath(testing.io, "lib/vendor-vm");
    try test_util.writeElf(tmp.dir, "lib/vendor-vm/libjvm.so", " JRE (21.0.9+1-LTS)\x00", std.elf.PF_R);
    try testing.expectEqual(@as(?u32, 21), try detectLauncherVersion(testing.io, gpa, library_dir));
}

test "JVM launcher: inspects bundled VMs in a deterministic, default-VM-first order" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // The VM the image boots by default comes first, whatever the directory order on disk and whatever the
    // alternatives are called. Sorting alphabetically alone would pick "alpha-vm" here.
    try tmp.dir.createDirPath(testing.io, "lib/alpha-vm");
    try tmp.dir.createDirPath(testing.io, "lib/server");
    try tmp.dir.createDirPath(testing.io, "lib/zulu-vm");
    try test_util.writeElf(tmp.dir, "lib/alpha-vm/libjvm.so", " JRE (11.0.22+7)\x00", std.elf.PF_R);
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (17.0.9+9)\x00", std.elf.PF_R);
    try test_util.writeElf(tmp.dir, "lib/zulu-vm/libjvm.so", " JRE (21.0.9+10)\x00", std.elf.PF_R);

    const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);
    try testing.expectEqual(@as(?u32, 17), try detectLauncherVersion(testing.io, gpa, library_dir));

    // Without a preferred name the order is alphabetical, not the order the filesystem happens to return.
    try tmp.dir.deleteTree(testing.io, "lib/server");
    try testing.expectEqual(@as(?u32, 11), try detectLauncherVersion(testing.io, gpa, library_dir));
}

test "JVM launcher: ignores directory symlinks to another Java installation" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "lib");
    try tmp.dir.createDirPath(testing.io, "other-jdk/server");
    try test_util.writeElf(tmp.dir, "other-jdk/server/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R);
    try tmp.dir.symLink(testing.io, "../other-jdk/server", "lib/linked-vm", .{ .is_directory = true });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);

    try testing.expectEqual(@as(?u32, null), try detectLauncherVersion(testing.io, gpa, library_dir));

    try tmp.dir.createDirPath(testing.io, "lib/server");
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (21.0.9+1-LTS)\x00", std.elf.PF_R);
    try testing.expectEqual(@as(?u32, 21), try detectLauncherVersion(testing.io, gpa, library_dir));
}

test "JVM launcher: returns the first recognized version without checking later candidates" {
    const test_util = @import("test_util.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "lib/server");
    try test_util.writeElf(tmp.dir, "lib/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R | std.elf.PF_X);
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (21.0.9+1-LTS)\x00", std.elf.PF_R);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);

    try testing.expectEqual(@as(?u32, 6), try detectLauncherVersion(testing.io, gpa, library_dir));
}

test "JVM launcher: follows OpenJ9 forwarders to numbered and unnumbered VM libraries" {
    const test_util = @import("test_util.zig");
    for ([_][]const u8{ "libj9vm29.so", "libj9vm.so" }) |vm_name| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(testing.io, "lib/j9vm");
        try tmp.dir.createDirPath(testing.io, "lib/default");

        try test_util.writeElf(tmp.dir, "lib/j9vm/libjvm.so", "IBM_JAVA_OPTIONS\x00-Xjvm:\x00", std.elf.PF_R);
        try test_util.writeElf(tmp.dir, "lib/default/libj9vmchk29.so", "VM check helper\x00", std.elf.PF_R);
        try test_util.writeElf(tmp.dir, "lib/default/libj9vmtest.so", "VM test helper\x00", std.elf.PF_R);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const gpa = arena.allocator();

        const library_dir = try tmp.dir.realPathFileAlloc(testing.io, "lib", gpa);
        try testing.expectEqual(
            @as(?u32, null),
            try detectLauncherVersion(testing.io, gpa, library_dir),
        );

        const vm_path = try std.fs.path.join(gpa, &.{ "lib/default", vm_name });
        try test_util.writeElf(
            tmp.dir,
            vm_path,
            "-Xinternalversion\x00linux\x001.8.0_181-b13\x00JRE 1.6.0\x00JRE 12\x00",
            std.elf.PF_R,
        );
        try testing.expectEqual(
            @as(?u32, 8),
            try detectLauncherVersion(testing.io, gpa, library_dir),
        );
    }
}

test "JVM launcher: alternate VM overrides skip version detection, but only for actual JVMs" {
    const test_util = @import("test_util.zig");
    const original = try test_util.setStdCEnviron(&.{});
    defer test_util.resetStdCEnviron(original);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "lib/server");
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    const maps = try std.fmt.allocPrint(gpa, "1000-2000 r--p 00000000 08:01 1 {s}/lib/libjli.so\n", .{directory});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "maps", .data = maps });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "maps-without-launcher",
        .data = "1000-2000 r--p 00000000 08:01 1 /usr/lib/libc.so.6\n",
    });

    const cmdline_path = try std.fs.path.join(gpa, &.{ directory, "cmdline" });
    const maps_path = try std.fs.path.join(gpa, &.{ directory, "maps" });
    const maps_without_launcher_path = try std.fs.path.join(gpa, &.{ directory, "maps-without-launcher" });
    // This file does not exist: reading it would fail, so the assertions below also prove it is never read.
    const missing_cmdline_path = try std.fs.path.join(gpa, &.{ directory, "missing-cmdline" });

    for ([_][]const u8{
        "java\x00-XXaltjvm=/path\x00",
        "javac\x00-J-XXaltjvm=/path\x00",
        "java\x00-Dproperty=-XXaltjvm=/path\x00",
        "java\x00Main\x00-XXaltjvm=/path\x00",
        "java\x00-XXaltjvm=\x00",
    }) |cmdline| {
        try tmp.dir.writeFile(
            testing.io,
            .{ .sub_path = "cmdline", .data = cmdline },
        );

        // The bundled VM is a Java 6 VM, but another VM will be loaded instead, so the version is unknown.
        try testing.expectEqual(
            @as(?u32, null),
            try getJavaMajorVersionFromFiles(
                testing.io,
                gpa,
                test_util.posixGetenv,
                cmdline_path,
                maps_path,
            ),
        );

        // Without a launcher the process is not a JVM, no matter what its command line contains.
        try testing.expectError(
            error.JvmLauncherNotFound,
            getJavaMajorVersionFromFiles(
                testing.io,
                gpa,
                test_util.posixGetenv,
                cmdline_path,
                maps_without_launcher_path,
            ),
        );
    }

    // "-XXaltjvm" without a value is not an alternate VM override.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cmdline", .data = "java\x00-XXaltjvm\x00" });
    try testing.expectEqual(
        @as(?u32, 6),
        try getJavaMajorVersionFromFiles(
            testing.io,
            gpa,
            test_util.posixGetenv,
            cmdline_path,
            maps_path,
        ),
    );

    for ([_][]const u8{ "JDK_ALTERNATE_VM=/path", "JDK_ALTERNATE_VM=" }) |variable| {
        const previous = try test_util.setStdCEnviron(&.{variable});
        defer test_util.resetStdCEnviron(previous);

        // The command line is never read when the environment variable is set.
        try testing.expectEqual(
            @as(?u32, null),
            try getJavaMajorVersionFromFiles(
                testing.io,
                gpa,
                test_util.posixGetenv,
                missing_cmdline_path,
                maps_path,
            ),
        );

        // An inherited JDK_ALTERNATE_VM must not wave through a process that is not a JVM either.
        try testing.expectError(
            error.JvmLauncherNotFound,
            getJavaMajorVersionFromFiles(
                testing.io,
                gpa,
                test_util.posixGetenv,
                missing_cmdline_path,
                maps_without_launcher_path,
            ),
        );
    }
}

test "JVM launcher: ordinary command line still detects the bundled Java 6 VM" {
    const test_util = @import("test_util.zig");
    const original = try test_util.setStdCEnviron(&.{});
    defer test_util.resetStdCEnviron(original);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "lib/server");
    try test_util.writeElf(tmp.dir, "lib/server/libjvm.so", " JRE (1.6.0_45-b06)\x00", std.elf.PF_R);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cmdline", .data = "java\x00-cp\x00classes\x00Main\x00" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    const maps = try std.fmt.allocPrint(gpa, "1000-2000 r--p 00000000 08:01 1 {s}/lib/libjli.so\n", .{directory});

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "maps", .data = maps });

    const cmdline_path = try std.fs.path.join(gpa, &.{ directory, "cmdline" });
    const maps_path = try std.fs.path.join(gpa, &.{ directory, "maps" });
    try testing.expectEqual(
        @as(?u32, 6),
        try getJavaMajorVersionFromFiles(
            testing.io,
            gpa,
            test_util.posixGetenv,
            cmdline_path,
            maps_path,
        ),
    );
}

test "JVM launcher: distinguishes a non-Java process from an unknown Java version" {
    const test_util = @import("test_util.zig");
    const original = try test_util.setStdCEnviron(&.{});
    defer test_util.resetStdCEnviron(original);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cmdline", .data = "/bin/sh\x00run.sh\x00" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "maps",
        .data = "1000-2000 r--p 00000000 08:01 1 /usr/lib/libc.so.6\n",
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    const cmdline_path = try std.fs.path.join(gpa, &.{ directory, "cmdline" });
    const maps_path = try std.fs.path.join(gpa, &.{ directory, "maps" });
    try testing.expectError(
        error.JvmLauncherNotFound,
        getJavaMajorVersionFromFiles(testing.io, gpa, test_util.posixGetenv, cmdline_path, maps_path),
    );
}
