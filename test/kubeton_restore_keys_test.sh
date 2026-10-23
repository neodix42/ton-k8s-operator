#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { ! grep -Fq -- "$1" "$2" || fail "unexpected '$1' in $2"; }

mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -n && "${2:-}" == test-ns && "${3:-}" == get ]] || exit 91
case "$4" in
  pod) printf 'worker-%s' "${5##*-}" ;;
  pvc)
    if [[ "$RESTORE_CASE" == missing-pvc && "$5" == keybundle-test-tonnode-1 ]]; then exit 1; fi
    ;;
  *) exit 92 ;;
esac
MOCK_KUBECTL
chmod +x "$test_dir/bin/kubectl"

run_case() {
  local mode="$1" expected_rc="$2" expected_summary="$3"
  local case_dir="$test_dir/$mode" ordinal item_dir rc=0
  mkdir -p "$case_dir/backup"
  : > "$case_dir/events"
  for ordinal in 0 1; do
    if [[ "$mode" == all-missing || ( "$mode" == missing-backup && "$ordinal" == 1 ) ]]; then
      continue
    fi
    item_dir="$case_dir/backup/test-ns/test-tonnode/$ordinal"
    mkdir -p "$item_dir/bundle"
    printf 'encrypted bundle\n' > "$item_dir/bundle/keys.bundle.enc"
    printf 'wrapped_key=test\n' > "$item_dir/bundle/keys.bundle.meta"
    (cd "$item_dir" && sha256sum bundle/keys.bundle.enc bundle/keys.bundle.meta > SHA256SUMS)
    if [[ "$mode" == checksum-failure && "$ordinal" == 1 ]]; then
      printf 'corruption\n' >> "$item_dir/bundle/keys.bundle.enc"
    fi
  done

  PATH="$test_dir/bin:$PATH" RESTORE_CASE="$mode" RESTORE_EVENTS="$case_dir/events" \
    bash -c '
      source "$1"
      confirm_or_exit() { :; }
      list_ton_statefulsets() { printf "test-ns\ttest-tonnode\t2\n"; }
      pause_operator_reconcile() { printf "pause\n" >> "$RESTORE_EVENTS"; }
      resume_operator_reconcile() { printf "resume\n" >> "$RESTORE_EVENTS"; }
      set_ton_replicas() { printf "scale %s\n" "$3" >> "$RESTORE_EVENTS"; }
      wait_statefulset_pods_gone() { :; }
      restore_bundle_to_pvc() {
        printf "upload %s\n" "$2" >> "$RESTORE_EVENTS"
        if [[ "$RESTORE_CASE" == all-failed \
          || ( "$RESTORE_CASE" == upload-failure && "$2" == keybundle-test-tonnode-1 ) ]]; then
          return 1
        fi
      }
      restore_statefulset_with_expected_nodes() {
        local -n nodes="$4"
        [[ "$3" == 2 && "${nodes[*]}" == "worker-0 worker-1" ]] || return 1
        printf "restart\n" >> "$RESTORE_EVENTS"
      }
      main restore-keys "$2"
    ' _ "$kubeton" "$case_dir/backup" > "$case_dir/output" 2>&1 || rc=$?

  if [[ "$rc" != "$expected_rc" ]]; then
    cat "$case_dir/output" >&2
    fail "$mode expected exit $expected_rc, got $rc"
  fi
  assert_contains "$expected_summary" "$case_dir/output"
  # Both success and bundle failures must finish node restoration and resume
  # the operator once, without the EXIT trap restarting the fleet again.
  [[ "$(grep -cx pause "$case_dir/events")" == 1 ]] || fail "$mode did not pause once"
  [[ "$(grep -cx restart "$case_dir/events")" == 1 ]] || fail "$mode did not restart once"
  [[ "$(grep -cx resume "$case_dir/events")" == 1 ]] || fail "$mode did not resume once"
  [[ "$(tail -n 2 "$case_dir/events")" == $'restart\nresume' ]] || fail "$mode cleanup order changed"
  if (( expected_rc != 0 )); then
    assert_not_contains 'Encrypted key bundle restore complete.' "$case_dir/output"
  else
    assert_contains 'Encrypted key bundle restore complete.' "$case_dir/output"
  fi
}

run_case success 0 'restored=2, skipped_missing=0, failed=0'
run_case upload-failure 1 'restored=1, skipped_missing=0, failed=1'
run_case checksum-failure 1 'restored=1, skipped_missing=0, failed=1'
run_case missing-pvc 1 'restored=1, skipped_missing=0, failed=1'
run_case all-failed 1 'restored=0, skipped_missing=0, failed=2'
# Missing backups are intentionally skipped by the existing command contract.
run_case missing-backup 0 'restored=1, skipped_missing=1, failed=0'
run_case all-missing 0 'restored=0, skipped_missing=2, failed=0'

echo 'kubeton restore-keys checks: PASS (7 cases)'
