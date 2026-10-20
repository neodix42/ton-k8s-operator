#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() {
  if ! grep -Fq -- "$1" "$2"; then
    cat "$2" >&2
    fail "expected '$1' in $2"
  fi
}
assert_not_contains() {
  if grep -Fq -- "$1" "$2"; then
    cat "$2" >&2
    fail "unexpected '$1' in $2"
  fi
}
assert_order() {
  local first second
  first="$(grep -n -F -- "$1" "$3" | head -n1 | cut -d: -f1 || true)"
  second="$(grep -n -F -- "$2" "$3" | head -n1 | cut -d: -f1 || true)"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] \
    || fail "expected '$1' before '$2' in $3"
}

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
events="$FAKE_STATE/events"
printf 'kubectl' >>"$events"
printf ' %q' "$@" >>"$events"
printf '\n' >>"$events"
[[ "${1:-}" == -n && "${2:-}" == test-ns ]] || exit 91
shift 2
operation="$1"
shift
current_ctrl="$FAKE_CURRENT_CTRL"
current_ton="$FAKE_CURRENT_TON"
if [[ "$FAKE_MODE" == noop || "$FAKE_MODE" == resume-* || -e "$FAKE_STATE/patched" ]]; then
  current_ctrl="$FAKE_DESIRED_CTRL"
  current_ton="$FAKE_DESIRED_TON"
