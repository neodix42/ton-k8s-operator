#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./upgrade-ton-docker-ctrl-only.sh <chart-version> <ton-docker-ctrl-tag>

Example:
  ./upgrade-ton-docker-ctrl-only.sh 0.1.24 v2026.05-amd64
  ./upgrade-ton-docker-ctrl-only.sh v0.1.24 v2026.05-amd64
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

TARGET_CHART_VERSION="${1#v}"
TARGET_TON_TAG="$2"

if ! [[ "$TARGET_CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid chart version '$1'. Expected semver like 0.1.24 or v0.1.24" >&2
  exit 1
fi
if [[ -z "$TARGET_TON_TAG" || "$TARGET_TON_TAG" =~ [[:space:]] ]]; then
  echo "Error: invalid TON image tag '$TARGET_TON_TAG'." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TON_IMAGE="ghcr.io/ton-blockchain/ton-docker-ctrl:${TARGET_TON_TAG}"

CHART_FILE="$ROOT_DIR/charts/ton-k8s-operator/Chart.yaml"
VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/values.yaml"
TON_VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/tonnode-values.yaml"
KUBETON_FILE="$ROOT_DIR/charts/ton-k8s-operator/kubeton"
README="$ROOT_DIR/README.md"
INSTALL_SH="$ROOT_DIR/install.sh"

for file in "$CHART_FILE" "$VALUES_FILE" "$TON_VALUES_FILE" "$KUBETON_FILE" "$README" "$INSTALL_SH"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: required file not found: $file" >&2
    exit 1
  fi
done

CURRENT_CHART_VERSION="$(awk -F': ' '/^version:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"
CURRENT_APP_VERSION="$(awk -F': ' '/^appVersion:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"

# TON image-only release:
# 1) update TON defaults in chart values,
# 2) bump chart version only,
# 3) keep appVersion/operator image tags unchanged.
sed -E -i "s|^version: .*$|version: ${TARGET_CHART_VERSION}|" "$CHART_FILE"
sed -E -i "s|^  image: ghcr\\.io/ton-blockchain/ton-docker-ctrl:.*$|  image: ${TON_IMAGE}|" "$VALUES_FILE"
sed -E -i "s|^      image: ghcr\\.io/ton-blockchain/ton-docker-ctrl:.*$|      image: ${TON_IMAGE}|" "$VALUES_FILE"
sed -E -i "s|^  image: ghcr\\.io/ton-blockchain/ton-docker-ctrl:.*$|  image: ${TON_IMAGE}|" "$TON_VALUES_FILE"
sed -E -i "s|^      image: ghcr\\.io/ton-blockchain/ton-docker-ctrl:.*$|      image: ${TON_IMAGE}|" "$TON_VALUES_FILE"
sed -E -i "s|^TON_IMAGE_TAG_DEFAULT=.*$|TON_IMAGE_TAG_DEFAULT=\"\${TON_IMAGE_TAG_DEFAULT:-${TARGET_TON_TAG}}\"|" "$KUBETON_FILE"

# Installer artifacts are always chart-versioned.
sed -E -i "s|(releases/download/)[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?(/install\\.sh)|\\1${TARGET_CHART_VERSION}\\3|g" "$README"
sed -E -i "s|^CHART_VERSION=.*$|CHART_VERSION=\"${TARGET_CHART_VERSION}\"|" "$INSTALL_SH"

grep -q "^version: ${TARGET_CHART_VERSION}$" "$CHART_FILE"
grep -q "^appVersion: \"${CURRENT_APP_VERSION}\"$" "$CHART_FILE"
grep -q "^  image: ${TON_IMAGE}$" "$VALUES_FILE"
grep -q "^      image: ${TON_IMAGE}$" "$VALUES_FILE"
grep -q "^  image: ${TON_IMAGE}$" "$TON_VALUES_FILE"
grep -q "^      image: ${TON_IMAGE}$" "$TON_VALUES_FILE"
grep -q "^TON_IMAGE_TAG_DEFAULT=\"\\\${TON_IMAGE_TAG_DEFAULT:-${TARGET_TON_TAG}}\"$" "$KUBETON_FILE"
grep -q "releases/download/${TARGET_CHART_VERSION}/install.sh" "$README"
grep -q "^CHART_VERSION=\"${TARGET_CHART_VERSION}\"$" "$INSTALL_SH"

echo "Updated TON image-only release:"
echo "- chart version: ${CURRENT_CHART_VERSION} -> ${TARGET_CHART_VERSION}"
echo "- appVersion:    ${CURRENT_APP_VERSION} (unchanged)"
echo "- ton image:     ${TON_IMAGE}"
echo
echo "Changed files:"
echo "- charts/ton-k8s-operator/Chart.yaml"
echo "- charts/ton-k8s-operator/values.yaml"
echo "- charts/ton-k8s-operator/tonnode-values.yaml"
echo "- charts/ton-k8s-operator/kubeton"
echo "- README.md"
echo "- install.sh"
