#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_IMG="${OPERATOR_IMG:-ghcr.io/neodix42/ton-k8s-operator:dev-local}"
OP_VALUES_FILE="${OP_VALUES_FILE:-$ROOT_DIR/charts/ton-k8s-operator/operator-values.yaml}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-}"

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command not found: $bin" >&2
    exit 1
  fi
}

parse_image_ref() {
  if [[ "$OPERATOR_IMG" != *:* ]]; then
    echo "Error: OPERATOR_IMG must include a tag, got: $OPERATOR_IMG" >&2
    exit 1
  fi
  OPERATOR_REPO="${OPERATOR_IMG%:*}"
  OPERATOR_TAG="${OPERATOR_IMG##*:}"
  if [[ -z "$OPERATOR_REPO" || -z "$OPERATOR_TAG" || "$OPERATOR_REPO" == "$OPERATOR_TAG" ]]; then
    echo "Error: invalid OPERATOR_IMG value: $OPERATOR_IMG" >&2
    exit 1
  fi
}

update_operator_values_image() {
  if [[ ! -f "$OP_VALUES_FILE" ]]; then
    echo "Error: operator values file not found: $OP_VALUES_FILE" >&2
    exit 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  awk -v repo="$OPERATOR_REPO" -v tag="$OPERATOR_TAG" '
    BEGIN { in_image = 0 }
    /^image:[[:space:]]*$/ { in_image = 1; print; next }
    in_image && /^[^[:space:]]/ { in_image = 0 }
    in_image && /^[[:space:]]+repository:[[:space:]]*/ { print "  repository: " repo; next }
    in_image && /^[[:space:]]+tag:[[:space:]]*/ { print "  tag: " tag; next }
    { print }
  ' "$OP_VALUES_FILE" > "$tmp_file"
  mv "$tmp_file" "$OP_VALUES_FILE"
}

detect_k3d_cluster_name() {
  local node_name cluster_candidate
  node_name="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "$node_name" ]] && return 1
  [[ "$node_name" == k3d-* ]] || return 1

  cluster_candidate="${node_name#k3d-}"
  cluster_candidate="${cluster_candidate%-server-*}"
  if [[ "$cluster_candidate" == "$node_name" || "$cluster_candidate" == "${node_name#k3d-}" ]]; then
    cluster_candidate="${node_name#k3d-}"
    cluster_candidate="${cluster_candidate%-agent-*}"
  fi
  [[ -z "$cluster_candidate" || "$cluster_candidate" == "$node_name" || "$cluster_candidate" == "${node_name#k3d-}" ]] && return 1
  printf '%s\n' "$cluster_candidate"
}

import_image_to_k3d_if_needed() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Skipping k3d image import: kubectl is not available."
    return 0
  fi

  local cluster_name="${K3D_CLUSTER_NAME:-}"
  if [[ -z "$cluster_name" ]]; then
    cluster_name="$(detect_k3d_cluster_name || true)"
  fi

  if [[ -z "$cluster_name" ]]; then
    echo "Skipping k3d image import: current kube-context does not look like k3d."
    echo "Set K3D_CLUSTER_NAME=<name> to force import."
    return 0
  fi

  require_bin k3d
  echo "Importing image into k3d cluster '$cluster_name' ..."
  k3d image import "$OPERATOR_IMG" -c "$cluster_name"
}

main() {
  require_bin make
  require_bin docker
  parse_image_ref

  cd "$ROOT_DIR"

  echo "Building operator image: $OPERATOR_IMG"
  make docker-build IMG="$OPERATOR_IMG"

  echo "Generating installer bundle: dist/install.yaml"
  make build-installer IMG="$OPERATOR_IMG"

  echo "Updating operator image values in: $OP_VALUES_FILE"
  update_operator_values_image

  import_image_to_k3d_if_needed

  cat <<EOF
Done.
Local image: $OPERATOR_IMG
Installer bundle: $ROOT_DIR/dist/install.yaml

Next:
  cd $ROOT_DIR/charts/ton-k8s-operator
  ./kubeton install
  ./kubeton start
EOF
}

main "$@"
