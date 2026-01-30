import builtins

# A simple Python usercustomize script which only sets a system property on the global builtins object, so that an
# application under test can verify whether this agent has been loaded or not.
setattr(builtins, 'otel_injector_python_no_op_agent_has_been_loaded', 'true')