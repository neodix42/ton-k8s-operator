#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# No cluster is contacted: production discovery, provenance checks, ledger
# reconciliation and CSI/local-path deletion gates use one stateful API mock.
cat > "$test_dir/scenario.sh" <<'SCENARIO'
set -euo pipefail
source "$1"
scenario="$2"
fixture_dir="$3"
mkdir -p "$fixture_dir"
events="$fixture_dir/events"
: > "$events"
claim_uid=claim-uid
mock_pv=pvc-claim-uid
mock_pv_uid=pv-uid
claim_ns=default
claim_name=keybundle-tonnode-7
mock_reclaim=Delete
mock_driver=driver.longhorn.io
mock_handle=volume-handle
mock_provisioner=driver.longhorn.io
mock_managed_by=""
mock_app_name=""
mock_resource_policy=""
command_label=uninstall
trusted_sts_rows=()
case "$scenario" in
  local|local-unsafe|local-unresolved|local-disabled)
    mock_driver=""; mock_handle=""; mock_provisioner=rancher.io/local-path
    claim_name=ton-work-tonnode-7 ;;
  retain) mock_reclaim=Retain ;;
  static) mock_pv=static-volume ;;
  no-claim-uid) claim_uid="" ;;
  foreign-label) mock_managed_by=external ;;
  foreign-app) mock_app_name=another-app ;;
  keep-policy) mock_resource_policy=keep ;;
  unprovisioned) mock_provisioner="" ;;
  foreign-driver) mock_driver=csi.example.io; mock_provisioner=csi.example.io ;;
  wrong-namespace) claim_ns=foreign ;;
  wrong-fleet) claim_name=keybundle-other-fleet-0 ;;
  invalid-ordinal) claim_name=keybundle-tonnode-7-extra ;;
  captured-sts)
    claim_ns=old-namespace; claim_name=keybundle-legacy-fleet-9
    trusted_sts_rows=($'old-namespace\tlegacy-fleet\t10') ;;
  drop) command_label=drop ;;
  start) command_label=start ;;
