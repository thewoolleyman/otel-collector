#!/usr/bin/env bash
# install-hp-factory-host.sh — idempotently install (or upgrade) the host OTel
# Collector on the `hp-xubuntu` Fabro FACTORY host, from THIS source tree.
#
# Run as root from a checkout (or a copied subtree) of this repo:
#   sudo scripts/install-hp-factory-host.sh
#
# What it does, in order — every step is safe to re-run:
#   1. Installs the pinned otelcol-contrib binary to /usr/local/bin (download +
#      sha256 check against the upstream release checksums) if absent or at a
#      different version.
#   2. Creates the unprivileged `otel-collector` system user and adds it to
#      the `docker` group (needed for the docker_stats receiver).
#   3. Installs config.hp-factory.yaml -> /etc/otel-collector/config.yaml.
#   4. REQUIRES /etc/otel-collector/.env (mode 0600 root:root) to already hold
#      HONEYCOMB_API_KEY — the agent-activity Honeycomb env's ingest key, the
#      SAME key the `vps` factory host's collector already uses. This script
#      never fetches, prints, or guesses a key; see README.md § "hp factory
#      host" for how to render the file without the value ever touching a
#      terminal.
#   5. Installs the systemd unit, daemon-reloads, enables + (re)starts it, and
#      proves the docker_stats receiver can reach the socket.
#
# Recreatability rule (same as the CI-runner-host installer): the live copies
# under /etc/otel-collector and /etc/systemd/system are OUTPUTS of this
# script; edit the source here and re-run, never the live files.
set -euo pipefail

OTELCOL_VERSION="${OTELCOL_VERSION:-0.147.0}"
src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
etc_dir=/etc/otel-collector
svc_user=otel-collector

if [[ "$(id -u)" -ne 0 ]]; then
  echo "install-hp-factory-host.sh: must run as root (sudo)" >&2
  exit 1
fi

# 1. binary -------------------------------------------------------------------
need_binary=1
if [[ -x /usr/local/bin/otelcol-contrib ]] \
   && /usr/local/bin/otelcol-contrib --version 2>/dev/null | grep -q " ${OTELCOL_VERSION}\$"; then
  need_binary=0
fi
if [[ "$need_binary" -eq 1 ]]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64) rel_arch=amd64 ;;
    aarch64) rel_arch=arm64 ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
  esac
  base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}"
  tarball="otelcol-contrib_${OTELCOL_VERSION}_linux_${rel_arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "downloading otelcol-contrib ${OTELCOL_VERSION} (${rel_arch})"
  curl -fsSL --retry 3 -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"
  (cd "$tmp" && grep " ${tarball}\$" checksums.txt | sha256sum -c -)
  tar -xzf "$tmp/$tarball" -C "$tmp" otelcol-contrib
  install -o root -g root -m 0755 "$tmp/otelcol-contrib" /usr/local/bin/otelcol-contrib
fi
echo "binary: $(/usr/local/bin/otelcol-contrib --version)"

# 2. user ---------------------------------------------------------------------
if ! id "$svc_user" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$svc_user"
fi
if ! id -nG "$svc_user" | grep -qw docker; then
  usermod -aG docker "$svc_user"
  echo "added $svc_user to the docker group (needed for docker_stats)"
fi

# 3. config -------------------------------------------------------------------
install -o root -g root -m 0755 -d "$etc_dir"
install -o root -g root -m 0644 "$src_dir/config.hp-factory.yaml" "$etc_dir/config.yaml"

# 4. secret env (pre-existing, never written here) ------------------------------
if [[ ! -f "$etc_dir/.env" ]]; then
  cat >&2 <<MSG
install-hp-factory-host.sh: missing $etc_dir/.env

It must hold HONEYCOMB_API_KEY=<agent-activity env ingest key> (and, if not
US ingest, HONEYCOMB_API_ENDPOINT), mode 0600 root:root. This is the SAME key
the vps factory host's collector already uses -- render it from that same
1Password Environment WITHOUT the value passing through a terminal, from a
host that already has it (vps):

  sudo grep '^HONEYCOMB_API_KEY=\\|^HONEYCOMB_API_ENDPOINT=' /data/projects/otel-collector/.env \\
    | ssh hp-xubuntu 'sudo install -o root -g root -m 0600 /dev/stdin $etc_dir/.env'

then re-run this installer.
MSG
  exit 1
fi
chown root:root "$etc_dir/.env"
chmod 0600 "$etc_dir/.env"
if ! grep -q '^HONEYCOMB_API_KEY=.\+' "$etc_dir/.env"; then
  echo "install-hp-factory-host.sh: $etc_dir/.env does not set HONEYCOMB_API_KEY" >&2
  exit 1
fi

# 5. unit -----------------------------------------------------------------------
install -o root -g root -m 0644 \
  "$src_dir/systemd/otel-collector.hp-factory-host.service" \
  /etc/systemd/system/otel-collector.service
systemctl daemon-reload
systemctl enable otel-collector.service >/dev/null
systemctl restart otel-collector.service

for _ in $(seq 1 20); do
  systemctl is-active --quiet otel-collector.service && break
  sleep 1
done
systemctl --no-pager --lines=0 status otel-collector.service | head -5
if ! systemctl is-active --quiet otel-collector.service; then
  echo "install-hp-factory-host.sh: otel-collector.service is not active" >&2
  journalctl -u otel-collector.service --no-pager -n 30 >&2
  exit 1
fi
sleep 3
if journalctl -u otel-collector.service --no-pager -n 50 | grep -qiE "error|permission denied"; then
  echo "install-hp-factory-host.sh: WARNING -- errors in the first 50 log lines, check journalctl -u otel-collector" >&2
fi
echo "installed: otel-collector on hp-xubuntu (agent-activity env, livespec-host-metrics dataset)"
