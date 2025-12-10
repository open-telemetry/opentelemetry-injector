// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;

/// Matches a string against a glob pattern supporting * (any sequence) and ? (single char).
/// Returns true if the text matches the pattern.
fn matchGlob(pattern: []const u8, text: []const u8) bool {
    return matchGlobRecursive(pattern, text, 0, 0);
}

fn matchGlobRecursive(pattern: []const u8, text: []const u8, p_idx: usize, t_idx: usize) bool {
    // If we've consumed both pattern and text, it's a match
    if (p_idx >= pattern.len and t_idx >= text.len) {
        return true;
    }

    // If pattern is exhausted but text remains, no match
    if (p_idx >= pattern.len) {
        return false;
    }

    // Handle * wildcard
    if (pattern[p_idx] == '*') {
        // Try matching * with zero characters
        if (matchGlobRecursive(pattern, text, p_idx + 1, t_idx)) {
            return true;
        }
        // Try matching * with one or more characters
        if (t_idx < text.len and matchGlobRecursive(pattern, text, p_idx, t_idx + 1)) {
            return true;
        }
        return false;
    }

    // If text is exhausted but pattern has non-* characters, no match
    if (t_idx >= text.len) {
        return false;
    }

    // Handle ? wildcard or exact character match
    if (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx]) {
        return matchGlobRecursive(pattern, text, p_idx + 1, t_idx + 1);
    }

    return false;
}

/// Checks if a path matches any of the provided glob patterns.
pub fn matchesAnyPattern(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchGlob(pattern, path)) {
            return true;
        }
    }
    return false;
}

pub fn matchesManyAnyPattern(args: []const []const u8, patterns: []const []const u8) bool {
    if (args.len < 2) {
        return false;
    }
    // args[0] is the program name/path
    // args[1..] are the actual arguments
    for (args[1..]) |arg| {
        for (patterns) |pattern| {
            if (matchGlob(pattern, arg)) {
                return true;
            }
        }
    }

    return false;
}

test "matchGlob: exact match" {
    try testing.expect(matchGlob("/usr/bin/bash", "/usr/bin/bash"));
    try testing.expect(!matchGlob("/usr/bin/bash", "/usr/bin/zsh"));
}

test "matchGlob: star wildcard" {
    try testing.expect(matchGlob("/usr/bin/*", "/usr/bin/bash"));
    try testing.expect(matchGlob("/usr/bin/*", "/usr/bin/zsh"));
    try testing.expect(matchGlob("/usr/bin/*", "/usr/bin/"));
    try testing.expect(!matchGlob("/usr/bin/*", "/usr/local/bin/bash"));
    try testing.expect(matchGlob("/usr/*/bash", "/usr/bin/bash"));
    try testing.expect(matchGlob("/usr/*/bash", "/usr/local/bash"));
    try testing.expect(!matchGlob("/usr/*/bash", "/usr/bin/zsh"));
}

test "matchGlob: multiple stars" {
    try testing.expect(matchGlob("*/bin/*", "/usr/bin/bash"));
    try testing.expect(matchGlob("*/bin/*", "home/user/bin/app"));
    try testing.expect(matchGlob("/usr/*/*", "/usr/bin/bash"));
    try testing.expect(!matchGlob("/usr/*/*", "/usr/bin"));
}

test "matchGlob: question mark wildcard" {
    try testing.expect(matchGlob("/usr/bin/ba?h", "/usr/bin/bash"));
    try testing.expect(matchGlob("/usr/bin/ba?h", "/usr/bin/bath"));
    try testing.expect(!matchGlob("/usr/bin/ba?h", "/usr/bin/bas"));
    try testing.expect(!matchGlob("/usr/bin/ba?h", "/usr/bin/batch"));
}