esac
resolve_tonnode_namespace_from_values() { printf default; }
resolve_tonnode_name_from_values() { printf tonnode; }
KUBETON_LOCAL_PATH_CLEANUP=true
[[ "$scenario" == local-disabled ]] && KUBETON_LOCAL_PATH_CLEANUP=false
snapshot_row() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$mock_pv" "$mock_pv_uid" "$claim_ns" "$claim_name" "$claim_uid" "$mock_reclaim" "$mock_driver" "$mock_handle" "$mock_provisioner" "$mock_managed_by" "$mock_app_name" "$mock_resource_policy"
}
kubectl() {
  local args="$*"
  printf 'api %s\n' "$args" >> "$events"
  case "$args" in
    'get pv -o jsonpath={range .items[*]}'*'"|"'*)
      [[ "$scenario" != inventory-error ]] || return 1
      [[ ! -e "$fixture_dir/pv-gone" ]] || return 0
      snapshot_row
      if [[ "$scenario" == ambiguous ]]; then printf '\n'; snapshot_row; fi
      ;;
    "get pv $mock_pv --ignore-not-found -o jsonpath={.metadata.name}"*)
      [[ "$scenario" != snapshot-error ]] || return 1
      [[ ! -e "$fixture_dir/pv-gone" ]] || return 0
      if [[ "$scenario" == changed-pv ]]; then printf changed; else snapshot_row; fi
      ;;
    "get pv $mock_pv --ignore-not-found -o jsonpath={.metadata.uid}"*'spec.claimRef.namespace'*)
      [[ ! -e "$fixture_dir/pv-gone" ]] || return 0
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$mock_pv_uid" "$claim_ns" "$claim_name" "$claim_uid" "$mock_reclaim" "$mock_driver" "$mock_handle"
      ;;
    "get pv $mock_pv --ignore-not-found -o jsonpath={.metadata.uid}"*'persistentVolumeReclaimPolicy'*)
      printf '%s\t%s' "$mock_pv_uid" "$mock_reclaim" ;;
    "get pv $mock_pv --ignore-not-found -o jsonpath={.metadata.uid}")
      [[ ! -e "$fixture_dir/pv-gone" ]] || return 0
      printf '%s' "$mock_pv_uid" ;;
    "get pv $mock_pv -o jsonpath={.spec.claimRef.namespace}"*)
      printf '%s\t%s\t%s' "$claim_ns" "$claim_name" "$claim_uid" ;;
    'get pv -o jsonpath={range .items[*]}'*'spec.csi.driver'*)
      [[ ! -e "$fixture_dir/pv-gone" ]] || return 0
      printf '%s\t%s\t%s\t%s\n' "$mock_pv" "$mock_pv_uid" "$mock_driver" "$mock_handle"
      [[ "$scenario" != rebound-handle ]] || printf 'other-pv\tother-uid\t%s\t%s\n' "$mock_driver" "$mock_handle"
      ;;
    'get pv -o jsonpath={range .items[*]}'*) printf '%s\n' "$mock_pv" ;;
    "-n $claim_ns get pvc $claim_name --ignore-not-found -o jsonpath={.metadata.uid}")
      [[ "$scenario" != pvc-api-error ]] || return 1
      [[ "$scenario" != recreated-pvc ]] || printf new-pvc-uid
      ;;
    'get namespace '*'-o jsonpath={.metadata.name}') printf '%s' "$claim_ns" ;;
    'get namespace '*'-o jsonpath={.metadata.uid}') printf namespace-uid ;;
    'get namespace '*'-o jsonpath={.status.phase}') printf Active ;;
    "-n $claim_ns get pods -o jsonpath="*)
      [[ "$scenario" != pods-api-error ]] || return 1
      [[ "$scenario" != mounted ]] || printf 'other-pod\t%s,\n' "$claim_name"
      ;;
    'get volumeattachments.storage.k8s.io '* )
      [[ "$scenario" != attachment-api-error ]] || return 1
      [[ "$scenario" != attached ]] || printf volume-attachment
      ;;
    '-n longhorn-system get volumes.longhorn.io volume-handle --ignore-not-found -o jsonpath={.metadata.uid}'*'"|"'*)
      [[ "$scenario" != backend-api-error ]] || return 1
      [[ ! -e "$fixture_dir/backend-gone" ]] || return 0
      if [[ "$scenario" == backend-attached ]]; then printf 'longhorn-uid|attached|worker|worker'; else printf 'longhorn-uid|detached||'; fi
      ;;
    '-n longhorn-system get volumes.longhorn.io volume-handle --ignore-not-found -o jsonpath={.metadata.uid}')
      [[ ! -e "$fixture_dir/backend-gone" ]] || return 0
      printf longhorn-uid ;;
    '-n longhorn-system delete volumes.longhorn.io volume-handle --ignore-not-found --wait=false')
      printf 'delete-backend\n' >> "$events"
      touch "$fixture_dir/backend-gone" ;;
    *) printf 'UNHANDLED MOCK: %s\n' "$args" >&2; return 1 ;;
  esac
}
# Stateful ledger writes are mocked, while the actual reconciliation checks
# use exactly the records production discovery handed to the durable writer.
record_local_path_cleanup_ledger() {
  local -n local_records="$1" pv_records="$2"
  printf 'persist-ledger exact=%s pv=%s\n' "${#local_records[@]}" "${#pv_records[@]}" >> "$events"
  [[ "$scenario" != ledger-error ]] || return 1
  printf '%s\n' "${local_records[@]}" > "$fixture_dir/local-ledger"
  printf '%s\n' "${pv_records[@]}" > "$fixture_dir/pv-ledger"
}
collect_local_path_cleanup_ledger_rows() {
  local -n output="$1"
  local line
  [[ -e "$fixture_dir/local-ledger" ]] || return 0
  while IFS= read -r line; do [[ -z "$line" ]] || output+=("$line"); done < "$fixture_dir/local-ledger"
}
collect_pv_cleanup_ledger_rows() {
  local -n output="$1"
  local line
  [[ -e "$fixture_dir/pv-ledger" ]] || return 0
  while IFS= read -r line; do [[ -z "$line" ]] || output+=("$line"); done < "$fixture_dir/pv-ledger"
}
clear_local_path_cleanup_ledgers() { printf 'clear-ledger\n' >> "$events"; }
local_path_pv_is_provisioned_by_local_path() { [[ "$mock_provisioner" == rancher.io/local-path ]]; }
local_path_pv_host_path() {
  if [[ "$scenario" == local-unsafe ]]; then printf /../etc; elif [[ "$mock_driver" == "" ]]; then printf /data/pvc-claim-uid_default_ton-work-tonnode-7; fi
}
collect_local_path_nodes_for_pv() {
  [[ "$scenario" != local-unresolved ]] || return 1
  local -n output="$2"
  output+=(worker)
}
cleanup_local_path_provisioner_data() { printf 'delete-host-directory\n' >> "$events"; }
delete_pv_and_wait_for_gone() {
  printf 'delete-pv %s\n' "$1" >> "$events"
  [[ "$scenario" != delete-error ]] || return 1
  touch "$fixture_dir/pv-gone"
}
cleanup_legacy_ton_pvs_for_statefulsets trusted_sts_rows "$command_label"
SCENARIO

