#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

# Reuse the ordinary legacy-PV mock API, then replace only its ledger writer
# with the production implementation and a stateful ConfigMap API. No cluster
# or host storage is contacted. The production discovery/reconciliation gates
# and the durable authorization reader/writer all execute in these scenarios.
python3 - "$repo_root/test/kubeton_legacy_pv_cleanup_test.sh" "$temporary/fixture.sh" <<'PY'
import sys
source = open(sys.argv[1]).read().split("<<'SCENARIO'\n", 1)[1].split("\nSCENARIO\n", 1)[0]
source = source.split('cleanup_legacy_ton_pvs_for_statefulsets trusted_sts_rows "$command_label"', 1)[0]
source = source.replace('source "$1"', 'source "$1"\nproduction_ledger_writer="$(declare -f record_local_path_cleanup_ledger)"', 1)
open(sys.argv[2], 'w').write(source)
PY

cat > "$temporary/scenario.sh" <<'SCENARIO'
set -euo pipefail
source "$4"
eval "$production_ledger_writer"
base_kubectl="$(declare -f kubectl)"
eval "${base_kubectl/kubectl ()/legacy_mock_kubectl ()}"
KUBETON_RETAIN_PURGE_CONFIRMED=true
mock_reclaim=Retain
claim_name=keybundle-tonnode-7
case "$scenario" in
  local|local-retry|local-path-change)
    mock_driver=""; mock_handle=""; mock_provisioner=rancher.io/local-path
    claim_name=ton-work-tonnode-7 ;;
  no-purge) KUBETON_RETAIN_PURGE_CONFIRMED=false ;;
  cross-fleet) claim_name=keybundle-foreign-7 ;;
esac
local_path_cleanup_ledger_namespace() { printf kube-system; }
local_path_cleanup_ledger_name() { printf retained-test; }
local_path_cleanup_ledger_id() { printf test-id; }
list_local_path_cleanup_ledger_locations() {
  [[ -e "$fixture_dir/configmap.json" ]] && printf 'kube-system\tretained-test\n'
  return 0
}
collect_local_path_cleanup_ledger_rows() {
  local -n output="$1"
  local line contents
  [[ -e "$fixture_dir/configmap.json" ]] || return 0
  contents="$(read_cm_data targets)"
  while IFS= read -r line; do [[ -z "$line" ]] || output+=("$line"); done <<<"$contents"
}
collect_pv_cleanup_ledger_rows() {
  local -n output="$1"
  local line contents
  [[ -e "$fixture_dir/configmap.json" ]] || return 0
  contents="$(read_cm_data pv-targets)"
  while IFS= read -r line; do [[ -z "$line" ]] || output+=("$line"); done <<<"$contents"
}
read_cm_data() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("data",{}).get(sys.argv[2],""),end="")' "$fixture_dir/configmap.json" "$1"
}
kubectl() {
  local args="$*" data_key
  case "$args" in
    '-n kube-system get configmap retained-test --ignore-not-found -o jsonpath={.metadata.name}')
      [[ ! -e "$fixture_dir/configmap.json" ]] || printf retained-test ;;
    '-n kube-system get configmap retained-test -o jsonpath={.metadata.labels.app\.kubernetes\.io/name}')
      printf kubeton-local-path-cleanup-ledger ;;
    '-n kube-system get configmap retained-test -o jsonpath={.metadata.labels.ton\.ton\.org/kubeton-storage-cleanup}')
      printf test-id ;;
    '-n kube-system get configmap retained-test -o jsonpath={.data.retained-purge-targets}')
      [[ "$scenario" != authorization-read-error ]] || return 1
      read_cm_data retained-purge-targets ;;
    '-n kube-system create configmap retained-test --from-file='*)
      python3 -c 'import json,sys; data={};
for item in sys.argv[1:]:
 if item.startswith("--from-file="):
  key,path=item[len("--from-file="):].split("=",1); data[key]=open(path).read()
