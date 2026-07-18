# AGENTS.md — otel-collector

This host's OpenTelemetry Collector (formerly `claude-collector`). It runs on
Linux or macOS and shapes agent telemetry (currently Claude Code; the
macOS-local config also normalizes Codex) for Honeycomb.

Full engineering notes, OTTL gotchas, the attribute-mapping table, and the
version-bump / restart conventions live in [`CLAUDE.md`](CLAUDE.md) — read it
before changing `config.yaml` or `config.macos.yaml`. Deployment and
cross-platform (Linux/macOS) running instructions are in
[`README.md`](README.md).