passes=0
run_scenario() {
  local scenario="$1" expected="$2" result=0
  bash "$test_dir/scenario.sh" "$kubeton" "$scenario" "$test_dir/$scenario" > "$test_dir/$scenario.out" 2>&1 || result=$?
  if [[ ( ( "$expected" == success || "$expected" == deleted ) && "$result" != 0 ) || ( ( "$expected" == failure || "$expected" == failed-delete ) && "$result" == 0 ) ]]; then
    cat "$test_dir/$scenario.out" >&2
    cat "$test_dir/$scenario/events" >&2
    echo "unexpected status $result in $scenario ($expected)" >&2
    exit 1
  fi
  if [[ "$expected" != deleted && "$expected" != failed-delete ]]; then
    if grep -Eq '^delete-(backend|host-directory|pv)' "$test_dir/$scenario/events"; then
      cat "$test_dir/$scenario/events" >&2
      echo "unsafe deletion in $scenario" >&2
      exit 1
    fi
  fi
  passes=$((passes + 1))
}
for scenario in retain static no-claim-uid foreign-label foreign-app keep-policy unprovisioned foreign-driver ambiguous changed-pv snapshot-error inventory-error pvc-api-error mounted pods-api-error attached attachment-api-error rebound-handle backend-api-error backend-attached local-unsafe local-unresolved local-disabled ledger-error; do
  run_scenario "$scenario" failure
done
for scenario in wrong-namespace wrong-fleet invalid-ordinal recreated-pvc start; do
  run_scenario "$scenario" success
done
for scenario in longhorn local captured-sts drop; do
  run_scenario "$scenario" deleted
  grep -q '^delete-pv ' "$test_dir/$scenario/events" || {
    cat "$test_dir/$scenario.out" >&2; cat "$test_dir/$scenario/events" >&2
    echo "verified legacy PV was not deleted in $scenario" >&2; exit 1
  }
  grep -q '^clear-ledger$' "$test_dir/$scenario/events"
  first="$(grep -n '^persist-ledger' "$test_dir/$scenario/events" | head -1 | cut -d: -f1)"
  second="$(grep -n '^delete-' "$test_dir/$scenario/events" | head -1 | cut -d: -f1)"
  [[ "$first" -lt "$second" ]]
done
run_scenario delete-error failed-delete
# A failed PV deletion retains its ledger even after its backend is gone.
! grep -q '^clear-ledger$' "$test_dir/delete-error/events"

# Wiring: a no-StatefulSet/no-PVC uninstall must still discover orphan PVs;
# start and non-destructive cleanup do not acquire that authority.
bash -c '
  set -euo pipefail
  source "$1"
  event_log="$2"
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() { :; }
  cleanup_legacy_ton_pvs_for_statefulsets() { printf "orphan-discovery %s\n" "$2" >> "$event_log"; }
  captured=()
  delete_ton_pvcs_for_statefulsets captured uninstall
' _ "$kubeton" "$test_dir/wiring"
grep -q '^orphan-discovery uninstall$' "$test_dir/wiring"
echo "kubeton legacy PV cleanup checks: PASS ($passes scenarios)"
