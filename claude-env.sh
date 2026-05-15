# Source this before running `claude` to send its telemetry to the local
# claude-collector (which forwards to Honeycomb).
#
#   source claude-env.sh
#   claude

# ---- Core: telemetry on, traces beta on (required for Agent Timeline) ----
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# Send metrics, logs, and traces over OTLP.
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp

# Point at the local collector on the standard OTLP gRPC port.
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

# service.name -> Honeycomb dataset name for traces.
export OTEL_SERVICE_NAME=claude-code

# Custom resource attributes. Add anything you want to tag every span with.
export OTEL_RESOURCE_ATTRIBUTES="source=claude-code"

# ---- Detailed beta tracing (claude_code.hook spans + richer content attrs) ----
# Requires your org to be allowlisted for interactive sessions; works
# unconditionally for Agent SDK and `claude -p`. Points at the local collector
# so the data flows through our transformations on its way to Honeycomb.
export ENABLE_BETA_TRACING_DETAILED=1
export BETA_TRACING_ENDPOINT=http://localhost:4317

# ---- Content gates: include prompts, tool I/O, and raw API bodies ----
# Each of these reveals sensitive content. Comment any of them out for
# privacy-sensitive use.
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_LOG_TOOL_CONTENT=1
# Logs full Anthropic Messages API request and response as separate log events
# (`claude_code.api_request_body`, `..._response_body`). Implies all the
# OTEL_LOG_* gates above. Bodies are truncated at 60 KB.
export OTEL_LOG_RAW_API_BODIES=1

# ---- Metrics cardinality (default values shown; OTEL_METRICS_INCLUDE_VERSION defaults off) ----
export OTEL_METRICS_INCLUDE_VERSION=true
export OTEL_METRICS_INCLUDE_SESSION_ID=true
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true

# ---- Faster export while debugging ----
# Defaults: metrics 60s, logs 5s. Comment out for production-y use.
export OTEL_METRIC_EXPORT_INTERVAL=10000
export OTEL_LOGS_EXPORT_INTERVAL=5000

echo "Claude Code will send telemetry to ${OTEL_EXPORTER_OTLP_ENDPOINT}"
