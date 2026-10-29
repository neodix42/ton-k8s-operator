#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: ./upgrade-mytonctrl-only.sh <mytonctrl-tag>' \
    '' \
    'Example:' \
    '  ./upgrade-mytonctrl-only.sh v1.0.0' \
    '' \
    'Updates only the MyTonCtrl image tag in the chart values files.'
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET_MYTONCTRL_TAG="$1"
if ! [[ "$TARGET_MYTONCTRL_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf "Error: invalid container image tag '%s'.\n" "$TARGET_MYTONCTRL_TAG" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYTONCTRL_IMAGE="ghcr.io/neodix42/mytonctrl:${TARGET_MYTONCTRL_TAG}"
VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/values.yaml"
TON_VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/tonnode-values.yaml"

for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  if [[ ! -f "$values_file" ]]; then
    printf 'Error: required file not found: %s\n' "$values_file" >&2
    exit 1
  fi
done

for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  sed -E -i "s|^  image: ghcr\\.io/neodix42/mytonctrl:.*$|  image: ${MYTONCTRL_IMAGE}|" "$values_file"
  grep -Fxq "  image: ${MYTONCTRL_IMAGE}" "$values_file"
done

printf 'Updated MyTonCtrl image: %s\n' "$MYTONCTRL_IMAGE"
