#!/bin/sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

PRELOAD_PATH="/etc/ld.so.preload"
LIBOTELINJECT_PATH="/usr/lib/opentelemetry/libotelinject.so"

if [ -f "$PRELOAD_PATH" ] && grep -q "$LIBOTELINJECT_PATH" "$PRELOAD_PATH"; then
    echo "Removing $LIBOTELINJECT_PATH from $PRELOAD_PATH"
    sed -i -e "s|$LIBOTELINJECT_PATH||" "$PRELOAD_PATH"
    if [ ! -s "$PRELOAD_PATH" ] || ! grep -q '[^[:space:]]' "$PRELOAD_PATH"; then
        echo "Removing empty $PRELOAD_PATH"
        rm -f "$PRELOAD_PATH"
    fi
fi
