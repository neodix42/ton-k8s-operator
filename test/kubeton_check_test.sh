#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${KUBETON_TEST_MODE:-healthy}"
args="$*"

if [[ "${1:-}" == "get" && "${2:-}" == "--raw" ]]; then
  case "${3:-}" in
    */node-good-1/*|*/node-good-2/*|*/node-good-3/*)
      printf '%s\n' '{"node":{"fs":{"availableBytes":2199023255552}}}'
      ;;
    */node-bad/*)
      printf '%s\n' '{"node":{"fs":{"availableBytes":2199023255552}}}'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "daemonset" ]]; then
  # Preflight tests model either a fresh or existing Longhorn deployment.
  if [[ "$mode" == "existing" || "$mode" == "existing-csi" ]]; then
    if [[ "$mode" == "existing-csi" && "$args" == *"go-template="* ]]; then
      case "$args" in
        *"longhorn-manager"*) printf '%s\n' 'storage=manager' ;;
        *"longhorn-csi-plugin"*) printf '%s\n' 'storage=csi' ;;
      esac
    fi
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "label" && "${2:-}" == "node" ]]; then
  printf '%s\n' "$*" >>"${KUBETON_TEST_LABEL_LOG:?}"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" ]]; then
  # A blank app label is intentional here: it guards against losing request
  # columns when parsing unlabelled workloads.
  if [[ "$mode" == "loaded" ]]; then
    printf 'node-good-1\x1fRunning\x1f\x1f\x1f17000m,70Gi;\n'
  fi
  # Other modes have no existing assigned workloads.
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "tonnodes.ton.ton.org" ]]; then
  [[ "$mode" == "existing-ton" ]] && printf '%s\n' 'default/tonnode'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "nodes" ]]; then
  if [[ "$args" == *"go-template="* ]]; then
    printf '%s\n' \
      $'node-good-1\t<no value>\t32\t134217728Ki\tMemoryPressure=False,DiskPressure=False,PIDPressure=False,Ready=True,\t' \
      $'node-good-2\t<no value>\t32\t134217728Ki\tMemoryPressure=False,DiskPressure=False,PIDPressure=False,Ready=True,\t'
    if [[ "$mode" != "short" ]]; then
      printf '%s\n' $'node-good-3\t<no value>\t32\t134217728Ki\tMemoryPressure=False,DiskPressure=False,PIDPressure=False,Ready=True,\t'
    fi
    printf '%s\n' $'node-bad\t<no value>\t32\t134217728Ki\tMemoryPressure=False,DiskPressure=True,PIDPressure=False,Ready=True,\t'
    exit 0
  fi

  if [[ "$args" == *"-l"* ]]; then
    if [[ "$args" == *"ton.ton.org/kubeton-prereq"* ]]; then
      # No pre-existing kubeton-owned labels.
      exit 0
    fi
    if [[ "$args" == *"node.longhorn.io/create-default-disk=true"* ]]; then
      printf '%s\n' node-good-1 node-good-2 node-good-3 node-bad
      exit 0
    fi
    if [[ "$args" == *"storage=manager,storage=csi"* ]]; then
      printf '%s\n' node-good-1 node-good-2 node-good-3
      exit 0
    fi
    if [[ "$args" == *"storage=manager"* ]]; then
      printf '%s\n' node-good-1 node-good-2 node-good-3
      exit 0
    fi
    if [[ "$args" == *"storage=csi"* ]]; then
      printf '%s\n' node-good-1 node-good-2 node-good-3 node-bad
      exit 0
    fi
    # The default values file has no TON node selector. This branch keeps the
    # mock usable if a selector is introduced to the fixture later.
    printf '%s\n' node-good-1 node-good-2
    [[ "$mode" != "short" ]] && printf '%s\n' node-good-3
    exit 0
  fi

  printf '%s\n' node-good-1 node-good-2
  [[ "$mode" != "short" ]] && printf '%s\n' node-good-3
  printf '%s\n' node-bad
  exit 0
fi

printf 'unexpected kubectl invocation: %s\n' "$args" >&2
exit 1
EOF

cat >"$fake_bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${KUBETON_TEST_HELM_LOG:?}"
exit 0
EOF
chmod +x "$fake_bin/kubectl" "$fake_bin/helm"

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "expected output to contain: $needle" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  fi
}

healthy_output="$test_dir/healthy.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" check >"$healthy_output" 2>&1
assert_contains "local TON data: 760.00 Gi" "$healthy_output"
assert_contains "node filesystem requirement: >= 780.00 Gi" "$healthy_output"
assert_contains "node-bad" "$healthy_output"
assert_contains "FAIL: DiskPressure" "$healthy_output"
assert_contains "Compatible target nodes: 3/3 required." "$healthy_output"

short_output="$test_dir/short.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=short KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" check >"$short_output" 2>&1; then
  echo "expected node check with only two compatible nodes to fail" >&2
  exit 1
fi
assert_contains "Compatible target nodes: 2/3 required." "$short_output"
assert_contains "not enough compatible nodes" "$short_output"

loaded_output="$test_dir/loaded.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=loaded KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" check >"$loaded_output" 2>&1; then
  echo "expected assigned unlabelled pod requests to reduce preflight headroom" >&2
  exit 1
fi
assert_contains "node-good-1" "$loaded_output"
assert_contains "insufficient CPU, insufficient memory" "$loaded_output"
assert_contains "Compatible target nodes: 2/3 required." "$loaded_output"

longhorn_replica_output="$test_dir/longhorn-replica.out"
if PATH="$fake_bin:$PATH" FORCE_BAREMETAL_BOOTSTRAP=true LONGHORN_DEFAULT_REPLICA_COUNT=4 KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$longhorn_replica_output" 2>&1; then
  echo "expected Longhorn-aware check to require all Longhorn replica nodes" >&2
  exit 1
fi
assert_contains "Compatible target nodes: 3/4 required." "$longhorn_replica_output"

install_output="$test_dir/install.out"
: >"$test_dir/helm.log"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=short KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" install >"$install_output" 2>&1; then
  echo "expected install to stop at the node preflight" >&2
  exit 1
fi
assert_contains "not enough compatible nodes" "$install_output"
if [[ -s "$test_dir/helm.log" ]]; then
  echo "helm was invoked even though install preflight failed" >&2
  cat "$test_dir/helm.log" >&2
  exit 1
fi

label_output="$test_dir/prepare.out"
: >"$test_dir/labels.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 true; printf "%s\n" "$LONGHORN_NODE_SELECTOR"' _ "$kubeton" >"$label_output" 2>&1
assert_contains "node.longhorn.io/create-default-disk=true,ton.ton.org/kubeton-prereq=ready" "$label_output"
assert_contains "label node node-good-1 ton.ton.org/kubeton-prereq=ready --overwrite" "$test_dir/labels.log"
assert_contains "label node node-good-3 node.longhorn.io/create-default-disk=true --overwrite" "$test_dir/labels.log"

preserve_output="$test_dir/preserve.out"
: >"$test_dir/labels.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=existing-ton KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 false' _ "$kubeton" >"$preserve_output" 2>&1
assert_contains "Existing TON resources found; preserving" "$preserve_output"
if [[ -s "$test_dir/labels.log" ]]; then
  echo "existing TON preflight unexpectedly changed node labels" >&2
  cat "$test_dir/labels.log" >&2
  exit 1
fi

existing_output="$test_dir/existing.out"
: >"$test_dir/labels.log"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=existing KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 true' _ "$kubeton" >"$existing_output" 2>&1; then
  echo "expected existing Longhorn with a DiskPressure target to fail safely" >&2
  exit 1
fi
assert_contains "existing Longhorn manager targets node(s)" "$existing_output"
assert_contains "node-bad: DiskPressure" "$existing_output"
if [[ -s "$test_dir/labels.log" ]]; then
  echo "existing Longhorn preflight unexpectedly changed node labels" >&2
  cat "$test_dir/labels.log" >&2
  exit 1
fi

csi_output="$test_dir/csi.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=existing-csi KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$csi_output" 2>&1; then
  echo "expected existing Longhorn CSI selector with a DiskPressure target to fail safely" >&2
  exit 1
fi
assert_contains "existing Longhorn CSI plugin targets node(s)" "$csi_output"
assert_contains "node-bad: DiskPressure" "$csi_output"

inline_values="$test_dir/inline-selector-values.yaml"
cat >"$inline_values" <<'EOF'
tonNode:
  nodeSelector: {topology.kubernetes.io/zone: a, workload: ton}
EOF
inline_output="$test_dir/inline.out"
PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_effective_tonnode_node_selector' _ "$kubeton" "$inline_values" >"$inline_output"
assert_contains "topology.kubernetes.io/zone=a,workload=ton" "$inline_output"

echo "kubeton node prerequisite checks: PASS"
