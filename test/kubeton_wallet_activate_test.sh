#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

# Exercise the real command dispatcher and pod shell with a synthetic console.
# Fixtures contain public addresses and response text; no keys, HTTP requests,
# or real Kubernetes clients participate in these tests.
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/mytonctrl" <<'MOCK_MYTONCTRL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --cmd ]]; then
  command_text="${2:-}"
else
  IFS= read -r command_text
fi
printf 'console %s %s\n' "$FIXTURE_POD" "$command_text" >>"$FIXTURE_CASE/events"
if [[ "$command_text" != 'aw validator_wallet_001' ]]; then
  echo 'Fixture unrelated console error' >&2
  exit 9
fi
touch "$FIXTURE_CASE/$FIXTURE_POD.submitted"
case "$FIXTURE_MODE:$FIXTURE_POD" in
  genuine-failure:*|mixed-failure:tonnode-1)
    echo 'Error: wallet address and key do not match' >&2
    exit 7
    ;;
  console-only:*|unknown-state:*)
    echo 'ActivateWallet - OK'
    ;;
  *)
    touch "$FIXTURE_CASE/$FIXTURE_POD.active"
    echo '[error] liteclient args: sendfile activation-query.boc'
    echo '[info] Failed to send boc to toncenter: external message rejected; exitcode=33'
    echo '[debug] got seqno 1 for fixture account'
    echo 'ActivateWallet - OK'
    if [[ "$FIXTURE_MODE" == recovered-cli-failure ]]; then
      exit 7
    fi
    ;;
esac
MOCK_MYTONCTRL
chmod +x "$test_dir/bin/mytonctrl"

run_case() (
  source "$kubeton"
  local mode="$1" case_dir="$test_dir/$1" fixture_raw fixture_address
  mkdir -p "$case_dir"
  : >"$case_dir/events"
  export FIXTURE_CASE="$case_dir" FIXTURE_MODE="$mode"
  export PATH="$test_dir/bin:$PATH"
  fixture_raw="-1:$(printf '%064d' 1)"
  fixture_address="$(ton_address_to_non_bounceable "$fixture_raw")"
  MYTONCTRL_EXEC_TIMEOUT=2s
  WALLET_ACTIVATION_CONFIRM_TIMEOUT_SECONDS=2
  WALLET_ACTIVATION_CONFIRM_ATTEMPTS=2
  WALLET_ACTIVATION_CONFIRM_DELAY_SECONDS=0
  require_bin() { :; }
  run_with_timeout() { shift; "$@"; }
  confirm_or_exit() { printf 'confirm %s\n' "$1" >>"$case_dir/events"; }
  list_ton_pods() { printf 'unit-ns\ttonnode-0\tworker-0\nunit-ns\ttonnode-1\tworker-1\n'; }
  resolve_tonnode_pod_row_by_name() {
    [[ "$1" == tonnode-0 || "$1" == tonnode-1 ]] || return 1
    printf 'unit-ns\t%s\tworker-%s\n' "$1" "${1##*-}"
  }
  read_tonnode_wallet_address_file_from_pod() { printf '%s' "$fixture_raw"; }
  read_tonnode_wallet_state_from_pod() {
    [[ "$1" == unit-ns && "$3" == validator_wallet_001 ]] || return 91
    local pod="$2" status=uninit name=validator_wallet_001 address="$fixture_address"
    printf 'state %s\n' "$pod" >>"$case_dir/events"
    if [[ "$mode" == already-active || "$mode" == mixed-active && "$pod" == tonnode-0 || -f "$case_dir/$pod.active" ]]; then
      status=active
    elif [[ "$mode" == unknown-state && -f "$case_dir/$pod.submitted" ]]; then
      echo 'Fixture chain query unavailable' >&2
      return 1
    fi
    if [[ -f "$case_dir/$pod.submitted" ]]; then
      if [[ "$mode" == delayed-active && ! -f "$case_dir/$pod.polled" ]]; then
        touch "$case_dir/$pod.polled"
        status=uninit
      elif [[ "$mode" == wrong-name ]]; then
        name=other_wallet
      elif [[ "$mode" == wrong-address ]]; then
        address="$(ton_address_to_non_bounceable "-1:$(printf '%064d' 2)")"
      fi
    fi
    printf '%s\t%s\t0.800000000\tv1\t-1\t%s\n' "$name" "$status" "$address"
  }
  resolve_tonnode_wallet_row_from_pod() { read_tonnode_wallet_state_from_pod "$@" "$fixture_raw"; }
  kubectl() {
    [[ "${1:-}" == -n && "${2:-}" == unit-ns && "${3:-}" == exec &&
       ( "${4:-}" == tonnode-0 || "${4:-}" == tonnode-1 ) &&
       "${5:-}" == -c && "${6:-}" == ton-node && "${7:-}" == -- ]] || {
      echo "Unexpected Kubernetes operation: $*" >&2
      return 93
    }
    local fixture_pod="$4"
    shift 7
    FIXTURE_POD="$fixture_pod" "$@"
  }
  if [[ "$mode" == generic-command ]]; then
    run_exec_mtc 'dangerous-command fixture'
  else
    run_wallet_activate
  fi
)

