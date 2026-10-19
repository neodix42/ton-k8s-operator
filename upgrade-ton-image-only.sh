#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: ./upgrade-ton-image-only.sh <ton-tag>' \
    '' \
    'Example:' \
    '  ./upgrade-ton-image-only.sh v2026.08-amd64' \
    '' \
    'Updates only the TON image tag in the chart values files.'
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET_TON_TAG="$1"
if ! [[ "$TARGET_TON_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf "Error: invalid container image tag '%s'.\n" "$TARGET_TON_TAG" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TON_IMAGE="ghcr.io/ton-blockchain/ton:${TARGET_TON_TAG}"
VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/values.yaml"
TON_VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/tonnode-values.yaml"

for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  if [[ ! -f "$values_file" ]]; then
    printf 'Error: required file not found: %s\n' "$values_file" >&2
    exit 1
  fi
done

for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  sed -E -i "s|^  tonImage: ghcr\\.io/ton-blockchain/ton:.*$|  tonImage: ${TON_IMAGE}|" "$values_file"
  grep -Fxq "  tonImage: ${TON_IMAGE}" "$values_file"
done

printf 'Updated TON image: %s\n' "$TON_IMAGE"