fi
case "$operation ${1:-}" in
  'get tonnodes.ton.ton.org')
    [[ "${2:-}" == test-tonnode ]] || exit 92
    [[ "$FAKE_MODE" != cr-api-failure ]] || exit 1
    [[ "$FAKE_MODE" != missing-cr ]] || exit 0
    count="$(cat "$FAKE_STATE/cr-count")"
    count=$((count + 1))
    printf '%s' "$count" >"$FAKE_STATE/cr-count"
    resource_version=7
    if [[ "$FAKE_MODE" == status-write && "$count" -gt 1 ]]; then resource_version=8; fi
    if [[ "$FAKE_MODE" == concurrent-edit && "$count" -gt 1 ]]; then current_ctrl=concurrent-image:v3; fi
    if [[ "$FAKE_MODE" == final-cr-drift && -e "$FAKE_STATE/rolled-out" ]]; then current_ton=concurrent-ton:v3; fi
    printf '%s\037%s\037%s\037%s\n' "$current_ctrl" "$current_ton" "$FAKE_REPLICAS" "$resource_version"
    ;;
  'get statefulset')
    [[ "${2:-}" == test-tonnode ]] || exit 93
    [[ "$FAKE_MODE" != sts-api-failure ]] || exit 1
    count="$(cat "$FAKE_STATE/sts-count")"
    count=$((count + 1))
    printf '%s' "$count" >"$FAKE_STATE/sts-count"
    image="$FAKE_CURRENT_CTRL" ton_image="$FAKE_CURRENT_TON" generation=1 observed=1
    if [[ "$FAKE_MODE" == noop || "$FAKE_MODE" == resume-pods || "$FAKE_MODE" == resume-exporter \
      || -e "$FAKE_STATE/patched" || ( "$FAKE_MODE" == resume-template && "$count" -gt 1 ) ]]; then
      image="$FAKE_DESIRED_CTRL" ton_image="$FAKE_DESIRED_TON" generation=2 observed=2
    fi
    if [[ "$FAKE_MODE" == template-timeout ]]; then
      image="$FAKE_CURRENT_CTRL" ton_image="$FAKE_CURRENT_TON"
    fi
    if [[ "$FAKE_MODE" == observed-generation && "$count" -eq 2 ]]; then
      observed=1
      printf 'template-unobserved\n' >>"$events"
    fi
    if [[ "$image" == "$FAKE_DESIRED_CTRL" && "$ton_image" == "$FAKE_DESIRED_TON" \
      && "$generation" == "$observed" ]]; then
      printf 'template-ready\n' >>"$events"
    fi
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
      "$image" "$ton_image" "$image" "$generation" "$observed" "$FAKE_REPLICAS"
    ;;
  'get pods')
    [[ "$*" == *app.kubernetes.io/instance=test-tonnode* ]] || exit 94
    [[ "$FAKE_MODE" != pods-api-failure ]] || exit 1
    image="$FAKE_CURRENT_CTRL" ton_image="$FAKE_CURRENT_TON" exporter="$FAKE_CURRENT_CTRL"
    if [[ "$FAKE_MODE" == noop || -e "$FAKE_STATE/rolled-out" ]]; then
      image="$FAKE_DESIRED_CTRL" ton_image="$FAKE_DESIRED_TON" exporter="$FAKE_DESIRED_CTRL"
    fi
    if [[ "$FAKE_MODE" == resume-exporter && ! -e "$FAKE_STATE/rolled-out" ]]; then
      image="$FAKE_DESIRED_CTRL" ton_image="$FAKE_DESIRED_TON"
    fi
    if [[ "$FAKE_MODE" == stale-pods && -e "$FAKE_STATE/rolled-out" ]]; then
      ton_image="$FAKE_CURRENT_TON"
    fi
    count="$FAKE_REPLICAS"
    if [[ "$FAKE_MODE" == missing-pod && -e "$FAKE_STATE/rolled-out" ]]; then count=0; fi
    for ((i=0; i<count; i++)); do
      backup=true
      if [[ "$FAKE_MODE" == backup-filter && "$i" == 2 ]]; then backup=""; fi
      printf 'test-tonnode-%s\037test-tonnode\037%s\037%s\037%s\037\037%s\n' \
        "$i" "$image" "$ton_image" "$exporter" "$backup"
    done
    # Labels can be stale or shared: only the exact controlling StatefulSet counts.
    printf 'other-fleet-0\037test-tonnode-other\037old\037old\037old\037\037true\n'
    if [[ "$FAKE_MODE" == backup-filter && ! -e "$FAKE_STATE/rolled-out" ]]; then
      printf 'test-tonnode-terminating\037test-tonnode\037old\037old\037old\037terminating\037true\n'
    fi
    ;;
  'patch tonnodes.ton.ton.org')
    [[ "${2:-}" == test-tonnode && "$*" == *--field-manager=helm* && "$*" == *--type=merge* ]] || exit 95
    printf 'patch\n' >>"$events"
    while (( $# )); do
      if [[ "$1" == -p || "$1" == --patch ]]; then
        printf '%s' "$2" >"$FAKE_STATE/patch.json"
        break
      fi
      shift
    done
    [[ "$FAKE_MODE" != patch-failure ]] || exit 1
    : >"$FAKE_STATE/patched"
    ;;
  'rollout status')
    [[ "${2:-}" == statefulset/test-tonnode && "${3:-}" == --timeout=*s ]] || exit 96
    printf 'rollout\n' >>"$events"
    [[ "$FAKE_MODE" != rollout-failure ]] || exit 1
    : >"$FAKE_STATE/rolled-out"
    ;;
  exec\ *)
    pod="$1"
    [[ "$pod" == test-tonnode-* && "$*" == *'-c key-backup --'* ]] || exit 97
    case "$*" in
      *initialized.json*)
        printf 'probe %s\n' "$pod" >>"$events"
        [[ "$FAKE_MODE" != probe-failure ]] || exit 1
        if [[ "$FAKE_MODE" == backup-filter && "$pod" == test-tonnode-1 ]]; then
          printf initializing
        else
          printf initialized
        fi
        ;;
      *key-backup.request*)
        printf 'backup %s\n' "$pod" >>"$events"
        [[ "$FAKE_MODE" != backup-failure ]] || exit 1
        ;;
      *key-backup.done*) printf done ;;
      *'/var/ton-key-bundle/'*)
        printf 'bundle %s\n' "$pod" >>"$events"
        [[ "$FAKE_MODE" != bundle-failure ]] || exit 1
        ;;
      *) exit 98 ;;
    esac
    ;;
  *) exit 99 ;;
esac
FAKE_KUBECTL
chmod +x "$test_dir/bin/kubectl"