print(json.dumps({"data":data}))' "$@" ;;
    'label --local -f - '*) cat ;;
    '-n kube-system create -f -'| 'apply -f -')
      [[ "$scenario" != ledger-error ]] || return 1
      cat > "$fixture_dir/configmap.json"
      printf 'persist-ledger\n' >> "$events" ;;
    '-n kube-system delete configmap retained-test --ignore-not-found --wait=true')
      printf 'clear-ledger\n' >> "$events"
      rm -f "$fixture_dir/configmap.json" ;;
    "get pv $mock_pv --ignore-not-found -o jsonpath={.metadata.uid}"*persistentVolumeReclaimPolicy*)
      if [[ -e "$fixture_dir/pv-gone" ]]; then
        printf 'verified-pv-absent\n' >> "$events"
        return 0
      fi
      legacy_mock_kubectl "$@" ;;
    *) legacy_mock_kubectl "$@" ;;
  esac
}
clear_local_path_cleanup_ledgers() {
  printf 'clear-ledger\n' >> "$events"
  rm -f "$fixture_dir/configmap.json"
}
delete_pv_and_wait_for_gone() {
  printf 'delete-pv\n' >> "$events"
  if [[ "$scenario" == interrupted && ! -e "$fixture_dir/interrupted" ]]; then
    touch "$fixture_dir/interrupted"
    return 1
  fi
  touch "$fixture_dir/pv-gone"
}

status=0
cleanup_legacy_ton_pvs_for_statefulsets trusted_sts_rows uninstall || status=$?
case "$scenario" in
  no-purge|ledger-error|mounted|attached|rebound-handle|backend-attached)
    [[ "$status" != 0 ]]
    ! grep -Eq '^delete-(backend|host-directory|pv)$' "$events"
    ;;
  cross-fleet)
    [[ "$status" == 0 ]]
    ! grep -Eq '^delete-(backend|host-directory|pv)$' "$events"
    ;;
  interrupted)
    [[ "$status" != 0 && -e "$fixture_dir/configmap.json" ]]
    read_cm_data retained-purge-targets | grep -Fq 'pvc-claim-uid|default/keybundle-tonnode-7|pv-uid|claim-uid|Retain|driver.longhorn.io|volume-handle|longhorn-uid||'
    # Updating ordinary cleanup records must preserve the separate authority.
    empty_local=(); empty_pv=()
    record_local_path_cleanup_ledger empty_local empty_pv
    KUBETON_RETAIN_PURGE_CONFIRMED=false
    if cleanup_recorded_local_path_data uninstall; then exit 11; fi
    KUBETON_RETAIN_PURGE_CONFIRMED=true
    touch "$fixture_dir/pv-gone"
    cleanup_recorded_local_path_data uninstall
    [[ ! -e "$fixture_dir/configmap.json" ]]
    ;;
  no-authorization|auth-without-purge|malformed-authorization|changed-authorization)
    [[ "$status" == 0 ]]
    # A Retain row on its own must never inherit authority from the purge flag.
    printf -v pv_row 'pvc-claim-uid\tdefault/keybundle-tonnode-7\tpv-uid\tclaim-uid\tRetain\tdriver.longhorn.io\tvolume-handle\tlonghorn-uid'
    local_rows=(); pv_rows=("$pv_row")
    auth_rows=('pvc-claim-uid|default/keybundle-tonnode-7|pv-uid|claim-uid|Retain|driver.longhorn.io|volume-handle|longhorn-uid||')
    record_local_path_cleanup_ledger local_rows pv_rows auth_rows
    case "$scenario" in
      no-authorization)
        python3 - "$fixture_dir/configmap.json" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); data['data'].pop('retained-purge-targets'); json.dump(data,open(p,'w'))
PY
        ;;
      auth-without-purge) KUBETON_RETAIN_PURGE_CONFIRMED=false ;;
      malformed-authorization|changed-authorization)
        python3 - "$fixture_dir/configmap.json" "$scenario" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); text=data['data']['retained-purge-targets'].rstrip('\n')
