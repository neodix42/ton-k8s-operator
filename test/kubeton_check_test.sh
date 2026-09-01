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
  available_bytes=2199023255552
  if [[ "$mode" == "dump-too-small" ]]; then
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
  if [[ "$mode" == "existing" || "$mode" == "existing-csi" || "$mode" == "existing-empty" ]]; then
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

if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "volumes.longhorn.io" ]]; then
  # A failed first Longhorn install has no user volumes, so it is safe to
  # reconfigure its selectors rather than preserve the bad broad placement.
  [[ "$mode" == "existing-empty" ]] && exit 0
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
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" "$kubeton" check >"$healthy_output" 2>&1
assert_contains "local TON PVC capacity: 760.00 Gi" "$healthy_output"
assert_contains "dump bootstrap (testnet, /var/ton-work/dump-cache)" "$healthy_output"
assert_contains "node filesystem requirement: >= 1.72 Ti" "$healthy_output"
assert_contains "node-bad" "$healthy_output"
assert_contains "FAIL: DiskPressure" "$healthy_output"
assert_contains "Compatible target nodes: 3/3 required." "$healthy_output"

# DUMP=false keeps the ordinary requested-PVC sizing path and does not make a
# network call to dump.ton.org.
no_dump_values="$test_dir/no-dump-values.yaml"
cat >"$no_dump_values" <<'EOF'
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
      value: "false"
EOF
no_dump_output="$test_dir/no-dump.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" TON_VALUES_FILE="$no_dump_values" KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$no_dump_output" 2>&1
assert_contains "node filesystem requirement: >= 780.00 Gi" "$no_dump_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "DUMP=false unexpectedly fetched dump metadata" >&2
  cat "$test_dir/curl.log" >&2
  exit 1
fi

# Preserve the existing configured-capacity floor when it is larger than the
# live dump peak. A large tonWork request must not make a smaller node pass
# merely because the current dump happens to be smaller.
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

# A host that would pass the old 780Gi request sum must now fail before Helm
# when it cannot hold the archive and extracted testnet database together.
dump_too_small_output="$test_dir/dump-too-small.out"
: >"$test_dir/helm.log"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=dump-too-small KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  bash -c 'source "$1"; should_bootstrap_baremetal() { return 1; }; longhorn_manager_exists() { return 1; }; run_start' _ "$kubeton" >"$dump_too_small_output" 2>&1; then
  echo "expected start to reject a node filesystem below the dump bootstrap peak" >&2
  exit 1
fi
assert_contains "dump bootstrap (testnet, /var/ton-work/dump-cache)" "$dump_too_small_output"
assert_contains "insufficient disk" "$dump_too_small_output"
if [[ -s "$test_dir/helm.log" ]]; then
  echo "helm was invoked even though dump-aware start preflight failed" >&2
  cat "$test_dir/helm.log" >&2
  exit 1
fi

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

metadata_unavailable_output="$test_dir/metadata-unavailable.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=metadata-unavailable KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$metadata_unavailable_output" 2>&1; then
  echo "expected DUMP=true preflight to fail closed when metadata is unavailable" >&2
  exit 1
fi
assert_contains "could not read current testnet dump metadata" "$metadata_unavailable_output"

# An air-gapped control host can deliberately provide both components of the
# peak. Partial overrides are rejected by kubeton, while the complete pair
# avoids a network fetch and retains the same disk gate.
offline_metadata_output="$test_dir/offline-metadata.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=metadata-unavailable KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  KUBETON_DUMP_ARCHIVE_BYTES=900000000000 KUBETON_DUMP_EXTRACTED_DB_BYTES=900000000000 \
  "$kubeton" check >"$offline_metadata_output" 2>&1
assert_contains "dump bootstrap (testnet, /var/ton-work/dump-cache)" "$offline_metadata_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "paired offline dump-size overrides unexpectedly fetched metadata" >&2
  cat "$test_dir/curl.log" >&2
  exit 1
