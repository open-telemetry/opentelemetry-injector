# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Regression test for issue #399:
# "panic: integer overflow in ElfDynLib.lookupAddress on empty GNU hash bucket"
#
# The Red Hat UBI 8 base image ships glibc 2.28. On glibc < 2.34,
# /proc/self/maps shows "libc-2.28.so" not "libc.so.6", so the injector's first
# pass finds nothing and the second pass scans ALL mapped .so files.
#
# Note: this used to be debian:bullseye-slim (glibc 2.31), but Debian 11 has
# reached its end of life, so its apt repositories no longer work (expired
# Release files, packages removed from the security pool). UBI 8 is supported
# until 2029.
#
# A crafted library (trigger.so) has a .gnu.hash section where the bloom filter
# passes (false positive) for "setenv" but the corresponding bucket value is 0
# (empty bucket). Without the fix, this causes:
#   chain_index = 0 - symoffset(1) → u32 underflow → panic: integer overflow → SIGABRT
#
# premapper.so maps trigger.so at a fixed low address (0x1000000) before the
# injector's constructor runs, so the second-pass scan hits it before libc.
# Because premapper.so is listed second in LD_PRELOAD, its constructor runs first
# (the dynamic linker initialises later entries first when there are no inter-
# library dependencies), ensuring trigger.so is already mapped when the injector's
# initEnviron is called.
ARG base_image_run="registry.access.redhat.com/ubi8/ubi:8.10@sha256:2dcfc23b79d88fdaeefc6ed0cfb144e41dca600bfa73c38ab5d8dca5b05d1b7f"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

RUN dnf install -y gcc glibc-devel python3 \
    && dnf clean all

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

# Generate the crafted trigger.so with the malformed GNU hash section.
COPY injector-integration-tests/apps/empty-gnu-hash-bucket/gen_trigger_so.py /tmp/gen_trigger_so.py
RUN ARCH=$(uname -m); \
    if [ "$ARCH" = "aarch64" ]; then MACHINE=183; \
    elif [ "$ARCH" = "x86_64" ]; then MACHINE=62; \
    else echo "Unsupported arch: $ARCH" && exit 1; fi; \
    python3 /tmp/gen_trigger_so.py --machine "$MACHINE" /trigger.so

# Build the premapper shared library.
# It maps /trigger.so at 0x1000000 in its constructor, before the injector runs.
COPY injector-integration-tests/apps/empty-gnu-hash-bucket/premapper.c /tmp/premapper.c
RUN gcc -shared -fPIC -o /premapper.so /tmp/premapper.c

WORKDIR /usr/src/otel/injector

# Build the test binary (plain C, no -ldl, so the injector's second pass is triggered).
COPY injector-integration-tests/apps/empty-gnu-hash-bucket/printenv.c .
RUN mkdir -p app && gcc -o app/printenv printenv.c && rm printenv.c

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
