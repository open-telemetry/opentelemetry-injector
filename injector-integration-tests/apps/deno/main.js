// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const command = Deno.args[0];
switch (command) {
  case 'node-options':
    echoEnvVar('NODE_OPTIONS');
    break;
  case 'verify-auto-instrumentation-agent-has-been-injected':
    echoGlobalProperty('otel_injector_nodejs_no_op_agent_has_been_loaded');
    break;
  case 'otel-resource-attributes':
    echoEnvVar('OTEL_RESOURCE_ATTRIBUTES');
    break;
  default:
    console.error(`error: unknown command "${command}"`);
    Deno.exit(1);
}

function echoEnvVar(envVarName) {
  const envVarValue = Deno.env.get(envVarName);
  if (!envVarValue) {
    Deno.stdout.writeSync(new TextEncoder().encode(`${envVarName}: -`));
  } else {
    Deno.stdout.writeSync(new TextEncoder().encode(`${envVarName}: ${envVarValue}`));
  }
}

function echoGlobalProperty(name) {
  const value = globalThis[name];
  if (!value) {
    Deno.stdout.writeSync(new TextEncoder().encode(`${name}: -`));
  } else {
    Deno.stdout.writeSync(new TextEncoder().encode(`${name}: ${value}`));
  }
}
