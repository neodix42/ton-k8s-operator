#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "expected output to contain: $needle" >&2
    sed -n '1,200p' "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  [[ -e "$file" ]] || return 0
  if grep -Fq -- "$needle" "$file"; then
    echo "expected output not to contain: $needle" >&2
    sed -n '1,200p' "$file" >&2
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

# The exact PV host path must be usable even when a Rancher local-path
# provisioner uses a custom root rather than /opt/local-path-provisioner.
script_output="$test_dir/exact-path-script.out"
bash -c '
  source "$1"
  printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
  exact=("$row")
  patterns=()
  build_local_path_cleanup_script devnet-03 /opt/local-path-provisioner exact patterns
' _ "$kubeton" >"$script_output"
assert_contains "target=\"\$host_root\"'/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1'" "$script_output"

# Host-root cleanup paths must not contain traversal or duplicate-slash forms
# that can resolve outside the intended target after the /host prefix is
# applied by the privileged cleanup Pod.
if ! bash -c '
  source "$1"
  unsafe_tab_path="$(printf "/var/lib\\tkubelet")"
  for unsafe_path in /../etc /..//host/etc /./etc /var/lib//kubelet "$unsafe_tab_path"; do
    if local_path_absolute_target "$unsafe_path" >/dev/null; then
      echo "accepted unsafe path: $unsafe_path" >&2
      exit 1
    fi
  done
' _ "$kubeton"; then
  echo "expected traversal-like local-path targets to be rejected" >&2
  exit 1
fi

append_output="$test_dir/append-exact.out"
bash -c '
  source "$1"
  local_path_pv_host_path() { printf "%s" "/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1"; }
  local_path_pv_matches_claim() { return 0; }
  local_path_pv_is_provisioned_by_local_path() { return 0; }
  collect_local_path_nodes_for_pv() { local -n out="$2"; out+=("devnet-03"); }
  kubectl() {
    case "$*" in
      *"get pv pv-ton"*"metadata.uid"*) printf "pv-uid" ;;
      *"-n default get pvc ton-work-tonnode-1"*"metadata.uid"*) printf "pvc-uid" ;;
    esac
  }
  rows=()
  append_local_path_exact_cleanup_rows_for_pv pv-ton default/ton-work-tonnode-1 rows
  printf "%s\n" "${rows[@]}"
' _ "$kubeton" >"$append_output"
assert_contains $'devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid' "$append_output"

# Privileged Pods are commonly rejected in application namespaces.  A failed
# first choice must retry an eligible fallback (typically kube-system) rather
# than leaving a perfectly valid exact local-path target behind.
cleanup_namespace_fallback_events="$test_dir/cleanup-namespace-fallback-events.out"
bash -c '
  source "$1"
  event_log="$2"
  run_local_path_cleanup_pod_for_node() {
    printf "try-namespace %s\n" "$1" >>"$event_log"
    [[ "$1" == "kube-system" ]]
  }
  namespaces=(default kube-system)
  exact=()
  patterns=()
  run_local_path_cleanup_pod_for_node_with_fallback namespaces devnet-03 "" uninstall exact patterns
' _ "$kubeton" "$cleanup_namespace_fallback_events"
assert_order "try-namespace default" "try-namespace kube-system" "$cleanup_namespace_fallback_events"

# Disabling privileged host-path cleanup must not make ordinary CSI PV cleanup
# non-retryable. The generic PV record is always captured before PVC deletion.
generic_append_output="$test_dir/append-generic-pv.out"
bash -c '
  source "$1"
  KUBETON_LOCAL_PATH_CLEANUP=false
  kubectl() {
    case "$*" in
      *"get pv pv-keybundle"*) printf "pv-uid\tdefault\tkeybundle-tonnode-1\tpvc-uid\tDelete\tcsi.example.io\tvolume-handle" ;;
      *"-n default get pvc keybundle-tonnode-1"*) printf "pvc-uid" ;;
    esac
  }
  rows=()
  append_pv_cleanup_ledger_row_for_pv pv-keybundle default/keybundle-tonnode-1 rows
  printf "%s\n" "${rows[@]}"
' _ "$kubeton" >"$generic_append_output"
assert_contains $'pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tcsi.example.io\tvolume-handle\t' "$generic_append_output"

# A PVC created by an older controller can be missing the labels now used for
# broad cleanup discovery.  It is still a trusted TON PVC when it is the exact
# claim-template name of a StatefulSet captured before destructive cleanup.
# In particular, an incomplete bootstrap must not leave a tiny
# `mytoncore.db` behind merely because `mytoncore-tonnode-2` lost its labels.
trusted_legacy_mytoncore_events="$test_dir/trusted-legacy-mytoncore-events.out"
bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"delete pvc mytoncore-tonnode-2"*)
        printf "delete-pvc mytoncore-tonnode-2\n" >>"$event_log"
        ;;
      *"get pvc -o jsonpath="*)
        printf "mytoncore-tonnode-2\n"
        ;;
      *"get pvc mytoncore-tonnode-2"*".spec.volumeName"*)
        printf "pv-mytoncore"
        ;;
      *"get pvc mytoncore-tonnode-2"*)
        # Exists, but deliberately has no kubeton/ton-k8s-operator labels.
        :
        ;;
    esac
  }
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  # Values may have been renamed since this legacy StatefulSet was created;
  # acceptance must come from the captured StatefulSet, not a broad current
  # values-name match.
  resolve_tonnode_namespace_from_values() { printf "%s" "other-namespace"; }
  resolve_tonnode_name_from_values() { printf "%s" "renamed-tonnode"; }
  list_ton_pods() { :; }
  collect_local_path_pattern_cleanup_rows_for_pvcs() { :; }
  append_local_path_exact_cleanup_rows_for_pv() {
    local -n out="$3"
    local exact_row
    printf -v exact_row "devnet-04\t/home/danklishch/state-200gb-b5/pvc-mytoncore_default_mytoncore-tonnode-2\t%s\t%s\tpv-uid\tpvc-uid" "$1" "$2"
    out+=("$exact_row")
    printf "inventory-local %s %s\n" "$1" "$2" >>"$event_log"
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    local pv_row
    printf -v pv_row "%s\t%s\tpv-uid\tpvc-uid\tDelete\t\t\t" "$1" "$2"
    out+=("$pv_row")
    printf "inventory-pv %s %s\n" "$1" "$2" >>"$event_log"
  }
  record_local_path_cleanup_ledger() {
    local -n exact_rows="$1"
    local -n pv_rows="$2"
    printf "record-ledger exact=%s pv=%s\n" "${#exact_rows[@]}" "${#pv_rows[@]}" >>"$event_log"
  }
  wait_pvc_gone() { return 0; }
  cleanup_recorded_local_path_data() { printf "cleanup-recorded\n" >>"$event_log"; }
  cleanup_local_path_provisioner_data() { :; }
  sts_rows=()
  printf -v sts_row "default\ttonnode\t3"
  sts_rows+=("$sts_row")
  delete_ton_pvcs_for_statefulsets sts_rows uninstall
' _ "$kubeton" "$trusted_legacy_mytoncore_events"
assert_contains "inventory-pv pv-mytoncore default/mytoncore-tonnode-2" "$trusted_legacy_mytoncore_events"
assert_contains "record-ledger exact=1 pv=1" "$trusted_legacy_mytoncore_events"
assert_order "record-ledger exact=1 pv=1" "delete-pvc mytoncore-tonnode-2" "$trusted_legacy_mytoncore_events"

