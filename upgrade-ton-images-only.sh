#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  ./upgrade-ton-images-only.sh <chart-version> <mytonctrl-tag> <ton-tag>' \
    '' \
    'Example:' \
    '  ./upgrade-ton-images-only.sh 0.3.1 v1.0.0 v2026.08-amd64' \
    '' \
    'Updates chart image defaults independently; operator appVersion and image stay unchanged.'
}

if [[ $# -ne 3 ]]; then
  usage
  exit 1
fi

TARGET_CHART_VERSION="${1#v}"
TARGET_MYTONCTRL_TAG="$2"
TARGET_TON_TAG="$3"

if ! [[ "$TARGET_CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  printf "Error: invalid chart version '%s'. Expected semver like 0.3.1 or v0.3.1.\n" "$1" >&2
  exit 1
fi
for target_tag in "$TARGET_MYTONCTRL_TAG" "$TARGET_TON_TAG"; do
  if ! [[ "$target_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    printf "Error: invalid container image tag '%s'.\n" "$target_tag" >&2
    exit 1
  fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYTONCTRL_IMAGE="ghcr.io/neodix42/mytonctrl:${TARGET_MYTONCTRL_TAG}"
TON_IMAGE="ghcr.io/ton-blockchain/ton:${TARGET_TON_TAG}"
CHART_FILE="$ROOT_DIR/charts/ton-k8s-operator/Chart.yaml"
VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/values.yaml"
TON_VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/tonnode-values.yaml"
README="$ROOT_DIR/README.md"
INSTALL_SH="$ROOT_DIR/install.sh"

for file in "$CHART_FILE" "$VALUES_FILE" "$TON_VALUES_FILE" "$README" "$INSTALL_SH"; do
  if [[ ! -f "$file" ]]; then
    printf 'Error: required file not found: %s\n' "$file" >&2
    exit 1
  fi
done

CURRENT_CHART_VERSION="$(awk -F': ' '/^version:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"
CURRENT_APP_VERSION="$(awk -F': ' '/^appVersion:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"

# The official TON tag selects packaged binaries, so no source branch is derived.
# Key agents inherit tonNode.image unless users explicitly choose a separate image.
sed -E -i "s|^version: .*$|version: ${TARGET_CHART_VERSION}|" "$CHART_FILE"
for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  sed -E -i "s|^  image: ghcr\\.io/neodix42/mytonctrl:.*$|  image: ${MYTONCTRL_IMAGE}|" "$values_file"
  sed -E -i "s|^  tonImage: ghcr\\.io/ton-blockchain/ton:.*$|  tonImage: ${TON_IMAGE}|" "$values_file"
done

# Installer artifacts are chart-versioned, even when operator code is unchanged.
sed -E -i "s|(releases/download/)[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?(/install\\.sh)|\\1${TARGET_CHART_VERSION}\\3|g" "$README"
sed -E -i "s|^CHART_VERSION=.*$|CHART_VERSION=\"${TARGET_CHART_VERSION}\"|" "$INSTALL_SH"

grep -Fxq "version: ${TARGET_CHART_VERSION}" "$CHART_FILE"
grep -Fxq "appVersion: \"${CURRENT_APP_VERSION}\"" "$CHART_FILE"
for values_file in "$VALUES_FILE" "$TON_VALUES_FILE"; do
  grep -Fxq "  image: ${MYTONCTRL_IMAGE}" "$values_file"
  grep -Fxq "  tonImage: ${TON_IMAGE}" "$values_file"
done
grep -Fq "releases/download/${TARGET_CHART_VERSION}/install.sh" "$README"
grep -Fxq "CHART_VERSION=\"${TARGET_CHART_VERSION}\"" "$INSTALL_SH"

printf '%s\n' \
  'Updated TON images-only release:' \
  "- chart version: ${CURRENT_CHART_VERSION} -> ${TARGET_CHART_VERSION}" \
  "- appVersion:    ${CURRENT_APP_VERSION} (unchanged)" \
  "- MyTonCtrl:     ${MYTONCTRL_IMAGE}" \
  "- TON binaries:  ${TON_IMAGE}"
