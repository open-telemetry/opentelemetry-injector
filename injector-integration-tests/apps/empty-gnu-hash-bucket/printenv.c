// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// A minimal C program that prints the value of a named environment variable.
// Deliberately uses only libc (stdio, stdlib) and is compiled without -ldl, so
// libdl.so does not appear in /proc/self/maps at runtime. This reproduces the
// scenario seen on RHEL 8 and any other pre-glibc-2.34 system where dlsym lives
// in libdl.so (not in libc.so), and the binary under test does not link libdl.

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "error: an environment variable name argument is required\n");
        return 1;
    }
    const char *name = argv[1];
    const char *value = getenv(name);
    if (value == NULL) {
        printf("%s: -", name);
    } else {
        printf("%s: %s", name, value);
    }
    return 0;
}