fi

partial_override_output="$test_dir/partial-override.out"
if PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=metadata-unavailable KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  KUBETON_DUMP_ARCHIVE_BYTES=900000000000 "$kubeton" check >"$partial_override_output" 2>&1; then
  echo "expected a partial offline dump-size override to fail" >&2
  exit 1
fi
assert_contains "set both KUBETON_DUMP_ARCHIVE_BYTES and KUBETON_DUMP_EXTRACTED_DB_BYTES" "$partial_override_output"

# Only direct tonNode.env is effective. A nested helper env block must not
# suppress the top-level chart DUMP=true configuration.
nested_env_values="$test_dir/nested-env-values.yaml"
cat >"$nested_env_values" <<'EOF'
tonNode:
    keyManagement:
        agent:
            env:
                - name: DUMP
                  value: "false"
EOF
nested_env_output="$test_dir/nested-env.out"
PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_effective_tonnode_env_value DUMP' _ \
  "$kubeton" "$nested_env_values" >"$nested_env_output"
assert_contains "true" "$nested_env_output"

# YAML indentation is not required to be two spaces. A direct four-space env
# entry still controls the effective setting and skips the dump metadata call.
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
    env:
        - name: DUMP
          value: "false"
EOF
four_space_env_output="$test_dir/four-space-env.out"
: >"$test_dir/curl.log"
PATH="$fake_bin:$PATH" TON_VALUES_FILE="$four_space_env_values" KUBETON_TEST_CURL_LOG="$test_dir/curl.log" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" \
  "$kubeton" check >"$four_space_env_output" 2>&1
assert_contains "node filesystem requirement: >= 780.00 Gi" "$four_space_env_output"
if [[ -s "$test_dir/curl.log" ]]; then
  echo "four-space DUMP=false unexpectedly fetched dump metadata" >&2
  exit 1
fi

# Literal EnvVar ordering matches Kubernetes/controller merge semantics: the
# final DUMP entry wins. A valueFrom cannot be evaluated safely on the control
# host, so it blocks preflight rather than being treated as false.
duplicate_env_values="$test_dir/duplicate-env-values.yaml"
cat >"$duplicate_env_values" <<'EOF'
tonNode:
  env:
    - name: DUMP
      value: "false"
    - name: DUMP
      value: "true"
    - name: NETWORK
      value: testnet
EOF
duplicate_env_output="$test_dir/duplicate-env.out"
PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_effective_tonnode_env_value DUMP' _ \
  "$kubeton" "$duplicate_env_values" >"$duplicate_env_output"
assert_contains "true" "$duplicate_env_output"

value_from_env_values="$test_dir/value-from-env-values.yaml"
cat >"$value_from_env_values" <<'EOF'
tonNode:
  env:
    - name: DUMP
      valueFrom:
        configMapKeyRef:
          name: runtime-settings
          key: dump
EOF
value_from_output="$test_dir/value-from.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_tonnode_dump_bootstrap_requirements' _ \
  "$kubeton" "$value_from_env_values" >"$value_from_output" 2>&1; then
  echo "expected DUMP valueFrom to block dump preflight" >&2
  exit 1
fi
assert_contains "DUMP is configured through valueFrom" "$value_from_output"

# Inline YAML is valid Helm input, but this lightweight shell parser cannot
# safely reproduce an inline EnvVar list.  It must stop before assuming that
# DUMP is false and allowing a peak-space bootstrap onto an undersized node.
inline_env_values="$test_dir/inline-env-values.yaml"
cat >"$inline_env_values" <<'EOF'
tonNode:
  env: [{name: DUMP, value: "true"}]
EOF
inline_env_output="$test_dir/inline-env.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_tonnode_dump_bootstrap_requirements' _ \
  "$kubeton" "$inline_env_values" >"$inline_env_output" 2>&1; then
  echo "expected inline tonNode.env to block dump preflight" >&2
  exit 1
