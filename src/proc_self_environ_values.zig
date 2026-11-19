// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const options = @import("config_generated.zig");

pub const LogLevel = @import("config_option.zig").LogLevel;

pub const ProcSelfEnvironValues = struct {
    log_level: LogLevel = options.log_level.default_value,
    pid: u32 = 0,
    otel_injector_disabled: bool = options.disabled.default_value,
};

var proc_self_environ_values: ProcSelfEnvironValues = .{};

pub fn reset() void {
    proc_self_environ_values = .{};
}

pub fn getPid() u32 {
    return proc_self_environ_values.pid;
}

pub fn setPid(pid: u32) void {
    proc_self_environ_values.pid = pid;
}

pub fn getLogLevel() LogLevel {
    return proc_self_environ_values.log_level;
}

pub fn setLogLevel(log_level: LogLevel) void {
    proc_self_environ_values.log_level = log_level;
}

pub fn getOtelInjectorDisabled() bool {
    return proc_self_environ_values.otel_injector_disabled;
}

pub fn setOtelInjectorDisabled(otel_injector_disabled: bool) void {
    proc_self_environ_values.otel_injector_disabled = otel_injector_disabled;
}
