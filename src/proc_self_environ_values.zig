// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

pub const LogLevel = enum(u8) {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
    None = 4,
};

pub const ProcSelfEnvironValues = struct {
    log_level: LogLevel = .Error,
    pid: u32 = 0,
    otel_injector_disabled: bool = false,
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
