#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -eu

command=${1:-}

if [ -z "$command" ]; then
  echo "Error: command parameter is required"
  exit 1
fi

injector_binary=/injector/libotelinject.so

check_no_weak_dynamic_symbols() {
  # Use readelf to get dynamic symbols and check for WEAK binding
  weak_symbols=$(readelf --dyn-syms "$injector_binary" 2>/dev/null | grep -E "WEAK" || true)

  if [ -n "$weak_symbols" ]; then
    echo "The injector binary contains weak dynamic symbols, which is not allowed."
    echo "Weak symbols found:"
    echo "$weak_symbols"
    exit 1
  else
    echo "test no weak dynamic symbols successful"
    exit 0
  fi
}

check_no_global_undefined_symbols() {
  # Use readelf to get dynamic symbols and check for GLOBAL binding with UNDEFINED (UND) section
  global_undefined_symbols=$(readelf --dyn-syms "$injector_binary" 2>/dev/null | grep -E "GLOBAL[[:space:]]+UND" || true)

  if [ -n "$global_undefined_symbols" ]; then
    echo "The injector binary contains global undefined dynamic symbols, which is not allowed."
    echo "Global undefined symbols found:"
    echo "$global_undefined_symbols"
    exit 1
  else
    echo "test no global undefined dynamic symbols successful"
    exit 0
  fi
}

check_dynsym_golden_signature() {
  # Expected output: only the mandatory null symbol entry
  # Note: readelf outputs a leading newline before the symbol table header
  expected_output="
Symbol table '.dynsym' contains 1 entry:
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     0: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT  UND "

  actual_output=$(readelf --dyn-syms "$injector_binary" 2>/dev/null)

  if [ "$actual_output" = "$expected_output" ]; then
    echo "test dynsym golden signature successful"
    exit 0
  else
    echo "The injector binary dynamic symbol table does not match the expected signature."
    echo "Expected (only the compulsory null symbol):"
    echo "$expected_output"
    echo ""
    echo "Actual:"
    echo "$actual_output"
    exit 1
  fi
}

case "$command" in
  check_no_weak_dynamic_symbols)
    check_no_weak_dynamic_symbols
    ;;
  check_no_global_undefined_symbols)
    check_no_global_undefined_symbols
    ;;
  check_dynsym_golden_signature)
    check_dynsym_golden_signature
    ;;
  *)
    echo "Error: unknown command '$command'"
    echo "Valid commands: check_no_weak_dynamic_symbols, check_no_global_undefined_symbols, check_dynsym_golden_signature"
    exit 1
    ;;
esac
