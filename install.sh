#!/usr/bin/env bash
set -euo pipefail

CHART_VERSION="0.5.1"
CHART_REF="${CHART_REF:-oci://ghcr.io/neodix42/charts/ton-k8s-operator}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/neodix42/ton-k8s-operator/releases/download/$CHART_VERSION}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/ton-k8s-operator-$CHART_VERSION}"

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command not found: $bin" >&2
    exit 1
  fi
}

require_bin helm
require_bin tar
if command -v curl >/dev/null 2>&1; then
  download_file() { curl -fsSL "$1" -o "$2"; }
else
  require_bin wget
  download_file() { wget -qO "$2" "$1"; }
fi

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

if [[ ! -f "$CHART_DIR/operator-values.yaml" || ! -f "$CHART_DIR/tonnode-values.yaml" ]]; then
  echo "Error: downloaded chart does not include operator-values.yaml and tonnode-values.yaml." >&2
  echo "Publish a newer chart version from this repo, then run install.sh again." >&2
  exit 1
fi
# Release clients can be updated without replacing an already-published OCI
# chart version. Download the CLI, wallet and fleet helpers as one matching set.
for client_file in kubeton main-wallet.sh fleet.sh fleet.py fleet-crypto.sh; do
  echo "Downloading ${client_file} from release ${CHART_VERSION} ..."
  download_file "$RELEASE_BASE_URL/$client_file" "$CHART_DIR/${client_file}.download"
  [[ -s "$CHART_DIR/${client_file}.download" ]] || { echo "Error: empty release asset: $client_file" >&2; exit 1; }
done
for client_file in kubeton main-wallet.sh fleet.sh fleet.py fleet-crypto.sh; do
  mv "$CHART_DIR/${client_file}.download" "$CHART_DIR/$client_file"
done
chmod +x "$CHART_DIR/kubeton" "$CHART_DIR/main-wallet.sh"

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

   # tonNode.image selects MyTonCtrl; tonNode.tonImage selects official TON binaries.
   # tonNode.args holds first-install flags, for example [-m, liteserver, -n, mainnet, -d, -i].

   # helper script for common TON fleet operations
   ./kubeton help

b) Check node prerequisites, then install the operator:
   ./kubeton check
   ./kubeton install

c) Start TON nodes (replica count is taken from tonnode-values.yaml):
  ./kubeton start

d) Scale one replica at a time:
   ./kubeton add
   ./kubeton del   # removes highest ordinal (tail) replica

e) Stop TON pods (keeps TonNode/STS/PVC resources):
   ./kubeton stop
   ./kubeton start             # restore previous TON replicas

f) Verify:
   ./kubeton verify

g) Stop/remove TON manifests from Helm release
   ./kubeton stop

h) Drop TON nodes and storage (PVCs)
   ./kubeton drop

i) Delete operator release + namespace
   ./kubeton uninstall

j) Back up a portable fleet (prompts for a recovery passphrase):
   ./kubeton backup-fleet

   Restore the copied directory on a destination cluster:
   ./kubeton restore-fleet ./fleet-backups/<timestamp> --bootstrap
EOF
