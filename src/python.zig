const std = @import("std");
const config = @import("config.zig");
const print = @import("print.zig");

pub const pyton_path_env_var_name = "PYTHONPATH";

pub fn getModule(allocator: std.mem.Allocator, module: []const u8, pypath: []const u8) ?[:0]u8 {
    if (module.len == 0) {
        print.printInfo("Skipping Python injection because no configuration was provided", .{});
        return null;
    }

    if (std.mem.indexOf(u8, pypath, module) != null) {
        print.printError("Skipping Python injection because an auto-instrumentation agent was already detected in \"PYTHONPATH\"", .{});
        return null;
    }

    std.fs.cwd().access(module, .{}) catch |err| {
        print.printError("Skipping Python injection because the agent module at {s} could not be accessed: {}", .{ module, err });
        return null;
    };

    const new_pypath = std.mem.joinZ(allocator, ":", &[_][]const u8{ module, pypath }) catch {
        return null;
    };
    return new_pypath;
}

test "getModule: skip when no config is provided" {
    const module = getModule(std.testing.allocator, "", "");
    try std.testing.expectEqual(null, module);
}

test "getModule: skip python agent path is already in PYTHONPATH" {
    const old_pythonpath = "/usr/local:/foo/bar/foobar:/usr/local/lib/python-otel-agent";
    const maybe_module = getModule(std.testing.allocator, "/usr/local/lib/python-otel-agent", old_pythonpath);
    try std.testing.expectEqual(null, maybe_module);
}

test "getModule: module does not exist or not accessible" {
    const maybe_module = getModule(std.testing.allocator, "/var/foo/bar", "");
    try std.testing.expectEqual(null, maybe_module);
}

test "getModule: prepend module path" {
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const agent_module = try tmp_dir.dir.createFile("python-otel-agent", .{});
    defer agent_module.close();

    const agent_module_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "python-otel-agent");
    defer testing.allocator.free(agent_module_path);

    const old_pythonpath = "/usr/local:/foo/bar";
    const maybe_module = getModule(std.testing.allocator, agent_module_path, old_pythonpath);
    try std.testing.expect(maybe_module != null);
    defer testing.allocator.free(maybe_module.?);

    try std.testing.expectStringStartsWith(maybe_module.?, agent_module_path);
}
