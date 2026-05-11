package io.opentelemetry.javaagent;

import java.lang.instrument.*;

// A simple Java agent that only sets a system property, so that an application under test can verify whether this agent
// has been loaded or not.
public class NoOpAgent {
    public static void premain(String args, Instrumentation inst) {
        // Intentionally left (almost) empty. We only set a system property that the application under test can use to
        // verify that the no-op agent has been loaded.
        System.setProperty("otel.injector.jvm.no_op_agent.has_been_loaded", "true");
    }
}