# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

def echo_env_var(name)
  value = ENV[name]
  if value.nil? || value.empty?
    print "#{name}: -"
  else
    print "#{name}: #{value}"
  end
end

def echo_no_op_agent_flag
  value = $otel_injector_ruby_no_op_agent_has_been_loaded
  if value
    print "otel_injector_ruby_no_op_agent_has_been_loaded: #{value}"
  else
    print "otel_injector_ruby_no_op_agent_has_been_loaded: -"
  end
end

command = ARGV[0]
if command.nil?
  warn "error: not enough arguments, the command for the app under test needs to be specified"
  exit 1
end

case command
when "rubyopt"
  echo_env_var("RUBYOPT")
when "additional-gem-path"
  echo_env_var("OTEL_RUBY_ADDITIONAL_GEM_PATH")
when "verify-auto-instrumentation-agent-has-been-injected"
  echo_no_op_agent_flag
when "otel-resource-attributes"
  echo_env_var("OTEL_RESOURCE_ATTRIBUTES")
when "custom-env-var"
  if ARGV[1].nil?
    warn "error: custom-env-var command requires an additional argument"
    exit 1
  end
  echo_env_var(ARGV[1])
else
  warn "unknown test app command: #{command}"
  exit 1
end