# Do not turn the legacy compatibility path into a broad prefix deletion.
# An unlabelled PVC with a similar name but no captured TON StatefulSet is not
# trusted and must remain untouched.
untrusted_legacy_mytoncore_events="$test_dir/untrusted-legacy-mytoncore-events.out"
bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc mytoncore-foreign-2"*) : ;;
    esac
  }
  collect_expected_ton_pvc_rows_from_values() {
    local -n out="$1"
    local foreign_row
    printf -v foreign_row "default\tmytoncore-foreign-2"
    out+=("$foreign_row")
  }
  collect_labeled_ton_pvc_rows() { :; }
  delete_pvc_rows_and_backing_volumes() {
    printf "UNSAFE delete %s\n" "${1:-}" >>"$event_log"
  }
  sts_rows=()
  delete_ton_pvcs_for_statefulsets sts_rows uninstall
' _ "$kubeton" "$untrusted_legacy_mytoncore_events"
if [[ -s "$untrusted_legacy_mytoncore_events" ]]; then
  echo "an untrusted unlabelled mytoncore PVC was selected for deletion" >&2
  cat "$untrusted_legacy_mytoncore_events" >&2
  exit 1
fi

# A retry can run after the operator and StatefulSet have already disappeared.
# The exact configured claim-template identity remains sufficient for explicit
# uninstall/drop, but must not be accepted by the non-destructive start path.
configured_legacy_mytoncore_selection="$test_dir/configured-legacy-mytoncore-selection.out"
bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pvc mytoncore-tonnode-2"*) : ;;
    esac
  }
  resolve_tonnode_namespace_from_values() { printf "%s" "default"; }
  resolve_tonnode_name_from_values() { printf "%s" "tonnode"; }
  candidates=($'"'"'default\tmytoncore-tonnode-2'"'"')
  uninstall_rows=()
  start_rows=()
  collect_existing_kubeton_pvc_rows candidates uninstall_rows uninstall
  collect_existing_kubeton_pvc_rows candidates start_rows start
  printf "uninstall=%s start=%s\n" "${uninstall_rows[*]:-}" "${start_rows[*]:-}"
' _ "$kubeton" >"$configured_legacy_mytoncore_selection"
assert_contains $'uninstall=default\tmytoncore-tonnode-2 start=' "$configured_legacy_mytoncore_selection"

# A present local-path PV follows the verified path through its final delete;
# this guards the fresh-UID check from becoming an unbound-variable failure.
present_local_events="$test_dir/present-local-events.out"
bash -c '
  source "$1"
  event_log="$2"
  local_path_recorded_pv_can_be_deleted() { :; }
  kubectl() {
    case "$*" in
      *"get pv pv-local"*"metadata.uid"*) printf "pv-uid" ;;
    esac
  }
  ensure_volume_attachments_gone_for_pv() { :; }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s finalizer=%s\n" "$1" "${4:-true}" >>"$event_log"; }
  printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-local\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
  rows=("$row")
  delete_recorded_local_path_pvs rows uninstall
' _ "$kubeton" "$present_local_events"
assert_contains "delete-pv pv-local finalizer=true" "$present_local_events"

# Exact host cleanup must never fan out to every node when the PV does not
# identify its owner through node affinity.
if bash -c '
  source "$1"
  local_path_pv_host_path() { printf "%s" "/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1"; }
  local_path_pv_matches_claim() { return 0; }
  local_path_pv_is_provisioned_by_local_path() { return 0; }
  collect_local_path_nodes_for_pv() { return 1; }
  rows=()
  append_local_path_exact_cleanup_rows_for_pv pv-ton default/ton-work-tonnode-1 rows
' _ "$kubeton"; then
  echo "expected missing PV node affinity to block exact host cleanup" >&2
  exit 1
fi

# Rancher local-path stores the real provisioning node in a PV annotation.
# Some older hostPath PVs lack the default hostname affinity (or use a custom
# nodeAffinityKey), so that annotation is a safe one-node fallback when the
# node still exists. This is the path used by stale-PVC cleanup before it may
# delete a PVC.
selected_node_append_output="$test_dir/selected-node-append.out"
bash -c '
  source "$1"
  local_path_pv_host_path() { printf "%s" "/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-2"; }
  local_path_pv_matches_claim() { return 0; }
  local_path_pv_is_provisioned_by_local_path() { return 0; }
  kubectl() {
    case "$*" in
      *"get pv pv-legacy --ignore-not-found"*nodeAffinity*) : ;;
      *"get pv pv-legacy --ignore-not-found"*selected-node*) printf "devnet-04" ;;
      "get node devnet-04") return 0 ;;
      *"get pv pv-legacy"*metadata.uid*) printf "pv-legacy-uid" ;;
      *"-n default get pvc ton-work-tonnode-2"*metadata.uid*) printf "pvc-legacy-uid" ;;
    esac
  }
  rows=()
  append_local_path_exact_cleanup_rows_for_pv pv-legacy default/ton-work-tonnode-2 rows
  printf "%s\n" "${rows[@]}"
' _ "$kubeton" >"$selected_node_append_output"
assert_contains $'devnet-04\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-2\tpv-legacy\tdefault/ton-work-tonnode-2\tpv-legacy-uid\tpvc-legacy-uid' "$selected_node_append_output"

# Ambiguous provenance must remain fail-closed: a PV whose hostname affinity
# and Rancher selected-node annotation disagree is not safe to clean.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pv pv-conflict --ignore-not-found"*nodeAffinity*) printf "In\tdevnet-04|\n__KUBETON_TERM_END__\n" ;;
      *"get pv pv-conflict --ignore-not-found"*selected-node*) printf "devnet-05" ;;
      "get nodes -l kubernetes.io/hostname=devnet-04"*) printf "devnet-04\n" ;;
      "get node devnet-05") return 0 ;;
    esac
  }
  nodes=()
  collect_local_path_nodes_for_pv pv-conflict nodes
' _ "$kubeton"; then
  echo "expected conflicting local-path affinity and selected-node provenance to block cleanup" >&2
  exit 1
fi

# A deleted node is not interchangeable with a node that merely shares a
# hostname label. Do not host-clean an old PV when its annotated owner is gone.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pv pv-gone --ignore-not-found"*nodeAffinity*) : ;;
      *"get pv pv-gone --ignore-not-found"*selected-node*) printf "gone-node" ;;
      "get node gone-node") return 1 ;;
    esac
  }
  nodes=()
  collect_local_path_nodes_for_pv pv-gone nodes
' _ "$kubeton"; then
  echo "expected a missing selected-node to block local-path cleanup" >&2
  exit 1
fi

# No node source at all is still a hard stop; do not turn the annotation
# fallback into a guessed/all-node cleanup path.
if bash -c '
  source "$1"
  kubectl() { :; }
  nodes=()
  collect_local_path_nodes_for_pv pv-unattributed nodes
' _ "$kubeton"; then
  echo "expected unattributed local-path PV to block cleanup" >&2
  exit 1
fi

# Existing hostname-affinity-only PVs retain their original behavior even if
# they predate Rancher selected-node annotations.
affinity_only_output="$test_dir/affinity-only.out"
bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pv pv-affinity --ignore-not-found"*nodeAffinity*) printf "In\tdevnet-03|\n__KUBETON_TERM_END__\n" ;;
      *"get pv pv-affinity --ignore-not-found"*selected-node*) : ;;
      "get nodes -l kubernetes.io/hostname=devnet-03"*) printf "devnet-03\n" ;;
    esac
  }
  nodes=()
  collect_local_path_nodes_for_pv pv-affinity nodes
  printf "%s\n" "${nodes[@]}"
' _ "$kubeton" >"$affinity_only_output"
assert_contains "devnet-03" "$affinity_only_output"

