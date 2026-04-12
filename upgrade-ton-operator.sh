#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./upgrade-ton-operator.sh <version>

Example:
  ./upgrade-ton-operator.sh 0.1.24
  ./upgrade-ton-operator.sh v0.1.24
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET_VERSION="${1#v}"
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid version '$1'. Expected semver like 0.1.24 or v0.1.24" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHART_FILE="$ROOT_DIR/charts/ton-k8s-operator/Chart.yaml"
VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/values.yaml"
OP_VALUES_FILE="$ROOT_DIR/charts/ton-k8s-operator/operator-values.yaml"
DOCKERFILE="$ROOT_DIR/Dockerfile"
KUSTOMIZATION="$ROOT_DIR/config/manager/kustomization.yaml"
INSTALL_YAML="$ROOT_DIR/dist/install.yaml"
README="$ROOT_DIR/README.md"
INSTALL_SH="$ROOT_DIR/install.sh"

for file in "$CHART_FILE" "$VALUES_FILE" "$OP_VALUES_FILE" "$DOCKERFILE" "$KUSTOMIZATION" "$INSTALL_YAML" "$README" "$INSTALL_SH"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: required file not found: $file" >&2
    exit 1
  fi
done

CURRENT_CHART_VERSION="$(awk -F': ' '/^version:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"
CURRENT_APP_VERSION="$(awk -F': ' '/^appVersion:/{print $2; exit}' "$CHART_FILE" | tr -d '"')"

# Operator release: bump chart version + appVersion + operator image pins.
sed -E -i "s|^version: .*$|version: ${TARGET_VERSION}|" "$CHART_FILE"
sed -E -i "s|^appVersion:.*$|appVersion: \"${TARGET_VERSION}\"|" "$CHART_FILE"
sed -E -i "s|^  tag: .*$|  tag: ${TARGET_VERSION}|" "$VALUES_FILE"
sed -E -i "s|^  tag: .*$|  tag: ${TARGET_VERSION}|" "$OP_VALUES_FILE"
sed -E -i "s|^ARG VERSION=.*$|ARG VERSION=${TARGET_VERSION}|" "$DOCKERFILE"
sed -E -i "s|^([[:space:]]*newTag:).*$|\\1 ${TARGET_VERSION}|" "$KUSTOMIZATION"
sed -E -i "s|(image: ghcr\\.io/neodix42/ton-k8s-operator:)[^[:space:]]+|\\1${TARGET_VERSION}|g" "$INSTALL_YAML"

# Installer artifacts are always chart-versioned.
sed -E -i "s|(releases/download/)[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?(/install\\.sh)|\\1${TARGET_VERSION}\\3|g" "$README"
sed -E -i "s|^CHART_VERSION=.*$|CHART_VERSION=\"${TARGET_VERSION}\"|" "$INSTALL_SH"

grep -q "^version: ${TARGET_VERSION}$" "$CHART_FILE"
grep -q "^appVersion: \"${TARGET_VERSION}\"$" "$CHART_FILE"
grep -q "^  tag: ${TARGET_VERSION}$" "$VALUES_FILE"
grep -q "^  tag: ${TARGET_VERSION}$" "$OP_VALUES_FILE"
grep -q "^ARG VERSION=${TARGET_VERSION}$" "$DOCKERFILE"
grep -q "^[[:space:]]*newTag: ${TARGET_VERSION}$" "$KUSTOMIZATION"
grep -q "image: ghcr.io/neodix42/ton-k8s-operator:${TARGET_VERSION}" "$INSTALL_YAML"
grep -q "releases/download/${TARGET_VERSION}/install.sh" "$README"
grep -q "^CHART_VERSION=\"${TARGET_VERSION}\"$" "$INSTALL_SH"

echo "Updated operator release version:"
echo "- chart version: ${CURRENT_CHART_VERSION} -> ${TARGET_VERSION}"
echo "- appVersion:    ${CURRENT_APP_VERSION} -> ${TARGET_VERSION}"
echo
echo "Changed files:"
echo "- charts/ton-k8s-operator/Chart.yaml"
echo "- charts/ton-k8s-operator/values.yaml"
echo "- charts/ton-k8s-operator/operator-values.yaml"
echo "- Dockerfile"
echo "- config/manager/kustomization.yaml"
echo "- dist/install.yaml"
echo "- README.md"
echo "- install.sh"
