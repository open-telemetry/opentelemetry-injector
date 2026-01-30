# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

import builtins
import os
import sys


def echo_env_var(env_var_name):
    env_var_value = os.environ.get(env_var_name)
    if not env_var_value:
        sys.stdout.write(f"{env_var_name}: -")
    else:
        sys.stdout.write(f"{env_var_name}: {env_var_value}")


def echo_builtin_property():
    value = builtins.otel_injector_python_no_op_agent_has_been_loaded
    if not value:
        sys.stdout.write(f"otel_injector_python_no_op_agent_has_been_loaded: -")
    else:
        sys.stdout.write(f"otel_injector_python_no_op_agent_has_been_loaded: {value}")

def main():
    if len(sys.argv) < 2:
        sys.stderr.write('error: not enough arguments, the command for the app under test needs to be specifed\n')
        sys.exit(1)

    command = sys.argv[1]

    if command == 'pythonpath':
        echo_env_var('PYTHONPATH')
    elif command == 'verify-auto-instrumentation-agent-has-been-injected':
        echo_builtin_property()
    elif command == 'otel-resource-attributes':
        echo_env_var('OTEL_RESOURCE_ATTRIBUTES')
    elif command == 'custom-env-var':
        if len(sys.argv) < 3:
            sys.stderr.write('error: custom-env-var command requires an additional argument\n')
            sys.exit(1)
        echo_env_var(sys.argv[2])
    else:
        sys.stderr.write(f'unknown test app command: {command}\n')
        sys.exit(1)


if __name__ == '__main__':
    main()