# The hostname value is a label value, not necessarily a Kubernetes node
# name. Resolve it through the label and never shortcut to an equal node name.
hostname_label_output="$test_dir/hostname-label.out"
bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      "get nodes -l kubernetes.io/hostname=legacy-host"*) printf "actual-node\n" ;;
      "get node legacy-host")
        echo "unsafe direct node-name lookup" >&2
        return 1
        ;;
    esac
  }
  resolve_node_name_for_hostname_value legacy-host
' _ "$kubeton" >"$hostname_label_output"
assert_contains "actual-node" "$hostname_label_output"

# A hostname `NotIn` (or any other non-In) requirement describes an exclusion,
# not one owning node. It must never turn into a host-path delete target.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pv pv-notin --ignore-not-found"*nodeAffinity*) printf "NotIn\tdevnet-04|\n__KUBETON_TERM_END__\n" ;;
      *"get pv pv-notin --ignore-not-found"*selected-node*) : ;;
    esac
  }
  nodes=()
  collect_local_path_nodes_for_pv pv-notin nodes
' _ "$kubeton"; then
  echo "expected non-In hostname affinity to block local-path cleanup" >&2
  exit 1
fi

# NodeSelectorTerms are alternatives.  A hostname-constrained term plus an
# alternate term with no hostname cannot prove a unique host unless Rancher
# recorded the provisioned node.  Do not delete based on the partial affinity.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get pv pv-or-ambiguous --ignore-not-found"*nodeAffinity*)
        printf "In\tdevnet-04|\n__KUBETON_TERM_END__\n__KUBETON_TERM_END__\n"
        ;;
      *"get pv pv-or-ambiguous --ignore-not-found"*selected-node*) : ;;
      "get nodes -l kubernetes.io/hostname=devnet-04"*) printf "devnet-04\n" ;;
    esac
  }
  nodes=()
  collect_local_path_nodes_for_pv pv-or-ambiguous nodes
' _ "$kubeton"; then
  echo "expected alternate unconstrained nodeSelectorTerm to block cleanup" >&2
  exit 1
fi

# If an old local-path PV is gone but a new PV now points at the same host
# directory, the old ledger must not remove that directory.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      "get pv pv-old --ignore-not-found"*) : ;;
      "get pv -o jsonpath="*) printf "pv-rebound\n" ;;
      "get pv pv-rebound --ignore-not-found"*"metadata.uid"*) printf "new-pv-uid" ;;
      "get pv pv-rebound --ignore-not-found"*"hostPath.path"*) printf "/home/danklishch/state-200gb-b5/pvc-old" ;;
    esac
  }
  local_path_recorded_pv_can_be_deleted pv-old /home/danklishch/state-200gb-b5/pvc-old default/ton-work-tonnode-1 old-pv-uid old-pvc-uid devnet-03
' _ "$kubeton"; then
  echo "expected a rebound local-path target to block host cleanup" >&2
  exit 1
fi

# The same directory cannot be removed merely because the recorded PV still
# exists: a second current hostPath/local PV may have rebound to it.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      "get pv -o jsonpath="*) printf "pv-old\npv-other\n" ;;
      "get pv pv-old --ignore-not-found"*"metadata.uid"*) printf "old-pv-uid" ;;
      "get pv pv-other --ignore-not-found"*"metadata.uid"*) printf "other-pv-uid" ;;
    esac
  }
  local_path_pv_host_path() { printf "%s" "/home/danklishch/state-200gb-b5/pvc-shared"; }
  local_path_target_is_exclusive_to_recorded_pv /home/danklishch/state-200gb-b5/pvc-shared pv-old old-pv-uid
' _ "$kubeton"; then
  echo "expected a shared live local-path target to block host cleanup" >&2
  exit 1
fi

# Deletion records the exact location before deleting its PVC, and does not
# continue to PV deletion if the post-PVC host cleanup cannot be verified.
delete_events="$test_dir/delete-events.out"
bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    printf "kubectl %s\n" "$*" >>"$event_log"
    case "$*" in
      *"get pvc ton-work-tonnode-1"*) printf "pv-ton" ;;
    esac
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() { :; }
  append_local_path_exact_cleanup_rows_for_pv() {
    local -n out="$3"
    local row
    printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
    out+=("$row")
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    local row
    printf -v row "pv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
    out+=("$row")
  }
  record_local_path_cleanup_ledger() { printf "record-ledger\n" >>"$event_log"; }
  wait_pvc_gone() { return 0; }
  cleanup_recorded_local_path_data() { printf "cleanup-ledger\ndelete-pv pv-ton\n" >>"$event_log"; }
  cleanup_local_path_provisioner_data() { printf "cleanup-patterns\n" >>"$event_log"; }
  wait_volume_attachments_gone() { return 0; }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  wait_longhorn_volume_gone() { return 0; }
  printf -v row "default\tton-work-tonnode-1"
  rows=("$row")
  delete_pvc_rows_and_backing_volumes rows uninstall
' _ "$kubeton" "$delete_events"
assert_order "record-ledger" "kubectl -n default delete pvc ton-work-tonnode-1" "$delete_events"
assert_order "kubectl -n default delete pvc ton-work-tonnode-1" "cleanup-ledger" "$delete_events"
assert_order "cleanup-ledger" "delete-pv pv-ton" "$delete_events"

failed_cleanup_events="$test_dir/failed-cleanup-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    printf "kubectl %s\n" "$*" >>"$event_log"
    case "$*" in
      *"get pvc ton-work-tonnode-1"*) printf "pv-ton" ;;
    esac
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() { :; }
  append_local_path_exact_cleanup_rows_for_pv() {
    local -n out="$3"
    local row
    printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
    out+=("$row")
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    local row
    printf -v row "pv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
    out+=("$row")
  }
  record_local_path_cleanup_ledger() { printf "record-ledger\n" >>"$event_log"; }
  wait_pvc_gone() { return 0; }
  cleanup_recorded_local_path_data() { printf "cleanup-ledger-failed\n" >>"$event_log"; return 1; }
  printf -v row "default\tton-work-tonnode-1"
  rows=("$row")
  delete_pvc_rows_and_backing_volumes rows uninstall
' _ "$kubeton" "$failed_cleanup_events"; then
  echo "expected host-cleanup failure to fail PVC/PV cleanup" >&2
  exit 1
fi
assert_contains "record-ledger" "$failed_cleanup_events"
assert_contains "cleanup-ledger-failed" "$failed_cleanup_events"
if grep -Fq "delete-pv" "$failed_cleanup_events"; then
  echo "PV deletion ran after an unverified host cleanup" >&2
  cat "$failed_cleanup_events" >&2
  exit 1
fi

# A ledger is a real durable record, not just an in-memory cleanup list. Its
# parser retains the node, path, PV/PVC names, and both UIDs for a retry after
# Kubernetes has already removed the PVC object.
ledger_rows_output="$test_dir/ledger-rows.out"
bash -c '
  source "$1"
  list_local_path_cleanup_ledger_locations() { printf "default\tkubeton-local-path-cleanup-test\n"; }
  kubectl() {
    case "$*" in
      *"get configmap kubeton-local-path-cleanup-test"*".data.targets"*)
        printf "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
        ;;
    esac
  }
  rows=()
  collect_local_path_cleanup_ledger_rows rows
  printf "%s\n" "${rows[@]}"
' _ "$kubeton" >"$ledger_rows_output"
assert_contains $'devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid' "$ledger_rows_output"

