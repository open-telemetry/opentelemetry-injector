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
  const envVarName = process.argv[2];
  if (!envVarName) {
    console.error('error: an environment variable name argument is required');
    process.exit(1);
  }
  echoEnvVar(envVarName);
}

main();