test "matchGlob: mixed wildcards" {
    try testing.expect(matchGlob("/usr/*/ba?h", "/usr/bin/bash"));
    try testing.expect(matchGlob("*/?sr/bin/*", "/home/usr/bin/app"));
    try testing.expect(matchGlob("*.txt", "file.txt"));
    try testing.expect(matchGlob("*.txt", "archive.txt"));
    try testing.expect(!matchGlob("*.txt", "file.log"));
}

test "matchGlob: empty pattern and text" {
    try testing.expect(matchGlob("", ""));
    try testing.expect(!matchGlob("", "text"));
    try testing.expect(!matchGlob("pattern", ""));
}

test "matchGlob: star matches empty as well as any text" {
    try testing.expect(matchGlob("*", ""));
    try testing.expect(matchGlob("*", "anything"));
    try testing.expect(matchGlob("a*b", "ab"));
    try testing.expect(matchGlob("a*b", "axxxb"));
}

test "matchesAnyPattern: empty patterns" {
    try testing.expect(!matchesAnyPattern("/usr/bin/bash", &.{}));
}

test "matchesAnyPattern: single pattern match" {
    const patterns: []const []const u8 = &.{"/usr/bin/*"};
    try testing.expect(matchesAnyPattern("/usr/bin/bash", patterns));
    try testing.expect(!matchesAnyPattern("/opt/bin/bash", patterns));
}

test "matchesAnyPattern: multiple patterns" {
    const patterns: []const []const u8 = &.{ "/usr/bin/*", "/opt/*/bin/*", "*.sh" };
    try testing.expect(matchesAnyPattern("/usr/bin/bash", patterns));
    try testing.expect(matchesAnyPattern("/opt/local/bin/app", patterns));
    try testing.expect(matchesAnyPattern("script.sh", patterns));
    try testing.expect(!matchesAnyPattern("/home/user/app", patterns));
}

test "matchesManyAnyPattern: empty args" {
    const patterns: []const []const u8 = &.{"/usr/bin/*"};
    try testing.expect(!matchesManyAnyPattern(&.{}, patterns));
}

test "matchesManyAnyPattern: only program name" {
    const patterns: []const []const u8 = &.{"/usr/bin/*"};
    const args: []const []const u8 = &.{"/usr/bin/myprogram"};
    try testing.expect(!matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: empty patterns" {
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "/usr/bin/bash", "arg2" };
    try testing.expect(!matchesManyAnyPattern(args, &.{}));
}

test "matchesManyAnyPattern: single arg matches" {
    const patterns: []const []const u8 = &.{"-javaagent*"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "-javaagent=myagent.jar" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: single arg no match" {
    const patterns: []const []const u8 = &.{"/usr/bin/*"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "/opt/bin/bash" };
    try testing.expect(!matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: multiple args first matches" {
    const patterns: []const []const u8 = &.{"*.sh"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "script.sh", "file.txt" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: multiple args last matches" {
    const patterns: []const []const u8 = &.{"*.txt"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "script.sh", "file.txt" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: multiple patterns and args" {
    const patterns: []const []const u8 = &.{ "/usr/bin/*", "*.sh", "/opt/*/bin/*" };
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "file.txt", "/usr/bin/bash", "data.log" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: multiple args none match" {
    const patterns: []const []const u8 = &.{ "/usr/bin/*", "*.sh" };
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "/opt/bin/app", "file.txt" };
    try testing.expect(!matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: wildcard matches multiple args" {
    const patterns: []const []const u8 = &.{"*"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "anything", "will", "match" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: complex patterns" {
    const patterns: []const []const u8 = &.{ "/usr/*/ba?h", "*.conf", "/opt/*/*" };
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "/usr/local/bash", "script.sh" };
    try testing.expect(matchesManyAnyPattern(args, patterns));
}

test "matchesManyAnyPattern: program name not matched" {
    const patterns: []const []const u8 = &.{"/usr/bin/myprogram"};
    const args: []const []const u8 = &.{ "/usr/bin/myprogram", "arg1" };
    try testing.expect(!matchesManyAnyPattern(args, patterns));
}
