# otel-collector

This host's OpenTelemetry Collector — it receives telemetry, shapes it, and forwards it to [Honeycomb](https://www.honeycomb.io). Today its main job is shaping [Claude Code](https://code.claude.com/docs/en/monitoring-usage) telemetry so it appears in Honeycomb's **Agentic Timeline**; the same collector also carries the host's metrics/logs pipelines and can grow additional shapers (e.g. for other agent runtimes). It runs on **Linux or macOS**.

> Formerly named `claude-collector`. The name was generalized because this is functionally the host's shared OTel collector, of which the Claude-Code Agentic-Timeline shaping is just one processor.

## What it does

Claude Code can emit OTel telemetry: metrics, log/event records, and (in beta) traces. This collector:

1. Receives that telemetry over OTLP.
2. Adds and renames attributes so spans match the conventions Honeycomb's Agentic Timeline expects.
3. Exports to Honeycomb.

## Running the collector

Runs the same way on **Linux or macOS** — the only requirement is Docker (Docker Engine on Linux, Docker Desktop on macOS).

```bash
export HONEYCOMB_API_KEY=<your key for the destination environment>
# US ingest is the default; set to api.eu1.honeycomb.io:443 if you're on EU.
# export HONEYCOMB_API_ENDPOINT=api.honeycomb.io:443

./run                      # foreground; sources .env if present
# or: docker compose up -d # detached / background
```

The collector listens on the standard OTLP gRPC port, **loopback only**:

- gRPC: `localhost:4317`

(The HTTP `:4318` receiver is intentionally omitted — see the comment in `config.yaml`. Add an `http:` block there if you need it.)

If you'd rather run the binary directly, install [`otelcol-contrib`](https://github.com/open-telemetry/opentelemetry-collector-releases) (the `transform` processor is in contrib, not core) and run `otelcol-contrib --config config.yaml` with the same env vars set.

### Running it as a background service