fi
assert_contains "inline tonNode.env form" "$inline_env_output"

inline_tonnode_values="$test_dir/inline-tonnode-values.yaml"
cat >"$inline_tonnode_values" <<'EOF'
tonNode: { env: [{ name: DUMP, value: "true" }] }
EOF
inline_tonnode_output="$test_dir/inline-tonnode.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_tonnode_dump_bootstrap_requirements' _ \
  "$kubeton" "$inline_tonnode_values" >"$inline_tonnode_output" 2>&1; then
  echo "expected inline tonNode mapping with env to block dump preflight" >&2
  exit 1
fi
assert_contains "inline tonNode.env form" "$inline_tonnode_output"

unsafe_cache_values="$test_dir/unsafe-cache-values.yaml"
cat >"$unsafe_cache_values" <<'EOF'
tonNode:
  env:
    - name: DUMP
      value: "true"
    - name: NETWORK
      value: testnet
    - name: DUMP_CACHE_DIR
      value: /var/ton-work/../tmp
EOF
unsafe_cache_output="$test_dir/unsafe-cache.out"
if PATH="$fake_bin:$PATH" bash -c 'source "$1"; TON_VALUES_FILE="$2"; resolve_tonnode_dump_bootstrap_requirements' _ \
  "$kubeton" "$unsafe_cache_values" >"$unsafe_cache_output" 2>&1; then
  echo "expected traversal-like DUMP_CACHE_DIR to block dump preflight" >&2
  exit 1
fi
assert_contains "not a normalized path inside /var/ton-work" "$unsafe_cache_output"

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
# ones first so dump growth does not leave the alphabetically first hosts with
# the thinnest margin.
ranked_output="$test_dir/ranked.out"
: >"$test_dir/labels.log"
PATH="$fake_bin:$PATH" KUBETON_TEST_MODE=ranked KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_LABEL_LOG="$test_dir/labels.log" \
  bash -c 'source "$1"; prepare_node_prerequisites_for_workload 3 true' _ "$kubeton" >"$ranked_output" 2>&1
assert_contains "Selected compatible node(s): node-good-3 node-good-2 node-good-1" "$ranked_output"

# The preflight label is useful only if it reaches Helm's TonNode values.
# Exercise a successful fresh start and inspect the transient final -f overlay
# while fake Helm receives it; both managed selector terms must be present.
start_selector_values="$test_dir/start-selector-values.out"
: >"$test_dir/helm.log"
: >"$start_selector_values"
PATH="$fake_bin:$PATH" KUBETON_TEST_HELM_LOG="$test_dir/helm.log" KUBETON_TEST_HELM_VALUES_LOG="$start_selector_values" \
  bash -c '
    source "$1"
    require_bin() { :; }
    resolve_ton_replicas_from_values_file() { printf "3"; }
    should_bootstrap_baremetal() { return 1; }
    longhorn_manager_exists() { return 1; }
    prepare_node_prerequisites_for_workload() {
      KUBETON_NODE_CHECK_TON_SELECTOR="node.longhorn.io/create-default-disk=true,ton.ton.org/kubeton-prereq=ready"
    }
    fleet_has_stop_annotations() { return 1; }
    ensure_ton_storage_class_available() { :; }
    append_ton_storage_overrides() { :; }
    should_use_sequential_ton_start() { return 1; }
    validate_external_key_prereqs() { :; }
    delete_stale_ton_pvcs_before_fresh_start() { :; }
    append_helm_force_conflicts_if_supported() { :; }
    repair_pending_ton_placement_after_start() { :; }
    run_start
  ' _ "$kubeton" >"$test_dir/start-selector.out" 2>&1
assert_contains "\"node.longhorn.io/create-default-disk\": \"true\"" "$start_selector_values"
assert_contains "\"ton.ton.org/kubeton-prereq\": \"ready\"" "$start_selector_values"

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