# The same durable ConfigMap also retains every CSI PV using immutable PV/PVC
# identities and the Longhorn CSI volume handle (not the PV name).
pv_ledger_rows_output="$test_dir/pv-ledger-rows.out"
bash -c '
  source "$1"
  list_local_path_cleanup_ledger_locations() { printf "kube-system\tkubeton-local-path-cleanup-test\n"; }
  kubectl() {
    case "$*" in
      *"get configmap kubeton-local-path-cleanup-test"*".data.pv-targets"*)
        printf "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
        ;;
    esac
  }
  rows=()
  collect_pv_cleanup_ledger_rows rows
  printf "%s\n" "${rows[@]}"
' _ "$kubeton" >"$pv_ledger_rows_output"
assert_contains $'pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid' "$pv_ledger_rows_output"

# A ledger-only retry must delete the exact Longhorn CSI handle only after the
# attachment check succeeds, then delete the matching PV. This remains possible
# even after the PVC object has already disappeared.
generic_retry_events="$test_dir/generic-retry-events.out"
bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { printf "verify-pv\n" >>"$event_log"; }
  ensure_volume_attachments_gone_for_pv() { printf "verify-attachment\n" >>"$event_log"; }
  recorded_longhorn_volume_matches_cleanup_ledger() { printf "verify-longhorn\n" >>"$event_log"; }
  kubectl() {
    case "$*" in
      *"get pv pv-keybundle"*"metadata.uid"*) printf "pv-uid" ;;
      *"get namespace longhorn-system"*"metadata.uid"*) printf "longhorn-namespace-uid" ;;
      *"get volumes.longhorn.io volume-handle"*"metadata.uid"*) printf "longhorn-uid" ;;
      *"delete volumes.longhorn.io volume-handle"*) printf "delete-longhorn\n" >>"$event_log" ;;
    esac
  }
  wait_longhorn_volume_gone() { printf "wait-longhorn\n" >>"$event_log"; }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$generic_retry_events"
assert_order "verify-attachment" "delete-longhorn" "$generic_retry_events"
assert_order "delete-longhorn" "wait-longhorn" "$generic_retry_events"
assert_order "wait-longhorn" "delete-pv pv-keybundle" "$generic_retry_events"

# Generic CSI PVs use normal CSI deletion only; they never get finalizers
# stripped, which could orphan a cloud disk.
generic_csi_events="$test_dir/generic-csi-events.out"
bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { :; }
  ensure_volume_attachments_gone_for_pv() { :; }
  kubectl() {
    case "$*" in
      *"get pv pv-csi"*"metadata.uid"*) printf "pv-uid" ;;
    esac
  }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s finalizer=%s\n" "$1" "$4" >>"$event_log"; }
  printf -v row "pv-csi\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tcsi.example.io\tvolume-handle\t"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$generic_csi_events"
assert_contains "delete-pv pv-csi finalizer=false" "$generic_csi_events"

# A reused PV name/UID mismatch must retain the ledger and must not delete the
# PV or Longhorn Volume CR.
generic_uid_mismatch_events="$test_dir/generic-uid-mismatch-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { return 1; }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  kubectl() { printf "delete-longhorn\n" >>"$event_log"; }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$generic_uid_mismatch_events"; then
  echo "expected a reused PV UID to retain the cleanup ledger" >&2
  exit 1
fi
if [[ -s "$generic_uid_mismatch_events" ]]; then
  echo "a reused PV triggered destructive cleanup" >&2
  cat "$generic_uid_mismatch_events" >&2
  exit 1
fi

# Recheck the PV identity immediately before delete; a PV recreated between
# validation and deletion must not be removed by name alone.
fresh_pv_mismatch_events="$test_dir/fresh-pv-mismatch-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { :; }
  kubectl() {
    case "$*" in
      *"get pv pv-keybundle"*"metadata.uid"*) printf "new-pv-uid" ;;
      *"delete pv pv-keybundle"*) printf "delete-pv\n" >>"$event_log" ;;
    esac
  }
  delete_pv_and_wait_for_gone() { printf "delete-pv-helper\n" >>"$event_log"; }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tcsi.example.io\tvolume-handle\t"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$fresh_pv_mismatch_events"; then
  echo "expected a fresh PV UID mismatch to block cleanup" >&2
  exit 1
fi
if [[ -s "$fresh_pv_mismatch_events" ]]; then
  echo "a PV recreated after validation was deleted" >&2
  cat "$fresh_pv_mismatch_events" >&2
  exit 1
fi

# An absent old PV is not enough to authorize Longhorn deletion: a new PV may
# have rebound the same CSI volume handle.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      "get pv -o jsonpath="*) printf "pv-rebound\tnew-pv-uid\tdriver.longhorn.io\tvolume-handle\n" ;;
    esac
  }
  longhorn_volume_handle_is_exclusive_to_recorded_pv pv-keybundle pv-uid volume-handle
' _ "$kubeton"; then
  echo "expected a rebound Longhorn volume handle to block cleanup" >&2
  exit 1
fi

# Generic CSI drivers need the identical live-PV handle guard. Otherwise a
# Delete-policy PV could make its controller delete storage still referenced
# by a static/rebound PV with the same backend handle.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      "get pv -o jsonpath="*) printf "pv-rebound\tnew-pv-uid\tcsi.example.io\tvolume-handle\n" ;;
    esac
  }
  csi_volume_handle_is_exclusive_to_recorded_pv pv-keybundle pv-uid csi.example.io volume-handle pv-uid
' _ "$kubeton"; then
  echo "expected a rebound generic CSI volume handle to block cleanup" >&2
  exit 1
fi

# Recheck the Longhorn UID immediately before delete as well; matching an
# earlier read is not enough if the CR was recreated in between.
fresh_longhorn_mismatch_events="$test_dir/fresh-longhorn-mismatch-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { :; }
  ensure_volume_attachments_gone_for_pv() { :; }
  longhorn_volume_handle_is_exclusive_to_recorded_pv() { :; }
  recorded_longhorn_volume_matches_cleanup_ledger() { :; }
  kubectl() {
    case "$*" in
      *"get pv pv-keybundle"*"metadata.uid"*) printf "pv-uid" ;;
      *"get namespace longhorn-system"*"metadata.uid"*) printf "longhorn-namespace-uid" ;;
      *"get volumes.longhorn.io volume-handle"*"metadata.uid"*) printf "new-longhorn-uid" ;;
      *"delete volumes.longhorn.io volume-handle"*) printf "delete-longhorn\n" >>"$event_log" ;;
    esac
  }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$fresh_longhorn_mismatch_events"; then
  echo "expected a fresh Longhorn UID mismatch to block cleanup" >&2
  exit 1
fi
if [[ -s "$fresh_longhorn_mismatch_events" ]]; then
  echo "a recreated Longhorn Volume CR was deleted" >&2
  cat "$fresh_longhorn_mismatch_events" >&2
  exit 1
fi

# If Longhorn has already been removed, its Volume CR is necessarily absent.
# A matching ledger can still finish PV deletion rather than being stuck on a
# lookup in a namespace that no longer exists.
absent_longhorn_namespace_events="$test_dir/absent-longhorn-namespace-events.out"
bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { :; }
  ensure_volume_attachments_gone_for_pv() { :; }
  longhorn_volume_handle_is_exclusive_to_recorded_pv() { :; }
  recorded_longhorn_volume_matches_cleanup_ledger() { :; }
  kubectl() {
    case "$*" in
      *"get pv pv-keybundle"*"metadata.uid"*) printf "pv-uid" ;;
      *"delete volumes.longhorn.io"*) printf "delete-longhorn\n" >>"$event_log" ;;
    esac
  }
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$absent_longhorn_namespace_events"
assert_contains "delete-pv pv-keybundle" "$absent_longhorn_namespace_events"
if grep -Fq "delete-longhorn" "$absent_longhorn_namespace_events"; then
  echo "attempted to delete a Longhorn Volume CR after its namespace was gone" >&2
  cat "$absent_longhorn_namespace_events" >&2
  exit 1
