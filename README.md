# claude-collector

An OpenTelemetry Collector configuration for receiving telemetry from [Claude Code](https://code.claude.com/docs/en/monitoring-usage) and forwarding it to [Honeycomb](https://www.honeycomb.io), shaped so it appears in Honeycomb's **Agentic Timeline**.

## What it does

Claude Code can emit OTel telemetry: metrics, log/event records, and (in beta) traces. This collector:

1. Receives that telemetry over OTLP.
2. Adds and renames attributes so spans match the conventions Honeycomb's Agentic Timeline expects.
3. Exports to Honeycomb.

## Running the collector

*(Coming soon — config files live alongside this README.)*

The collector listens on the standard OTLP ports:

- gRPC: `localhost:4317`
- HTTP: `localhost:4318`

## Pointing Claude Code at the collector

Set these environment variables before running `claude`. Full reference: <https://code.claude.com/docs/en/monitoring-usage#quick-start>.

```bash
# Turn on telemetry
export CLAUDE_CODE_ENABLE_TELEMETRY=1

# Turn on traces (beta) — required for the Agentic Timeline
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# Choose what to export
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp

# Send to the local collector
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

# Optional: shorter intervals while you're verifying the setup
export OTEL_METRIC_EXPORT_INTERVAL=10000  # 10s (default 60s)
export OTEL_LOGS_EXPORT_INTERVAL=5000     # 5s  (default 5s)

claude
```

By default, Claude Code redacts prompt text, tool inputs, and tool outputs. To include them in spans:

```bash
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_LOG_TOOL_CONTENT=1
```

### What you'll see

Each user turn produces a `claude_code.interaction` root span with these children:

```
claude_code.interaction
├── claude_code.llm_request
├── claude_code.hook
└── claude_code.tool
    ├── claude_code.tool.blocked_on_user
    └── claude_code.tool.execution
```

LLM-request spans already carry the OTel GenAI conventions (`gen_ai.system=anthropic`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`), which is what Honeycomb's Agentic Timeline keys off of.

## Status

Just getting started. See `notes/` for working notes as we figure out the right attribute mapping.
