// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import java.util.Map;

public class Main {
    public static void main(String[] args) {
        if (args.length == 0) {
            System.err.println("error: not enough arguments, the command for the app under test needs to be specifed");
            System.exit(1);
        }
        final String command = args[0];
        if (command == null || command.equals("")) {
            System.err.println("error: not enough arguments, the command for the app under test needs to be specifed");
            System.exit(1);
        }

        switch (command) {
            case "verify-javaagent-has-been-injected":
                echoProperty("otel.injector.jvm.no_op_agent.has_been_loaded");
                break;
            case "verify-javaagent-has-been-injected-and-existing-property-is-still-in-place":
                echoProperties(new String[]{"otel.injector.jvm.no_op_agent.has_been_loaded", "some-property"});
                break;
            case "custom-env-var":
                echoEnvVar("CUSTOM_ENV_VAR");
                break;
            default:
                System.out.println("error: unknown test app command: " +  command);
                System.exit(1);
        }
    }

    public static void echoProperty(String propertyName) {
        String value = System.getProperty(propertyName);
        if (value != null) {
            System.out.println(propertyName + ": " + value);
        } else {
            System.out.println(propertyName + ": -");
        }
    }

    public static void echoEnvVar(String envName) {
        String value = System.getenv(envName);
        if (value != null) {
            System.out.println(envName + ": " + value);
        } else {
            System.out.println(envName + ": -");
        }
    }

    public static void echoProperties(String[] propertyNames) {
        for (int i = 0; i < propertyNames.length - 1; i++) {
            System.out.print(propertyNames[i] + ": " + System.getProperty(propertyNames[i]) + "; ");
        }
        echoProperty(propertyNames[propertyNames.length - 1]);
    }
}
