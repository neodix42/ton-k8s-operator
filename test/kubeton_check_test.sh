#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
export KUBETON_LAUNCH_LOGS_ENABLED=false
export KUBETON_START_VICTORIA_LOGS_ENABLED=false
export KUBETON_START_WAIT_FOR_BOOTSTRAP=false
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
  available_bytes=2199023255552
  if [[ "$mode" == "storage-control" ]]; then
    available_bytes=1099511627776
  elif [[ "$mode" == "large-work" ]]; then
    available_bytes=3298534883328
  elif [[ "$mode" == "ranked" ]]; then
    case "${3:-}" in
      */node-good-1/*) available_bytes=2199023255552 ;;
      */node-good-2/*) available_bytes=3298534883328 ;;
      */node-good-3/*) available_bytes=4398046511104 ;;
    esac
  fi
  case "${3:-}" in
    */node-good-1/*|*/node-good-2/*|*/node-good-3/*)
      printf '{"node":{"fs":{"availableBytes":%s}}}\n' "$available_bytes"
      ;;
    */node-bad/*)
      printf '{"node":{"fs":{"availableBytes":%s}}}\n' "$available_bytes"
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "daemonset" ]]; then
  # Preflight tests model either a fresh or existing Longhorn deployment.
  if [[ "$mode" == "existing" || "$mode" == "existing-csi" || "$mode" == "existing-csi-registration-gap" || "$mode" == "existing-empty" ]]; then
    if [[ ( "$mode" == "existing-csi" || "$mode" == "existing-csi-registration-gap" ) && "$args" == *"go-template="* ]]; then
      case "$args" in
        *"longhorn-manager"*) printf '%s\n' 'storage=manager' ;;
        *"longhorn-csi-plugin"*) printf '%s\n' 'storage=csi' ;;
      esac
    fi
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "volumes.longhorn.io" ]]; then
  # A failed first Longhorn install has no user volumes, so it is safe to
  # reconfigure its selectors rather than preserve the bad broad placement.
  [[ "$mode" == "existing-empty" ]] && exit 0
  exit 1
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "statefulset" && "${5:-}" == "tonnode" ]]; then
  # A same-fleet HostPort is exempt only when the Pod has this live
  # StatefulSet UID as its controller owner.
  [[ "$mode" != "host-port-no-current-sts" ]] && printf '%s' 'target-sts-uid'
  exit 0
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "pods" && "$args" == *"app=longhorn-csi-plugin"* ]]; then
  printf '%s\n' node-good-1 node-good-2
  [[ "$mode" != "csi-plugin-not-ready" ]] && printf '%s\n' node-good-3
  exit 0
fi

if [[ "${1:-}" == "label" && "${2:-}" == "node" ]]; then
  printf '%s\n' "$*" >>"${KUBETON_TEST_LABEL_LOG:?}"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" ]]; then
  if [[ "$args" == *".hostPort"* ]]; then
    case "$mode" in
      host-port-conflict)
        printf '%s\n' $'node-good-3\x1fRunning\x1fother\x1fport-holder\x1fother-app\x1fother-manager\x1fother-instance\x1fDeployment/other,\x1fTCP/9777,'
        ;;
      host-port-protocol-mismatch)
        # TCP/30001 must not reserve the TON validator's UDP/30001 endpoint.
        printf '%s\n' $'node-good-3\x1fRunning\x1fother\x1fport-holder\x1fother-app\x1fother-manager\x1fother-instance\x1fDeployment/other,\x1fTCP/30001,'
        ;;
      host-port-current-fleet)
        # Same-fleet pods are replaceable during an in-place kubeton start and
        # must not remove their own currently assigned nodes from the pool.
        printf '%s\n' $'node-good-3\x1fRunning\x1fdefault\x1ftonnode-2\x1fton-node\x1fton-k8s-operator\x1ftonnode\x1fcontroller/StatefulSet/tonnode/target-sts-uid,\x1fUDP/30001,'
        ;;
      host-port-label-only)
        # Matching labels alone are not enough to ignore a reservation: an
        # orphan/foreign Pod must be owned by this TonNode's StatefulSet too.
        printf '%s\n' $'node-good-3\x1fRunning\x1fdefault\x1fforeign\x1fton-node\x1fton-k8s-operator\x1ftonnode\x1fcontroller/Deployment/foreign/foreign-uid,\x1fUDP/30001,'
        ;;
      host-port-stale-owner)
        # A recreated StatefulSet can reuse the name. Its old UID must not
        # exempt a still-assigned orphan from the port reservation check.
        printf '%s\n' $'node-good-3\x1fRunning\x1fdefault\x1fstale\x1fton-node\x1fton-k8s-operator\x1ftonnode\x1fcontroller/StatefulSet/tonnode/stale-sts-uid,\x1fUDP/30001,'
        ;;
    esac
    exit 0
  fi
  # A blank app label is intentional here: it guards against losing request
  # columns when parsing unlabelled workloads.
  if [[ "$mode" == "loaded" ]]; then
    printf 'node-good-1\x1fRunning\x1f\x1f\x1f17000m,70Gi;\n'
  fi
  # Other modes have no existing assigned workloads.
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "csinode" ]]; then
  case "$mode" in
    csi-missing-selected|existing-csi-registration-gap)
      # node-good-3 intentionally lacks driver.longhorn.io even though the
      # aggregate registration count still looks healthy.
      printf '%s\n' node-good-1 node-good-2
      ;;
    csi-read-error)
      exit 1
      ;;
    *)
      printf '%s\n' node-good-1 node-good-2 node-good-3
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "storageclass" && "${3:-}" == "encrypted-sc" ]]; then
  [[ "$mode" == "longhorn-sc-manager-missing" ]] && printf '%s' 'driver.longhorn.io'
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
      printf '%s\n' node-good-1 node-good-2 node-good-3
      [[ "$mode" != "existing-csi-registration-gap" ]] && printf '%s\n' node-bad
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
if [[ -n "${KUBETON_TEST_HELM_VALUES_LOG:-}" ]]; then
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-f" && -f "$arg" ]]; then
      printf '%s\n' "--- $arg" >>"$KUBETON_TEST_HELM_VALUES_LOG"
      sed -n '1,120p' "$arg" >>"$KUBETON_TEST_HELM_VALUES_LOG"
    fi
    previous="$arg"
  done
fi
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${KUBETON_TEST_MODE:-healthy}"
url="${!#}"
[[ -n "${KUBETON_TEST_CURL_LOG:-}" ]] && printf '%s\n' "$url" >>"$KUBETON_TEST_CURL_LOG"
[[ "$mode" == "metadata-unavailable" ]] && exit 1

case "$url" in
  *latest_testnet.tar.name.txt) printf '%s\n' 'ton_dump_testnet.fake.tar.lz' ;;
  *latest.tar.name.txt) printf '%s\n' 'ton_dump.fake.tar.lz' ;;
  *.size.archive.txt) printf '%s\n' '900000000000' ;;
  *.size.disk.txt) printf '%s\n' '900000000000' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/kubectl" "$fake_bin/helm" "$fake_bin/curl"

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "expected output to contain: $needle" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "expected output not to contain: $needle" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  fi
}

assert_order() {
  local first="$1"
  local second="$2"
  local file="$3"
  local first_line second_line
  first_line="$(grep -n -F -- "$first" "$file" | head -n1 | cut -d: -f1 || true)"
  second_line="$(grep -n -F -- "$second" "$file" | head -n1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    echo "expected '$first' before '$second'" >&2
    sed -n '1,200p' "$file" >&2
    exit 1
  fi
}

healthy_output="$test_dir/healthy.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$healthy_output" 2>&1
assert_contains "local TON PVC capacity: 760.00 Gi" "$healthy_output"
assert_contains "node filesystem requirement: >= 780.00 Gi" "$healthy_output"
assert_not_contains "dump bootstrap" "$healthy_output"
assert_contains "node-bad" "$healthy_output"
assert_contains "FAIL: DiskPressure" "$healthy_output"
assert_contains "Compatible target nodes: 3/3 required." "$healthy_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "node preflight unexpectedly fetched dump metadata" >&2
  cat "$test_dir/curl.log" >&2
  exit 1
fi

# Longhorn's aggregate CSI readiness can be satisfied by registrations on
# other nodes. The start gate must instead inspect every node selected for TON
# and identify the exact missing CSINode driver registration.
csi_missing_nodes_output="$test_dir/csi-missing-nodes.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=csi-missing-selected KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c 'source "$1"; ton_selected_nodes_missing_longhorn_csi storage=manager' _ "$kubeton" >"$csi_missing_nodes_output"
assert_contains "node-good-3" "$csi_missing_nodes_output"
if grep -Eq 'node-good-1|node-good-2' "$csi_missing_nodes_output"; then
  echo "Longhorn CSI gate reported a node that has driver.longhorn.io" >&2
  cat "$csi_missing_nodes_output" >&2
  exit 1
fi

csi_ready_nodes_output="$test_dir/csi-ready-nodes.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c 'source "$1"; wait_ton_selected_nodes_longhorn_csi_ready storage=manager 1' _ "$kubeton" >"$csi_ready_nodes_output" 2>&1
assert_contains "registered and its node plugin is Ready on every selected TON node" "$csi_ready_nodes_output"

csi_read_error_output="$test_dir/csi-read-error.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=csi-read-error KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c 'source "$1"; ton_selected_nodes_missing_longhorn_csi storage=manager' _ "$kubeton" >"$csi_read_error_output" 2>&1; then
  echo "expected unreadable CSINode inventory to fail closed" >&2
  exit 1
fi
assert_contains "cannot list CSINode objects" "$csi_read_error_output"

# Read-only `kubeton check` reports an exact registration gap when Longhorn
# exists, instead of trusting aggregate DaemonSet/CSINode counts.
csi_check_gap_output="$test_dir/csi-check-gap.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=existing-csi-registration-gap KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$csi_check_gap_output" 2>&1; then
  echo "expected kubeton check to reject a selected node without Longhorn CSI registration" >&2
  exit 1
fi
assert_contains "driver registration or Ready node plugin is missing" "$csi_check_gap_output"
assert_contains "node-good-3" "$csi_check_gap_output"

csi_plugin_not_ready_output="$test_dir/csi-plugin-not-ready.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=csi-plugin-not-ready KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c 'source "$1"; ton_selected_nodes_missing_longhorn_csi storage=manager' _ "$kubeton" >"$csi_plugin_not_ready_output"
assert_contains "node-good-3" "$csi_plugin_not_ready_output"

missing_manager_output="$test_dir/missing-longhorn-manager.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=longhorn-sc-manager-missing KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$missing_manager_output" 2>&1; then
  echo "expected a Longhorn-backed encrypted-sc without longhorn-manager to fail check" >&2
  exit 1
fi
assert_contains "encrypted-sc uses driver.longhorn.io" "$missing_manager_output"
assert_contains "longhorn-system/longhorn-manager is missing or unreadable" "$missing_manager_output"

# `kubeton check` and `kubeton start` must reject a node that kube-scheduler
# would reject for an already-reserved requested hostPort. This happens before
# labels/Helm, so a fresh local-path fleet never creates a Pending pod merely
# because its exporter port is already assigned on the selected node.
host_port_conflict_output="$test_dir/host-port-conflict.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-conflict KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_port_conflict_output" 2>&1; then
  echo "expected host-port conflict to fail the node preflight" >&2
  exit 1
fi
assert_contains "required host ports: UDP/30001 UDP/31001 TCP/30003 TCP/9777" "$host_port_conflict_output"
assert_contains "node-good-3" "$host_port_conflict_output"
assert_contains "host ports in use (TCP/9777 by other/port-holder)" "$host_port_conflict_output"
assert_contains "Compatible target nodes: 2/3 required." "$host_port_conflict_output"

# HostPort protocol is part of the scheduler key: a TCP listener must not
# incorrectly exclude the TON validator's UDP endpoint.
host_port_protocol_output="$test_dir/host-port-protocol.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-protocol-mismatch KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_port_protocol_output" 2>&1
assert_contains "Compatible target nodes: 3/3 required." "$host_port_protocol_output"

# An in-place start can reuse nodes already occupied by the configured TonNode
# itself; a different workload is still a conflict as covered above.
host_port_current_fleet_output="$test_dir/host-port-current-fleet.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-current-fleet KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_port_current_fleet_output" 2>&1
assert_contains "Compatible target nodes: 3/3 required." "$host_port_current_fleet_output"

# A label collision or orphan must still reserve the node. Only Pods owned by
# this exact StatefulSet are safely replaceable during an in-place start.
host_port_label_only_output="$test_dir/host-port-label-only.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-label-only KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_port_label_only_output" 2>&1; then
  echo "expected label-only host-port owner to remain a conflict" >&2
  exit 1
fi
assert_contains "host ports in use (UDP/30001 by default/foreign)" "$host_port_label_only_output"

# StatefulSet names can be reused. An assigned Pod with the old controller UID
# still reserves its HostPort and must not be exempted merely because labels and
# owner name match the current TonNode.
host_port_stale_owner_output="$test_dir/host-port-stale-owner.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-stale-owner KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_port_stale_owner_output" 2>&1; then
  echo "expected stale StatefulSet owner to remain a host-port conflict" >&2
  exit 1
fi
assert_contains "host ports in use (UDP/30001 by default/stale)" "$host_port_stale_owner_output"

# Disabling host ports deliberately removes this scheduler constraint.
host_ports_disabled_values="$test_dir/host-ports-disabled-values.yaml"
cat >"$host_ports_disabled_values" <<'EOF'
tonNode:
  replicas: 3
  storage:
    tonWorkSize: 700Gi
    tonSourceSize: 20Gi
    myTonCoreSize: 20Gi
    myTonCtrlSize: 20Gi
  resources:
    requests:
      cpu: 16000m
      memory: 64Gi
  network:
    hostPortsEnabled: false
  env:
    - name: DUMP
      value: "false"
EOF
host_ports_disabled_output="$test_dir/host-ports-disabled.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=host-port-label-only TON_VALUES_FILE="$host_ports_disabled_values" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$host_ports_disabled_output" 2>&1
assert_contains "required host ports: disabled" "$host_ports_disabled_output"
assert_contains "Compatible target nodes: 3/3 required." "$host_ports_disabled_output"

# Helm accepts inline maps, but kubeton's lightweight values reader cannot
# safely infer a custom requested HostPort from one. It must fail closed rather
# than checking the default UDP/30001 and missing a real UDP/32001 conflict.
inline_network_values="$test_dir/inline-network-values.yaml"
cat >"$inline_network_values" <<'EOF'
tonNode:
  replicas: 3
  storage:
    tonWorkSize: 700Gi
    tonSourceSize: 20Gi
    myTonCoreSize: 20Gi
    myTonCtrlSize: 20Gi
  resources:
    requests:
      cpu: 16000m
      memory: 64Gi
  network: { validatorPort: 32001 }
  env:
    - name: DUMP
      value: "false"
EOF
inline_network_output="$test_dir/inline-network.out"
if PATH="$fake_bin:$PATH" TON_VALUES_FILE="$inline_network_values" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$inline_network_output" 2>&1; then
  echo "expected inline tonNode.network mapping to block host-port preflight" >&2
  exit 1
fi
assert_contains "inline tonNode/network map" "$inline_network_output"

# DUMP=true does not change the declared-capacity sizing path or cause a
# metadata fetch. With tonWorkSize=700Gi, a node with 1Ti free still passes;
# capacity policy remains under the operator's explicit control.
dump_enabled_values="$test_dir/dump-enabled-values.yaml"
cat >"$dump_enabled_values" <<'EOF'
tonNode:
  replicas: 3
  storage:
    tonWorkSize: 700Gi
    tonSourceSize: 20Gi
    myTonCoreSize: 20Gi
    myTonCtrlSize: 20Gi
  resources:
    requests:
      cpu: 16000m
      memory: 64Gi
  env:
    - name: DUMP
      value: "true"
EOF
dump_enabled_output="$test_dir/dump-enabled.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=storage-control TON_VALUES_FILE="$dump_enabled_values" \
  KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$dump_enabled_output" 2>&1
assert_contains "node filesystem requirement: >= 780.00 Gi" "$dump_enabled_output"
assert_contains "Compatible target nodes: 3/3 required." "$dump_enabled_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "DUMP=true unexpectedly fetched dump metadata" >&2
  cat "$test_dir/curl.log" >&2
  exit 1
fi

# A larger tonWork request directly raises the node filesystem requirement.
large_work_values="$test_dir/large-work-values.yaml"
cat >"$large_work_values" <<'EOF'
tonNode:
  replicas: 3
  storage:
    tonWorkSize: 2Ti
    tonSourceSize: 20Gi
    myTonCoreSize: 20Gi
    myTonCtrlSize: 20Gi
  resources:
    requests:
      cpu: 16000m
      memory: 64Gi
  env:
    - name: NETWORK
      value: testnet
    - name: DUMP
      value: "true"
EOF
large_work_output="$test_dir/large-work.out"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=large-work TON_VALUES_FILE="$large_work_values" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$large_work_output" 2>&1
assert_contains "local TON PVC capacity: 2.06 Ti" "$large_work_output"
assert_contains "node filesystem requirement: >= 2.08 Ti" "$large_work_output"

# The same 1Ti hosts which pass tonWorkSize=700Gi are rejected when the
# configured tonWorkSize is 2Ti. This verifies that the setting is the gate.
configured_too_large_output="$test_dir/configured-too-large.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=storage-control TON_VALUES_FILE="$large_work_values" \
  KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" check >"$configured_too_large_output" 2>&1; then
  echo "expected configured TON storage capacity to reject 1Ti nodes" >&2
  exit 1
fi
assert_contains "node filesystem requirement: >= 2.08 Ti" "$configured_too_large_output"
assert_contains "insufficient disk" "$configured_too_large_output"

# A fresh disk read after Longhorn/Vault bootstrap must still happen before
# stale PVC deletion or Helm. Model a bootstrap that consumes too much space
# and assert that the second gate is a hard stop.
post_bootstrap_events="$test_dir/post-bootstrap-events.out"
post_bootstrap_selector="$test_dir/post-bootstrap-selector.yaml"
: >"$post_bootstrap_selector"
if PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c '
    source "$1"
    event_log="$2"
    selector_path="$3"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 0; }
    longhorn_manager_exists() { return 1; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_REQUIRED_NODES=3
      KUBETON_NODE_CHECK_TON_SELECTOR="ton.ton.org/kubeton-prereq=ready"
      printf "initial-preflight\n" >>"$event_log"
    }
    build_ton_node_selector_values_file() { printf "%s" "$selector_path"; }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    ensure_auto_bootstrap_stack() { printf "bootstrap\n" >>"$event_log"; }
    append_baremetal_key_overrides() { :; }
    run_node_prerequisite_check() { printf "post-bootstrap-preflight\n" >>"$event_log"; return 1; }
    delete_stale_ton_pvcs_before_fresh_start() { printf "UNSAFE stale-cleanup\n" >>"$event_log"; }
    run_start
  ' _ "$kubeton" "$post_bootstrap_events" "$post_bootstrap_selector" >"$test_dir/post-bootstrap.out" 2>&1; then
  echo "expected post-bootstrap disk recheck to stop start" >&2
  exit 1
fi
assert_order "bootstrap" "post-bootstrap-preflight" "$post_bootstrap_events"
if grep -Fq "UNSAFE" "$post_bootstrap_events"; then
  echo "start continued to stale cleanup after post-bootstrap disk recheck failed" >&2
  cat "$post_bootstrap_events" >&2
  exit 1
fi
if [[ -e "$post_bootstrap_selector" ]]; then
  echo "start left its generated selector values file behind after post-bootstrap failure" >&2
  exit 1
fi

# An already-installed Longhorn cluster does not run the bootstrap branch, so
# the exact selected-node CSINode gate must still run before stale PVC cleanup
# or Helm can create a TON pod. This models the driver missing from one of the
# selected nodes and verifies that start makes no deployment-side mutation.
existing_csi_gate_events="$test_dir/existing-csi-gate-events.out"
existing_csi_gate_selector="$test_dir/existing-csi-gate-selector.yaml"
: >"$existing_csi_gate_selector"
if PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c '
    source "$1"
    event_log="$2"
    selector_path="$3"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 1; }
    longhorn_manager_exists() { return 1; }
    storage_class_is_longhorn() { return 0; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_TON_SELECTOR="storage=manager"
      printf "initial-preflight\n" >>"$event_log"
    }
    build_ton_node_selector_values_file() { printf "%s" "$selector_path"; }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    validate_external_key_prereqs() { :; }
    wait_ton_selected_nodes_longhorn_csi_ready() { printf "csi-gate\n" >>"$event_log"; return 1; }
    delete_stale_ton_pvcs_before_fresh_start() { printf "UNSAFE stale-cleanup\n" >>"$event_log"; }
    run_start
  ' _ "$kubeton" "$existing_csi_gate_events" "$existing_csi_gate_selector" >"$test_dir/existing-csi-gate.out" 2>&1; then
  echo "expected selected-node Longhorn CSI gate to stop start" >&2
  exit 1
fi
assert_order "initial-preflight" "csi-gate" "$existing_csi_gate_events"
if grep -Fq "UNSAFE" "$existing_csi_gate_events"; then
  echo "start continued to stale PVC cleanup after selected-node Longhorn CSI gate failed" >&2
  cat "$existing_csi_gate_events" >&2
  exit 1
fi
if [[ -e "$existing_csi_gate_selector" ]]; then
  echo "start left its generated selector values file behind after Longhorn CSI gate failure" >&2
  exit 1
fi

# k3d runs the automatic bootstrap path but intentionally backs encrypted-sc
# with local-path, not Longhorn. It must retain node checks without waiting for
# a driver that this supported mode never installs.
k3d_start_events="$test_dir/k3d-start-events.out"
: >"$k3d_start_events"
: >"$test_dir/helm.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c '
    source "$1"
    event_log="$2"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 0; }
    cluster_is_k3d() { return 0; }
    longhorn_manager_exists() { return 1; }
    storage_class_is_longhorn() { return 1; }
    prepare_node_prerequisites_for_workload() {
      printf "use-longhorn=%s\n" "$2" >>"$event_log"
      KUBETON_NODE_CHECK_REQUIRED_NODES=3
      KUBETON_NODE_CHECK_TON_SELECTOR="ton.ton.org/kubeton-prereq=ready"
    }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    ensure_auto_bootstrap_stack() { printf "local-bootstrap\n" >>"$event_log"; }
    append_baremetal_key_overrides() { :; }
    run_node_prerequisite_check() { printf "node-recheck\n" >>"$event_log"; }
    node_check_selector_is_all_compatible() { :; }
    wait_ton_selected_nodes_longhorn_csi_ready() { printf "UNSAFE csi-wait\n" >>"$event_log"; return 1; }
    verify_ton_selected_nodes_longhorn_csi_ready() { printf "UNSAFE csi-probe\n" >>"$event_log"; return 1; }
    delete_stale_ton_pvcs_before_fresh_start() { printf "stale-cleanup\n" >>"$event_log"; }
    append_helm_force_conflicts_if_supported() { :; }
    repair_pending_ton_placement_after_start() { :; }
    run_start
  ' _ "$kubeton" "$k3d_start_events" >"$test_dir/k3d-start.out" 2>&1
assert_contains "use-longhorn=false" "$k3d_start_events"
assert_contains "local-bootstrap" "$k3d_start_events"
if grep -Fq "UNSAFE" "$k3d_start_events"; then
  echo "k3d start incorrectly required Longhorn CSI" >&2
  cat "$k3d_start_events" >&2
  exit 1
fi
assert_contains "upgrade" "$test_dir/helm.log"

# An existing Longhorn installation skips the bootstrap-only recheck. Even in
# that path, stale cleanup must be followed by one last resource/DiskPressure/
# HostPort check before Helm. A failure also removes the generated overlay.
final_recheck_events="$test_dir/final-recheck-events.out"
final_recheck_selector="$test_dir/final-recheck-selector.yaml"
: >"$final_recheck_selector"
: >"$test_dir/helm.log"
if PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c '
    source "$1"
    event_log="$2"
    selector_path="$3"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 1; }
    longhorn_manager_exists() { return 0; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_REQUIRED_NODES=3
      KUBETON_NODE_CHECK_TON_SELECTOR="storage=manager"
      printf "initial-preflight\n" >>"$event_log"
    }
    build_ton_node_selector_values_file() { printf "%s" "$selector_path"; }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    validate_external_key_prereqs() { :; }
    wait_ton_selected_nodes_longhorn_csi_ready() { printf "csi-gate\n" >>"$event_log"; }
    delete_stale_ton_pvcs_before_fresh_start() { printf "stale-cleanup\n" >>"$event_log"; }
    run_node_prerequisite_check() { printf "final-node-recheck\n" >>"$event_log"; return 1; }
    run_start
  ' _ "$kubeton" "$final_recheck_events" "$final_recheck_selector" >"$test_dir/final-recheck.out" 2>&1; then
  echo "expected final existing-Longhorn node recheck to stop start" >&2
  exit 1
fi
assert_order "stale-cleanup" "final-node-recheck" "$final_recheck_events"
if [[ -s "$test_dir/helm.log" ]]; then
  echo "start invoked Helm after its final node recheck failed" >&2
  cat "$test_dir/helm.log" >&2
  exit 1
fi
if [[ -e "$final_recheck_selector" ]]; then
  echo "start left its generated selector values file behind after final recheck failure" >&2
  exit 1
fi

# A selector can acquire an extra managed-label node while bootstrap runs.
# Rechecking only the count would still allow Helm to place a TON pod on that
# failed node, so require every node selected by the rendered selector to pass.
selector_drift_events="$test_dir/selector-drift-events.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c '
    source "$1"
    event_log="$2"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 0; }
    longhorn_manager_exists() { return 1; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_REQUIRED_NODES=3
      KUBETON_NODE_CHECK_TON_SELECTOR="ton.ton.org/kubeton-prereq=ready"
    }
    build_ton_node_selector_values_file() { printf "%s" "/tmp/kubeton-selector-drift.yaml"; }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    ensure_auto_bootstrap_stack() { printf "bootstrap\n" >>"$event_log"; }
    append_baremetal_key_overrides() { :; }
    run_node_prerequisite_check() { printf "count-recheck\n" >>"$event_log"; }
    node_check_selector_is_all_compatible() { printf "selector-recheck\n" >>"$event_log"; return 1; }
    node_check_print_failed_selector_nodes() { printf "failed-selector-node\n" >>"$event_log"; }
    delete_stale_ton_pvcs_before_fresh_start() { printf "UNSAFE stale-cleanup\n" >>"$event_log"; }
    run_start
  ' _ "$kubeton" "$selector_drift_events" >"$test_dir/selector-drift.out" 2>&1; then
  echo "expected selector drift onto a failed node to stop start" >&2
  exit 1
fi
assert_order "count-recheck" "selector-recheck" "$selector_drift_events"
if grep -Fq "UNSAFE" "$selector_drift_events"; then
  echo "start continued after the selected-node selector included a failed node" >&2
  cat "$selector_drift_events" >&2
  exit 1
fi

# Dump service availability is no longer part of the node check: configured
# storage remains authoritative even when the metadata endpoint is unavailable.
metadata_unavailable_output="$test_dir/metadata-unavailable.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=metadata-unavailable KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$metadata_unavailable_output" 2>&1
assert_contains "node filesystem requirement: >= 780.00 Gi" "$metadata_unavailable_output"
assert_contains "Compatible target nodes: 3/3 required." "$metadata_unavailable_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "storage-configured preflight unexpectedly depended on dump metadata" >&2
  cat "$test_dir/curl.log" >&2
  exit 1
fi

# YAML indentation is not required to be two spaces. The configured storage
# quantities remain authoritative with a four-space values layout.
four_space_env_values="$test_dir/four-space-env-values.yaml"
cat >"$four_space_env_values" <<'EOF'
tonNode:
    replicas: 3
    storage:
        tonWorkSize: 700Gi
        tonSourceSize: 20Gi
        myTonCoreSize: 20Gi
        myTonCtrlSize: 20Gi
    resources:
        requests:
            cpu: 16000m
            memory: 64Gi
EOF
four_space_env_output="$test_dir/four-space-env.out"
PATH="$fake_bin:$PATH" TON_VALUES_FILE="$four_space_env_values" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$four_space_env_output" 2>&1
assert_contains "node filesystem requirement: >= 780.00 Gi" "$four_space_env_output"

# Literal EnvVar ordering matches Kubernetes/controller merge semantics: the
# final entry wins when host-port discovery reads CUSTOM_PARAMETERS.
duplicate_env_values="$test_dir/duplicate-env-values.yaml"
cat >"$duplicate_env_values" <<'EOF'
tonNode:
  name: tonnode
  env:
    - name: CUSTOM_PARAMETERS
      value: "--exporter-address 0.0.0.0:9777"
    - name: CUSTOM_PARAMETERS
      value: "--exporter-address 0.0.0.0:9888"
EOF
duplicate_env_output="$test_dir/duplicate-env.out"
PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_effective_tonnode_env_value CUSTOM_PARAMETERS' _ \
  "$kubeton" "$duplicate_env_values" >"$duplicate_env_output"
assert_contains "0.0.0.0:9888" "$duplicate_env_output"

# DUMP may come from valueFrom because node capacity no longer depends on
# interpreting it. The storage-only check must still complete successfully.
value_from_env_values="$test_dir/value-from-env-values.yaml"
cat >"$value_from_env_values" <<'EOF'
tonNode:
  name: tonnode
  env:
    - name: DUMP
      valueFrom:
        configMapKeyRef:
          name: runtime-settings
          key: dump
EOF
value_from_output="$test_dir/value-from.out"
if ! PATH="$fake_bin:$PATH" TON_VALUES_FILE="$value_from_env_values" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$value_from_output" 2>&1; then
  echo "storage-only check failed for an unrelated DUMP valueFrom" >&2
  cat "$value_from_output" >&2
  exit 1
fi
assert_contains "node filesystem requirement: >= 780.00 Gi" "$value_from_output"
assert_contains "Compatible target nodes: 3/3 required." "$value_from_output"

# Inline YAML is valid Helm input, but this lightweight shell parser cannot
# safely reproduce an inline EnvVar list. Host-port discovery still fails
# closed because an exporter HostPort may be hidden in CUSTOM_PARAMETERS.
inline_env_values="$test_dir/inline-env-values.yaml"
cat >"$inline_env_values" <<'EOF'
tonNode:
  env: [{name: CUSTOM_PARAMETERS, value: "--exporter-address 0.0.0.0:9888"}]
EOF
inline_env_output="$test_dir/inline-env.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; node_check_resolve_host_port_requirements' _ \
  "$kubeton" "$inline_env_values" >"$inline_env_output" 2>&1; then
  echo "expected inline tonNode.env to block host-port preflight" >&2
  exit 1
fi
assert_contains "inline tonNode.env form that kubeton cannot safely preflight requested host ports" "$inline_env_output"

inline_tonnode_values="$test_dir/inline-tonnode-values.yaml"
cat >"$inline_tonnode_values" <<'EOF'
tonNode: { env: [{ name: CUSTOM_PARAMETERS, value: "--exporter-address 0.0.0.0:9888" }] }
EOF
inline_tonnode_output="$test_dir/inline-tonnode.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; node_check_resolve_host_port_requirements' _ \
  "$kubeton" "$inline_tonnode_values" >"$inline_tonnode_output" 2>&1; then
  echo "expected inline tonNode mapping with env to block host-port preflight" >&2
  exit 1
fi
assert_contains "inline tonNode/network map that kubeton cannot safely preflight requested host ports" "$inline_tonnode_output"

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

# Every selected node passes the same lower bound, but choose the least-used
# ones first so the alphabetically first hosts are not selected with the
# thinnest remaining disk margin.
ranked_output="$test_dir/ranked.out"
: >"$test_dir/labels.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=ranked KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 true' _ "$kubeton" >"$ranked_output" 2>&1
assert_contains "Selected compatible node(s): node-good-3 node-good-2 node-good-1" "$ranked_output"

# The preflight label is useful only if it reaches Helm's TonNode values.
# Exercise a successful fresh start and inspect the transient final -f overlay
# while fake Helm receives it; both managed selector terms must be present.
start_selector_values="$test_dir/start-selector-values.out"
start_gate_events="$test_dir/start-gate-events.out"
: >"$test_dir/helm.log"
: >"$start_selector_values"
: >"$start_gate_events"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_HELM_VALUES_LOG="$start_selector_values" \
  bash -c '
    source "$1"
    event_log="$2"
    csi_call_count=0
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 1; }
    longhorn_manager_exists() { return 0; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_REQUIRED_NODES=3
      KUBETON_NODE_CHECK_TON_SELECTOR="node.longhorn.io/create-default-disk=true,ton.ton.org/kubeton-prereq=ready"
    }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    validate_external_key_prereqs() { :; }
    wait_ton_selected_nodes_longhorn_csi_ready() {
      ((csi_call_count+=1))
      printf "csi-%s\n" "$csi_call_count" >>"$event_log"
    }
    verify_ton_selected_nodes_longhorn_csi_ready() {
      ((csi_call_count+=1))
      printf "csi-%s\n" "$csi_call_count" >>"$event_log"
    }
    delete_stale_ton_pvcs_before_fresh_start() { printf "stale-cleanup\n" >>"$event_log"; }
    run_node_prerequisite_check() { printf "final-node-recheck\n" >>"$event_log"; }
    node_check_selector_is_all_compatible() { printf "final-selector-recheck\n" >>"$event_log"; }
    append_helm_force_conflicts_if_supported() { :; }
    repair_pending_ton_placement_after_start() { :; }
    run_start
  ' _ "$kubeton" "$start_gate_events" >"$test_dir/start-selector.out" 2>&1
assert_contains "\"node.longhorn.io/create-default-disk\": \"true\"" "$start_selector_values"
assert_contains "\"ton.ton.org/kubeton-prereq\": \"ready\"" "$start_selector_values"
assert_order "csi-1" "stale-cleanup" "$start_gate_events"
assert_order "stale-cleanup" "csi-2" "$start_gate_events"
assert_order "csi-2" "final-node-recheck" "$start_gate_events"
assert_order "final-node-recheck" "final-selector-recheck" "$start_gate_events"
assert_order "final-selector-recheck" "csi-3" "$start_gate_events"

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

repair_output="$test_dir/repair.out"
: >"$test_dir/labels.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=existing-empty KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 true; printf "%s\n" "$LONGHORN_NODE_SELECTOR"' _ "$kubeton" >"$repair_output" 2>&1
assert_contains "Existing Longhorn has no volumes; safely rebuilding" "$repair_output"
assert_contains "node.longhorn.io/create-default-disk=true,ton.ton.org/kubeton-prereq=ready" "$repair_output"
assert_contains "label node node-good-1 ton.ton.org/kubeton-prereq=ready --overwrite" "$test_dir/labels.log"

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

# longhorn-csi-plugin is system-managed and is not rendered by Helm. Its first
# pod is safe only when the selector reaches Longhorn's default-settings
# ConfigMap before the manager creates that DaemonSet.
longhorn_values_output="$test_dir/longhorn-selector-values.out"
TMPDIR="$test_dir" PATH="$fake_bin:$PATH" bash -c 'source "$1"; selector_file="$(build_longhorn_selector_values_file "$2")"; sed -n "1,120p" "$selector_file"' _ \
  "$kubeton" 'node.longhorn.io/create-default-disk=true,ton.ton.org/kubeton-prereq=ready' >"$longhorn_values_output"
assert_contains "defaultSettings:" "$longhorn_values_output"
assert_contains 'systemManagedComponentsNodeSelector: "node.longhorn.io/create-default-disk:true;ton.ton.org/kubeton-prereq:ready"' "$longhorn_values_output"

echo "kubeton node prerequisite checks: PASS"
