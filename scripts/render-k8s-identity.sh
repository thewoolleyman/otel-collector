#!/usr/bin/env bash
# render-k8s-identity.sh — (re)create the CI-runner host collector's READ-ONLY
# cluster identity and render /etc/otel-collector/kubeconfig from it.
#
# Installed by scripts/install-ci-runner-host.sh to
#   /usr/local/lib/otel-collector/render-k8s-identity.sh   (root, 0755)
# next to the RBAC manifest it applies,
#   /usr/local/lib/otel-collector/otel-collector-rbac.yaml  (k8s/otel-collector-rbac.yaml)
# and run (a) once by the installer and (b) on EVERY boot by
# otel-collector-identity.service, which orders itself after k3s.service and
# before otel-collector.service.
#
# Why it runs on every boot: the host's k3s datastore
# (/var/lib/rancher/k3s/server/db, the livespec-dev-tooling kit's
# var-lib-rancher-k3s-server-db.mount) is a tmpfs, EMPTY at every boot. The
# `observability` namespace, the otel-collector ServiceAccount, its token
# Secret, and the ClusterRole/Binding are all wiped with it, so a kubeconfig
# rendered once by hand carries a token the API server no longer knows
# (`failed to start "k8s_cluster" receiver: ... Unauthorized`, measured
# 2026-09-02 after the 12:14Z reboot: 300+ restarts). Re-applying the manifest
# and re-rendering the kubeconfig from the fresh token before the collector
# starts is what makes the identity reconstruct from git with no hand step.
#
# Idempotent and safe to re-run at any time: `kubectl apply` converges the
# objects and the kubeconfig is simply rewritten (0640 root:otel-collector;
# the collector reads it once at startup). The token is never printed and is
# unset before exit.
#
# Env:
#   KUBECONFIG  admin kubeconfig to apply the manifest with
#               (default /etc/rancher/k3s/k3s.yaml; the unit sets it explicitly).
#   OTEL_COLLECTOR_ETC_DIR / OTEL_COLLECTOR_LIB_DIR / OTEL_COLLECTOR_USER
#               overrides for the paths below; only the installer's defaults
#               are exercised.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
etc_dir="${OTEL_COLLECTOR_ETC_DIR:-/etc/otel-collector}"
lib_dir="${OTEL_COLLECTOR_LIB_DIR:-/usr/local/lib/otel-collector}"
svc_user="${OTEL_COLLECTOR_USER:-otel-collector}"
rbac_manifest="$lib_dir/otel-collector-rbac.yaml"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "render-k8s-identity.sh: must run as root" >&2
  exit 1
fi
if [[ ! -f "$rbac_manifest" ]]; then
  echo "render-k8s-identity.sh: missing $rbac_manifest (run install-ci-runner-host.sh)" >&2
  exit 1
fi
if ! id "$svc_user" >/dev/null 2>&1; then
  echo "render-k8s-identity.sh: user $svc_user does not exist (run install-ci-runner-host.sh)" >&2
  exit 1
fi

# 1. Wait for the API server to actually SERVE. k3s.service being `active`
#    only means the process is up; the apiserver answers /readyz some seconds
#    later, and on a tmpfs datastore it is also bootstrapping an empty etcd.
ready=0
for _ in $(seq 1 60); do
  if kubectl get --raw /readyz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "render-k8s-identity.sh: API server never answered /readyz (KUBECONFIG=$KUBECONFIG)" >&2
  exit 1
fi

# 2. Converge the identity objects (namespace, ServiceAccount, token Secret,
#    ClusterRole, ClusterRoleBinding).
kubectl apply -f "$rbac_manifest"

# 3. Wait for the token controller to populate the long-lived token Secret.
token=""
for _ in $(seq 1 30); do
  token="$(kubectl -n observability get secret otel-collector-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$token" ]] && break
  sleep 1
done
if [[ -z "$token" ]]; then
  echo "render-k8s-identity.sh: ServiceAccount token never populated" >&2
  exit 1
fi
ca_b64="$(kubectl -n observability get secret otel-collector-token -o jsonpath='{.data.ca\.crt}')"

# 4. Render the scoped kubeconfig the collector runs with. 0640 root:<svc_user>
#    so only root and the collector can read it; umask 027 so the file is never
#    world-readable even for the instant before chmod.
install -o root -g root -m 0755 -d "$etc_dir"
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
echo "rendered: $etc_dir/kubeconfig (ServiceAccount observability/otel-collector)"