check_case() {
  local mode="$1" expected="$2" rc=0
  run_case "$mode" >"$test_dir/$mode.out" 2>&1 || rc=$?
  if [[ "$expected" == success ]]; then
    [[ "$rc" == 0 ]] || { cat "$test_dir/$mode.out" >&2; fail "$mode unexpectedly failed"; }
  else
    [[ "$rc" != 0 ]] || { cat "$test_dir/$mode.out" >&2; fail "$mode incorrectly reported success"; }
  fi
}

check_case recovered success
assert_not_contains 'exitcode=33' "$test_dir/recovered.out"
assert_not_contains '[error] liteclient args' "$test_dir/recovered.out"
assert_contains '2/2' "$test_dir/recovered.out"
assert_contains 'confirmed on chain' "$test_dir/recovered.out"
[[ "$(grep -c '^console ' "$test_dir/recovered/events")" == 2 ]] || fail 'activation was submitted more than once per wallet'

check_case recovered-cli-failure success
assert_not_contains 'exitcode=33' "$test_dir/recovered-cli-failure.out"
assert_contains 'confirmed on chain' "$test_dir/recovered-cli-failure.out"

check_case delayed-active success
[[ "$(grep -c '^console ' "$test_dir/delayed-active/events")" == 2 ]] || fail 'delayed confirmation caused another submission'

check_case genuine-failure failure
assert_contains 'wallet address and key do not match' "$test_dir/genuine-failure.out"
assert_not_contains 'Activated 2/2' "$test_dir/genuine-failure.out"

check_case mixed-failure failure
assert_contains '1/2' "$test_dir/mixed-failure.out"
assert_contains 'wallet address and key do not match' "$test_dir/mixed-failure.out"

check_case already-active success
assert_contains 'already active' "$test_dir/already-active.out"
assert_not_contains 'console ' "$test_dir/already-active/events"
assert_not_contains 'confirm ' "$test_dir/already-active/events"

check_case mixed-active success
[[ "$(grep -c '^console ' "$test_dir/mixed-active/events")" == 1 ]] || fail 'already active wallet was submitted again'
assert_not_contains 'console tonnode-0 ' "$test_dir/mixed-active/events"

check_case unknown-state failure
assert_not_contains 'Activated 2/2' "$test_dir/unknown-state.out"
assert_contains 'Fixture chain query unavailable' "$test_dir/unknown-state.out"
check_case console-only failure
assert_not_contains 'Activated 2/2' "$test_dir/console-only.out"
check_case wrong-name failure
assert_not_contains 'Activated 2/2' "$test_dir/wrong-name.out"
check_case wrong-address failure
assert_not_contains 'Activated 2/2' "$test_dir/wrong-address.out"

# The change is specific to verified activation success. Generic console
# commands keep their failure exit codes in the existing per-node table.
check_case generic-command success
assert_contains 'tonnode-0' "$test_dir/generic-command.out"
assert_contains 'tonnode-1' "$test_dir/generic-command.out"
if [[ "$(grep -Ec 'tonnode-[01].*[[:space:]|]9([[:space:]|]|$)' "$test_dir/generic-command.out")" != 2 ]]; then
  fail 'generic mytonctrl failure was hidden or changed to success'
fi

echo 'kubeton wallet activation tests passed (12 scenarios).'