new_case() {
  local case_name="$1"
  export FAKE_STATE="$test_dir/$case_name"
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_STATE/events"
  printf 0 >"$FAKE_STATE/sts-count"
  printf 0 >"$FAKE_STATE/cr-count"
  printf 100 >"$FAKE_STATE/clock"
  export FAKE_MODE="$case_name"
  export FAKE_DESIRED_CTRL=ghcr.io/neodix42/mytonctrl:v2
  export FAKE_DESIRED_TON=ghcr.io/ton-blockchain/ton:v2026.09-amd64
  export FAKE_CURRENT_CTRL=ghcr.io/neodix42/mytonctrl:v1
  export FAKE_CURRENT_TON=ghcr.io/ton-blockchain/ton:v2026.08-amd64
  export FAKE_REPLICAS=1
  export TON_VALUES_FILE="$FAKE_STATE/values.yaml"
  export KUBETON_UPGRADE_TIMEOUT_SECONDS=5 KUBETON_LAUNCH_LOGS_ENABLED=false
  cat >"$TON_VALUES_FILE" <<VALUES
tonNode:
  name: test-tonnode
  namespace: test-ns
  replicas: 99
  image: '$FAKE_DESIRED_CTRL' # quoted image with comment
  tonImage: "$FAKE_DESIRED_TON"
VALUES
}

run_case() {
  local expected="$1" entrypoint="${2:-source}" rc=0
  shift 2
  if [[ "$entrypoint" == main ]]; then
    PATH="$test_dir/bin:$PATH" bash "$kubeton" upgrade "$@" >"$FAKE_STATE/output" 2>&1 || rc=$?
  else
    PATH="$test_dir/bin:$PATH" bash -c '
      source "$1"
      shift
      date() {
        if [[ "${1:-}" == +%s ]]; then cat "$FAKE_STATE/clock"; else command date "$@"; fi
      }
      sleep() {
        local now
        now="$(cat "$FAKE_STATE/clock")"
        printf "%s" "$((now + 2))" >"$FAKE_STATE/clock"
      }
      run_upgrade "$@"
    ' _ "$kubeton" "$@" >"$FAKE_STATE/output" 2>&1 || rc=$?
  fi
  if [[ "$expected" == success && "$rc" != 0 || "$expected" == failure && "$rc" == 0 ]]; then
    cat "$FAKE_STATE/output" "$FAKE_STATE/events" >&2
    fail "case $FAKE_MODE expected $expected, got exit $rc"
  fi
}

assert_patch_fields() {
  local controller="$1" ton="$2" resource_version="${3:-7}" payload field
  payload="$(tr -d '[:space:]' <"$FAKE_STATE/patch.json")"
  for field in '"metadata":' "\"resourceVersion\":\"$resource_version\"" '"spec":'; do
    [[ "$payload" == *"$field"* ]] || fail "missing patch field $field"
    payload="${payload//"$field"/}"
  done
  if [[ "$controller" == true ]]; then
    field="\"image\":\"$FAKE_DESIRED_CTRL\""
    [[ "$payload" == *"$field"* ]] || fail 'missing MyTonCtrl patch field'
    payload="${payload//"$field"/}"
  fi
  if [[ "$ton" == true ]]; then
    field="\"tonImage\":\"$FAKE_DESIRED_TON\""
    [[ "$payload" == *"$field"* ]] || fail 'missing TON patch field'
    payload="${payload//"$field"/}"
  fi
  payload="$(printf '%s' "$payload" | tr -d '{},')"
  [[ -z "$payload" ]] || fail "unexpected patch content: $payload"
}

# Actual command dispatch, actual row queries and the optimistic image-only patch.
new_case both-images
run_case success main
assert_patch_fields true true
assert_order 'bundle test-tonnode-0' patch "$FAKE_STATE/events"
assert_order patch template-ready "$FAKE_STATE/events"
assert_order template-ready rollout "$FAKE_STATE/events"
assert_contains upgraded "$FAKE_STATE/output"
assert_not_contains 'probe other-fleet' "$FAKE_STATE/events"

new_case noop
run_case success main
assert_contains 'Nothing to upgrade.' "$FAKE_STATE/output"
[[ ! -e "$FAKE_STATE/patch.json" && ! -e "$FAKE_STATE/rolled-out" ]] || fail 'noop mutated fleet'
assert_not_contains 'probe test-tonnode' "$FAKE_STATE/events"

new_case ton-only
FAKE_CURRENT_CTRL="$FAKE_DESIRED_CTRL"
run_case success source
assert_patch_fields false true

new_case controller-only
FAKE_CURRENT_TON="$FAKE_DESIRED_TON"
run_case success source
assert_patch_fields true false

