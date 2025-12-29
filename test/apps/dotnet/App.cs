// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

namespace OpenTelemetry;

using System;

class App
{
    static int Main(string[] args)
    {
        if (args.Length == 0) {
            Console.WriteLine("error: not enough arguments, the command for the app under test needs to be specifed");
            return 1;
        }
        string command = args[0];
        if (command == null || command == "") {
            Console.WriteLine("error: not enough arguments, the command for the app under test needs to be specifed");
            return 1;
        }

        switch (command) {
            case "verify-startup-hook-has-been-injected":
                EchoEnvVar("otel_injector_dotnet_no_op_startup_hook_has_been_loaded");
                break;
            case "custom-env-var":
                EchoEnvVar(args[1]);
                break;
            default:
                Console.WriteLine("error: unknown test app command: " +  command);
                return 1;
        }

        return 0;
    }

    private static void EchoEnvVar(String envVarName)
    {
        string value = Environment.GetEnvironmentVariable(envVarName);
        if (value != null) {
            Console.WriteLine("{0}: {1}", envVarName, value);
        } else {
            Console.WriteLine("{0}: -", envVarName);
        }
    }
}
