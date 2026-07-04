# macOS Local Collector Routing Plan

You are operating in `/Users/cwoolley/workspace/claude-collector`, a local clone
of `git@github.com:thewoolleyman/claude-collector.git`.

Your job is to set up a local macOS OpenTelemetry Collector that receives Codex
telemetry on this Mac, normalizes only real emitted fields, forwards the data to
Honeycomb `agent-activity`, and proves that the existing VPS Claude collector
continues to run from the same repo without being broken.

Do not stop at a proposal. Implement, verify, commit, and push a branch unless a
hard blocker requires user input.

## Non-Negotiables

- Preserve the VPS collector. The active VPS service uses
  `vps:/data/projects/claude-collector/config.yaml`; do not modify that file for
  macOS routing in this pass.
- Add macOS-specific files alongside the existing config, for example
  `config.macos.yaml`, `bin/run-macos-collector`, `launchd/*.plist.example`, and
  `scripts/*`.
- Do not expose OTLP receivers on public interfaces. Bind local receivers to
  `127.0.0.1` only.
- Do not commit secrets. `.env.local`, generated plists, logs, and scratch
  output must be gitignored.
- Before installing anything system-wide, inspect `~/Brewfile`; global/system
  packages are Homebrew-managed on this Mac.
- Do not print Honeycomb keys or full `~/.codex/config.toml` contents. Redact
  secrets in all logs and notes.
- Do not manufacture false telemetry fields. Add aliases/transforms only from
  fields that are actually emitted by Codex or Claude.
- Treat `config.yaml` as the VPS production config. If it needs changes for VPS,
  that is a separate deploy with separate VPS tests.

## Current Known State

VPS:

- Repo path: `vps:/data/projects/claude-collector`
- Service: `claude-collector.service`
- Active command:
  `/usr/local/bin/otelcol-contrib --config=/data/projects/claude-collector/config.yaml`
- Listener: `127.0.0.1:4317`
- Internal metrics: `127.0.0.1:8888`
- Working branch: `main`
- Known HEAD: `6810480`
- `origin`: `https://github.com/thewoolleyman/claude-collector.git`
- `upstream`: `https://github.com/jessitron/claude-collector.git`

Mac:

- Codex currently exports OTLP/HTTP directly to Honeycomb through
  `~/.codex/config.toml` `[otel]`.
- Previous local investigation found no local collector listening on `4317` or
  `4318`.
- This pass should put a local collector in between Codex and Honeycomb.

## Target Architecture

Mac Codex:

```text
Codex on Mac
  -> OTLP/HTTP localhost:4318
  -> local otelcol-contrib using config.macos.yaml
  -> Honeycomb agent-activity
```

Local Claude Code on Mac, if used later:

```text
Claude Code on Mac
  -> OTLP/gRPC localhost:4317
  -> local otelcol-contrib using config.macos.yaml
  -> Honeycomb agent-activity
```

VPS Claude Code must remain:

```text
Claude Code on VPS
  -> OTLP/gRPC localhost:4317
  -> vps systemd claude-collector.service
  -> /data/projects/claude-collector/config.yaml
  -> Honeycomb agent-activity
```

## Phase 0: Repo And Branch Preflight

Run:

```bash
pwd
git status --short
git remote -v
git fetch --all --prune
git branch --show-current
git log --oneline --decorate --max-count=8
```

If not already on a feature branch, create one:

```bash
git switch -c codex/macos-local-collector-routing
```

Record the starting state in `tmp/macos-local-collector/preflight.md`.

## Phase 1: Prove VPS Is Healthy Before Mac Changes

Create a scratch directory:

```bash
mkdir -p tmp/macos-local-collector
```

Run these read-only checks and save output under
`tmp/macos-local-collector/vps-before.txt`:

```bash
ssh vps 'set -e
echo "== repo =="
cd /data/projects/claude-collector
pwd
git status --short
git branch --show-current
git rev-parse --short HEAD
git remote -v
echo "== service =="
systemctl is-enabled claude-collector.service
systemctl is-active claude-collector.service
systemctl status claude-collector.service --no-pager -l | sed -n "1,35p"
echo "== listeners =="
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep -E "4317|4318|8888|otelcol" || true
echo "== collector metrics =="
curl -fsS http://127.0.0.1:8888/metrics | grep -E "otelcol_receiver_accepted|otelcol_exporter_sent|otelcol_process_uptime" | head -40 || true
echo "== recent warnings/errors =="
journalctl -u claude-collector.service --since "15 minutes ago" --no-pager -p warning | tail -40 || true
'
```

Acceptance before continuing:

- Service is enabled and active.
- Repo is clean.
- HEAD is still the expected VPS commit unless you can explain a newer commit.
- `127.0.0.1:4317` is listening.
- Collector metrics endpoint responds.

If these fail, stop and report. Do not change the Mac routing until the baseline
is clear.

## Phase 2: Add macOS Collector Files

Add these committed files:

- `config.macos.yaml`
- `bin/run-macos-collector`
- `launchd/com.thewoolleyweb.claude-collector.plist.example`
- `scripts/install-macos-launchagent.sh`
- `scripts/uninstall-macos-launchagent.sh`
- `scripts/smoke-test-macos-collector.sh`

Update `.gitignore` for:

- `.env.local`
- `tmp/`
- `*.log`
- generated launchd plists if any are written inside the repo

### `config.macos.yaml` Requirements

Use a separate macOS config instead of modifying `config.yaml`.

Receiver requirements:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318
```

Exporter requirements:

```yaml
exporters:
  otlp/honeycomb:
    endpoint: ${env:HONEYCOMB_API_ENDPOINT}
    headers:
      x-honeycomb-team: ${env:HONEYCOMB_API_KEY}