new_case status-write
run_case success source
assert_patch_fields true true 8

# The CR can already contain the new images after an interrupted invocation.
for mode in resume-template resume-pods resume-exporter; do
  new_case "$mode"
  run_case success source
  [[ ! -e "$FAKE_STATE/patch.json" ]] || fail "$mode patched already-desired CR"
  assert_contains rollout "$FAKE_STATE/events"
  assert_contains upgraded "$FAKE_STATE/output"
done

new_case observed-generation
run_case success source
assert_order template-unobserved template-ready "$FAKE_STATE/events"
assert_order template-ready rollout "$FAKE_STATE/events"

# Live replicas are authoritative; values replicas=99 must never start a stopped fleet.
new_case stopped
FAKE_REPLICAS=0
run_case success source
assert_patch_fields true true
assert_contains 'remains stopped' "$FAKE_STATE/output"
[[ ! -e "$FAKE_STATE/rolled-out" ]] || fail 'stopped upgrade rolled out pods'
assert_not_contains 'probe test-tonnode' "$FAKE_STATE/events"

new_case stopped-noop
FAKE_MODE=noop FAKE_REPLICAS=0
run_case success source
assert_contains 'Nothing to upgrade.' "$FAKE_STATE/output"
[[ ! -e "$FAKE_STATE/patch.json" && ! -e "$FAKE_STATE/rolled-out" ]] || fail 'stopped noop mutated fleet'

# Refresh initialized pods only; ignore other owners, deleting pods and missing sidecars.
new_case backup-filter
FAKE_REPLICAS=3
run_case success source
assert_order 'bundle test-tonnode-0' patch "$FAKE_STATE/events"
assert_contains 'probe test-tonnode-1' "$FAKE_STATE/events"
assert_not_contains 'backup test-tonnode-1' "$FAKE_STATE/events"
assert_not_contains 'probe test-tonnode-2' "$FAKE_STATE/events"
assert_not_contains 'probe test-tonnode-terminating' "$FAKE_STATE/events"
assert_not_contains 'probe other-fleet' "$FAKE_STATE/events"

for mode in probe-failure backup-failure bundle-failure cr-api-failure sts-api-failure pods-api-failure missing-cr concurrent-edit; do
  new_case "$mode"
  run_case failure source
  [[ ! -e "$FAKE_STATE/patch.json" ]] || fail "$mode applied images despite failed preflight"
  [[ ! -e "$FAKE_STATE/rolled-out" ]] || fail "$mode started rollout"
done

for mode in patch-failure template-timeout rollout-failure stale-pods missing-pod final-cr-drift; do
  new_case "$mode"
  run_case failure source
  assert_patch_fields true true
  assert_not_contains 'MyTonCtrl is Ready' "$FAKE_STATE/output"
  if [[ "$mode" == patch-failure || "$mode" == template-timeout ]]; then
    assert_not_contains 'rollout status' "$FAKE_STATE/events"
  fi
done

new_case bad-args
run_case failure main unexpected
assert_contains 'usage: kubeton upgrade' "$FAKE_STATE/output"
[[ ! -s "$FAKE_STATE/events" ]] || fail 'bad arguments reached Kubernetes'

new_case missing-file
rm "$TON_VALUES_FILE"
run_case failure main
[[ ! -s "$FAKE_STATE/events" ]] || fail 'missing values file reached Kubernetes'

for field in image tonImage; do
  new_case "missing-$field"
  sed -i "/^  $field:/d" "$TON_VALUES_FILE"
  run_case failure source
  assert_contains "tonNode.$field is missing" "$FAKE_STATE/output"
  [[ ! -s "$FAKE_STATE/events" ]] || fail "missing $field reached Kubernetes"
done

new_case bad-timeout
KUBETON_UPGRADE_TIMEOUT_SECONDS=0
run_case failure source
[[ ! -s "$FAKE_STATE/events" ]] || fail 'invalid timeout reached Kubernetes'

for image in null true 'invalid image'; do
  new_case "bad-image-${image// /-}"
  sed -i "s/^  image:.*/  image: '$image'/" "$TON_VALUES_FILE"
  run_case failure source
  [[ ! -s "$FAKE_STATE/events" ]] || fail 'invalid image reached Kubernetes'
done

echo 'kubeton upgrade checks: PASS'