fi

# Two UID/handle records for a reused PV name are ambiguous. The reconciler
# must retain the ledger rather than delete one backend and silently skip the
# other.
generic_conflict_events="$test_dir/generic-conflict-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  kubectl() { printf "delete-longhorn\n" >>"$event_log"; }
  printf -v old_row "pv-reused\tdefault/keybundle-tonnode-1\told-pv-uid\told-pvc-uid\tDelete\tdriver.longhorn.io\told-handle\told-longhorn-uid"
  printf -v new_row "pv-reused\tdefault/keybundle-tonnode-1\tnew-pv-uid\tnew-pvc-uid\tDelete\tdriver.longhorn.io\tnew-handle\tnew-longhorn-uid"
  rows=("$old_row" "$new_row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$generic_conflict_events"; then
  echo "expected conflicting reused-PV ledger rows to block cleanup" >&2
  exit 1
fi
if [[ -s "$generic_conflict_events" ]]; then
  echo "a conflicting reused-PV ledger deleted storage" >&2
  cat "$generic_conflict_events" >&2
  exit 1
fi

# A CSI volume handle can be rebound under a different PV name.  Detect that
# conflict before processing either row: otherwise the first Delete-policy PV
# could let its CSI controller delete storage that a later Retain row protects.
shared_csi_handle_events="$test_dir/shared-csi-handle-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  kubectl() { printf "delete-longhorn\n" >>"$event_log"; }
  printf -v delete_row "pv-old\tdefault/keybundle-tonnode-1\told-pv-uid\told-pvc-uid\tDelete\tcsi.example.io\tshared-handle\t"
  printf -v retain_row "pv-new\tdefault/keybundle-tonnode-1\tnew-pv-uid\tnew-pvc-uid\tRetain\tcsi.example.io\tshared-handle\t"
  rows=("$delete_row" "$retain_row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$shared_csi_handle_events"; then
  echo "expected a shared generic CSI handle to block cleanup" >&2
  exit 1
fi
if [[ -s "$shared_csi_handle_events" ]]; then
  echo "a shared generic CSI handle triggered destructive cleanup" >&2
  cat "$shared_csi_handle_events" >&2
  exit 1
fi

# The same conflict rule applies to Longhorn handles.  Both backend Volume CR
# deletion and PV deletion must be blocked before the first row is processed.
shared_longhorn_handle_events="$test_dir/shared-longhorn-handle-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
  kubectl() { printf "delete-longhorn\n" >>"$event_log"; }
  printf -v delete_row "pv-old\tdefault/keybundle-tonnode-1\told-pv-uid\told-pvc-uid\tDelete\tdriver.longhorn.io\tshared-handle\told-longhorn-uid"
  printf -v retain_row "pv-new\tdefault/keybundle-tonnode-1\tnew-pv-uid\tnew-pvc-uid\tRetain\tdriver.longhorn.io\tshared-handle\tnew-longhorn-uid"
  rows=("$delete_row" "$retain_row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$shared_longhorn_handle_events"; then
  echo "expected a shared Longhorn handle to block cleanup" >&2
  exit 1
fi
if [[ -s "$shared_longhorn_handle_events" ]]; then
  echo "a shared Longhorn handle triggered destructive cleanup" >&2
  cat "$shared_longhorn_handle_events" >&2
  exit 1
fi

# With no remaining PVCs or local-path rows, the combined ledger reconciler
# still processes a persisted CSI PV target before it clears the ConfigMap.
storage_ledger_events="$test_dir/storage-ledger-events.out"
bash -c '
  source "$1"
  event_log="$2"
  collect_local_path_cleanup_ledger_rows() { :; }
  collect_pv_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
    out+=("$row")
  }
  delete_recorded_pv_cleanup_targets() { printf "delete-recorded-csi-pv\n" >>"$event_log"; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  cleanup_recorded_local_path_data uninstall
' _ "$kubeton" "$storage_ledger_events"
assert_order "delete-recorded-csi-pv" "clear-ledger" "$storage_ledger_events"

# The real no-PVC branch used by a second `kubeton uninstall` must reconcile
# the durable ledger, not merely return success because discovery is empty.
no_pvc_retry_events="$test_dir/no-pvc-retry-events.out"
bash -c '
  source "$1"
  event_log="$2"
  ton_fleet_resources_exist() { return 1; }
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() { :; }
  collect_local_path_cleanup_ledger_rows() { :; }
  collect_pv_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
    out+=("$row")
  }
  delete_recorded_pv_cleanup_targets() { printf "delete-recorded-csi-pv\n" >>"$event_log"; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  delete_stale_ton_pvcs_without_fleet uninstall true
' _ "$kubeton" "$no_pvc_retry_events"
assert_order "delete-recorded-csi-pv" "clear-ledger" "$no_pvc_retry_events"

# A local-path PV with Retain must never reach host deletion, PV deletion, or
# ledger clearing. Retain is a deliberate manual-storage policy.
retain_local_events="$test_dir/retain-local-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  collect_local_path_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-retain\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
    out+=("$row")
  }
  collect_pv_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "pv-retain\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid\tRetain\t\t\t"
    out+=("$row")
  }
  cleanup_local_path_provisioner_data() { printf "delete-host-path\n" >>"$event_log"; }
  delete_recorded_local_path_pvs() { printf "delete-pv\n" >>"$event_log"; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  cleanup_recorded_local_path_data uninstall
' _ "$kubeton" "$retain_local_events"; then
  echo "expected a Retain local-path target to block cleanup" >&2
  exit 1
fi
if [[ -s "$retain_local_events" ]]; then
  echo "Retain local-path data was destructively cleaned" >&2
  cat "$retain_local_events" >&2
  exit 1
fi

# A reused PV name with two ledger lifetimes is ambiguous even if one record is
# Delete. No host path may be removed before a human resolves the conflict.
local_reuse_events="$test_dir/local-reuse-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  collect_local_path_cleanup_ledger_rows() {
    local -n out="$1"
    local old_row new_row
    printf -v old_row "devnet-03\t/home/danklishch/old\tpv-reused\tdefault/ton-work-tonnode-1\told-pv-uid\told-pvc-uid"
    printf -v new_row "devnet-03\t/home/danklishch/new\tpv-reused\tdefault/ton-work-tonnode-1\tnew-pv-uid\tnew-pvc-uid"
    out+=("$old_row" "$new_row")
  }
  collect_pv_cleanup_ledger_rows() {
    local -n out="$1"
    local old_row new_row
    printf -v old_row "pv-reused\tdefault/ton-work-tonnode-1\told-pv-uid\told-pvc-uid\tDelete\t\t\t"
    printf -v new_row "pv-reused\tdefault/ton-work-tonnode-1\tnew-pv-uid\tnew-pvc-uid\tRetain\t\t\t"
    out+=("$old_row" "$new_row")
  }
  cleanup_local_path_provisioner_data() { printf "delete-host-path\n" >>"$event_log"; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  cleanup_recorded_local_path_data uninstall
' _ "$kubeton" "$local_reuse_events"; then
  echo "expected a reused local PV ledger to block cleanup" >&2
  exit 1
fi
if [[ -s "$local_reuse_events" ]]; then
  echo "a reused local PV ledger deleted host data" >&2
  cat "$local_reuse_events" >&2
  exit 1
fi

# On a ledger-only retry, host cleanup is followed by deletion of the exact
# recorded PV. The ledger is cleared only after both operations succeed.
retry_events="$test_dir/retry-events.out"
bash -c '
  source "$1"
  event_log="$2"
  collect_local_path_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
    out+=("$row")
  }
  collect_pv_cleanup_ledger_rows() { :; }
  verify_recorded_local_path_targets_use_delete_reclaim_policy() { :; }
  verify_recorded_local_path_targets_safe_for_host_cleanup() { :; }
  cleanup_local_path_provisioner_data() { printf "cleanup-host-path\n" >>"$event_log"; }
  delete_recorded_local_path_pvs() { printf "delete-recorded-pv\n" >>"$event_log"; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  cleanup_recorded_local_path_data uninstall
' _ "$kubeton" "$retry_events"
assert_order "cleanup-host-path" "delete-recorded-pv" "$retry_events"
assert_order "delete-recorded-pv" "clear-ledger" "$retry_events"

retry_failure_events="$test_dir/retry-failure-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  collect_local_path_cleanup_ledger_rows() {
    local -n out="$1"
    local row
    printf -v row "devnet-03\t/home/danklishch/state-200gb-b5/pvc-pvc-uid_default_ton-work-tonnode-1\tpv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid"
    out+=("$row")
  }
  collect_pv_cleanup_ledger_rows() { :; }
  verify_recorded_local_path_targets_use_delete_reclaim_policy() { :; }
  verify_recorded_local_path_targets_safe_for_host_cleanup() { :; }
  cleanup_local_path_provisioner_data() { printf "cleanup-host-path\n" >>"$event_log"; }
  delete_recorded_local_path_pvs() { printf "delete-recorded-pv-failed\n" >>"$event_log"; return 1; }
  clear_local_path_cleanup_ledgers() { printf "clear-ledger\n" >>"$event_log"; }
  cleanup_recorded_local_path_data uninstall
' _ "$kubeton" "$retry_failure_events" >"$test_dir/retry-failure-command.out" 2>&1; then
  echo "expected unresolved recorded PV to retain the cleanup ledger" >&2
  exit 1
fi
assert_contains "delete-recorded-pv-failed" "$retry_failure_events"
if grep -Fq "clear-ledger" "$retry_failure_events"; then
  echo "cleanup ledger was cleared before its recorded PV was gone" >&2
  cat "$retry_failure_events" >&2
  exit 1
fi

# A ledger-only drop/uninstall retry must propagate an unresolved cleanup, even
# after the PVC/PV objects have disappeared from the usual discovery paths.
if bash -c '
  source "$1"
  ton_fleet_resources_exist() { return 1; }
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() { :; }
  cleanup_recorded_local_path_data() { return 1; }
  delete_stale_ton_pvcs_without_fleet uninstall true
' _ "$kubeton"; then
  echo "expected ledger-only retry failure to propagate from drop/uninstall" >&2
  exit 1
fi

# API/RBAC errors are not the same as a deleted resource. A failed PV lookup
# must not trigger finalizer removal or allow the ledger to be cleared.
pv_lookup_events="$test_dir/pv-lookup-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() { printf "kubectl %s\n" "$*" >>"$event_log"; }
  wait_pv_gone() { return 2; }
  delete_pv_and_wait_for_gone pv-ton 1 1
' _ "$kubeton" "$pv_lookup_events"; then
  echo "expected PV lookup failure to fail cleanup" >&2
  exit 1
fi
if grep -Fq "patch pv/pv-ton" "$pv_lookup_events"; then
  echo "PV finalizers were cleared after an API/RBAC lookup failure" >&2
  cat "$pv_lookup_events" >&2
  exit 1
fi

# A VolumeAttachment API/RBAC failure or a timeout is not evidence that the
# volume is detached.  Neither case may reach PV deletion/finalizer recovery.
for attachment_result in 2 1; do
  attachment_events="$test_dir/attachment-${attachment_result}-events.out"
  if bash -c '
    source "$1"
    event_log="$2"
    attachment_result="$3"
    kubectl() {
      printf "kubectl %s\n" "$*" >>"$event_log"
      case "$*" in
        *"get pv pv-ton"*"metadata.uid"*) printf "pv-uid" ;;
      esac
    }
    recorded_pv_matches_cleanup_ledger() { :; }
    ensure_volume_attachments_gone_for_pv() { return "$attachment_result"; }
    delete_pv_and_wait_for_gone() { printf "delete-pv %s\n" "$1" >>"$event_log"; }
    printf -v row "pv-ton\tdefault/ton-work-tonnode-1\tpv-uid\tpvc-uid\tDelete\tcsi.example.io\tvolume-handle\t"
    rows=("$row")
    delete_recorded_pv_cleanup_targets rows uninstall
  ' _ "$kubeton" "$attachment_events" "$attachment_result"; then
    echo "expected unresolved VolumeAttachment state to fail cleanup" >&2
    exit 1
  fi
