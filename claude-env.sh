# Source this before running `claude` to send its telemetry to the local
# claude-collector (which forwards to Honeycomb).
#
#   source claude-env.sh
#   claude

# Enable telemetry, including the traces beta (required for Agent Timeline).
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# Send metrics, logs, and traces over OTLP.
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp

# Point at the local collector on the standard OTLP gRPC port.
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

# Surface subagent_type on Task-tool spans so the collector can label
# sub-agent invocations in the Agent Timeline.
export OTEL_LOG_TOOL_DETAILS=1

# Shorter export intervals make it easier to see data while you're testing.
# Defaults are 60s for metrics, 5s for logs. Comment out for production use.
export OTEL_METRIC_EXPORT_INTERVAL=10000
export OTEL_LOGS_EXPORT_INTERVAL=5000

# Uncomment to include the raw prompt text and tool input/output on spans.
# These can contain sensitive content -- only enable if you're OK with that.
# export OTEL_LOG_USER_PROMPTS=1
# export OTEL_LOG_TOOL_CONTENT=1

echo "Claude Code will send telemetry to ${OTEL_EXPORTER_OTLP_ENDPOINT}"