data['data']['retained-purge-targets']=(text+'|' if sys.argv[2]=='malformed-authorization' else text.replace('|pv-uid|','|different-pv-uid|'))+'\n'
json.dump(data,open(p,'w'))
PY
        ;;
    esac
    before="$(wc -l < "$events")"
    if cleanup_recorded_local_path_data uninstall; then exit 13; fi
    [[ -e "$fixture_dir/configmap.json" ]]
    ! tail -n "+$((before + 1))" "$events" | grep -Eq '^delete-(backend|host-directory|pv)$'
    ;;
  local-retry|local-path-change)
    # A retained authorization may survive with only its ledger and host path.
    # Discovery above completed, so recreate its durable interrupted state.
    printf -v local_row 'worker\t/data/pvc-claim-uid_default_ton-work-tonnode-7\tpvc-claim-uid\tdefault/ton-work-tonnode-7\tpv-uid\tclaim-uid'
    printf -v pv_row 'pvc-claim-uid\tdefault/ton-work-tonnode-7\tpv-uid\tclaim-uid\tRetain\t\t\t'
    local_rows=("$local_row"); pv_rows=("$pv_row")
    auth_rows=('pvc-claim-uid|default/ton-work-tonnode-7|pv-uid|claim-uid|Retain||||worker|/data/pvc-claim-uid_default_ton-work-tonnode-7')
    record_local_path_cleanup_ledger local_rows pv_rows auth_rows
    if [[ "$scenario" == local-path-change ]]; then
      python3 - "$fixture_dir/configmap.json" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); data['data']['targets']=data['data']['targets'].replace('/data/','/foreign/'); json.dump(data,open(p,'w'))
PY
      if cleanup_recorded_local_path_data uninstall; then exit 12; fi
      [[ -e "$fixture_dir/configmap.json" ]]
    else
      cleanup_recorded_local_path_data uninstall
      [[ ! -e "$fixture_dir/configmap.json" ]]
      grep -Fq 'verified-pv-absent' "$events"
    fi
    ;;
  *)
    [[ "$status" == 0 ]]
    grep -Fq 'persist-ledger' "$events"
    grep -Fq 'delete-pv' "$events"
    [[ ! -e "$fixture_dir/configmap.json" ]]
    ;;
esac
! grep -Fq 'patch pv' "$events"
SCENARIO

passes=0
for mode in longhorn local interrupted local-retry local-path-change no-purge no-authorization auth-without-purge malformed-authorization changed-authorization cross-fleet mounted attached rebound-handle backend-attached ledger-error; do
  mkdir "$temporary/$mode"
  if ! bash "$temporary/scenario.sh" "$repo_root/charts/ton-k8s-operator/kubeton" "$mode" "$temporary/$mode" "$temporary/fixture.sh" >"$temporary/$mode.log" 2>&1; then
    echo "retained purge scenario failed: $mode" >&2
    cat "$temporary/$mode.log" >&2
    exit 1
  fi
  passes=$((passes + 1))
done

# Confirmation is the only production entry that enables the dynamic flag;
# both a successful return and a failed teardown restore the previous scope.
for mode in success failure; do
  bash -euo pipefail -c '
    KUBETON_RETAIN_PURGE_CONFIRMED=true
    source "$1"
    [[ "$KUBETON_RETAIN_PURGE_CONFIRMED" == false ]]
    require_bin() { :; }
    confirm_or_exit() { [[ "$*" == *"retained TON recovery volumes"* ]]; }
    mode="$2"
    run_uninstall_core() { [[ "$KUBETON_RETAIN_PURGE_CONFIRMED" == true ]]; [[ "$mode" != failure ]]; }
    verify_uninstall_leftovers() { :; }
    kubectl() { :; }
    result=0
    run_purge || result=$?
    [[ "$KUBETON_RETAIN_PURGE_CONFIRMED" == false ]]
    if [[ "$mode" == success ]]; then [[ "$result" == 0 ]]; else [[ "$result" != 0 ]]; fi
  ' _ "$repo_root/charts/ton-k8s-operator/kubeton" "$mode" >"$temporary/scope-$mode.log" 2>&1
  passes=$((passes + 1))
done

echo "kubeton retained recovery purge checks: PASS ($passes scenarios)"