if grep -Fq "delete-pv" "$attachment_events"; then
    echo "PV deletion ran without a verified detached VolumeAttachment" >&2
    cat "$attachment_events" >&2
    exit 1
  fi
done

# A stale attachment can outlive the PV object itself. A ledger-only Longhorn
# retry must still verify attachments before it deletes the backend Volume CR.
absent_pv_attachment_events="$test_dir/absent-pv-attachment-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  recorded_pv_matches_cleanup_ledger() { :; }
  kubectl() {
    case "$*" in
      *"delete volumes.longhorn.io"*) printf "delete-longhorn\n" >>"$event_log" ;;
    esac
  }
  ensure_volume_attachments_gone_for_pv() { return 1; }
  printf -v row "pv-keybundle\tdefault/keybundle-tonnode-1\tpv-uid\tpvc-uid\tDelete\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid"
  rows=("$row")
  delete_recorded_pv_cleanup_targets rows uninstall
' _ "$kubeton" "$absent_pv_attachment_events"; then
  echo "expected stale attachment to block a ledger-only Longhorn cleanup" >&2
  exit 1
fi
if [[ -s "$absent_pv_attachment_events" ]]; then
  echo "Longhorn backend deletion ran while a stale attachment was unresolved" >&2
  cat "$absent_pv_attachment_events" >&2
  exit 1
fi

# Do not tear down Longhorn while its recorded cleanup target remains: a retry
# needs the Longhorn API to prove and remove the exact backend volume.
longhorn_gate_events="$test_dir/longhorn-gate-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  storage_cleanup_ledger_has_pending_longhorn_targets() { return 0; }
  uninstall_longhorn() { printf "uninstall-longhorn\n" >>"$event_log"; }
  cleanup_longhorn_force() { printf "force-longhorn\n" >>"$event_log"; }
  delete_namespace_with_progress() { printf "delete-longhorn-namespace\n" >>"$event_log"; }
  cleanup_longhorn_release
' _ "$kubeton" "$longhorn_gate_events"; then
  echo "expected a pending Longhorn ledger to block Longhorn uninstall" >&2
  exit 1
fi
if [[ -s "$longhorn_gate_events" ]]; then
  echo "Longhorn teardown ran while a cleanup ledger was pending" >&2
  cat "$longhorn_gate_events" >&2
  exit 1
fi

