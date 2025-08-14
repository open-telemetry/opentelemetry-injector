package io.opentelemetry.javaagent;

import java.lang.instrument.*;

public class NoOpAgent {
    public static void premain(String args, Instrumentation inst) {
        // Intentionally left (almost) empty. We only set a system property that the application under test can use to
        // verify that the no-op agent has been loaded.
        System.setProperty("otel.injector.jvm.no_op_agent.has_been_loaded", "true");
    }
}