- **Linux (CI runner host):** see [CI runner host](#ci-runner-host-linux-systemd-k3s) below — installer-driven, dedicated system user, k3s receivers.
- **Linux (hp factory host):** see [hp factory host](#hp-factory-host-linux-systemd-host-metrics-only) below — installer-driven, dedicated system user, host/container metrics only.
- **Linux:** a `systemd` unit works well — `Type=simple`, `User=<you>`, `EnvironmentFile=<path>/.env`, `ExecStart=/usr/local/bin/otelcol-contrib --config=<path>/config.yaml`. This host runs it exactly that way.
- **macOS:** use `docker compose up -d` (Docker Desktop can start it at login), or a `launchd` LaunchAgent running the same `otelcol-contrib` command.

## CI runner host (Linux, systemd, k3s)

The self-hosted CI runner host (`poweredge-xubuntu`: k3s + Actions Runner
Controller + Kueue, carrying every livespec fleet repository's gating CI) runs
a SECOND deployment shape of this collector, `config.ci-runner-host.yaml`,
installed by `scripts/install-ci-runner-host.sh`. It exists because the
CI-runner kit in `livespec-dev-tooling` (`ci-runner/observability/`) posts a
5-minute liveness gauge to a local collector on `127.0.0.1:4319`; for eight
days (2026-08-15 → 2026-08-23) no collector was there and the heartbeat
failed twelve times an hour unnoticed (livespec `livespec-s43svm.20`).

What it carries, all into the **`livespec`** Honeycomb environment (the one the
fleet's `github-ci` telemetry already lives in — NOT `agent-activity`, so the
factory host's single-host resource triggers are not mixed with a second host):

| Pipeline | Receivers | Where it lands in `livespec` |
|---|---|---|
| `metrics/host` | `hostmetrics` + `otlp` (the liveness gauges) | the env's single `metrics` dataset |
| `metrics/k3s` | `k8s_cluster` + `kubeletstats` | the env's single `metrics` dataset |
| `traces`, `logs` | `otlp` | auto-routed by `service.name` |

`livespec` is a Honeycomb **Metrics 2.0** environment: every OTLP metric lands in
its one `metrics` dataset and an `x-honeycomb-dataset` header is ignored
(measured 2026-08-23 — a header naming `livespec-host-metrics` created nothing).
Rows are told apart by metric name + `host.name`, not by dataset. This differs
from `agent-activity`, where the factory host's header-pinned
`livespec-host-metrics` is an events-type dataset — which is also why a bare
`COUNT` dead-man works there but the CI-runner dead-man must use
`COUNT_DATAPOINTS(livespec.ci_runners.active)`.

Every row is stamped with `host.name` (`resourcedetection/system`), because the
liveness dead-man trigger is an **ungrouped COUNT filtered to one host** — the
only trigger shape that fires on a host's silence (a grouped query has no group
to evaluate when the host is silent; measured with a paired probe on the homelab
"Floor 1 — dead-man" trigger).

### Onboarding / upgrading the host

```bash
# 0. On a host that has the livespec 1Password Environment wrapper, render the
#    secret env file on the runner host WITHOUT the value touching a terminal.
/usr/local/bin/with-livespec-env.sh -- sh -c \
  'printf "HONEYCOMB_INGEST_KEY_LIVESPEC=%s\n" "$HONEYCOMB_INGEST_KEY_LIVESPEC"' \
  | ssh poweredge-xubuntu 'sudo install -o root -g root -m 0600 /dev/stdin /etc/otel-collector/.env'
# (create /etc/otel-collector first if it does not exist: sudo install -d -m 0755 /etc/otel-collector)

# 1. Copy this repo (or just config.ci-runner-host.yaml, k8s/, systemd/, scripts/)
#    to the host and run the installer as root. Idempotent; re-run to upgrade.
sudo scripts/install-ci-runner-host.sh
```

The installer pins `otelcol-contrib` **0.147.0** (the version every other
deployment of this repo runs; the OTTL gotchas in `CLAUDE.md` were measured on
it), verifies the upstream sha256, creates the unprivileged `otel-collector`
system user, applies `k8s/otel-collector-rbac.yaml` (a read-only ClusterRole +
ServiceAccount), and renders `/etc/otel-collector/kubeconfig` from that
ServiceAccount's token — so the running collector never holds the admin
`k3s.yaml`. Live files under `/etc/otel-collector/`,
`/usr/local/lib/otel-collector/`, and `/etc/systemd/system/otel-collector*.service`
are OUTPUTS of the installer; edit the source here and re-run.

**The cluster identity is re-rendered on every boot**, not only at install
time. The host's k3s datastore is a tmpfs (the `livespec-dev-tooling` kit's
`var-lib-rancher-k3s-server-db.mount`), EMPTY at each boot, so the
`observability/otel-collector` ServiceAccount and its token Secret vanish with
it and a kubeconfig rendered once would carry a token the fresh API server has
never seen (measured 2026-09-02: `k8s_cluster receiver: ... Unauthorized`,
300+ restarts, and the CI heartbeat on `127.0.0.1:4319` down with it). The
installer therefore also installs `scripts/render-k8s-identity.sh` + the RBAC
manifest into `/usr/local/lib/otel-collector/` and enables
`otel-collector-identity.service`
(`systemd/otel-collector-identity.ci-runner-host.service`), a oneshot ordered
after `k3s.service` and before `otel-collector.service` that waits for the API
server's `/readyz`, re-applies the manifest, and re-renders the kubeconfig from
the new token — the identity reconstructs from git with no hand step.

Verify after install:

```bash
systemctl is-enabled otel-collector-identity       # enabled (boot-time re-render)
systemctl is-active otel-collector                 # active
ss -ltn | grep -E '4317|4319'                      # both loopback listeners
systemctl start ci-runner-heartbeat.service        # the kit's heartbeat now exits 0
```

and in Honeycomb (env `livespec`, dataset `metrics`):
`COUNT_DATAPOINTS(livespec.ci_runners.active) where host.name = poweredge-xubuntu`.

## hp factory host (Linux, systemd, host metrics only)

The second Fabro factory host, `hp-xubuntu`, runs a THIRD deployment shape,
`config.hp-factory.yaml`, installed by `scripts/install-hp-factory-host.sh`.
It exists to answer one question `hp` could not answer before: how much free
disk space does this host have right now
(`livespec-orchestrator-beads-fabro` `bd-ib-bdcmok`, requirement R2, Route A,
maintainer-decided 2026-08-29). `hp` does not run interactive Claude Code
sessions and already has a separate receiver for Fabro sandbox worker
telemetry (`livespec-orchestrator-beads-fabro`'s `otel_receiver_daemon.py` on
`172.17.0.1:4318`) — this collector does not duplicate that; it carries only
`hostmetrics` + `docker_stats`, no OTLP receiver at all.

Everything lands in the **`agent-activity`** Honeycomb environment's
`livespec-host-metrics` dataset — the SAME dataset `vps`'s `config.yaml`
`metrics/host` pipeline already writes to. One dataset, one alert threshold,
both factory hosts, instead of two dashboards kept in sync by hand. Both
sides now stamp `resourcedetection/system` so rows stay distinguishable by
`host.name`.

The cost: this host now holds a copy of the `agent-activity` env's
`HONEYCOMB_API_KEY` — an internal-only credential, not customer-facing, on a
host this fleet already fully controls — where before it held only the
`livespec` env's ingest key for its sandbox-telemetry receiver.

`hp`'s `/var/lib/docker` and `/var/lib/containerd` are bind mounts of
`/data/docker` and `/data/containerd` (`/etc/fstab`) — the same filesystem as
`/data`, so `df`-style free-space accounting reports identical numbers for
all three. `config.hp-factory.yaml` excludes both bind-mount aliases from the
filesystem scraper and keeps `/data` itself; nothing is lost, three duplicate
rows are.

### Onboarding / upgrading the host

```bash
# 0. Render the secret env file on hp WITHOUT the value touching a terminal.
#    Same key vps's collector already uses -- copy it from there, not from a
#    fresh 1Password read, so there is exactly one place this key is fetched.
sudo grep '^HONEYCOMB_API_KEY=\|^HONEYCOMB_API_ENDPOINT=' /data/projects/otel-collector/.env \
  | ssh hp-xubuntu 'sudo install -d -m 0755 /etc/otel-collector && sudo install -o root -g root -m 0600 /dev/stdin /etc/otel-collector/.env'

# 1. Copy this repo (or just config.hp-factory.yaml, systemd/, scripts/) to
#    the host and run the installer as root. Idempotent; re-run to upgrade.
sudo scripts/install-hp-factory-host.sh
```

Verify after install:

```bash
systemctl is-active otel-collector                 # active
journalctl -u otel-collector --no-pager -n 30       # no errors, no permission denied
```

and in Honeycomb (env `agent-activity`, dataset `livespec-host-metrics`):
a row for `host.name = hp-xubuntu` alongside the existing `vps` rows.

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

`OTEL_LOG_TOOL_DETAILS=1` is also what makes `subagent_type` available on Task-tool spans, which is what the collector uses to label sub-agent invocations in the timeline.

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

## How the timeline mapping works

The collector applies these transforms to traces (see `config.yaml`):

| Source span                | Becomes                       | `gen_ai.operation.name` |
| -------------------------- | ----------------------------- | ----------------------- |
| `claude_code.interaction`  | `invoke_agent Claude Code`    | `invoke_agent`          |
| `claude_code.llm_request`  | `chat {model}`                | `chat`                  |
| `claude_code.tool` (Task w/ subagent) | `invoke_agent {subagent_type}` | `invoke_agent`   |
| `claude_code.tool` (other) | `execute_tool {tool_name}`    | `execute_tool`          |

Every span also gets `gen_ai.conversation.id` (copied from `session.id`) and `gen_ai.agent.name` (defaults to `"Claude Code"`, overridden to `subagent_type` for Task-tool invocations).

### Known limitations

- The timeline span for a tool call is the parent `claude_code.tool`, whose duration includes the time spent waiting for permission. The more accurate `claude_code.tool.execution` child doesn't carry `tool_name`, so we can't easily synthesize `execute_tool {tool_name}` on it without cross-span propagation.
- A sub-agent's own nested spans (the `claude_code.llm_request` / `claude_code.tool` spans inside a Task call) inherit the default `gen_ai.agent.name = "Claude Code"` instead of the sub-agent's name, for the same reason.

See `notes/` for the full mapping rationale and a list of open questions.
