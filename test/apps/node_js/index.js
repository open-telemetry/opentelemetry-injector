// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const process = require('node:process');

function echoEnvVar(envVarName) {
  const envVarValue = process.env[envVarName];
  if (!envVarValue) {
    process.stdout.write(`${envVarName}: -`);
  } else {
    process.stdout.write(`${envVarName}: ${envVarValue}`);
  }
}

function main() {
  const command = process.argv[2];
  if (!command) {
    console.error('error: not enough arguments, the command for the app under test needs to be specifed');
    process.exit(1);
  }

  switch (command) {
    case 'non-existing':
      echoEnvVar('DOES_NOT_EXIST');
      break;
    case 'existing':
      echoEnvVar('TEST_VAR');
      break;
    case 'node-options':
      echoEnvVar('NODE_OPTIONS');
      break;
    case 'node-options-twice':
      echoEnvVar('NODE_OPTIONS');
      process.stdout.write('; ');
      echoEnvVar('NODE_OPTIONS');
      break;
    case 'otel-resource-attributes':
      echoEnvVar('OTEL_RESOURCE_ATTRIBUTES');
      break;
    case 'java-tool-options':
      echoEnvVar('JAVA_TOOL_OPTIONS');
      break;
    case 'dotnet-startup-hooks':
      echoEnvVar('DOTNET_STARTUP_HOOKS');
      break;
    case 'custom-env-var':
      echoEnvVar('CUSTOM_ENV_VAR');
      break;
    default:
      console.error(`unknown test app command: ${command}`);
      process.exit(1);
  }
}

main();
