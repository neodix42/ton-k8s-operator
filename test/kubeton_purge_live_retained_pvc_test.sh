#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

# Exercise the two production deletion stages together. A Retain PVC still
# present at purge start must become an orphan before exact purge authority
# can be discovered, and reconciliation must follow that discovery. No real
# Kubernetes API or backing storage is used.
cat > "$temporary/scenario.sh" <<'SCENARIO'
set -euo pipefail
source "$1"
mode="$2"
fixture="$3"
mkdir -p "$fixture"
touch "$fixture/pvc-present"
events="$fixture/events"
: > "$events"
KUBETON_RETAIN_PURGE_CONFIRMED=true
[[ "$mode" != uninstall ]] || KUBETON_RETAIN_PURGE_CONFIRMED=false
collect_expected_ton_pvc_rows_from_values() { :; }
collect_labeled_ton_pvc_rows() { :; }
collect_existing_kubeton_pvc_rows() {
  local -n existing="$2"
  existing+=($'default\tkeybundle-tonnode-0')
}
list_ton_pods() { :; }
append_pv_cleanup_ledger_row_for_pv() {
  [[ "$mode" != inventory-failure ]] || return 1
  local -n rows="$3"
  rows+=($'pvc-claim-uid\tdefault/keybundle-tonnode-0\tpv-uid\tclaim-uid\tRetain\tdriver.longhorn.io\tvolume-handle\tbackend-uid')
}
append_local_path_exact_cleanup_rows_for_pv() { :; }
record_local_path_cleanup_ledger() {
  [[ "$mode" != ledger-failure ]] || return 1
  printf 'persist-ledger\n' >> "$events"
}
collect_local_path_pattern_cleanup_rows_for_pvcs() { :; }
kubectl() {
  case "$*" in
    '-n default get pvc keybundle-tonnode-0 --ignore-not-found -o jsonpath={.spec.volumeName}') printf pvc-claim-uid ;;
    '-n default delete pvc keybundle-tonnode-0 --ignore-not-found --wait=false')
      printf 'delete-pvc\n' >> "$events"
      [[ "$mode" != deletion-failure ]] || return 1
      rm -f "$fixture/pvc-present" ;;
    *) echo "Unexpected API call: $*" >&2; return 1 ;;
  esac
}
wait_pvc_gone() { [[ ! -e "$fixture/pvc-present" ]]; }
delete_pvc_and_wait_for_gone() { return 1; }
cleanup_legacy_ton_pvs_for_statefulsets() {
  # Model the real discovery precondition: no same-name live claim. An
  # ordinary uninstall never grants retained-volume deletion authority.
  [[ "$KUBETON_RETAIN_PURGE_CONFIRMED" == true ]] || return 0
  [[ ! -e "$fixture/pvc-present" ]] || return 1
  touch "$fixture/authorized"
  printf 'authorize-retained-orphan\n' >> "$events"
}
cleanup_recorded_local_path_data() {
  printf 'reconcile-storage\n' >> "$events"
  [[ ! -e "$fixture/pvc-present" && -e "$fixture/authorized" ]]
}
cleanup_local_path_provisioner_data() { printf 'cleanup-patterns\n' >> "$events"; }
captured=()
status=0
delete_ton_pvcs_for_statefulsets captured uninstall || status=$?
case "$mode" in
  purge)
    [[ "$status" == 0 ]]
    [[ ! -e "$fixture/pvc-present" ]]
    python3 - "$events" <<'PY'
import sys
events = open(sys.argv[1]).read().splitlines()
assert events.index('persist-ledger') < events.index('delete-pvc')
assert events.index('delete-pvc') < events.index('authorize-retained-orphan')
assert events.index('authorize-retained-orphan') < events.index('reconcile-storage')
assert events.index('reconcile-storage') < events.index('cleanup-patterns')
PY
    ;;
  uninstall)
    [[ "$status" != 0 && ! -e "$fixture/authorized" ]]
    ! grep -q '^cleanup-patterns$' "$events" ;;
  *)
    [[ "$status" != 0 && -e "$fixture/pvc-present" && ! -e "$fixture/authorized" ]]
    ! grep -q '^cleanup-patterns$' "$events" ;;
esac
SCENARIO

for mode in purge uninstall deletion-failure ledger-failure inventory-failure; do
  if ! bash "$temporary/scenario.sh" "$repo_root/charts/ton-k8s-operator/kubeton" "$mode" "$temporary/$mode" > "$temporary/$mode.log" 2>&1; then
    echo "live retained PVC purge scenario failed: $mode" >&2
    cat "$temporary/$mode.log" >&2
    exit 1
  fi
done
echo 'kubeton live retained PVC purge checks: PASS (5 scenarios)'