# An explicit TON uninstall may remove a stuck PVC whose local-path owner
# cannot be proven, but only after its generic PV/PVC identity is persisted.
# The unresolved target must stay out of wildcard/host cleanup and cause a
# non-zero result so the durable ledger is retained for manual reconciliation.
unresolved_local_force_events="$test_dir/unresolved-local-force-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"spec.volumeName"*) printf "pv-unresolved" ;;
      *"get pvc ton-work-tonnode-0"*"metadata.deletionTimestamp"*) printf "pvc-uid\t2026-09-01T12:00:00Z" ;;
      *"get pvc ton-work-tonnode-0"*"metadata.uid"*) printf "pvc-uid" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "patch-pvc-finalizers %s\n" "$*" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "delete-pvc\n" >>"$event_log" ;;
    esac
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    printf -v row "pv-unresolved\tdefault/ton-work-tonnode-0\tpv-uid\tpvc-uid\tDelete\t\t\t"
    out+=("$row")
    printf "generic-ledger\n" >>"$event_log"
  }
  append_local_path_exact_cleanup_rows_for_pv() {
    printf "exact-local-unresolved\n" >>"$event_log"
    return 2
  }
  record_local_path_cleanup_ledger() {
    local -n exact_rows="$1"
    local -n pv_rows="$2"
    printf "record-ledger exact=%s pv=%s\n" "${#exact_rows[@]}" "${#pv_rows[@]}" >>"$event_log"
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() {
    local -n rows="$1"
    printf "pattern-input=%s\n" "${#rows[@]}" >>"$event_log"
  }
  verify_no_pod_references_for_pvc() {
    printf "verify-no-pod-reference\n" >>"$event_log"
  }
  wait_calls=0
  wait_pvc_gone() {
    wait_calls=$((wait_calls + 1))
    if [[ "$wait_calls" -eq 1 ]]; then
      printf "wait-normal-delete\n" >>"$event_log"
      return 1
    fi
    printf "wait-after-finalizer-patch\n" >>"$event_log"
  }
  cleanup_recorded_local_path_data() {
    printf "retain-unresolved-ledger\n" >>"$event_log"
    return 1
  }
  cleanup_local_path_provisioner_data() {
    printf "host-cleanup\n" >>"$event_log"
  }
  rows=($'"'"'default\tton-work-tonnode-0'"'"')
  delete_pvc_rows_and_backing_volumes rows uninstall true
' _ "$kubeton" "$unresolved_local_force_events"; then
  echo "expected unresolved local-path storage to retain a non-zero uninstall result" >&2
  exit 1
fi
assert_order "generic-ledger" "record-ledger exact=0 pv=1" "$unresolved_local_force_events"
assert_order "record-ledger exact=0 pv=1" "delete-pvc" "$unresolved_local_force_events"
assert_order "delete-pvc" "verify-no-pod-reference" "$unresolved_local_force_events"
assert_order "verify-no-pod-reference" "patch-pvc-finalizers" "$unresolved_local_force_events"
assert_contains "--type=json" "$unresolved_local_force_events"
assert_contains "/metadata/uid" "$unresolved_local_force_events"
assert_contains "pattern-input=0" "$unresolved_local_force_events"
assert_contains "retain-unresolved-ledger" "$unresolved_local_force_events"
assert_not_contains "host-cleanup" "$unresolved_local_force_events"

# The guarded force helper must never strip finalizers while a Pod still
# references the claim, even in explicit uninstall/drop mode.
unresolved_local_pod_reference_events="$test_dir/unresolved-local-pod-reference-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"metadata.deletionTimestamp"*) printf "pvc-uid\t2026-09-01T12:00:00Z" ;;
      *"get pvc ton-work-tonnode-0"*"metadata.uid"*) printf "pvc-uid" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "UNSAFE patch-pvc-finalizers\n" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "normal-delete-pvc\n" >>"$event_log" ;;
    esac
  }
  wait_pvc_gone() { return 1; }
  verify_no_pod_references_for_pvc() {
    printf "pod-reference-remains\n" >>"$event_log"
    return 1
  }
  force_delete_unmounted_pvc_after_unresolved_local_inventory default ton-work-tonnode-0 pvc-uid 1
' _ "$kubeton" "$unresolved_local_pod_reference_events"; then
  echo "expected an active PVC reference to block finalizer removal" >&2
  exit 1
fi
assert_contains "pod-reference-remains" "$unresolved_local_pod_reference_events"
assert_order "normal-delete-pvc" "pod-reference-remains" "$unresolved_local_pod_reference_events"
assert_not_contains "UNSAFE patch-pvc-finalizers" "$unresolved_local_pod_reference_events"

# A same-name PVC recreated after inventory must not inherit the old claim's
# destructive finalizer recovery authorization.
unresolved_local_uid_change_events="$test_dir/unresolved-local-uid-change-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"metadata.uid"*) printf "new-pvc-uid" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "UNSAFE patch-pvc-finalizers\n" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "UNSAFE delete-pvc\n" >>"$event_log" ;;
    esac
  }
  verify_no_pod_references_for_pvc() {
    printf "UNSAFE verify-no-pod-reference\n" >>"$event_log"
  }
  force_delete_unmounted_pvc_after_unresolved_local_inventory default ton-work-tonnode-0 old-pvc-uid 1
' _ "$kubeton" "$unresolved_local_uid_change_events"; then
  echo "expected a recreated PVC UID to block finalizer removal" >&2
  exit 1
fi
assert_not_contains "UNSAFE verify-no-pod-reference" "$unresolved_local_uid_change_events"
assert_not_contains "UNSAFE patch-pvc-finalizers" "$unresolved_local_uid_change_events"
assert_not_contains "UNSAFE delete-pvc" "$unresolved_local_uid_change_events"

