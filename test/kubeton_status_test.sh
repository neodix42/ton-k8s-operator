#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == get && "${2:-}" == pods ]]; then
  [[ "${3:-}" == -A ]] || exit 91
  case "$STATUS_CASE" in
    empty) ;;
    failed-probes) printf 'test-ns\tton-unassigned\t\n' ;;
    *) printf 'test-ns\tton-0\tworker-a\ntest-ns\tton-1\tworker-b\n' ;;
  esac
  exit 0
fi

[[ "${1:-}" == -n && "${2:-}" == test-ns ]] || exit 92
shift 2
[[ "$STATUS_CASE" != failed-probes ]] || exit 1
if [[ "${1:-}" == get && "${2:-}" == pod ]]; then
  case "${3:-}" in
    ton-0) printf 'registry.example:5000/ton:v1.2.3\037registry.example/mtc:ctrl-old' ;;
    ton-1) printf 'registry.example/ton@sha256:abc123\037registry.example/mtc' ;;
    *) exit 93 ;;
  esac
  exit 0
fi

[[ "${1:-}" == exec ]] || exit 94
pod="$2"
script="${!#}"
case "$script" in
  *'status fast'*)
    if [[ "$pod" == ton-0 ]]; then
      # The first pod waits for the second pod's last probe. This proves
      # concurrent collection without depending on a wall-clock speedup.
      for ((attempt=0; attempt<100; attempt++)); do
        [[ -f "$STATUS_STATE/second-finished" ]] && break
        sleep 0.05
      done
      if [[ ! -f "$STATUS_STATE/second-finished" ]]; then
        touch "$STATUS_STATE/barrier-timeout"
        exit 95
      fi
    fi
    printf '\033[32mLocal validator wallet address: wallet-%s\033[0m\r\n' "$pod"
    printf 'Public ADNL address of node: adnl-%s\r\n' "$pod"
    ;;
  *'validator-engine -V'*)
    printf 'validator-engine [Commit: abcdef123456, Date: 2026-10-20 10:00:00 UTC]\n'
    ;;
  *'mytonctrl --cmd status'*)
    if [[ "$pod" == ton-0 ]]; then
      printf 'Local validator out of sync: 99 s\nMasterchain out of sync: 9 s\n'
    else
      printf 'Local validator initial sync status: last known block was 17 s ago\n'
    fi
    ;;
  *'/db/celldb'*) printf '1073741824' ;;
  *'/db/archive'*)
    printf '%s\n' "$pod" >>"$STATUS_STATE/completed"
    [[ "$pod" != ton-1 ]] || touch "$STATUS_STATE/second-finished"
    printf '2147483648'
    ;;
  *) exit 96 ;;
esac
MOCK_KUBECTL
chmod +x "$test_dir/bin/kubectl"

run_case() {
  local mode="$1"
  mkdir -p "$test_dir/$mode"
  if ! PATH="$test_dir/bin:$PATH" STATUS_CASE="$mode" STATUS_STATE="$test_dir/$mode" \
    bash "$kubeton" status >"$test_dir/$mode/output" 2>&1; then
    cat "$test_dir/$mode/output" >&2
    fail "$mode command failed"
  fi
}

normalize_table() {
  # Compare all ten cells, allowing the table formatter to choose padding.
  awk -F '|' '
    /^\|/ && !/^\|-/ {
      for (i=2; i<NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        printf "%s%s", $i, (i == NF-1 ? "\n" : "\t")
      }
    }
  ' "$1"
}

assert_table() {
  local mode="$1" expected_rows="$2"
  printf 'server name\tpod name\tTON image\tMyTonCtrl image\tdate\twallet\tADNL address\tsync\tcell db\tarchive db\n%s\n' \
    "$expected_rows" >"$test_dir/$mode/expected"
  normalize_table "$test_dir/$mode/output" >"$test_dir/$mode/actual"
  if ! diff -u "$test_dir/$mode/expected" "$test_dir/$mode/actual"; then
    cat "$test_dir/$mode/output" >&2
    fail "$mode table changed"
  fi
}

run_case empty
[[ "$(cat "$test_dir/empty/output")" == 'No TON pods found.' ]] \
  || fail 'empty cluster should have no status table'

run_case parallel
assert_table parallel $'worker-a\tton-0\tv1.2.3\tctrl-old\t2026-10-20 10:00:00 UTC\twallet-ton-0\tadnl-ton-0\t9 s\t1.00 GB\t2.00 GB\nworker-b\tton-1\tsha256:abc123\tlatest\t2026-10-20 10:00:00 UTC\twallet-ton-1\tadnl-ton-1\t17 s ago\t1.00 GB\t2.00 GB'
[[ ! -e "$test_dir/parallel/barrier-timeout" ]] \
  || fail 'pod status probes did not run concurrently'
[[ "$(cat "$test_dir/parallel/completed")" == $'ton-1\nton-0' ]] \
  || fail 'test must complete pods in reverse order to check stable display order'

run_case failed-probes
assert_table failed-probes $'N/A\tton-unassigned\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A'

# A collector can fail before publishing its result. Keep its pod visible with
# a complete fallback row and still display the other pods.
mkdir -p "$test_dir/failed-workers"
if ! PATH="$test_dir/bin:$PATH" STATUS_CASE=failed-workers \
  bash -c '
    source "$1"
    status_collect_row() { return 1; }
    main status
  ' _ "$kubeton" >"$test_dir/failed-workers/output" 2>&1; then
  cat "$test_dir/failed-workers/output" >&2
  fail 'failed collectors should not prevent status output'
fi
assert_table failed-workers $'worker-a\tton-0\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\nworker-b\tton-1\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A'

echo 'kubeton status checks: PASS (4 cases)'
