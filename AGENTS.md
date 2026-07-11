> **⚠️ IMPORTANT — PENDING macOS RENAME MIGRATION. If you are on macOS, do this FIRST, before any other work, on the first session that sees this:** the collector was renamed `claude-collector` → `otel-collector`, including the macOS launchd label (`com.thewoolleyweb.claude-collector` → `com.thewoolleyweb.otel-collector`). Run the migration in [`plan/rename-to-otel-collector-macos-migration.md`](plan/rename-to-otel-collector-macos-migration.md) to move the local LaunchAgent to the new name. **Once the collector is successfully running and smoke-tested under the new label on this Mac, DELETE this reminder (and the mirrored pointer at the top of [`CLAUDE.md`](CLAUDE.md)) and archive that plan.** On Linux/the VPS this migration does not apply — the VPS rename is handled separately.

# AGENTS.md — otel-collector

This host's OpenTelemetry Collector (formerly `claude-collector`). It runs on
Linux or macOS and shapes agent telemetry (currently Claude Code; the
macOS-local config also normalizes Codex) for Honeycomb.

Full engineering notes, OTTL gotchas, the attribute-mapping table, and the
version-bump / restart conventions live in [`CLAUDE.md`](CLAUDE.md) — read it
before changing `config.yaml` or `config.macos.yaml`. Deployment and
cross-platform (Linux/macOS) running instructions are in
[`README.md`](README.md).