# A missing generic PV identity is a hard block. In particular, an exact path
# must not even be inventoried/persisted after generic identity collection
# fails, otherwise an unbound host path could be cleaned on a later retry.
generic_ledger_failure_events="$test_dir/generic-ledger-failure-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"spec.volumeName"*) printf "pv-unresolved" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "UNSAFE patch-pvc-finalizers\n" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "UNSAFE delete-pvc\n" >>"$event_log" ;;
    esac
  }
  append_pv_cleanup_ledger_row_for_pv() {
    printf "generic-ledger-failed\n" >>"$event_log"
    return 1
  }
  append_local_path_exact_cleanup_rows_for_pv() {
    printf "UNSAFE exact-local-inventory\n" >>"$event_log"
  }
  record_local_path_cleanup_ledger() {
    local -n exact_rows="$1"
    local -n pv_rows="$2"
    printf "record-ledger exact=%s pv=%s\n" "${#exact_rows[@]}" "${#pv_rows[@]}" >>"$event_log"
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() {
    local -n rows="$1"
    printf "pattern-input=%s\n" "${#rows[@]}" >>"$event_log"
  }
  cleanup_recorded_local_path_data() { :; }
  cleanup_local_path_provisioner_data() {
    local -n exact_rows="$1"
    local -n pattern_rows="$2"
    printf "host-cleanup exact=%s patterns=%s\n" "${#exact_rows[@]}" "${#pattern_rows[@]}" >>"$event_log"
  }
  rows=($'"'"'default\tton-work-tonnode-0'"'"')
  delete_pvc_rows_and_backing_volumes rows uninstall true
' _ "$kubeton" "$generic_ledger_failure_events"; then
  echo "expected a missing generic PV identity to block PVC cleanup" >&2
  exit 1
fi
assert_contains "generic-ledger-failed" "$generic_ledger_failure_events"
assert_contains "record-ledger exact=0 pv=0" "$generic_ledger_failure_events"
assert_contains "host-cleanup exact=0 patterns=0" "$generic_ledger_failure_events"
assert_not_contains "UNSAFE exact-local-inventory" "$generic_ledger_failure_events"
assert_not_contains "UNSAFE patch-pvc-finalizers" "$generic_ledger_failure_events"
assert_not_contains "UNSAFE delete-pvc" "$generic_ledger_failure_events"

# Only the narrow “owner node cannot resolve” exact-inventory result is
# eligible for guarded PVC removal. A malformed path, claim mismatch, or
# untrusted provisioner returns the ordinary failure status and must leave the
# PVC intact even during explicit uninstall/drop.
unsafe_exact_inventory_events="$test_dir/unsafe-exact-inventory-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"spec.volumeName"*) printf "pv-unresolved" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "UNSAFE patch-pvc-finalizers\n" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "UNSAFE delete-pvc\n" >>"$event_log" ;;
    esac
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    printf -v row "pv-unresolved\tdefault/ton-work-tonnode-0\tpv-uid\tpvc-uid\tDelete\t\t\t"
    out+=("$row")
    printf "generic-ledger\n" >>"$event_log"
  }
  append_local_path_exact_cleanup_rows_for_pv() {
    printf "unsafe-exact-inventory\n" >>"$event_log"
    return 1
  }
  record_local_path_cleanup_ledger() {
    local -n exact_rows="$1"
    local -n pv_rows="$2"
    printf "record-ledger exact=%s pv=%s\n" "${#exact_rows[@]}" "${#pv_rows[@]}" >>"$event_log"
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() {
    local -n rows="$1"
    printf "pattern-input=%s\n" "${#rows[@]}" >>"$event_log"
  }
  verify_no_pod_references_for_pvc() {
    printf "UNSAFE verify-no-pod-reference\n" >>"$event_log"
  }
  cleanup_recorded_local_path_data() {
    printf "retain-ledger\n" >>"$event_log"
    return 1
  }
  cleanup_local_path_provisioner_data() {
    printf "UNSAFE host-cleanup\n" >>"$event_log"
  }
  rows=($'"'"'default\tton-work-tonnode-0'"'"')
  delete_pvc_rows_and_backing_volumes rows uninstall true
' _ "$kubeton" "$unsafe_exact_inventory_events"; then
  echo "expected an unsafe exact local-path inventory failure to block force deletion" >&2
  exit 1
fi
assert_order "generic-ledger" "unsafe-exact-inventory" "$unsafe_exact_inventory_events"
assert_contains "record-ledger exact=0 pv=1" "$unsafe_exact_inventory_events"
assert_contains "pattern-input=0" "$unsafe_exact_inventory_events"
assert_not_contains "UNSAFE verify-no-pod-reference" "$unsafe_exact_inventory_events"
assert_not_contains "UNSAFE patch-pvc-finalizers" "$unsafe_exact_inventory_events"
assert_not_contains "UNSAFE delete-pvc" "$unsafe_exact_inventory_events"
assert_not_contains "UNSAFE host-cleanup" "$unsafe_exact_inventory_events"

# Persisting the generic ledger is the final authorization point. A failed
# write leaves even a known, unmounted PVC untouched.
unresolved_ledger_persist_failure_events="$test_dir/unresolved-ledger-persist-failure-events.out"
if bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      *"get pvc ton-work-tonnode-0"*"spec.volumeName"*) printf "pv-unresolved" ;;
      *"get pvc ton-work-tonnode-0"*"metadata.uid"*) printf "pvc-uid" ;;
      *"patch pvc ton-work-tonnode-0"*) printf "UNSAFE patch-pvc-finalizers\n" >>"$event_log" ;;
      *"delete pvc ton-work-tonnode-0"*) printf "UNSAFE delete-pvc\n" >>"$event_log" ;;
    esac
  }
  append_pv_cleanup_ledger_row_for_pv() {
    local -n out="$3"
    printf -v row "pv-unresolved\tdefault/ton-work-tonnode-0\tpv-uid\tpvc-uid\tDelete\t\t\t"
    out+=("$row")
    printf "generic-ledger\n" >>"$event_log"
  }
  append_local_path_exact_cleanup_rows_for_pv() {
    printf "exact-local-unresolved\n" >>"$event_log"
    return 2
  }
  record_local_path_cleanup_ledger() {
    printf "ledger-persist-failed\n" >>"$event_log"
    return 1
  }
  collect_local_path_pattern_cleanup_rows_for_pvcs() {
    printf "UNSAFE pattern-cleanup-input\n" >>"$event_log"
  }
  verify_no_pod_references_for_pvc() {
    printf "UNSAFE verify-no-pod-reference\n" >>"$event_log"
  }
  cleanup_recorded_local_path_data() {
    printf "UNSAFE recorded-cleanup\n" >>"$event_log"
  }
  rows=($'"'"'default\tton-work-tonnode-0'"'"')
  delete_pvc_rows_and_backing_volumes rows uninstall true
' _ "$kubeton" "$unresolved_ledger_persist_failure_events"; then
  echo "expected a failed cleanup-ledger write to block PVC force deletion" >&2
  exit 1
fi
assert_order "generic-ledger" "ledger-persist-failed" "$unresolved_ledger_persist_failure_events"
assert_not_contains "UNSAFE patch-pvc-finalizers" "$unresolved_ledger_persist_failure_events"
assert_not_contains "UNSAFE delete-pvc" "$unresolved_ledger_persist_failure_events"
assert_not_contains "UNSAFE pattern-cleanup-input" "$unresolved_ledger_persist_failure_events"
assert_not_contains "UNSAFE verify-no-pod-reference" "$unresolved_ledger_persist_failure_events"
assert_not_contains "UNSAFE recorded-cleanup" "$unresolved_ledger_persist_failure_events"

# The extra force authorization is wired only through destructive TON
# commands. Ordinary cleanup/start callers retain the original fail-closed
# behavior when exact local-path provenance is missing.
ton_force_mode_events="$test_dir/ton-force-mode-events.out"
bash -c '
  source "$1"
  event_log="$2"
  collect_expected_ton_pvc_rows_from_values() {
    local -n out="$1"
    out+=($'"'"'default\tton-work-tonnode-0'"'"')
  }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() {
    local -n out="$2"
    out+=($'"'"'default\tton-work-tonnode-0'"'"')
  }
  list_ton_pods() { :; }
  delete_pvc_rows_and_backing_volumes() {
    printf "%s force=%s\n" "$2" "$3" >>"$event_log"
  }
  sts_rows=()
  delete_ton_pvcs_for_statefulsets sts_rows uninstall
  delete_ton_pvcs_for_statefulsets sts_rows drop
  delete_ton_pvcs_for_statefulsets sts_rows start
' _ "$kubeton" "$ton_force_mode_events"
assert_contains "uninstall force=true" "$ton_force_mode_events"
assert_contains "drop force=true" "$ton_force_mode_events"
assert_contains "start force=false" "$ton_force_mode_events"

# A recorded teardown error must make uninstall non-successful even when the
# generic Kubernetes leftover sweep happens to be empty.
uninstall_output="$test_dir/uninstall-failure.out"
if bash -c '
  source "$1"
  list_ton_statefulsets() { :; }
  stop_ton_for_destructive_cleanup() { :; }
  delete_ton_pvcs_for_statefulsets() { return 1; }
  cleanup_kubectl_debug_pods() { :; }
  cleanup_observability_resources() { :; }
  cleanup_operator_release() { :; }
  cleanup_vault_release() { :; }
  cleanup_encrypted_storage_class() { :; }
  cleanup_longhorn_release() { :; }
  delete_stale_ton_pvcs_without_fleet() { :; }
  cleanup_kubeton_managed_labeled_resources() { :; }
  verify_uninstall_leftovers() { :; }
  run_uninstall_core
' _ "$kubeton" >"$uninstall_output" 2>&1; then
  echo "expected uninstall to fail after a teardown step failure" >&2
  cat "$uninstall_output" >&2
  exit 1
fi
assert_contains "Uninstall is not marked complete" "$uninstall_output"
if grep -Fq "[uninstall] Uninstall complete." "$uninstall_output"; then
  echo "uninstall falsely reported completion after a teardown failure" >&2
  cat "$uninstall_output" >&2
  exit 1
fi

echo "kubeton cleanup checks: PASS"
