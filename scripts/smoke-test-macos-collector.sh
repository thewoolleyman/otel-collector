#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LABEL="com.thewoolleyweb.otel-collector"

if [[ ! -f "$REPO_ROOT/.env.local" ]]; then
  echo "Missing $REPO_ROOT/.env.local" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/.env.local"
set +a

: "${HONEYCOMB_API_ENDPOINT:=api.honeycomb.io:443}"

if command -v otelcol-contrib >/dev/null 2>&1; then
  otelcol-contrib validate --config "$REPO_ROOT/config.macos.yaml"
elif [[ -x "$HOME/.local/bin/otelcol-contrib" ]]; then
  "$HOME/.local/bin/otelcol-contrib" validate --config "$REPO_ROOT/config.macos.yaml"
else
  echo "otelcol-contrib not found" >&2
  exit 1
fi

launchctl print "gui/$(id -u)/$LABEL" >/dev/null
lsof -nP -iTCP:4317 -iTCP:4318 -iTCP:8888 -sTCP:LISTEN
curl -fsS http://127.0.0.1:8888/metrics |
  grep -E "otelcol_receiver_accepted|otelcol_exporter_sent|otelcol_process_uptime" |
  head -40
