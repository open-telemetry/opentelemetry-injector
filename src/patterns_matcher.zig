// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;

/// Matches a string against a glob pattern supporting * (any sequence) and ? (single char).
/// Returns true if the text matches the pattern.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
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

test "matchGlob: star matches empty" {
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
