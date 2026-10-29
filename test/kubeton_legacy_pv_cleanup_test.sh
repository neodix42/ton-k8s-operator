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
  no-pv-uid) mock_pv_uid="" ;;
  empty-reclaim) mock_reclaim="" ;;
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
      if [[ "$scenario" == malformed-missing-field ]]; then
        local malformed_row
        malformed_row="$(snapshot_row)"
        printf '%s' "${malformed_row%|}"
      else
        snapshot_row
      fi
      case "$scenario" in
        ambiguous) printf '\n'; snapshot_row ;;
        malformed-extra) printf '|unexpected' ;;
        malformed-empty-extra) printf '|' ;;
      esac
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
for scenario in retain empty-reclaim static no-claim-uid no-pv-uid foreign-label foreign-app keep-policy unprovisioned foreign-driver ambiguous malformed-extra malformed-empty-extra malformed-missing-field changed-pv snapshot-error inventory-error pvc-api-error mounted pods-api-error attached attachment-api-error rebound-handle backend-api-error backend-attached local-unsafe local-unresolved local-disabled ledger-error; do
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

grep -q 'spec.persistentVolumeReclaimPolicy.*Retain' "$test_dir/retain.out"
grep -q 'metadata.name.*static-volume.*claim UID' "$test_dir/static.out"
grep -q 'spec.claimRef.uid is empty' "$test_dir/no-claim-uid.out"
grep -q 'metadata.uid is empty' "$test_dir/no-pv-uid.out"
grep -q "spec.persistentVolumeReclaimPolicy.*<empty>" "$test_dir/empty-reclaim.out"
grep -q 'expected 12 fields, received 11' "$test_dir/malformed-missing-field.out"
grep -q 'metadata.labels\[app.kubernetes.io/managed-by\].*external' "$test_dir/foreign-label.out"
grep -q 'metadata.labels\[app.kubernetes.io/name\].*another-app' "$test_dir/foreign-app.out"
grep -q 'metadata.annotations\[helm.sh/resource-policy\].*keep' "$test_dir/keep-policy.out"
grep -q 'expected 12 fields, received 13' "$test_dir/malformed-extra.out"
grep -q 'expected 12 fields, received 13' "$test_dir/malformed-empty-extra.out"

# Several historical PVC objects may legitimately share namespace/name while
# their immutable PVC/PV UIDs and volume handles remain distinct. Exercise
# the actual legacy discovery against realistic rows without a current PVC.
cat > "$test_dir/lifetimes.sh" <<'LIFETIMES'
set -euo pipefail
source "$1"
scenario="$2"
fixture_dir="$3"
mkdir -p "$fixture_dir"
events="$fixture_dir/events"
: > "$events"
old_claim_uid=20e0103d-594d-4223-9ba0-1e2ae09d48f0
new_claim_uid=384d90a3-f8fa-433b-8f44-42e2da5b4ca0
old_pv="pvc-$old_claim_uid"
new_pv="pvc-$new_claim_uid"
old_pv_uid=56b63294-977c-43dc-bac5-d2357fc1f1a1
new_pv_uid=55b5e3aa-a0b4-44a4-9416-9704f9b754de
old_handle="$old_pv"
new_handle="$new_pv"
claim_name=keybundle-tonnode-0
case "$scenario" in
  claim-uid-conflict) new_claim_uid="$old_claim_uid" ;;
  pv-name-conflict) new_pv="$old_pv" ;;
  pv-uid-conflict) new_pv_uid="$old_pv_uid" ;;
  handle-conflict) new_handle="$old_handle" ;;
  local-lifetimes|local-path-conflict) claim_name=ton-work-tonnode-0 ;;
esac
old_path="/opt/local-path-provisioner/${old_pv}_default_${claim_name}"
new_path="/opt/local-path-provisioner/${new_pv}_default_${claim_name}"
[[ "$scenario" != local-path-conflict ]] || new_path="$old_path"
if [[ "$scenario" == local-* ]]; then
  mock_driver=""; mock_provisioner=rancher.io/local-path; old_handle=""; new_handle=""
else
  mock_driver=driver.longhorn.io; mock_provisioner=driver.longhorn.io
