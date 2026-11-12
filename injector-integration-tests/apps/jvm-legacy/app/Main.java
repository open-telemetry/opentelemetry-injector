// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

public class Main {
    public static void main(String[] args) {
        if (args.length == 0) {
            args = new String[] { "otel.injector.jvm.no_op_agent.has_been_loaded" };
        }
        for (String name : args) {
            String value;
            if (name.startsWith("env:")) {
                name = name.substring(4);
                value = System.getenv(name);
            } else {
                value = System.getProperty(name);
            }
            System.out.println(name + ": " + (value == null ? "-" : value));
        }
    }
}