```

Processor requirements:

- Keep `batch`.
- Add a macOS marker processor that stamps all three signals with:
  - `collector.agent-activity-local = "washere"`
  - `collector.agent-activity-local.version = "0.1"`
  - `collector.agent-activity-local.host = "macos"`
- Add conservative Codex normalization transforms:
  - `conversation.id` -> `gen_ai.conversation.id` where present.
  - `session.id` -> `gen_ai.conversation.id` only if conversation id was not
    already set.
  - `tool.name` or `tool_name` -> `gen_ai.tool.name` where present.
  - `tool.call_id` or `call_id` -> `gen_ai.tool.call.id` where present.
  - `codex.turn.token_usage.input_tokens` -> `gen_ai.usage.input_tokens`.
  - `codex.turn.token_usage.output_tokens` -> `gen_ai.usage.output_tokens`.
  - `codex.turn.token_usage.total_tokens` -> `gen_ai.usage.total_tokens` if
    Honeycomb accepts it.
  - `api.path` -> `route` only when `api.path` exists.
- Do not derive `http.response.status_code` from OTel span `status_code`.
- Do not create `trace.link.trace_id` or `trace.link.span_id`.
- Avoid aggressive span renames in the first pass unless live data proves they
  are correct.

Pipelines:

- traces: `otlp -> marker -> codex normalize -> batch -> honeycomb`
- logs: `otlp -> marker -> batch -> honeycomb`
- metrics: `otlp -> marker -> batch -> honeycomb`

### `bin/run-macos-collector` Requirements

Make a small shell wrapper that:

- determines the repo root,
- sources `.env.local`,
- requires `HONEYCOMB_API_KEY`,
- defaults `HONEYCOMB_API_ENDPOINT=api.honeycomb.io:443` if unset,
- finds `otelcol-contrib`,
- execs:

```bash
otelcol-contrib --config "$REPO_ROOT/config.macos.yaml"
```

Do not echo secrets.

### LaunchAgent Requirements

Use a user LaunchAgent, not a system LaunchDaemon, unless there is a specific
reason root is required.

Suggested label:

```text
com.thewoolleyweb.claude-collector
```

The actual installed plist should live at:

```text
~/Library/LaunchAgents/com.thewoolleyweb.claude-collector.plist
```

It should run:

```text
/Users/cwoolley/workspace/claude-collector/bin/run-macos-collector
```

Use log paths under:

```text
/Users/cwoolley/workspace/claude-collector/tmp/macos-local-collector/
```

## Phase 3: Install Or Locate `otelcol-contrib` On The Mac

First inspect Homebrew state:

```bash
rg -n "otel|opentelemetry|collector|otelcol|honeycomb" ~/Brewfile || true
command -v otelcol-contrib || true
brew search opentelemetry || true
```

If Homebrew does not provide `otelcol-contrib`, install a release binary under
the user's local bin directory, not by scattering files globally:

```text
/Users/cwoolley/.local/bin/otelcol-contrib
```

Use the same major/minor family as the VPS when practical. The VPS currently
runs `otelcol-contrib` `0.147.0`; prefer that version unless the release is
unavailable for this Mac architecture.

Verify:

```bash
otelcol-contrib --version
otelcol-contrib validate --config config.macos.yaml
```

If this collector version lacks `validate`, run it briefly in foreground and
verify it starts cleanly, then stop it:

```bash
./bin/run-macos-collector
```

## Phase 4: Configure `.env.local`

Create `.env.local` from a safe source of the Honeycomb ingest key. Do not commit
it.

Required shape:

```bash
export HONEYCOMB_API_KEY="..."
export HONEYCOMB_API_ENDPOINT="api.honeycomb.io:443"
```

If the only available key is currently in `~/.codex/config.toml`, extract it
without printing it. Prefer moving long-term key management to 1Password, but do
not block this pass on that if the existing local config already contains the
key.

Verify without leaking the key:

```bash
test -f .env.local
chmod 600 .env.local
bash -lc 'source ./.env.local && test -n "$HONEYCOMB_API_KEY" && echo key_present'
```

## Phase 5: Start The macOS Collector

Install and load the LaunchAgent:

```bash
./scripts/install-macos-launchagent.sh
```

Verify:

```bash
launchctl print "gui/$(id -u)/com.thewoolleyweb.claude-collector"
lsof -nP -iTCP:4317 -iTCP:4318 -sTCP:LISTEN
curl -fsS http://127.0.0.1:8888/metrics | grep -E "otelcol_receiver_accepted|otelcol_exporter_sent|otelcol_process_uptime" | head -40
```

Expected:

- `otelcol-contrib` is running.
- `127.0.0.1:4317` and `127.0.0.1:4318` are listening.
- `127.0.0.1:8888/metrics` responds.

## Phase 6: Route Codex OTLP/HTTP Through The Local Collector

Backup the Codex config:

```bash
cp ~/.codex/config.toml "tmp/macos-local-collector/config.toml.before.$(date +%Y%m%d%H%M%S)"
```

Modify only the `[otel]` exporter endpoints in `~/.codex/config.toml`:

```toml
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "binary", headers = { } } }
trace_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/traces", protocol = "binary", headers = { } } }
metrics_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/metrics", protocol = "binary", headers = { } } }
```

If Codex rejects empty headers, preserve the existing header table as a
temporary compatibility measure and document it. The local collector should not
need Codex to send Honeycomb headers.

Do not print the full file after editing. Validate with redacted output only.

Restart the relevant Codex process/session so it reads the config. If this is a
Codex Desktop app-server setting, restart Codex Desktop or start a fresh Codex
CLI session for verification.

## Phase 7: Generate And Verify Mac Telemetry

Generate a small, intentional Codex telemetry sample from a fresh process. Keep
the action harmless, for example a short CLI invocation or a fresh Codex session
that runs `date` / `pwd`.

Then verify locally:

```bash
curl -fsS http://127.0.0.1:8888/metrics | grep -E "otelcol_receiver_accepted|otelcol_exporter_sent|otelcol_exporter_send_failed" | head -80
```

Verify in Honeycomb using the Honeycomb MCP if available, otherwise via the UI.
Look for fresh data in `agent-activity`, especially `codex-app-server` and
`codex_cli_rs`, with marker fields:

- `collector.agent-activity-local = "washere"`
- `collector.agent-activity-local.version = "0.1"`
- `collector.agent-activity-local.host = "macos"`

Also verify that existing useful Codex fields are preserved:

- `trace.trace_id`
- `trace.span_id`
- `trace.parent_id`
- `service.name`
- `name`
- `duration_ms`
- `http.response.status_code` when actually present
- `api.path`
- `conversation.id`
- `turn.id`
- `tool.name`
- `tool.call_id`
- `gen_ai.usage.input_tokens`
- `gen_ai.usage.output_tokens`

If Honeycomb shows no fresh marked data, do not declare success. Check:

- LaunchAgent logs.
- `otelcol_exporter_send_failed_*` metrics.
- whether Codex actually restarted.
- whether Codex accepts the local OTLP/HTTP endpoint shape.
- whether firewall or TLS assumptions are wrong.

## Phase 8: Prove VPS Still Works After Mac Changes

Repeat the VPS checks and save output under
`tmp/macos-local-collector/vps-after.txt`:

```bash
ssh vps 'set -e
echo "== repo =="
cd /data/projects/claude-collector
pwd
git status --short
git branch --show-current
git rev-parse --short HEAD
git remote -v
echo "== service =="
systemctl is-enabled claude-collector.service
systemctl is-active claude-collector.service
systemctl status claude-collector.service --no-pager -l | sed -n "1,35p"
echo "== listeners =="
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep -E "4317|4318|8888|otelcol" || true
echo "== collector metrics =="
curl -fsS http://127.0.0.1:8888/metrics | grep -E "otelcol_receiver_accepted|otelcol_exporter_sent|otelcol_process_uptime" | head -40 || true
echo "== recent warnings/errors =="
journalctl -u claude-collector.service --since "15 minutes ago" --no-pager -p warning | tail -40 || true
'
```

Acceptance:

- VPS service remains enabled and active.
- VPS still listens on `127.0.0.1:4317`.
- VPS repo remains clean.
- VPS HEAD did not change unless you intentionally deployed and documented it.
- No Mac-only file is required for the VPS service to run.
- No public `0.0.0.0:4317` or `0.0.0.0:4318` listener appears on the VPS.

## Phase 9: Commit And Push

Before committing:

```bash
git status --short
git diff --check
```

Commit only repo files. Do not commit:

- `.env.local`
- generated launchd plist
- scratch files under `tmp/`
- logs
- backups of `~/.codex/config.toml`

Commit:

```bash
git add .gitignore config.macos.yaml bin/run-macos-collector launchd scripts plan/macos-local-collector-routing-plan.md
git commit -m "Add macOS local collector routing"
git push -u origin codex/macos-local-collector-routing
```

Do not merge to `main` unless the user asks. The VPS tracks `main`, so keeping
the Mac work on a branch is the safest default until reviewed.

## Final Report Requirements

Report:

- Local branch and commit.
- Whether the Mac collector is installed and running.
- Exact local listener state for `4317`, `4318`, and `8888`.
- What changed in `~/.codex/config.toml`, without secrets.
- Honeycomb evidence that fresh Codex telemetry passed through the Mac collector.
- VPS before/after proof summary.
- Any residual risk or rollback steps.

Rollback commands must include:

```bash
./scripts/uninstall-macos-launchagent.sh
cp tmp/macos-local-collector/config.toml.before.<timestamp> ~/.codex/config.toml
```

Then restart Codex so it reads the restored direct-to-Honeycomb config.