fi
snapshot_row() {
  if [[ "$1" == old ]]; then
    printf '%s|%s|default|%s|%s|Delete|%s|%s|%s|||' "$old_pv" "$old_pv_uid" "$claim_name" "$old_claim_uid" "$mock_driver" "$old_handle" "$mock_provisioner"
  else
    printf '%s|%s|default|%s|%s|Delete|%s|%s|%s|||' "$new_pv" "$new_pv_uid" "$claim_name" "$new_claim_uid" "$mock_driver" "$new_handle" "$mock_provisioner"
  fi
}
resolve_tonnode_namespace_from_values() { printf default; }
resolve_tonnode_name_from_values() { printf tonnode; }
kubectl() {
  local args="$*" pv_uid claim_uid handle
  printf 'api %s\n' "$args" >> "$events"
  case "$args" in
    'get pv -o jsonpath={range .items[*]}'*'"|"'*)
      snapshot_row old; printf '\n'; snapshot_row new ;;
    "get pv $old_pv --ignore-not-found -o jsonpath={.metadata.name}"*) snapshot_row old ;;
    "get pv $new_pv --ignore-not-found -o jsonpath={.metadata.name}"*) snapshot_row new ;;
    '-n default get pvc '*'--ignore-not-found -o jsonpath={.metadata.uid}') : ;;
    'get namespace '*'-o jsonpath={.metadata.name}') printf default ;;
    'get namespace '*'-o jsonpath={.metadata.uid}') printf namespace-uid ;;
    'get namespace '*'-o jsonpath={.status.phase}') printf Active ;;
    '-n default get pods -o jsonpath='*) : ;;
    'get volumeattachments.storage.k8s.io '*) : ;;
    'get pv -o jsonpath={range .items[*]}'*'spec.csi.driver'*)
      printf '%s\t%s\t%s\t%s\n' "$old_pv" "$old_pv_uid" "$mock_driver" "$old_handle"
      printf '%s\t%s\t%s\t%s\n' "$new_pv" "$new_pv_uid" "$mock_driver" "$new_handle" ;;
    'get pv -o jsonpath={range .items[*]}'*) printf '%s\n%s\n' "$old_pv" "$new_pv" ;;
    'get pv '*'--ignore-not-found -o jsonpath={.metadata.uid}'*)
      if [[ "$2" == pv && "$3" == "$old_pv" ]]; then
        pv_uid="$old_pv_uid"; claim_uid="$old_claim_uid"; handle="$old_handle"
      else
        pv_uid="$new_pv_uid"; claim_uid="$new_claim_uid"; handle="$new_handle"
      fi
      if [[ "$args" == *spec.claimRef.namespace* ]]; then
        printf '%s\tdefault\t%s\t%s\tDelete\t%s\t%s' "$pv_uid" "$claim_name" "$claim_uid" "$mock_driver" "$handle"
      elif [[ "$args" == *persistentVolumeReclaimPolicy* ]]; then
        printf '%s\tDelete' "$pv_uid"
      else
        printf '%s' "$pv_uid"
      fi ;;
    'get pv '*'-o jsonpath={.spec.claimRef.namespace}'*)
      if [[ "$3" == "$old_pv" ]]; then claim_uid="$old_claim_uid"; else claim_uid="$new_claim_uid"; fi
      printf 'default\t%s\t%s' "$claim_name" "$claim_uid" ;;
    '-n longhorn-system get volumes.longhorn.io '*'--ignore-not-found -o jsonpath={.metadata.uid}'*'"|"'*)
      if [[ "$4" == "$old_handle" ]]; then printf 'old-backend-uid|detached||'; else printf 'new-backend-uid|detached||'; fi ;;
    *) printf 'UNHANDLED MOCK: %s\n' "$args" >&2; return 1 ;;
  esac
}
local_path_pv_is_provisioned_by_local_path() { [[ "$mock_provisioner" == rancher.io/local-path ]]; }
local_path_pv_host_path() { if [[ "$1" == "$old_pv" ]]; then printf '%s' "$old_path"; else printf '%s' "$new_path"; fi; }
collect_local_path_nodes_for_pv() { local -n output="$2"; output+=(devnet-03); }
record_local_path_cleanup_ledger() {
  local -n local_records="$1" pv_records="$2"
  printf 'persist-ledger exact=%s pv=%s\n' "${#local_records[@]}" "${#pv_records[@]}" >> "$events"
  printf '%s\n' "${pv_records[@]}" > "$fixture_dir/pv-ledger"
  printf '%s\n' "${local_records[@]}" > "$fixture_dir/local-ledger"
}
# The single-volume scenarios above exercise backend deletion reconciliation.
# Here validate every independent adoption reaches that phase durably intact.
cleanup_recorded_local_path_data() { printf 'reconcile-ledger\n' >> "$events"; }
trusted_sts_rows=()
KUBETON_LOCAL_PATH_CLEANUP=true
cleanup_legacy_ton_pvs_for_statefulsets trusted_sts_rows uninstall
LIFETIMES
for scenario in distinct-lifetimes local-lifetimes claim-uid-conflict pv-name-conflict pv-uid-conflict handle-conflict local-path-conflict; do
  result=0
  bash "$test_dir/lifetimes.sh" "$kubeton" "$scenario" "$test_dir/$scenario" > "$test_dir/$scenario.out" 2>&1 || result=$?
  case "$scenario" in
    distinct-lifetimes|local-lifetimes)
      [[ "$result" == 0 ]] && grep -q 'persist-ledger.*pv=2' "$test_dir/$scenario/events" && grep -q '^reconcile-ledger$' "$test_dir/$scenario/events" || {
        cat "$test_dir/$scenario.out" >&2; cat "$test_dir/$scenario/events" >&2; echo "could not adopt distinct lifetimes in $scenario" >&2; exit 1;
      }
      [[ "$(wc -l < "$test_dir/$scenario/pv-ledger")" == 2 ]]
      ;;
    *)
      [[ "$result" != 0 ]] && ! grep -q '^persist-ledger' "$test_dir/$scenario/events" || {
        cat "$test_dir/$scenario.out" >&2; cat "$test_dir/$scenario/events" >&2; echo "conflicting identity accepted in $scenario" >&2; exit 1;
      }
      ;;
  esac
  passes=$((passes + 1))
done
grep -q 'spec.claimRef.uid.*shared by different PV identities' "$test_dir/claim-uid-conflict.out"
grep -q 'metadata.uid conflicts between inventory entries' "$test_dir/pv-name-conflict.out"
grep -q 'metadata.uid.*shared by different PV names' "$test_dir/pv-uid-conflict.out"

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
