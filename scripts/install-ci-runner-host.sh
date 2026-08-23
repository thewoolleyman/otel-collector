#!/usr/bin/env bash
# install-ci-runner-host.sh — idempotently install (or upgrade) the host OTel
# Collector on a self-hosted CI RUNNER host (k3s + ARC + Kueue; today
# poweredge-xubuntu), from THIS source tree.
#
# Run as root from a checkout (or a copied subtree) of this repo:
#   sudo scripts/install-ci-runner-host.sh
#
# What it does, in order — every step is safe to re-run:
#   1. Installs the pinned otelcol-contrib binary to /usr/local/bin (download +
#      sha256 check against the upstream release checksums) if absent or at a
#      different version.
#   2. Creates the unprivileged `otel-collector` system user.
#   3. Installs config.ci-runner-host.yaml -> /etc/otel-collector/config.yaml.
#   4. REQUIRES /etc/otel-collector/.env (mode 0600 root:root) to already hold
#      HONEYCOMB_INGEST_KEY_LIVESPEC — the livespec Honeycomb env's ingest key,
#      from the livespec 1Password Environment. This script never fetches,
#      prints, or guesses a key; see README.md § "CI runner host" for how to
#      render the file without the value ever touching a terminal.
#   5. Renders /etc/otel-collector/host.env (non-secret: OTEL_K8S_NODE_NAME,
#      HONEYCOMB_API_ENDPOINT default).
#   6. Applies k8s/otel-collector-rbac.yaml with the admin kubeconfig and
#      renders /etc/otel-collector/kubeconfig (0640 root:otel-collector) from
#      the read-only ServiceAccount token, so the running collector never holds
#      the admin credential.
#   7. Installs the systemd unit, daemon-reloads, enables + (re)starts it, and
#      proves the loopback receivers are listening.
#
# Recreatability rule (same as the livespec-dev-tooling ci-runner kit): the
# live copies under /etc/otel-collector and /etc/systemd/system are OUTPUTS of
# this script; edit the source here and re-run, never the live files.
set -euo pipefail

OTELCOL_VERSION="${OTELCOL_VERSION:-0.147.0}"
src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
etc_dir=/etc/otel-collector
svc_user=otel-collector
admin_kubeconfig="${ADMIN_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "install-ci-runner-host.sh: must run as root (sudo)" >&2
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

# 3. config -------------------------------------------------------------------
install -o root -g root -m 0755 -d "$etc_dir"
install -o root -g root -m 0644 "$src_dir/config.ci-runner-host.yaml" "$etc_dir/config.yaml"

# 4. secret env (pre-existing, never written here) ------------------------------
if [[ ! -f "$etc_dir/.env" ]]; then
  cat >&2 <<MSG
install-ci-runner-host.sh: missing $etc_dir/.env

It must hold HONEYCOMB_INGEST_KEY_LIVESPEC=<livespec env ingest key>, mode 0600
root:root. Render it from the livespec 1Password Environment WITHOUT the value
passing through a terminal — from a host that has with-livespec-env.sh:

  /usr/local/bin/with-livespec-env.sh -- sh -c \\
    'printf "HONEYCOMB_INGEST_KEY_LIVESPEC=%s\\n" "\$HONEYCOMB_INGEST_KEY_LIVESPEC"' \\
    | ssh <ci-runner-host> 'sudo install -o root -g root -m 0600 /dev/stdin $etc_dir/.env'

then re-run this installer.
MSG
  exit 1
fi
chown root:root "$etc_dir/.env"
chmod 0600 "$etc_dir/.env"
if ! grep -q '^HONEYCOMB_INGEST_KEY_LIVESPEC=.\+' "$etc_dir/.env"; then
  echo "install-ci-runner-host.sh: $etc_dir/.env does not set HONEYCOMB_INGEST_KEY_LIVESPEC" >&2
  exit 1
fi

# 5. non-secret host env --------------------------------------------------------
node_name="$(hostname)"
cat > "$etc_dir/host.env" <<ENV
# Rendered by install-ci-runner-host.sh — non-secret. Re-run the installer to change.
OTEL_K8S_NODE_NAME=${node_name}
HONEYCOMB_API_ENDPOINT=api.honeycomb.io:443
ENV
chmod 0644 "$etc_dir/host.env"

# 6. cluster identity -----------------------------------------------------------
export KUBECONFIG="$admin_kubeconfig"
kubectl apply -f "$src_dir/k8s/otel-collector-rbac.yaml"
token=""
for _ in $(seq 1 30); do
  token="$(kubectl -n observability get secret otel-collector-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$token" ]] && break
  sleep 1
done
if [[ -z "$token" ]]; then
  echo "install-ci-runner-host.sh: ServiceAccount token never populated" >&2
  exit 1
fi
ca_b64="$(kubectl -n observability get secret otel-collector-token -o jsonpath='{.data.ca\.crt}')"
umask 027
cat > "$etc_dir/kubeconfig" <<KC
apiVersion: v1
kind: Config
clusters:
- name: k3s
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: ${ca_b64}
contexts:
- name: otel-collector@k3s
  context:
    cluster: k3s
    user: otel-collector
current-context: otel-collector@k3s
users:
- name: otel-collector
  user:
    token: ${token}
KC
umask 022
chown "root:${svc_user}" "$etc_dir/kubeconfig"
chmod 0640 "$etc_dir/kubeconfig"
unset token

# 7. unit ---------------------------------------------------------------------
install -o root -g root -m 0644 \
  "$src_dir/systemd/otel-collector.ci-runner-host.service" \
  /etc/systemd/system/otel-collector.service
systemctl daemon-reload
systemctl enable otel-collector.service >/dev/null
systemctl restart otel-collector.service

for _ in $(seq 1 20); do
  if ss -ltn | grep -q '127.0.0.1:4319'; then break; fi
  sleep 1
done
systemctl --no-pager --lines=0 status otel-collector.service | head -5
if ! ss -ltn | grep -q '127.0.0.1:4319'; then
  echo "install-ci-runner-host.sh: collector not listening on 127.0.0.1:4319" >&2
  journalctl -u otel-collector.service --no-pager -n 30 >&2
  exit 1
fi
echo "installed: otel-collector (listening 127.0.0.1:4317 gRPC, 127.0.0.1:4319 HTTP)"
