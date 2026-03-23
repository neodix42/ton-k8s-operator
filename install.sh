#!/usr/bin/env bash
set -euo pipefail

CHART_REF="${CHART_REF:-oci://ghcr.io/neodix42/charts/ton-k8s-operator}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/ton-k8s-operator}"
CHART_VERSION="${CHART_VERSION:-}"

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command not found: $bin" >&2
    exit 1
  fi
}

require_bin helm
require_bin tar

if [[ -d "$INSTALL_DIR" ]] && [[ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
  BACKUP_DIR="${INSTALL_DIR}-backup-$(date +%Y%m%d-%H%M%S)"
  mv "$INSTALL_DIR" "$BACKUP_DIR"
  echo "Existing folder moved to: $BACKUP_DIR"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

rm -f ton-k8s-operator-*.tgz

echo "Downloading chart from: $CHART_REF"
if [[ -n "$CHART_VERSION" ]]; then
  helm pull "$CHART_REF" --version "$CHART_VERSION"
else
  helm pull "$CHART_REF"
fi

ARCHIVE="$(ls -1 ton-k8s-operator-*.tgz 2>/dev/null | head -n1 || true)"
if [[ -z "$ARCHIVE" ]]; then
  echo "Error: failed to find downloaded chart archive." >&2
  exit 1
fi

tar -xzf "$ARCHIVE" --strip-components=1

CHART_DIR="$INSTALL_DIR"
if [[ ! -f "$CHART_DIR/Chart.yaml" ]]; then
  echo "Error: extracted chart files not found in: $CHART_DIR" >&2
  exit 1
fi

if [[ ! -f "$CHART_DIR/operator-values.yaml" || ! -f "$CHART_DIR/tonnode-values.yaml" ]]; then
  echo "Error: downloaded chart does not include operator-values.yaml and tonnode-values.yaml." >&2
  echo "Publish a newer chart version from this repo, then run install.sh again." >&2
  exit 1
fi

RESOLVED_VERSION="${ARCHIVE#ton-k8s-operator-}"
RESOLVED_VERSION="${RESOLVED_VERSION%.tgz}"

cat <<EOF

Done. Chart version: $RESOLVED_VERSION
Created folder: $INSTALL_DIR
Chart path: $CHART_DIR

Next steps:

a) Review default values files (already bundled in the chart):
   cd "$CHART_DIR"
   ls -1 values.yaml operator-values.yaml tonnode-values.yaml
   ${EDITOR:-vi} operator-values.yaml
   ${EDITOR:-vi} tonnode-values.yaml

b) Install operator:
   helm install ton-k8s-operator . \\
     -n ton-k8s-operator-system \\
     --create-namespace \\
     -f operator-values.yaml

c) Install TON nodes:
   helm upgrade ton-k8s-operator . \\
     -n ton-k8s-operator-system \\
     -f operator-values.yaml \\
     -f tonnode-values.yaml

d) Verify:
   kubectl -n ton-k8s-operator-system get deploy,pods
   kubectl -n default get tonnodes
   kubectl -n default get sts,pods,pvc

e) Stop/remove TON nodes and delete operator:
   # stop and remove all TON nodes (keep operator)
   helm upgrade ton-k8s-operator . \\
     -n ton-k8s-operator-system \\
     -f operator-values.yaml \\
     --set tonNode.enabled=false
   kubectl delete tonnodes.ton.ton.org --all -A

   # optional destructive TON data cleanup
   kubectl delete pvc -A -l app.kubernetes.io/name=ton-node

   # delete operator release + namespace
   helm uninstall ton-k8s-operator -n ton-k8s-operator-system
   kubectl delete namespace ton-k8s-operator-system

   # optional destructive CRD cleanup
   kubectl delete crd tonnodes.ton.ton.org

EOF
