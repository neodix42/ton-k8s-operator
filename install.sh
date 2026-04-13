#!/usr/bin/env bash
set -euo pipefail

CHART_REF="${CHART_REF:-oci://ghcr.io/neodix42/charts/ton-k8s-operator}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/ton-k8s-operator}"
CHART_VERSION="0.1.26"

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

echo "Downloading chart from: $CHART_REF (version: $CHART_VERSION)"
helm pull "$CHART_REF" --version "$CHART_VERSION"

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

if [[ ! -f "$CHART_DIR/operator-values.yaml" || ! -f "$CHART_DIR/tonnode-values.yaml" || ! -f "$CHART_DIR/kubeton" ]]; then
  echo "Error: downloaded chart does not include operator-values.yaml, tonnode-values.yaml and kubeton." >&2
  echo "Publish a newer chart version from this repo, then run install.sh again." >&2
  exit 1
fi
chmod +x "$CHART_DIR/kubeton"

RESOLVED_VERSION="${ARCHIVE#ton-k8s-operator-}"
RESOLVED_VERSION="${RESOLVED_VERSION%.tgz}"

cat <<EOF

Done. Chart version: $RESOLVED_VERSION
Created folder: $INSTALL_DIR
Chart path: $CHART_DIR

Next steps:

a) Review default values files:
   cd "$CHART_DIR"
   ${EDITOR:-vi} operator-values.yaml
   ${EDITOR:-vi} tonnode-values.yaml

   # helper script for common TON fleet operations
   ./kubeton help

b) Install operator:
   ./kubeton install

c) Start 10 TON nodes:
  ./kubeton start 10

d) Scale one replica at a time:
   ./kubeton add
   ./kubeton del   # removes highest ordinal (tail) replica

e) Stop TON pods (keeps TonNode/STS/PVC resources):
   ./kubeton stop
   ./kubeton start             # restore previous TON replicas

f) Verify:
   kubectl verify

g) Stop/remove TON manifests from Helm release
   ./kubeton stop

h) Drop TON nodes and storage (PVCs)
   ./kubeton drop

i) Delete operator release + namespace
   ./kubeton uninstall
EOF
