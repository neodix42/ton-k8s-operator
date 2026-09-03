#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

fail() {
  echo "test failure: $*" >&2
  exit 1
}

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

test_launch_session_begin_permissions() (
  export KUBETON_LAUNCH_LOG_ROOT="$test_dir/begin-root"
  export TON_VALUES_FILE="$test_dir/tonnode-values.yaml"
  mkdir -p "$KUBETON_LAUNCH_LOG_ROOT"
  chmod 0755 "$KUBETON_LAUNCH_LOG_ROOT"
  source "$kubeton"

  run_with_timeout() {
    shift
    "$@"
  }

  kubectl() {
    if [[ "$*" == "config current-context" ]]; then
      printf '%s\n' test-context
      return 0
    fi
    return 1
  }

  local launch_dir mode
  launch_dir="$(launch_session_begin start 2>"$test_dir/begin.stderr")"
  [[ -d "$launch_dir/pods" ]] || fail "launch session did not create pods directory"
  [[ -d "$launch_dir/final" ]] || fail "launch session did not create final directory"
  mode="$(stat -c '%a' "$launch_dir")"
  [[ "$mode" == "700" ]] || fail "launch evidence directory mode is $mode, expected 700"
  mode="$(stat -c '%a' "$KUBETON_LAUNCH_LOG_ROOT")"
  [[ "$mode" == "755" ]] \
    || fail "launch evidence root mode changed to $mode, expected caller-owned mode 755"
  assert_contains "command=start" "$launch_dir/session.meta"
  assert_contains "kube_context=test-context" "$launch_dir/session.meta"
)

test_run_with_launch_session_exit_and_evidence() (
  export KUBETON_LAUNCH_LOGS_ENABLED=true
  export KUBETON_LAUNCH_LOG_ROOT="$test_dir/run-root"
  export TON_VALUES_FILE="$test_dir/tonnode-values.yaml"
  source "$kubeton"

  kubectl() {
    if [[ "$*" == "config current-context" ]]; then
      printf '%s\n' test-context
      return 0
    fi
    return 1
  }
  resolve_tonnode_namespace_from_values() { printf '%s' test-ns; }
  resolve_tonnode_name_from_values() { printf '%s' test-tonnode; }
  resolve_ton_replicas_from_values_file() { printf '%s' 2; }
  launch_session_start_watchers() { :; }
  launch_session_stop_watchers() { :; }
  launch_session_snapshot() {
    local destination="$4"
    mkdir -p "$destination"
    printf '%s\n' final-snapshot >"$destination/evidence.txt"
  }
  deliberately_failing_command() {
    echo "command stdout"
    echo "command stderr" >&2
    return 23
  }

  local rc launch_dir
  set +e
  if run_with_launch_session start deliberately_failing_command >"$test_dir/run.stdout" 2>"$test_dir/run.stderr"; then
    fail "run_with_launch_session discarded the command failure"
  else
    rc=$?
  fi
  if [[ "$-" == *e* ]]; then
    fail "run_with_launch_session enabled errexit although its caller had disabled it"
  fi
  set -e
  [[ "$rc" == "23" ]] || fail "run_with_launch_session returned $rc, expected 23"

  launch_dir="$(find "$KUBETON_LAUNCH_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$launch_dir" ]] || fail "run_with_launch_session did not create an evidence directory"
  assert_contains "command stdout" "$test_dir/run.stdout"
  assert_not_contains "command stderr" "$test_dir/run.stdout"
  assert_contains "command stderr" "$test_dir/run.stderr"
  assert_not_contains "command stdout" "$test_dir/run.stderr"
  assert_contains "command stdout" "$launch_dir/command.stdout.log"
  assert_not_contains "command stderr" "$launch_dir/command.stdout.log"
  assert_contains "command stderr" "$launch_dir/command.stderr.log"
  assert_not_contains "command stdout" "$launch_dir/command.stderr.log"
  assert_contains "command stdout" "$launch_dir/command.log"
  assert_contains "command stderr" "$launch_dir/command.log"
  assert_contains "ton_namespace=test-ns" "$launch_dir/session.meta"
  assert_contains "desired_replicas=2" "$launch_dir/session.meta"
  assert_contains "exit_code=23" "$launch_dir/session.meta"
  assert_contains "kubeton start exit code: 23" "$launch_dir/summary.txt"
  assert_contains "final-snapshot" "$launch_dir/final/evidence.txt"
)

test_install_waits_for_operator_rollout_inside_launch_session() (
  export KUBETON_LAUNCH_LOGS_ENABLED=true
  export KUBETON_LAUNCH_LOG_ROOT="$test_dir/install-rollout-launches"
  export KUBETON_SKIP_NODE_PREREQ_CHECK=true
  export KUBETON_INSTALL_READY_TIMEOUT_SECONDS=37
  export TON_VALUES_FILE="$test_dir/tonnode-values.yaml"
  source "$kubeton"

  local mode=success
  local active_marker="$test_dir/install-watchers.active"
  local success_events="$test_dir/install-rollout-success.events"
  local failure_events="$test_dir/install-rollout-failure.events"
  : >"$success_events"
  : >"$failure_events"

  OP_NAMESPACE=test-operator-ns
  OP_CONTROLLER_DEPLOYMENT=default-controller-must-not-be-used
  RELEASE_NAME=custom-release
  record_install_event() {
    printf '%s\n' "$1" >>"$test_dir/install-rollout-${mode}.events"
  }
  require_bin() { :; }
  resolve_tonnode_namespace_from_values() { printf '%s' default; }
  resolve_tonnode_name_from_values() { printf '%s' tonnode; }
  resolve_ton_replicas_from_values_file() { printf '%s' 1; }
  append_helm_force_conflicts_if_supported() { :; }
  launch_session_start_watchers() {
    record_install_event watcher-start
    : >"$active_marker"
  }
  launch_session_stop_watchers() {
    record_install_event watcher-stop
    rm -f "$active_marker"
  }
  launch_session_snapshot() {
    mkdir -p "$4"
    record_install_event final-snapshot
  }
  helm() {
    if [[ "$*" == "-n test-operator-ns status custom-release" ]]; then
      return 1
    fi
    record_install_event helm-applied
    return 0
  }
  kubectl() {
    if [[ "$*" == "config current-context" ]]; then
      printf '%s\n' test-context
      return 0
    fi
    if [[ "$*" == *"-n test-operator-ns get deployment -l app.kubernetes.io/instance=custom-release,control-plane=controller-manager "* ]]; then
      record_install_event deployment-resolved-by-release-labels
      printf '%s\n' custom-release-rendered-controller
      return 0
    fi
    if [[ "$*" == "-n test-operator-ns get deployment default-controller-must-not-be-used" ]]; then
      record_install_event fixed-deployment-fallback-used
      return 1
    fi
    if [[ "$*" == "-n test-operator-ns rollout status deployment/custom-release-rendered-controller --timeout=37s" ]]; then
      record_install_event rollout-started
      if [[ ! -e "$active_marker" ]]; then
        record_install_event rollout-outside-watcher-scope
      fi
      if [[ "$mode" == "failure" ]]; then
        record_install_event rollout-failed
        return 1
      fi
      record_install_event rollout-ready
      return 0
    fi
    return 1
  }

  run_with_launch_session install run_install \
    >"$test_dir/install-rollout-success.out" 2>"$test_dir/install-rollout-success.stderr"
  assert_order "watcher-start" "helm-applied" "$success_events"
  assert_order "helm-applied" "deployment-resolved-by-release-labels" "$success_events"
  assert_order "deployment-resolved-by-release-labels" "rollout-started" "$success_events"
  assert_order "rollout-started" "rollout-ready" "$success_events"
  assert_order "rollout-ready" "watcher-stop" "$success_events"
  assert_not_contains "rollout-outside-watcher-scope" "$success_events"
  assert_not_contains "fixed-deployment-fallback-used" "$success_events"

  mode=failure
  if run_with_launch_session install run_install \
      >"$test_dir/install-rollout-failure.out" 2>"$test_dir/install-rollout-failure.stderr"; then
    fail "install launch session discarded the operator rollout failure"
  fi
  assert_order "watcher-start" "helm-applied" "$failure_events"
  assert_order "helm-applied" "deployment-resolved-by-release-labels" "$failure_events"
  assert_order "deployment-resolved-by-release-labels" "rollout-started" "$failure_events"
  assert_order "rollout-started" "rollout-failed" "$failure_events"
  assert_order "rollout-failed" "watcher-stop" "$failure_events"
  assert_not_contains "rollout-outside-watcher-scope" "$failure_events"
  assert_not_contains "fixed-deployment-fallback-used" "$failure_events"
  assert_contains "did not become Ready" "$test_dir/install-rollout-failure.stderr"
)

test_launch_session_preserves_enabled_errexit() (
  export KUBETON_LAUNCH_LOGS_ENABLED=true
  export KUBETON_LAUNCH_LOG_ROOT="$test_dir/enabled-errexit-root"
  export TON_VALUES_FILE="$test_dir/tonnode-values.yaml"
  source "$kubeton"

  kubectl() { return 1; }
  resolve_tonnode_namespace_from_values() { printf '%s' test-ns; }
  resolve_tonnode_name_from_values() { printf '%s' test-tonnode; }
  resolve_ton_replicas_from_values_file() { printf '%s' 1; }
  launch_session_start_watchers() { :; }
  launch_session_stop_watchers() { :; }
  launch_session_snapshot() { mkdir -p "$4"; }
  successful_command() { printf '%s\n' success; }

  set -e
  run_with_launch_session start successful_command >"$test_dir/enabled-errexit.out" 2>&1
  [[ "$-" == *e* ]] || fail "run_with_launch_session disabled errexit although its caller had enabled it"
)

test_launch_session_preserves_errexit() (
  export KUBETON_LAUNCH_LOGS_ENABLED=true
  export KUBETON_LAUNCH_LOG_ROOT="$test_dir/errexit-root"
  export TON_VALUES_FILE="$test_dir/tonnode-values.yaml"
  source "$kubeton"

  kubectl() { return 1; }
  resolve_tonnode_namespace_from_values() { printf '%s' test-ns; }
  resolve_tonnode_name_from_values() { printf '%s' test-tonnode; }
  resolve_ton_replicas_from_values_file() { printf '%s' 1; }
  launch_session_start_watchers() { :; }
  launch_session_stop_watchers() { :; }
  launch_session_snapshot() { mkdir -p "$4"; }
  unguarded_failure() {
    false
    echo "UNSAFE continued after failure"
  }

  set +e
  run_with_launch_session start unguarded_failure >"$test_dir/errexit.out" 2>&1
  local rc=$?
  if [[ "$-" == *e* ]]; then
    fail "run_with_launch_session did not restore its caller's disabled errexit state"
  fi
  set -e
  [[ "$rc" != "0" ]] || fail "launch transcript pipeline converted an unguarded failure into success"
  if grep -Fq "UNSAFE" "$test_dir/errexit.out"; then
    fail "launch transcript pipeline disabled errexit in the wrapped command"
  fi
)

test_launch_session_term_kills_command_tree() (
  local launch_root="$test_dir/signal-root"
  local child_state_file="$test_dir/signal-child.state"
  local wrapper_stdout="$test_dir/signal-wrapper.stdout"
  local wrapper_stderr="$test_dir/signal-wrapper.stderr"
  local timeout_file="$test_dir/signal-wrapper.timeout"
  local tail_ready_file="$test_dir/signal-tail.ready"
  local tail_marker="KUBETON_BUFFERED_TAIL_${BASHPID}_${RANDOM}"
  local marker="kubeton-signal-child-${BASHPID}-${RANDOM}"
  local wrapper_pid="" wrapper_start="" command_pid="" command_start=""
  local child_pid="" child_start="" current_cmdline="" rc="" watchdog_pid=""
  local deadline launch_dir

  same_process_instance() {
    local pid="$1"
    local expected_start="$2"
    local actual_start
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_start" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/${pid}/stat" ]] || return 1
    actual_start="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
    [[ "$actual_start" == "$expected_start" ]]
  }
  signal_test_cleanup() {
    if same_process_instance "$child_pid" "$child_start"; then
      kill -KILL "$child_pid" >/dev/null 2>&1 || true
    fi
    if same_process_instance "$command_pid" "$command_start"; then
      kill -KILL "$command_pid" >/dev/null 2>&1 || true
    fi
    if same_process_instance "$wrapper_pid" "$wrapper_start"; then
      kill -KILL "$wrapper_pid" >/dev/null 2>&1 || true
    fi
    if [[ "$watchdog_pid" =~ ^[1-9][0-9]*$ ]]; then
      kill "$watchdog_pid" >/dev/null 2>&1 || true
    fi
  }
  trap signal_test_cleanup EXIT

  KUBETON_LAUNCH_LOGS_ENABLED=true \
  KUBETON_LAUNCH_LOG_ROOT="$launch_root" \
  TON_VALUES_FILE="$test_dir/tonnode-values.yaml" \
    bash -c '
      set -euo pipefail
      kubeton_path="$1"
      child_state_file="$2"
      child_marker="$3"
      tail_ready_file="$4"
      tail_marker="$5"
      source "$kubeton_path"

      kubectl() {
        if [[ "$*" == "config current-context" ]]; then
          printf "%s\n" signal-test
          return 0
        fi
        return 1
      }
      resolve_tonnode_namespace_from_values() { printf "%s" test-ns; }
      resolve_tonnode_name_from_values() { printf "%s" test-tonnode; }
      resolve_ton_replicas_from_values_file() { printf "%s" 1; }
      launch_session_start_watchers() { :; }
      launch_session_stop_watchers() { :; }
      launch_session_snapshot() { mkdir -p "$4"; }
      long_command_with_descendant() {
        local command_pid="$BASHPID"
        local command_start
        command_start="$(cut -d " " -f 22 "/proc/${command_pid}/stat")"
        (
          # Ignored dispositions survive exec. The wrapper must therefore
          # escalate against this exact process instance after TERM+CONT.
          trap "" TERM
          child_pid="$BASHPID"
          child_start="$(cut -d " " -f 22 "/proc/${child_pid}/stat")"
          printf "%s\t%s\t%s\t%s\n" \
            "$command_pid" "$command_start" "$child_pid" "$child_start" >"$child_state_file"
          exec -a "$child_marker" sleep 300
        ) &
        # Fill the transcript pipe, then publish a unique final marker before
        # telling the parent it may signal the wrapper. The wrapper must let
        # tee drain bytes already accepted by the FIFO after command teardown.
        head -c 4194304 /dev/zero | tr "\000" x
        printf "\n%s\n" "$tail_marker"
        : >"$tail_ready_file"
        wait "$!"
      }

      run_with_launch_session start long_command_with_descendant
    ' _ "$kubeton" "$child_state_file" "$marker" "$tail_ready_file" "$tail_marker" \
      >"$wrapper_stdout" 2>"$wrapper_stderr" &
  wrapper_pid=$!
  wrapper_start="$(awk '{print $22}' "/proc/${wrapper_pid}/stat")"

  deadline=$((SECONDS + 5))
  while [[ ( ! -s "$child_state_file" || ! -e "$tail_ready_file" ) && $SECONDS -lt $deadline ]]; do
    same_process_instance "$wrapper_pid" "$wrapper_start" \
      || fail "launch wrapper exited before starting its command descendant"
    command sleep 0.02
  done
  [[ -s "$child_state_file" ]] || fail "launch wrapper did not record its command descendant"
  [[ -e "$tail_ready_file" ]] || fail "launch command did not finish writing its buffered tail marker"
  IFS=$'\t' read -r command_pid command_start child_pid child_start <"$child_state_file"
  same_process_instance "$command_pid" "$command_start" \
    || fail "recorded launch command process is not running"
  same_process_instance "$child_pid" "$child_start" \
    || fail "recorded launch command descendant is not running"

  deadline=$((SECONDS + 2))
  while (( SECONDS < deadline )); do
    if [[ -r "/proc/${child_pid}/cmdline" ]]; then
      current_cmdline="$(tr '\0' ' ' <"/proc/${child_pid}/cmdline" 2>/dev/null || true)"
      [[ "$current_cmdline" == "$marker "* ]] && break
    fi
    command sleep 0.02
  done
  [[ "$current_cmdline" == "$marker "* ]] \
    || fail "recorded descendant never acquired its unique command identity"

  # Address only the wrapper PID. The wrapper must propagate teardown through
  # its tracked command process to the marked grandchild.
  kill -TERM "$wrapper_pid"
  (
    command sleep 3
    if same_process_instance "$wrapper_pid" "$wrapper_start"; then
      : >"$timeout_file"
      kill -KILL "$wrapper_pid" >/dev/null 2>&1 || true
    fi
  ) &
  watchdog_pid=$!

  set +e
  wait "$wrapper_pid"
  rc=$?
  set -e
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true
  watchdog_pid=""

  [[ ! -e "$timeout_file" ]] || fail "TERM did not stop the launch wrapper promptly"
  [[ "$rc" == "143" ]] || fail "TERM produced launch-wrapper exit code $rc, expected 143"

  deadline=$((SECONDS + 2))
  while same_process_instance "$child_pid" "$child_start" && (( SECONDS < deadline )); do
    command sleep 0.02
  done
  if same_process_instance "$child_pid" "$child_start"; then
    current_cmdline="$(tr '\0' ' ' <"/proc/${child_pid}/cmdline" 2>/dev/null || true)"
    fail "TERM left tracked descendant ${child_pid} (${current_cmdline:-unknown command}) running"
  fi
  if same_process_instance "$command_pid" "$command_start"; then
    fail "TERM left tracked launch command process ${command_pid} running"
  fi

  launch_dir="$(find "$launch_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$launch_dir" ]] || fail "signal test launch evidence was not retained"
  assert_contains "exit_code=143" "$launch_dir/session.meta"
  assert_contains "$tail_marker" "$launch_dir/command.stdout.log"
  assert_contains "$tail_marker" "$launch_dir/command.log"
)

test_launch_session_term_before_command_spawn_never_starts_command() (
  local launch_root="$test_dir/pre-spawn-signal-root"
  local command_started_file="$test_dir/pre-spawn-command.started"
  local lifecycle_file="$test_dir/pre-spawn-signal.lifecycle"
  local wrapper_stdout="$test_dir/pre-spawn-signal.stdout"
  local wrapper_stderr="$test_dir/pre-spawn-signal.stderr"
  local rc launch_dir
  : >"$lifecycle_file"

  set +e
  timeout 5s env \
    KUBETON_LAUNCH_LOGS_ENABLED=true \
    KUBETON_LAUNCH_LOG_ROOT="$launch_root" \
    TON_VALUES_FILE="$test_dir/tonnode-values.yaml" \
    bash -c '
      set -euo pipefail
      kubeton_path="$1"
      command_started_file="$2"
      lifecycle_file="$3"
      source "$kubeton_path"

      kubectl() {
        if [[ "$*" == "config current-context" ]]; then
          printf "%s\n" pre-spawn-signal-test
          return 0
        fi
        return 1
      }
      resolve_tonnode_namespace_from_values() { printf "%s" test-ns; }
      resolve_tonnode_name_from_values() { printf "%s" test-tonnode; }
      resolve_ton_replicas_from_values_file() { printf "%s" 1; }
      launch_session_start_watchers() {
        printf "%s\n" watcher-start-entered >>"$lifecycle_file"
        # The launch trap must already exist at this exact pre-spawn point.
        kill -TERM "$BASHPID"
        printf "%s\n" watcher-start-returned >>"$lifecycle_file"
      }
      launch_session_stop_watchers() {
        printf "%s\n" watchers-stopped >>"$lifecycle_file"
      }
      launch_session_snapshot() { mkdir -p "$4"; }
      command_that_must_not_start() {
        : >"$command_started_file"
      }

      set +e
      run_with_launch_session start command_that_must_not_start
      exit "$?"
    ' _ "$kubeton" "$command_started_file" "$lifecycle_file" \
      >"$wrapper_stdout" 2>"$wrapper_stderr"
  rc=$?
  set -e

  [[ "$rc" == "143" ]] \
    || fail "pre-spawn TERM produced exit code $rc, expected 143"
  [[ ! -e "$command_started_file" ]] \
    || fail "launch command started after TERM arrived in the pre-spawn window"
  assert_contains "watcher-start-entered" "$lifecycle_file"
  assert_contains "watchers-stopped" "$lifecycle_file"
  assert_order "watcher-start-entered" "watchers-stopped" "$lifecycle_file"
  launch_dir="$(find "$launch_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$launch_dir" ]] || fail "pre-spawn signal did not retain launch evidence"
  assert_contains "exit_code=143" "$launch_dir/session.meta"
)

test_owned_process_tree_uses_ps_when_proc_is_unavailable() (
  source "$kubeton"

  local marker="kubeton-ps-fallback-${BASHPID}-${RANDOM}"
  local child_pid="" child_parent="" child_state="" child_token=""
  local identity="" current_cmdline="" wait_rc=0 deadline
  KUBETON_PROCESS_PROC_ROOT="$test_dir/no-such-proc-root"

  fallback_identity_matches() {
    local row parent state token
    row="$(kubeton_process_identity "$child_pid" 2>/dev/null || true)"
    IFS=$'\t' read -r parent state token <<<"$row"
    [[ "$parent" == "$child_parent" && "$token" == "$child_token" && -n "$token" ]]
  }
  fallback_process_cleanup() {
    if fallback_identity_matches; then
      kill -KILL "$child_pid" >/dev/null 2>&1 || true
    fi
    wait "$child_pid" >/dev/null 2>&1 || true
  }
  trap fallback_process_cleanup EXIT

  bash -c 'trap "" TERM; exec -a "$1" sleep 300' _ "$marker" &
  child_pid=$!
  deadline=$((SECONDS + 2))
  while (( SECONDS < deadline )); do
    identity="$(kubeton_process_identity "$child_pid" 2>/dev/null || true)"
    IFS=$'\t' read -r child_parent child_state child_token <<<"$identity"
    if [[ -r "/proc/${child_pid}/cmdline" ]]; then
      current_cmdline="$(tr '\0' ' ' <"/proc/${child_pid}/cmdline" 2>/dev/null || true)"
    fi
    if [[ "$child_parent" == "$BASHPID" \
      && "$child_token" == ps-* \
      && "$current_cmdline" == "$marker "* ]]; then
      break
    fi
    command sleep 0.02
  done
  [[ "$child_parent" == "$BASHPID" ]] || fail "ps fallback did not retain the child PPID"
  [[ "$child_token" == ps-* ]] || fail "process identity did not use ps when procfs was unavailable"
  [[ "$current_cmdline" == "$marker "* ]] || fail "fallback test child did not reach its TERM-ignoring exec"

  terminate_owned_process_tree "$child_pid" "$BASHPID"
  set +e
  wait "$child_pid" 2>/dev/null
  wait_rc=$?
  set -e
  [[ "$wait_rc" == "137" ]] \
    || fail "TERM-ignoring ps-fallback child exited with $wait_rc, expected KILL status 137"
  if kubeton_process_identity "$child_pid" >/dev/null 2>&1; then
    fail "ps-fallback teardown left the original child process present"
  fi
  child_pid=""
)

test_owned_process_tree_ps_fallback_rejects_reused_pid() (
  source "$kubeton"

  local ps_calls="$test_dir/ps-fallback-reuse.calls"
  local signal_log="$test_dir/ps-fallback-reuse.signals"
  : >"$ps_calls"
  : >"$signal_log"
  KUBETON_PROCESS_PROC_ROOT="$test_dir/no-such-proc-root"

  ps() {
    local calls
    if [[ "$*" == *"-p 4242"* ]]; then
      calls="$(wc -l <"$ps_calls")"
      printf '%s\n' identity-read >>"$ps_calls"
      if (( calls == 0 )); then
        printf '%s\n' '100 S Mon Sep  1 00:00:00 2026'
      else
        # Same PID and PPID but a different stable start token models PID
        # reuse between the ownership read and the post-STOP validation.
        printf '%s\n' '100 T Tue Sep  2 00:00:00 2026'
      fi
      return 0
    fi
    return 0
  }
  kill() {
    printf '%s\n' "$*" >>"$signal_log"
  }

  terminate_owned_process_tree 4242 100
  assert_contains "-STOP 4242" "$signal_log"
  assert_contains "-CONT 4242" "$signal_log"
  assert_not_contains "-TERM 4242" "$signal_log"
  assert_not_contains "-KILL 4242" "$signal_log"
)

test_container_followers_reconnect_independently() (
  source "$kubeton"

  local launch_dir="$test_dir/container-followers"
  local call_log="$test_dir/container-followers.calls"
  local stop_file="$launch_dir/.stop"
  local key_pid ton_pid deadline follow_count
  mkdir -p "$launch_dir/pods"
  : >"$call_log"

  # Keep the reconnect backoff short while retaining a genuinely long-lived
  # key-backup connection in the kubectl stub below.
  sleep() { command sleep 0.02; }
  run_with_timeout() {
    shift
    "$@"
  }
  kubectl() {
    local args="$*"
    if [[ "$args" == *" get pod tonnode-0 "* && "$args" == *"metadata.uid"* ]]; then
      printf '%s' pod-uid
      return 0
    fi
    if [[ "$args" == *" logs tonnode-0 "* ]]; then
      printf '%s\n' "$args" >>"$call_log"
      if [[ "$args" == *"-c key-backup"* || "$args" == *"--container=key-backup"* ]]; then
        command sleep 1
        printf '%s\n' key-backup-heartbeat
        return 0
      fi
      if [[ "$args" == *"-c ton-node"* || "$args" == *"--container=ton-node"* ]]; then
        if [[ "$args" == *"--previous"* ]]; then
          printf '%s\n' ton-node-previous-generation
        else
          printf '%s\n' ton-node-current-generation
        fi
        return 0
      fi
    fi
    return 1
  }

  launch_session_follow_one_container "$launch_dir" default tonnode-0 pod-uid key-backup app &
  key_pid=$!
  launch_session_follow_one_container "$launch_dir" default tonnode-0 pod-uid ton-node app &
  ton_pid=$!

  deadline=$((SECONDS + 3))
  follow_count=0
  while (( SECONDS < deadline )); do
    follow_count="$(grep -F -- 'logs tonnode-0' "$call_log" \
      | grep -E -- '(^| )-c ton-node( |$)|--container=ton-node( |$)' \
      | grep -Fvc -- '--previous' || true)"
    (( follow_count >= 2 )) && break
    command sleep 0.02
  done
  : >"$stop_file"
  wait "$ton_pid" || true
  wait "$key_pid" || true

  (( follow_count >= 2 )) \
    || fail "ton-node follower did not reconnect while key-backup remained connected"
  grep -F -- 'logs tonnode-0' "$call_log" \
    | grep -E -- '(^| )-c key-backup( |$)|--container=key-backup( |$)' >/dev/null \
    || fail "key-backup did not receive its own log follower"
  grep -F -- 'logs tonnode-0' "$call_log" \
    | grep -E -- '(^| )-c ton-node( |$)|--container=ton-node( |$)' \
    | grep -F -- '--previous' >/dev/null \
    || fail "ton-node reconnect did not snapshot the previous container generation"
  assert_contains "ton-node-current-generation" "$launch_dir/pods/tonnode-0-pod-uid-ton-node.log"
  assert_contains "ton-node-previous-generation" "$launch_dir/pods/tonnode-0-pod-uid-ton-node.log"
)

test_log_supervisor_spawns_every_container() (
  source "$kubeton"

  local launch_dir="$test_dir/log-supervisor"
  local spawn_log="$test_dir/log-supervisor.spawns"
  mkdir -p "$launch_dir/pods"
  : >"$spawn_log"

  run_with_timeout() {
    shift
    "$@"
  }
  terminate_owned_child_processes() { :; }
  launch_session_follow_one_container() {
    printf '%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" >>"$spawn_log"
  }
  kubectl() {
    if [[ "$*" == *" get pods -l "* ]]; then
      printf '%s\n' \
        $'tonnode-0\tpod-uid\tinit\tprepare-persistent-layout' \
        $'tonnode-0\tpod-uid\tinit\tkey-restore' \
        $'tonnode-0\tpod-uid\tapp\tton-node' \
        $'tonnode-0\tpod-uid\tapp\tkey-backup'
      return 0
    fi
    return 1
  }
  sleep() {
    local observed
    observed="$(wc -l <"$spawn_log")"
    if (( observed >= 4 )); then
      : >"$launch_dir/.stop"
    else
      command sleep 0.02
    fi
  }

  launch_session_log_supervisor "$launch_dir" default tonnode
  assert_contains $'tonnode-0\tpod-uid\tprepare-persistent-layout\tinit' "$spawn_log"
  assert_contains $'tonnode-0\tpod-uid\tkey-restore\tinit' "$spawn_log"
  assert_contains $'tonnode-0\tpod-uid\tton-node\tapp' "$spawn_log"
  assert_contains $'tonnode-0\tpod-uid\tkey-backup\tapp' "$spawn_log"
)

test_launch_watchers_track_and_stop_cluster_event_stream() (
  source "$kubeton"

  local launch_dir="$test_dir/watcher-lifecycle"
  local watcher_log="$test_dir/watcher-lifecycle.log"
  local deadline pid
  local -a watcher_pids=()
  mkdir -p "$launch_dir"
  : >"$watcher_log"

  watcher_stub() {
    local dir="$1"
    local name="$2"
    printf 'started-%s\n' "$name" >>"$watcher_log"
    while [[ ! -e "$dir/.stop" ]]; do
      sleep 0.02
    done
    printf 'stopped-%s\n' "$name" >>"$watcher_log"
  }
  launch_session_event_watch() { watcher_stub "$1" namespace-events; }
  launch_session_cluster_event_watch() { watcher_stub "$1" cluster-events; }
  launch_session_timeline_watch() { watcher_stub "$1" timeline; }
  launch_session_log_supervisor() { watcher_stub "$1" pod-logs; }
  launch_session_operator_log_watch() { watcher_stub "$1" operator-logs; }

  launch_session_start_watchers "$launch_dir" default tonnode
  [[ "${#KUBETON_LAUNCH_WATCHER_PIDS[@]}" == "5" ]] \
    || fail "launch session did not track all five evidence watchers"
  watcher_pids=("${KUBETON_LAUNCH_WATCHER_PIDS[@]}")
  deadline=$((SECONDS + 2))
  while ! grep -Fq 'started-cluster-events' "$watcher_log"; do
    (( SECONDS < deadline )) || fail "cluster-wide event watcher was not started"
    sleep 0.02
  done

  launch_session_stop_watchers "$launch_dir"
  [[ -e "$launch_dir/.stop" ]] || fail "watcher stop marker was not created"
  [[ "${#KUBETON_LAUNCH_WATCHER_PIDS[@]}" == "0" ]] \
    || fail "watcher PID registry was not cleared"
  assert_contains "stopped-cluster-events" "$watcher_log"
  for pid in "${watcher_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      fail "launch watcher PID $pid survived launch_session_stop_watchers"
    fi
  done
)

test_event_watchers_use_atomic_list_watch_without_replay_timeout() (
  source "$kubeton"

  local namespace_dir="$test_dir/namespace-event-rv"
  local cluster_dir="$test_dir/cluster-event-rv"
  local call_log="$test_dir/event-rv.calls"
  local active_stop watcher_kind
  mkdir -p "$namespace_dir" "$cluster_dir"
  : >"$call_log"

  kubectl() {
    local args="$*"
    if [[ "$args" == *"get events"* ]]; then
      printf 'atomic-watch-%s %s\n' "$watcher_kind" "$args" >>"$call_log"
      printf '%s\n' "atomic-${watcher_kind}-event"
      : >"$active_stop"
      return 0
    fi
    return 1
  }
  sleep() { fail "event watcher started a periodic timeout/replay loop after one completed watch"; }

  watcher_kind=namespace
  active_stop="$namespace_dir/.stop"
  launch_session_event_watch "$namespace_dir" default
  watcher_kind=cluster
  active_stop="$cluster_dir/.stop"
  launch_session_cluster_event_watch "$cluster_dir"

  assert_contains "atomic-watch-namespace -n default get events --watch" "$call_log"
  assert_contains "atomic-watch-cluster get events --all-namespaces --watch" "$call_log"
  assert_not_contains "--resource-version" "$call_log"
  assert_not_contains "--watch-only" "$call_log"
  assert_not_contains "--request-timeout" "$call_log"
  [[ "$(grep -c '^atomic-watch-namespace ' "$call_log")" == "1" ]] \
    || fail "namespace event watcher reconnected after its completed atomic watch"
  [[ "$(grep -c '^atomic-watch-cluster ' "$call_log")" == "1" ]] \
    || fail "cluster event watcher reconnected after its completed atomic watch"
  assert_contains "atomic-namespace-event" "$namespace_dir/events.log"
  assert_contains "atomic-cluster-event" "$cluster_dir/events-cluster.log"
  if find "$namespace_dir" "$cluster_dir" -name '*.snapshot' -print -quit | grep -q .; then
    fail "atomic event watcher unexpectedly created a manual snapshot handoff file"
  fi
)

test_launch_snapshot_captures_dependency_diagnostics_without_secrets() (
  export VICTORIA_METRICS_NAMESPACE=vm-shared
  export VICTORIA_METRICS_OPERATOR_NAMESPACE=vm-operator
  source "$kubeton"

  local destination="$test_dir/dependency-snapshot"
  local kubectl_log="$test_dir/dependency-snapshot-kubectl.log"
  OP_NAMESPACE=operator-ns
  LONGHORN_NAMESPACE=longhorn-ns
  VAULT_NAMESPACE=vault-ns
  : >"$kubectl_log"

  victoria_logs_namespace() { printf '%s' vm-shared; }
  run_with_timeout() {
    shift
    "$@"
  }
  kubectl() {
    printf '%s\n' "$*" >>"$kubectl_log"
    if [[ " $* " == *" get secret "* \
      || " $* " == *" get secrets "* \
      || " $* " == *" get configmap "* \
      || " $* " == *" get configmaps "* ]]; then
      printf '%s\n' "FORBIDDEN-SECRET-OR-CONFIGMAP-READ $*" >>"$kubectl_log"
      return 97
    fi
    if [[ "$*" == *" get pods "* && "$*" == *" -o json"* ]]; then
      printf '%s\n' '{"items":[]}'
    else
      printf '%s\n' 'mocked diagnostic output'
    fi
  }

  launch_session_snapshot "$test_dir" default tonnode "$destination"
  for artifact in \
    events-cluster.txt \
    operator-diagnostics.txt \
    longhorn-diagnostics.txt \
    vault-diagnostics.txt \
    longhorn-storage.txt \
    victoria-vm-shared-diagnostics.txt \
    victoria-vm-shared-resources.txt \
    victoria-vm-operator-diagnostics.txt \
    victoria-vm-operator-resources.txt; do
    [[ -s "$destination/$artifact" ]] \
      || fail "launch snapshot did not retain $artifact"
  done
  assert_not_contains "FORBIDDEN-SECRET-OR-CONFIGMAP-READ" "$kubectl_log"
  [[ "$(grep -c 'get namespace vm-shared' "$kubectl_log")" == "1" ]] \
    || fail "duplicate Victoria namespaces were not deduplicated"
)

test_running_without_commit_is_extracting() (
  source "$kubeton"

  run_with_timeout() {
    shift
    "$@"
  }

  kubectl() {
    local args="$*"
    if [[ "$args" == *" get pod tonnode-0 "* ]]; then
      printf 'node-a\x1fRunning\x1fTrue\x1f\x1f\x1f0\x1f\x1f'
      return 0
    fi
    if [[ "$args" == *" exec tonnode-0 "* && "$args" == *"test -f /var/ton-work/db/mtc_done"* ]]; then
      return 1
    fi
    if [[ "$args" == *" exec tonnode-0 "* && "$args" == *"ps -eo args"* ]]; then
      printf '%s\n' extracting
      return 0
    fi
    return 1
  }

  local row state detail
  row="$(ton_pod_initial_bootstrap_state default tonnode-0)"
  IFS=$'\x1f' read -r state _ _ _ _ detail <<<"$row"
  [[ "$state" == "extracting" ]] || fail "Running pod without mtc_done was reported as '$state', expected extracting"
  [[ "$detail" == *"mtc_done is not committed"* ]] || fail "missing uncommitted-bootstrap detail"
)

test_scheduled_pending_pod_reports_attach_failure() (
  source "$kubeton"

  run_with_timeout() {
    shift
    "$@"
  }
  kubectl() {
    local args="$*"
    if [[ "$args" == *" get pod tonnode-0 "* ]]; then
      # The scheduler selected node-a, but no container status exists because
      # kubelet cannot attach the volume.
      printf 'node-a\x1fPending\x1fTrue\x1f\x1f\x1f\x1f\x1f'
      return 0
    fi
    if [[ "$args" == *" get events "* ]]; then
      printf '%s\n' 'FailedAttachVolume AttachVolume.Attach failed for volume "pvc-123": CSINode node-a does not contain driver driver.longhorn.io'
      return 0
    fi
    return 1
  }

  local row state node detail
  row="$(ton_pod_initial_bootstrap_state default tonnode-0)"
  IFS=$'\x1f' read -r state node _ _ _ detail <<<"$row"
  [[ "$state" == "FailedAttachVolume" ]] \
    || fail "scheduled Pending pod was reported as '$state', expected FailedAttachVolume"
  [[ "$node" == "node-a" ]] || fail "scheduled Pending pod lost its assigned node"
  [[ "$detail" == *'AttachVolume.Attach failed for volume "pvc-123"'* ]] \
    || fail "FailedAttachVolume state lost the Warning event message"
  [[ "$detail" == *"does not contain driver driver.longhorn.io"* ]] \
    || fail "FailedAttachVolume state truncated the Warning event cause"
)

test_bootstrap_wait_requires_every_replica() (
  export KUBETON_START_STATUS_INTERVAL_SECONDS=1
  export KUBETON_START_FATAL_RESTART_COUNT=5
  source "$kubeton"

  local calls_file="$test_dir/bootstrap.calls"
  : >"$calls_file"
  ton_pod_initial_bootstrap_state() {
    local pod="$2"
    printf '%s\n' "$pod" >>"$calls_file"
    if [[ "$pod" == "tonnode-0" ]]; then
      printf 'complete\x1fnode-a\x1f0\x1f\x1f\x1fcommitted'
    elif [[ "$(grep -c '^tonnode-1$' "$calls_file")" -eq 1 ]]; then
      printf 'extracting\x1fnode-b\x1f0\x1f\x1f\x1fmtc_done is not committed yet'
    else
      printf 'complete\x1fnode-b\x1f0\x1f\x1f\x1fcommitted'
    fi
  }
  sleep() { :; }

  wait_ton_initial_bootstrap_complete default tonnode 2 3 >"$test_dir/bootstrap.out" 2>&1
  assert_contains "state=extracting" "$test_dir/bootstrap.out"
  assert_contains "All 2 TON replica(s) committed" "$test_dir/bootstrap.out"
  [[ "$(grep -c '^tonnode-1$' "$calls_file")" -ge 2 ]] \
    || fail "bootstrap wait returned before the second replica committed"
)

test_bootstrap_wait_fails_repeated_crashloop() (
  export KUBETON_START_STATUS_INTERVAL_SECONDS=1
  export KUBETON_START_FATAL_RESTART_COUNT=5
  source "$kubeton"

  ton_pod_initial_bootstrap_state() {
    printf 'CrashLoopBackOff\x1fnode-a\x1f5\x1fCrashLoopBackOff\x1f64\x1fcontainer is waiting'
  }
  sleep() { :; }

  if wait_ton_initial_bootstrap_complete default tonnode 1 3 >"$test_dir/crashloop.out" 2>&1; then
    fail "bootstrap wait accepted a deterministic CrashLoopBackOff"
  fi
  assert_contains "repeatedly failed with a deterministic non-zero exit" "$test_dir/crashloop.out"
)

test_victoria_logs_requires_ready_collector_per_selected_node() (
  source "$kubeton"
  local coverage_mode=current

  kubectl() {
    local args="$*"
    if [[ "$args" == *" get daemonset collector-victoria-logs-collector "* ]]; then
      printf '7\x1f7\x1fds-current-uid\x1f2\x1f2\x1f0'
      return 0
    fi
    if [[ "$args" == *" get controllerrevision "* ]]; then
      # The newest revision for this exact DaemonSet UID is currenthash.
      # Higher revisions owned by another DaemonSet instance must be ignored.
      printf 'DaemonSet\x1fcollector-victoria-logs-collector\x1fds-current-uid\x1ftrue\x1f1\x1fcollector-victoria-logs-collector-oldhash\n'
      printf 'DaemonSet\x1fcollector-victoria-logs-collector\x1fds-current-uid\x1ftrue\x1f2\x1fcollector-victoria-logs-collector-currenthash\n'
      printf 'DaemonSet\x1fcollector-victoria-logs-collector\x1fstale-ds-uid\x1ftrue\x1f99\x1fcollector-victoria-logs-collector-stalehash\n'
      return 0
    fi
    if [[ "$args" == get\ nodes\ -l* ]]; then
      printf '%s\n' node/node-a node/node-b
      return 0
    fi
    if [[ "$args" == *"--field-selector spec.nodeName=node-a"* ]]; then
      if [[ "$coverage_mode" == "old" ]]; then
        printf 'oldhash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-victoria-logs-collector\x1fds-current-uid\n'
      else
        printf 'currenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-victoria-logs-collector\x1fds-current-uid\n'
      fi
      return 0
    fi
    if [[ "$args" == *"--field-selector spec.nodeName=node-b"* ]]; then
      if [[ "$coverage_mode" != "missing" ]]; then
        if [[ "$coverage_mode" == "old" ]]; then
          printf 'oldhash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-victoria-logs-collector\x1fds-current-uid\n'
        else
          printf 'currenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-victoria-logs-collector\x1fds-current-uid\n'
        fi
      fi
      return 0
    fi
    return 1
  }

  victoria_logs_collector_ready_on_selected_nodes vm collector 'ton-ready=true' \
    >"$test_dir/coverage-complete.out" 2>&1
  coverage_mode=old
  if victoria_logs_collector_ready_on_selected_nodes vm collector 'ton-ready=true' \
      >"$test_dir/coverage-old-revision.out" 2>&1; then
    fail "collector coverage accepted Ready Pods from the previous ControllerRevision"
  fi
  assert_contains "node-a has no Ready VictoriaLogs collector" "$test_dir/coverage-old-revision.out"
  coverage_mode=missing
  if victoria_logs_collector_ready_on_selected_nodes vm collector 'ton-ready=true' \
      >"$test_dir/coverage-missing.out" 2>&1; then
    fail "collector coverage succeeded without a Ready collector on node-b"
  fi
  assert_contains "node-b has no Ready VictoriaLogs collector" "$test_dir/coverage-missing.out"
)

test_clusterwide_collector_verify_requires_current_complete_rollout() (
  export KUBETON_START_VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_ENABLED=true
  source "$kubeton"

  local mode=complete
  local call_log="$test_dir/clusterwide-collector-verify.calls"
  local failed_mode desired_for_mode
  : >"$call_log"

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  victoria_logs_collector_daemonset_name() { printf '%s' collector-ds; }
  kubectl() {
    local args="$*"
    if [[ "$args" == *" get daemonset collector-ds "* && "$args" == *".metadata.uid"* ]]; then
      case "$mode" in
        terminating-pod|old-revision|wrong-owner) desired_for_mode=1 ;;
        duplicate-node|misscheduled-target) desired_for_mode=2 ;;
        *) desired_for_mode=3 ;;
      esac
      printf 'identity-%s\n' "$mode" >>"$call_log"
      if [[ "$mode" == "misscheduled-target" ]]; then
        printf '9\x1f9\x1fcollector-ds-uid\x1f2\x1f1\x1f1'
      else
        printf '9\x1f9\x1fcollector-ds-uid\x1f%s\x1f%s\x1f0' \
          "$desired_for_mode" "$desired_for_mode"
      fi
      return 0
    fi
    if [[ "$args" == *" get daemonset collector-ds "* ]]; then
      printf 'aggregate-%s\n' "$mode" >>"$call_log"
      case "$mode" in
        complete)          printf '9\x1f9\x1f3\x1f3\x1f3\x1f3' ;;
        stale-generation)  printf '9\x1f8\x1f3\x1f3\x1f3\x1f3' ;;
        stale-updated)     printf '9\x1f9\x1f3\x1f2\x1f3\x1f3' ;;
        stale-ready)       printf '9\x1f9\x1f3\x1f3\x1f2\x1f3' ;;
        stale-available)   printf '9\x1f9\x1f3\x1f3\x1f3\x1f2' ;;
        terminating-pod|old-revision|wrong-owner)
                           printf '9\x1f9\x1f1\x1f1\x1f1\x1f1' ;;
        duplicate-node)    printf '9\x1f9\x1f2\x1f2\x1f2\x1f2' ;;
        misscheduled-target)
                           printf '9\x1f9\x1f2\x1f2\x1f2\x1f2' ;;
      esac
      return 0
    fi
    if [[ "$args" == *" get controllerrevision "* ]]; then
      printf 'revision-%s\n' "$mode" >>"$call_log"
      printf 'DaemonSet\x1fcollector-ds\x1fcollector-ds-uid\x1ftrue\x1f1\x1fcollector-ds-oldhash\n'
      printf 'DaemonSet\x1fcollector-ds\x1fcollector-ds-uid\x1ftrue\x1f2\x1fcollector-ds-currenthash\n'
      return 0
    fi
    if [[ "$args" == *" get pods "* ]]; then
      printf 'pods-%s\n' "$mode" >>"$call_log"
      case "$mode" in
        complete)
          printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          printf 'node-b\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          printf 'node-c\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          # Invalid decoys must not inflate the unique current-owner count.
          printf 'node-z\x1foldhash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          printf 'node-y\x1fcurrenthash\x1fRunning\x1fterminating\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          ;;
        terminating-pod)
          printf 'node-a\x1fcurrenthash\x1fRunning\x1fterminating\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          ;;
        duplicate-node)
          printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          ;;
        old-revision)
          printf 'node-a\x1foldhash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          ;;
        wrong-owner)
          printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fstale-owner-uid\n'
          ;;
        misscheduled-target)
          printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          printf 'node-c\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
          ;;
      esac
      return 0
    fi
    return 1
  }

  KUBETON_NODE_CHECK_TON_SELECTOR=""
  verify_start_victoria_logs_collection_ready \
    >"$test_dir/clusterwide-complete.out" 2>&1
  assert_contains "Ready on every DaemonSet target (3/3)" "$test_dir/clusterwide-complete.out"

  for failed_mode in stale-generation stale-updated stale-ready stale-available; do
    mode="$failed_mode"
    if verify_start_victoria_logs_collection_ready \
        >"$test_dir/clusterwide-${failed_mode}.out" 2>&1; then
      fail "cluster-wide verification accepted ${failed_mode} collector rollout status"
    fi
    assert_contains "refusing to create TON pods with incomplete restart-log coverage" \
      "$test_dir/clusterwide-${failed_mode}.out"
  done
  for failed_mode in terminating-pod duplicate-node old-revision wrong-owner; do
    mode="$failed_mode"
    if verify_start_victoria_logs_collection_ready \
        >"$test_dir/clusterwide-${failed_mode}.out" 2>&1; then
      fail "cluster-wide verification accepted ${failed_mode} collector coverage"
    fi
    assert_contains "only" "$test_dir/clusterwide-${failed_mode}.out"
    assert_contains "non-terminating Ready VictoriaLogs collector of the current revision" \
      "$test_dir/clusterwide-${failed_mode}.out"
  done
  mode=misscheduled-target
  if verify_start_victoria_logs_collection_ready \
      >"$test_dir/clusterwide-misscheduled-target.out" 2>&1; then
    fail "cluster-wide verification trusted valid-looking Pods on a stale/misscheduled DaemonSet target set"
  fi
  assert_contains "target set is not current (current=1, desired=2, misscheduled=1)" \
    "$test_dir/clusterwide-misscheduled-target.out"
  assert_not_contains "pods-misscheduled-target" "$call_log"
  [[ "$(grep -c '^aggregate-' "$call_log")" == "10" ]] \
    || fail "cluster-wide verification did not obtain exactly one aggregate DaemonSet row per check"
  [[ "$(grep -c '^identity-' "$call_log")" == "6" ]] \
    || fail "aggregate-stale rollouts unexpectedly proceeded to exact Pod identity checks"
)

test_unconstrained_ton_rejects_restricted_collector_before_daemonset_query() (
  export KUBETON_START_VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR='logs-only=true'
  source "$kubeton"

  local query_log="$test_dir/restricted-collector-unconstrained-ton.queries"
  : >"$query_log"
  KUBETON_NODE_CHECK_TON_SELECTOR=""
  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  victoria_logs_collector_ready_on_selected_nodes() {
    printf 'selected-node-probe %s\n' "$*" >>"$query_log"
    return 0
  }
  kubectl() {
    printf 'kubectl %s\n' "$*" >>"$query_log"
    return 0
  }

  if verify_start_victoria_logs_collection_ready \
      >"$test_dir/restricted-collector-unconstrained-ton.out" \
      2>"$test_dir/restricted-collector-unconstrained-ton.stderr"; then
    fail "unconstrained TON placement trusted a selector-restricted collector"
  fi
  [[ ! -s "$query_log" ]] \
    || fail "restricted collector mismatch was not rejected before DaemonSet/node queries"
  assert_contains \
    "TON placement is unconstrained but VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR restricts log collection" \
    "$test_dir/restricted-collector-unconstrained-ton.stderr"
)

test_victoria_logs_helm_durability_settings() (
  export VICTORIA_LOGS_STORAGE_CLASS=""
  export VICTORIA_LOGS_NODE_SELECTOR=""
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR=""
  export LONGHORN_NODE_SELECTOR=""
  export VICTORIA_LOGS_RETENTION_DISK_SPACE=7GB
  export VICTORIA_LOGS_COLLECTOR_BUFFER_SIZE=3GB
  export VICTORIA_LOGS_COLLECTOR_CPU_REQUEST=125m
  export VICTORIA_LOGS_COLLECTOR_MEMORY_REQUEST=192Mi
  export VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_REQUEST=384Mi
  export VICTORIA_LOGS_COLLECTOR_CPU_LIMIT=2
  export VICTORIA_LOGS_COLLECTOR_MEMORY_LIMIT=2Gi
  export VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_LIMIT=4Gi
  source "$kubeton"

  local helm_log="$test_dir/victoria-helm.log"
  : >"$helm_log"
  cluster_is_k3d() { return 0; }
  ensure_namespace() { :; }
  ensure_helm_repo() { :; }
  victoria_logs_service_name() { printf '%s' vlogs-server; }
  victoria_logs_collector_daemonset_name() { printf '%s' vlogs-collector; }
  ensure_victoria_logs_access_service() { printf '%s' vlogs-access; }
  build_victoria_logs_collector_selector_values_file() {
    fail "default cluster-wide collector unexpectedly received a node-selector overlay"
  }
  run_with_timeout() {
    shift
    "$@"
  }
  helm() {
    printf '%s\n' "$*" >>"$helm_log"
  }
  kubectl() {
    local args="$*"
    if [[ "$args" == "get storageclass longhorn" ]]; then
      return 1
    fi
    if [[ "$args" == *" rollout status "* ]]; then
      return 0
    fi
    if [[ "$args" == *" get daemonset vlogs-collector "* && "$args" == *"metadata.generation"* ]]; then
      printf '5\x1f5\x1fds-vlogs-uid\x1f4\x1f4\x1f0'
      return 0
    fi
    if [[ "$args" == *" get daemonset vlogs-collector "* && "$args" == *"desiredNumberScheduled"* ]]; then
      printf '%s' 4
      return 0
    fi
    if [[ "$args" == *" get daemonset vlogs-collector "* && "$args" == *"numberReady"* ]]; then
      printf '%s' 3
      return 0
    fi
    if [[ "$args" == *" get controllerrevision "* ]]; then
      printf 'DaemonSet\x1fvlogs-collector\x1fds-vlogs-uid\x1ftrue\x1f4\x1fvlogs-collector-currenthash\n'
      return 0
    fi
    if [[ "$args" == get\ nodes\ -l\ ton-ready=true* ]]; then
      printf '%s\n' node/node-a node/node-b
      return 0
    fi
    if [[ "$args" == *" get pods "* && "$args" == *"spec.nodeName=node-a"* ]]; then
      printf 'currenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/vlogs-collector\x1fds-vlogs-uid\n'
      return 0
    fi
    if [[ "$args" == *" get pods "* && "$args" == *"spec.nodeName=node-b"* ]]; then
      printf 'currenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/vlogs-collector\x1fds-vlogs-uid\n'
      return 0
    fi
    return 1
  }

  KUBETON_NODE_CHECK_TON_SELECTOR="ton-ready=true"
  ensure_victoria_logs_stack vm vlogs collector 9428 11d 12Gi 60 60 \
    >"$test_dir/victoria.out" 2>"$test_dir/victoria.stderr"
  assert_contains "server.retentionPeriod=11d" "$helm_log"
  assert_contains "server.persistentVolume.size=12Gi" "$helm_log"
  assert_contains "server.retentionDiskSpaceUsage=7GB" "$helm_log"
  assert_contains "remoteWrite[0].maxDiskUsagePerURL=3GB" "$helm_log"
  assert_contains "resources.requests.cpu=125m" "$helm_log"
  assert_contains "resources.requests.memory=192Mi" "$helm_log"
  assert_contains "resources.requests.ephemeral-storage=384Mi" "$helm_log"
  assert_contains "resources.limits.cpu=2" "$helm_log"
  assert_contains "resources.limits.memory=2Gi" "$helm_log"
  assert_contains "resources.limits.ephemeral-storage=4Gi" "$helm_log"
  assert_contains "extraArgs.tmpDataPath=/var/lib/kubeton-vlogs-buffer-vm-collector" "$helm_log"
  assert_contains "persistence.volume.hostPath.path=/var/lib/kubeton-vlogs-buffer-vm-collector" "$helm_log"
  assert_contains "persistence.volume.hostPath.type=DirectoryOrCreate" "$helm_log"
  assert_contains "readiness is 3/4" "$test_dir/victoria.stderr"
  assert_contains "Ready on every selected TON node" "$test_dir/victoria.stderr"
  assert_not_contains "nodeSelector" "$helm_log"
  if grep -F "upgrade --install collector " "$helm_log" | grep -Fq -- " --wait "; then
    fail "cluster-wide VictoriaLogs collector Helm upgrade waits for unrelated nodes"
  fi
)

test_victoria_logs_collector_buffer_path_matches_early_and_full_install() (
  export KUBETON_START_VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_STORAGE_CLASS=""
  export VICTORIA_LOGS_NODE_SELECTOR=""
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR=""
  export LONGHORN_NODE_SELECTOR=""
  source "$kubeton"

  local helm_log="$test_dir/victoria-buffer-path.helm"
  local expected_path=/var/lib/kubeton-vlogs-buffer-logs-ns-collector-release
  local -a observed_paths=()
  : >"$helm_log"

  require_bin() { :; }
  cluster_is_k3d() { return 0; }
  ensure_namespace() { :; }
  ensure_helm_repo() { :; }
  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  victoria_logs_service_name() { printf '%s' backend-statefulset; }
  victoria_logs_access_service_name() { printf '%s' future-access; }
  victoria_logs_collector_daemonset_name() { printf '%s' collector-ds; }
  resolve_victoria_metrics_rollout_timeout_seconds() { printf '%s' 60; }
  resolve_victoria_logs_helm_timeout_seconds() { printf '%s' 60; }
  wait_victoria_logs_collector_ready_on_selected_nodes() { :; }
  write_victoria_logs_state() { :; }
  ensure_victoria_logs_access_service() { printf '%s' future-access; }
  run_with_timeout() {
    shift
    "$@"
  }
  helm() {
    printf '%s\n' "$*" >>"$helm_log"
  }
  kubectl() {
    local args="$*"
    if [[ "$args" == "get storageclass longhorn" ]]; then
      return 1
    fi
    if [[ "$args" == *" rollout status "* ]]; then
      return 0
    fi
    if [[ "$args" == *" get daemonset collector-ds "* && "$args" == *"desiredNumberScheduled"* ]]; then
      printf '%s' 1
      return 0
    fi
    if [[ "$args" == *" get daemonset collector-ds "* && "$args" == *"numberReady"* ]]; then
      printf '%s' 1
      return 0
    fi
    return 1
  }

  KUBETON_NODE_CHECK_TON_SELECTOR="ton-ready=true"
  ensure_start_victoria_logs_buffering_collector \
    >"$test_dir/victoria-buffer-early.out" 2>"$test_dir/victoria-buffer-early.stderr"
  ensure_victoria_logs_stack logs-ns backend-release collector-release 9428 11d 12Gi 60 60 \
    >"$test_dir/victoria-buffer-full.out" 2>"$test_dir/victoria-buffer-full.stderr"

  mapfile -t observed_paths < <(
    grep -F 'upgrade --install collector-release ' "$helm_log" \
      | sed -n 's#.*extraArgs\.tmpDataPath=\([^ ]*\).*#\1#p'
  )
  [[ "${#observed_paths[@]}" == "2" ]] \
    || fail "expected early and full collector Helm installs, got ${#observed_paths[@]}"
  [[ "${observed_paths[0]}" == "$expected_path" ]] \
    || fail "early collector used '${observed_paths[0]}', expected '$expected_path'"
  [[ "${observed_paths[1]}" == "$expected_path" ]] \
    || fail "full collector used '${observed_paths[1]}', expected '$expected_path'"
  [[ "$(grep -Fc "persistence.volume.hostPath.path=${expected_path}" "$helm_log")" == "2" ]] \
    || fail "early and full collectors did not mount the identical release-specific host buffer"
  [[ "$(grep -Fc 'persistence.volume.hostPath.type=DirectoryOrCreate' "$helm_log")" == "2" ]] \
    || fail "early and full collector hostPath mounts are not created on fresh nodes"
  [[ "$(grep -Fc 'remoteWrite[0].url=http://future-access:9428' "$helm_log")" == "2" ]] \
    || fail "early and full collector installs did not target the same future access Service"
)

test_prebootstrap_collector_is_ready_before_storage_bootstrap() (
  export KUBETON_START_VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_ENABLED=true
  export KUBETON_SKIP_NODE_PREREQ_CHECK=true
  export KUBETON_START_WAIT_FOR_BOOTSTRAP=false
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR=""
  source "$kubeton"

  local mode=success
  local selector_file="$test_dir/prebootstrap-selector.yaml"
  local success_events="$test_dir/prebootstrap-success.events"
  local failure_events="$test_dir/prebootstrap-failure.events"
  local state_failure_events="$test_dir/prebootstrap-state-failure.events"
  local readiness_failure_events="$test_dir/prebootstrap-readiness-failure.events"
  local misscheduled_failure_events="$test_dir/prebootstrap-misscheduled-readiness.events"
  local namespace_line state_line
  : >"$selector_file"
  : >"$success_events"
  : >"$failure_events"
  : >"$state_failure_events"
  : >"$readiness_failure_events"
  : >"$misscheduled_failure_events"

  record_prebootstrap_event() {
    printf '%s\n' "$1" >>"$test_dir/prebootstrap-${mode}.events"
  }
  require_bin() { :; }
  resolve_ton_replicas_from_values_file() { printf '%s' 1; }
  should_bootstrap_baremetal() { return 0; }
  cluster_is_k3d() { return 0; }
  longhorn_manager_exists() { return 1; }
  storage_class_is_longhorn() { return 1; }
  prepare_node_prerequisites_for_workload() {
    KUBETON_NODE_CHECK_REQUIRED_NODES=1
    if [[ "$mode" == "misscheduled-readiness" ]]; then
      KUBETON_NODE_CHECK_TON_SELECTOR=""
    else
      KUBETON_NODE_CHECK_TON_SELECTOR="ton-ready=true"
    fi
    record_prebootstrap_event node-preflight
  }
  build_ton_node_selector_values_file() { printf '%s' "$selector_file"; }
  fleet_has_stop_annotations() { return 1; }
  ensure_ton_storage_class_available() { :; }
  append_ton_storage_overrides() { :; }
  should_use_sequential_ton_start() { return 1; }
  append_baremetal_key_overrides() { :; }
  ensure_auto_bootstrap_stack() { record_prebootstrap_event storage-bootstrap; }
  ensure_start_victoria_logs() { record_prebootstrap_event full-logging-stack; }
  delete_stale_ton_pvcs_before_fresh_start() { record_prebootstrap_event stale-pvc-cleanup; }
  verify_start_victoria_logs_collection_ready() { record_prebootstrap_event final-log-coverage; }
  append_helm_force_conflicts_if_supported() { :; }
  repair_pending_ton_placement_after_start() { :; }

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  victoria_logs_access_service_name() { printf '%s' future-access; }
  victoria_logs_collector_daemonset_name() { printf '%s' collector-ds; }
  resolve_victoria_metrics_rollout_timeout_seconds() { printf '%s' 60; }
  resolve_victoria_logs_helm_timeout_seconds() { printf '%s' 60; }
  ensure_namespace() { record_prebootstrap_event collector-namespace; }
  ensure_helm_repo() { record_prebootstrap_event collector-repository; }
  write_victoria_logs_state() {
    record_prebootstrap_event collector-state-persisted
    if [[ "$1" != "$OP_NAMESPACE" \
      || "$2" != "logs-ns" \
      || "$3" != "backend-release" \
      || "$4" != "collector-release" \
      || "$5" != "future-access" \
      || "$6" != "collector-ds" ]]; then
      record_prebootstrap_event collector-state-arguments-invalid
      return 1
    fi
    [[ "$mode" != "state-failure" ]]
  }
  wait_victoria_logs_collector_ready_on_selected_nodes() {
    if [[ "$mode" == "readiness-failure" ]]; then
      record_prebootstrap_event collector-readiness-failed
      return 1
    fi
    victoria_logs_collector_ready_on_selected_nodes "$1" "$2" "$3"
  }
  run_with_timeout() {
    shift
    "$@"
  }
  helm() {
    local args="$*"
    if [[ "$args" == *"upgrade --install collector-release "* ]]; then
      record_prebootstrap_event collector-helm
      printf '%s\n' "$args" >>"$test_dir/prebootstrap-${mode}.helm"
      [[ "$mode" != "failure" ]]
      return
    fi
    if [[ "$args" == "repo update vm" ]]; then
      record_prebootstrap_event collector-repo-update
      return 0
    fi
    if [[ "$args" == upgrade\ * ]]; then
      record_prebootstrap_event ton-helm
      return 0
    fi
    return 0
  }
  kubectl() {
    local args="$*"
    if [[ "$args" == *" get service future-access"* ]]; then
      record_prebootstrap_event future-service-absent
      return 1
    fi
    if [[ "$args" == *" get daemonset collector-ds "* ]]; then
      record_prebootstrap_event collector-generation-observed
      if [[ "$mode" == "misscheduled-readiness" ]]; then
        printf '4\x1f4\x1fcollector-ds-uid\x1f2\x1f1\x1f1'
      else
        printf '4\x1f4\x1fcollector-ds-uid\x1f1\x1f1\x1f0'
      fi
      return 0
    fi
    if [[ "$args" == *" get controllerrevision "* ]]; then
      record_prebootstrap_event collector-current-revision
      printf 'DaemonSet\x1fcollector-ds\x1fcollector-ds-uid\x1ftrue\x1f1\x1fcollector-ds-oldhash\n'
      printf 'DaemonSet\x1fcollector-ds\x1fcollector-ds-uid\x1ftrue\x1f2\x1fcollector-ds-currenthash\n'
      return 0
    fi
    if [[ "$args" == get\ nodes\ -l\ ton-ready=true* ]]; then
      printf '%s\n' node/node-a
      return 0
    fi
    if [[ "$mode" == "misscheduled-readiness" && "$args" == *" get pods "* ]]; then
      record_prebootstrap_event misscheduled-pods-listed
      printf 'node-a\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
      printf 'node-c\x1fcurrenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
      return 0
    fi
    if [[ "$args" == *" get pods "* && "$args" == *"spec.nodeName=node-a"* ]]; then
      record_prebootstrap_event collector-current-pod-ready
      printf 'currenthash\x1fRunning\x1f\x1fready\x1fDaemonSet/collector-ds\x1fcollector-ds-uid\n'
      return 0
    fi
    return 1
  }

  # Model a fresh cluster: the access Service is not present yet. The early
  # collector must still install and buffer against its future DNS name.
  if kubectl -n logs-ns get service future-access >/dev/null 2>&1; then
    fail "future VictoriaLogs access Service unexpectedly exists in the test model"
  fi
  run_start >"$test_dir/prebootstrap-success.out" 2>&1
  assert_order "collector-namespace" "collector-state-persisted" "$success_events"
  assert_order "collector-state-persisted" "collector-repository" "$success_events"
  assert_order "collector-repository" "collector-helm" "$success_events"
  assert_order "collector-helm" "collector-generation-observed" "$success_events"
  assert_order "collector-generation-observed" "collector-current-revision" "$success_events"
  assert_order "collector-current-revision" "collector-current-pod-ready" "$success_events"
  assert_order "collector-current-pod-ready" "storage-bootstrap" "$success_events"
  assert_order "storage-bootstrap" "full-logging-stack" "$success_events"
  namespace_line="$(grep -n -F 'collector-namespace' "$success_events" | cut -d: -f1)"
  state_line="$(grep -n -F 'collector-state-persisted' "$success_events" | cut -d: -f1)"
  (( state_line == namespace_line + 1 )) \
    || fail "pre-bootstrap collector intent was not persisted immediately after namespace creation"
  assert_not_contains "collector-state-arguments-invalid" "$success_events"
  [[ "$(grep -c '^future-service-absent$' "$success_events")" == "1" ]] \
    || fail "pre-bootstrap collector unexpectedly depended on the absent future access Service"
  assert_contains "remoteWrite[0].url=http://future-access:9428" "$test_dir/prebootstrap-success.helm"
  assert_contains "persistence.volume.hostPath.path=/var/lib/kubeton-vlogs-buffer-logs-ns-collector-release" "$test_dir/prebootstrap-success.helm"
  assert_contains "persistence.volume.hostPath.type=DirectoryOrCreate" "$test_dir/prebootstrap-success.helm"

  mode=failure
  : >"$selector_file"
  if run_start >"$test_dir/prebootstrap-failure.out" 2>&1; then
    fail "run_start continued after the pre-bootstrap collector Helm install failed"
  fi
  assert_order "collector-namespace" "collector-state-persisted" "$failure_events"
  assert_order "collector-state-persisted" "collector-repository" "$failure_events"
  assert_order "collector-repository" "collector-helm" "$failure_events"
  assert_contains "collector-helm" "$failure_events"
  assert_contains "collector-state-persisted" "$failure_events"
  assert_not_contains "collector-generation-observed" "$failure_events"
  assert_not_contains "storage-bootstrap" "$failure_events"
  assert_not_contains "full-logging-stack" "$failure_events"
  assert_not_contains "ton-helm" "$failure_events"
  assert_contains "storage/key bootstrap was not started" "$test_dir/prebootstrap-failure.out"

  mode=state-failure
  : >"$selector_file"
  if run_start >"$test_dir/prebootstrap-state-failure.out" 2>&1; then
    fail "run_start continued after pre-bootstrap VictoriaLogs state persistence failed"
  fi
  assert_order "collector-namespace" "collector-state-persisted" "$state_failure_events"
  assert_not_contains "collector-state-arguments-invalid" "$state_failure_events"
  assert_not_contains "collector-repository" "$state_failure_events"
  assert_not_contains "collector-helm" "$state_failure_events"
  assert_not_contains "collector-generation-observed" "$state_failure_events"
  assert_not_contains "storage-bootstrap" "$state_failure_events"
  assert_not_contains "full-logging-stack" "$state_failure_events"
  assert_not_contains "ton-helm" "$state_failure_events"

  mode=readiness-failure
  : >"$selector_file"
  if run_start >"$test_dir/prebootstrap-readiness-failure.out" 2>&1; then
    fail "run_start continued after pre-bootstrap collector readiness failed"
  fi
  assert_order "collector-namespace" "collector-state-persisted" "$readiness_failure_events"
  assert_order "collector-state-persisted" "collector-helm" "$readiness_failure_events"
  assert_order "collector-helm" "collector-readiness-failed" "$readiness_failure_events"
  assert_not_contains "collector-state-arguments-invalid" "$readiness_failure_events"
  assert_not_contains "storage-bootstrap" "$readiness_failure_events"
  assert_not_contains "full-logging-stack" "$readiness_failure_events"
  assert_not_contains "ton-helm" "$readiness_failure_events"

  mode=misscheduled-readiness
  : >"$selector_file"
  if run_start >"$test_dir/prebootstrap-misscheduled-readiness.out" 2>&1; then
    fail "run_start accepted a misscheduled pre-bootstrap collector target set"
  fi
  assert_order "collector-state-persisted" "collector-helm" "$misscheduled_failure_events"
  assert_order "collector-helm" "collector-generation-observed" "$misscheduled_failure_events"
  assert_contains "collector-current-revision" "$misscheduled_failure_events"
  assert_not_contains "misscheduled-pods-listed" "$misscheduled_failure_events"
  assert_not_contains "storage-bootstrap" "$misscheduled_failure_events"
  assert_not_contains "full-logging-stack" "$misscheduled_failure_events"
  assert_not_contains "ton-helm" "$misscheduled_failure_events"
  assert_contains "target set is not current (current=1, desired=2, misscheduled=1)" \
    "$test_dir/prebootstrap-misscheduled-readiness.out"
)

test_failed_victoria_logs_cleanup_retains_guards_and_generic_sweep_excludes_them() (
  source "$kubeton"

  local kubectl_log="$test_dir/vlogs-cleanup-failed.kubectl"
  local access_selector='app.kubernetes.io/part-of=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton'
  : >"$kubectl_log"
  OP_NAMESPACE=operator-ns
  VICTORIA_LOGS_NAMESPACE=logs-ns
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=0

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  read_victoria_logs_state_value() {
    case "$2" in
      namespace) printf '%s' logs-ns ;;
      releaseName) printf '%s' backend-release ;;
      collectorReleaseName) printf '%s' collector-release ;;
    esac
  }
  collect_victoria_logs_release_rows() { :; }
  collect_pvc_rows_by_prefix() { :; }
  wait_victoria_logs_backend_gone() { return 1; }
  cleanup_victoria_logs_port_forwards() { :; }
  helm() { :; }
  kubectl() {
    printf '%s\n' "$*" >>"$kubectl_log"
    if [[ "$*" == "-n operator-ns get configmap $VICTORIA_LOGS_STATE_CONFIGMAP" ]]; then
      return 0
    fi
    if [[ "$*" == "api-resources --verbs=list --namespaced=true -o name" ]]; then
      printf '%s\n' configmaps networkpolicies.networking.k8s.io services
      return 0
    fi
    if [[ "$*" == "api-resources --verbs=list --namespaced=false -o name" ]]; then
      return 0
    fi
    return 0
  }

  if cleanup_victoria_logs_resources \
      >"$test_dir/vlogs-cleanup-failed.out" 2>"$test_dir/vlogs-cleanup-failed.stderr"; then
    fail "stalled VictoriaLogs backend cleanup reported success"
  fi
  [[ "$KUBETON_RETAIN_VICTORIA_LOGS_GUARDS" == "1" ]] \
    || fail "failed VictoriaLogs cleanup did not enable guard retention"
  assert_contains "delete service -A -l $access_selector" "$kubectl_log"
  assert_not_contains "delete networkpolicy -A -l $access_selector" "$kubectl_log"
  assert_not_contains "delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-logs" "$kubectl_log"

  cleanup_kubeton_managed_labeled_resources \
    >"$test_dir/vlogs-generic-sweep.out" 2>"$test_dir/vlogs-generic-sweep.stderr"
  assert_contains "delete configmaps -A -l app.kubernetes.io/managed-by=kubeton,app.kubernetes.io/part-of!=kubeton-victoria-logs" "$kubectl_log"
  assert_contains "delete networkpolicies.networking.k8s.io -A -l app.kubernetes.io/managed-by=kubeton,app.kubernetes.io/part-of!=kubeton-victoria-logs" "$kubectl_log"
  assert_not_contains "delete configmaps -A -l app.kubernetes.io/managed-by=kubeton --" "$kubectl_log"
  assert_not_contains "delete networkpolicies.networking.k8s.io -A -l app.kubernetes.io/managed-by=kubeton --" "$kubectl_log"
  assert_contains "release ledger and any still-needed ingress NetworkPolicy were retained" \
    "$test_dir/vlogs-cleanup-failed.stderr"
)

test_successful_victoria_logs_cleanup_removes_policy_and_state() (
  source "$kubeton"

  local lifecycle_log="$test_dir/vlogs-cleanup-success.lifecycle"
  local access_selector='app.kubernetes.io/part-of=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton'
  : >"$lifecycle_log"
  OP_NAMESPACE=operator-ns
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=0

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  read_victoria_logs_state_value() {
    case "$2" in
      namespace) printf '%s' logs-ns ;;
      releaseName) printf '%s' backend-release ;;
      collectorReleaseName) printf '%s' collector-release ;;
    esac
  }
  collect_victoria_logs_release_rows() { :; }
  collect_pvc_rows_by_prefix() {
    local -n rows_ref="$2"
    rows_ref+=("logs-ns"$'\t'"server-volume-backend-statefulset-0")
  }
  wait_victoria_logs_backend_gone() {
    printf '%s\n' backend-confirmed-gone >>"$lifecycle_log"
  }
  wait_victoria_logs_collector_gone() {
    printf '%s\n' collector-confirmed-gone >>"$lifecycle_log"
  }
  victoria_logs_helm_release_is_gone() {
    printf 'helm-release-confirmed-gone:%s/%s\n' "$1" "$2" >>"$lifecycle_log"
  }
  delete_pvc_rows_and_backing_volumes() {
    local -n rows_ref="$1"
    (( ${#rows_ref[@]} == 1 )) || return 1
    printf '%s\n' pvc-and-backing-storage-confirmed-gone >>"$lifecycle_log"
  }
  cleanup_victoria_logs_port_forwards() { :; }
  helm() { :; }
  kubectl() {
    printf 'kubectl %s\n' "$*" >>"$lifecycle_log"
    if [[ "$*" == "-n operator-ns get configmap $VICTORIA_LOGS_STATE_CONFIGMAP" ]]; then
      return 0
    fi
    return 0
  }

  cleanup_victoria_logs_resources \
    >"$test_dir/vlogs-cleanup-success.out" 2>"$test_dir/vlogs-cleanup-success.stderr"
  [[ "$KUBETON_RETAIN_VICTORIA_LOGS_GUARDS" == "0" ]] \
    || fail "successful VictoriaLogs cleanup retained its guard flag"
  assert_order "backend-confirmed-gone" "pvc-and-backing-storage-confirmed-gone" "$lifecycle_log"
  assert_order "collector-confirmed-gone" "pvc-and-backing-storage-confirmed-gone" "$lifecycle_log"
  assert_order "helm-release-confirmed-gone:logs-ns/collector-release" \
    "pvc-and-backing-storage-confirmed-gone" "$lifecycle_log"
  assert_order "helm-release-confirmed-gone:logs-ns/backend-release" \
    "pvc-and-backing-storage-confirmed-gone" "$lifecycle_log"
  assert_order "pvc-and-backing-storage-confirmed-gone" "kubectl delete networkpolicy -A -l $access_selector" "$lifecycle_log"
  assert_contains "kubectl delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton" "$lifecycle_log"
)

test_victoria_logs_cleanup_requires_collector_and_both_helm_identities_gone() (
  local scenario

  for scenario in collector-workload backend-helm-metadata collector-helm-metadata; do
    (
      source "$kubeton"

      local kubectl_log="$test_dir/vlogs-identity-${scenario}.kubectl"
      local release_from_selector=""
      : >"$kubectl_log"
      OP_NAMESPACE=operator-ns
      VICTORIA_LOGS_NAMESPACE=logs-ns
      KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=0

      victoria_logs_namespace() { printf '%s' logs-ns; }
      victoria_logs_release_name() { printf '%s' backend-release; }
      victoria_logs_collector_release_name() { printf '%s' collector-release; }
      read_victoria_logs_state_value() {
        case "$2" in
          namespace) printf '%s' logs-ns ;;
          releaseName) printf '%s' backend-release ;;
          collectorReleaseName) printf '%s' collector-release ;;
        esac
      }
      collect_victoria_logs_release_rows() { :; }
      collect_pvc_rows_by_prefix() { :; }
      delete_pvc_rows_and_backing_volumes() { return 0; }
      wait_victoria_logs_backend_gone() { return 0; }
      wait_victoria_logs_collector_gone() {
        [[ "$scenario" != "collector-workload" ]]
      }
      cleanup_victoria_logs_port_forwards() { :; }
      helm() {
        printf 'helm %s\n' "$*" >>"$kubectl_log"
        if [[ "$*" == "list --help" ]]; then
          printf '%s\n' '      --all-namespaces   list releases across all namespaces'
        fi
        return 0
      }
      kubectl() {
        local joined
        joined="$*"
        printf 'kubectl %s\n' "$*" >>"$kubectl_log"
        if [[ "$*" == "-n operator-ns get configmap $VICTORIA_LOGS_STATE_CONFIGMAP" ]]; then
          return 0
        fi
        if [[ "$*" == "get namespace logs-ns --ignore-not-found -o name" ]]; then
          printf '%s\n' namespace/logs-ns
          return 0
        fi
        if [[ "$joined" == *"get secret,configmap -l owner=helm,name="* ]]; then
          release_from_selector="${joined##*owner=helm,name=}"
          release_from_selector="${release_from_selector%% *}"
          printf 'helm-metadata-query:%s\n' "$release_from_selector" >>"$kubectl_log"
          case "$scenario:$release_from_selector" in
            backend-helm-metadata:backend-release|collector-helm-metadata:collector-release)
              printf '%s\n' "$release_from_selector"
              ;;
          esac
          return 0
        fi
        return 0
      }

      if cleanup_victoria_logs_resources \
          >"$test_dir/vlogs-identity-${scenario}.out" \
          2>"$test_dir/vlogs-identity-${scenario}.stderr"; then
        fail "VictoriaLogs cleanup succeeded with remaining ${scenario}"
      fi
      [[ "$KUBETON_RETAIN_VICTORIA_LOGS_GUARDS" == "1" ]] \
        || fail "VictoriaLogs cleanup did not retain its ledger for ${scenario}"
      assert_not_contains \
        "delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton" \
        "$kubectl_log"
      assert_contains "helm-metadata-query:collector-release" "$kubectl_log"
      assert_contains "helm-metadata-query:backend-release" "$kubectl_log"
    )
  done
)

test_victoria_logs_cleanup_retains_state_when_strict_pvc_inventory_fails() (
  source "$kubeton"

  local lifecycle_log="$test_dir/vlogs-strict-pvc-inventory.lifecycle"
  local access_selector='app.kubernetes.io/part-of=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton'
  : >"$lifecycle_log"
  OP_NAMESPACE=operator-ns
  VICTORIA_LOGS_NAMESPACE=logs-ns
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=0

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  read_victoria_logs_state_value() {
    case "$2" in
      namespace) printf '%s' logs-ns ;;
      releaseName) printf '%s' backend-release ;;
      collectorReleaseName) printf '%s' collector-release ;;
    esac
  }
  collect_victoria_logs_release_rows() {
    printf '%s\n' release-inventory-complete >>"$lifecycle_log"
    return 0
  }
  wait_victoria_logs_backend_gone() { return 0; }
  wait_victoria_logs_collector_gone() { return 0; }
  victoria_logs_helm_release_is_gone() { return 0; }
  delete_pvc_rows_and_backing_volumes() {
    printf '%s\n' backing-volume-cleanup-called >>"$lifecycle_log"
    return 0
  }
  cleanup_victoria_logs_port_forwards() { :; }
  helm() {
    printf 'helm %s\n' "$*" >>"$lifecycle_log"
    return 0
  }
  kubectl() {
    printf 'kubectl %s\n' "$*" >>"$lifecycle_log"
    if [[ "$*" == "-n operator-ns get configmap $VICTORIA_LOGS_STATE_CONFIGMAP" ]]; then
      return 0
    fi
    if [[ "$*" == "get pvc -A -l app.kubernetes.io/name=victoria-logs-single,app.kubernetes.io/instance=backend-release "* ]]; then
      printf '%s\n' pvc-inventory-failed >>"$lifecycle_log"
      return 1
    fi
    return 0
  }

  if cleanup_victoria_logs_resources \
      >"$test_dir/vlogs-strict-pvc-inventory.out" \
      2>"$test_dir/vlogs-strict-pvc-inventory.stderr"; then
    fail "VictoriaLogs cleanup succeeded after strict PVC inventory failed"
  fi
  [[ "$KUBETON_RETAIN_VICTORIA_LOGS_GUARDS" == "1" ]] \
    || fail "strict VictoriaLogs PVC inventory failure did not set guard retention"
  assert_order "release-inventory-complete" "pvc-inventory-failed" "$lifecycle_log"
  assert_contains "kubectl delete networkpolicy -A -l $access_selector" "$lifecycle_log"
  assert_not_contains \
    "kubectl delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton" \
    "$lifecycle_log"
  assert_contains "cannot inventory PVCs matching" \
    "$test_dir/vlogs-strict-pvc-inventory.stderr"
)

test_victoria_logs_cleanup_stops_before_destructive_work_when_release_inventory_fails() (
  source "$kubeton"

  local lifecycle_log="$test_dir/vlogs-release-inventory-failed.lifecycle"
  : >"$lifecycle_log"
  OP_NAMESPACE=operator-ns
  VICTORIA_LOGS_NAMESPACE=logs-ns
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=0

  victoria_logs_namespace() { printf '%s' logs-ns; }
  victoria_logs_release_name() { printf '%s' backend-release; }
  victoria_logs_collector_release_name() { printf '%s' collector-release; }
  read_victoria_logs_state_value() {
    case "$2" in
      namespace) printf '%s' logs-ns ;;
      releaseName) printf '%s' backend-release ;;
      collectorReleaseName) printf '%s' collector-release ;;
    esac
  }
  cleanup_victoria_logs_port_forwards() {
    printf '%s\n' port-forwards-cleaned >>"$lifecycle_log"
  }
  helm() {
    printf 'helm %s\n' "$*" >>"$lifecycle_log"
    return 0
  }
  kubectl() {
    printf 'kubectl %s\n' "$*" >>"$lifecycle_log"
    if [[ "$*" == "-n operator-ns get configmap $VICTORIA_LOGS_STATE_CONFIGMAP" ]]; then
      return 0
    fi
    if [[ "$*" == "get configmap -A -l app.kubernetes.io/name=kubeton-victoria-logs,app.kubernetes.io/managed-by=kubeton "* ]]; then
      printf '%s\n' release-ledger-inventory-failed >>"$lifecycle_log"
      return 1
    fi
    return 0
  }

  if cleanup_victoria_logs_resources \
      >"$test_dir/vlogs-release-inventory-failed.out" \
      2>"$test_dir/vlogs-release-inventory-failed.stderr"; then
    fail "VictoriaLogs cleanup succeeded with incomplete release inventory"
  fi
  [[ "$KUBETON_RETAIN_VICTORIA_LOGS_GUARDS" == "1" ]] \
    || fail "release inventory failure did not retain VictoriaLogs guards"
  assert_contains "release-ledger-inventory-failed" "$lifecycle_log"
  assert_contains "port-forwards-cleaned" "$lifecycle_log"
  assert_not_contains "helm uninstall" "$lifecycle_log"
  assert_not_contains "kubectl delete service" "$lifecycle_log"
  assert_not_contains "kubectl delete daemonset" "$lifecycle_log"
  assert_not_contains "kubectl delete statefulset" "$lifecycle_log"
  assert_not_contains "kubectl delete networkpolicy" "$lifecycle_log"
  assert_not_contains "kubectl delete configmap" "$lifecycle_log"
  assert_contains "release inventory is incomplete" \
    "$test_dir/vlogs-release-inventory-failed.stderr"
)

test_victoria_logs_collector_cleanup_detects_remaining_daemonset_or_pod() (
  source "$kubeton"

  local clock_file="$test_dir/vlogs-collector-cleanup.clock"
  local remaining_object stderr_file
  sleep() { :; }
  date() {
    local now
    if [[ "${1:-}" == "+%s" ]]; then
      now="$(<"$clock_file")"
      printf '%s\n' "$now"
      printf '%s\n' "$((now + 2))" >"$clock_file"
      return 0
    fi
    command date "$@"
  }
  kubectl() {
    if [[ "$*" == "get namespace logs-ns --ignore-not-found -o name" ]]; then
      printf '%s\n' namespace/logs-ns
      return 0
    fi
    if [[ "$*" == *"-n logs-ns get daemonset,pod "* ]]; then
      printf '%s\n' "$remaining_object"
      return 0
    fi
    return 1
  }

  for remaining_object in daemonset.apps/collector-release pod/collector-release-abcd; do
    printf '%s\n' 100 >"$clock_file"
    stderr_file="$test_dir/vlogs-collector-${remaining_object%%/*}.stderr"
    if wait_victoria_logs_collector_gone logs-ns collector-release 1 \
        >"$test_dir/vlogs-collector-wait.out" 2>"$stderr_file"; then
      fail "collector cleanup treated remaining ${remaining_object} as gone"
    fi
    assert_contains "collector logs-ns/collector-release is still present" "$stderr_file"
  done
)

test_victoria_logs_helm_release_check_uses_supported_all_flag() (
  source "$kubeton"

  local helm_log="$test_dir/vlogs-helm-list.log"
  local helm_mode=4 arg has_all
  kubectl() {
    if [[ "$*" == "get namespace logs-ns --ignore-not-found -o name" ]]; then
      printf '%s\n' namespace/logs-ns
      return 0
    fi
    if [[ "$*" == *"-n logs-ns get secret,configmap -l owner=helm,name=backend-release "* ]]; then
      return 0
    fi
    return 1
  }
  helm() {
    printf '%s\n' "$*" >>"$helm_log"
    if [[ "$*" == "list --help" ]]; then
      if [[ "$helm_mode" == "4" ]]; then
        printf '%s\n' '      --all-namespaces   list releases across all namespaces'
      else
        printf '%s\n' '  -a, --all              show all releases without filtering by status'
      fi
      return 0
    fi
    has_all=0
    for arg in "$@"; do
      [[ "$arg" == "--all" ]] && has_all=1
    done
    if [[ "$helm_mode" == "4" && "$has_all" == "1" ]]; then
      printf '%s\n' unsupported-standalone-all >>"$helm_log"
      return 64
    fi
    if [[ "$helm_mode" == "3" && "$has_all" != "1" ]]; then
      printf '%s\n' missing-standalone-all >>"$helm_log"
      return 64
    fi
    return 0
  }

  : >"$helm_log"
  victoria_logs_helm_release_is_gone logs-ns backend-release \
    || fail "Helm 4 release check rejected help containing only --all-namespaces"
  assert_contains "list -n logs-ns --short" "$helm_log"
  assert_not_contains "list -n logs-ns --short --all" "$helm_log"
  assert_not_contains "unsupported-standalone-all" "$helm_log"

  helm_mode=3
  : >"$helm_log"
  victoria_logs_helm_release_is_gone logs-ns backend-release \
    || fail "Helm 3 release check did not use its supported standalone --all flag"
  assert_contains "list -n logs-ns --short --all" "$helm_log"
  assert_not_contains "missing-standalone-all" "$helm_log"
)

test_longhorn_cleanup_refuses_while_victoria_logs_guards_are_retained() (
  source "$kubeton"

  local lifecycle_log="$test_dir/longhorn-retained-vlogs-guard.lifecycle"
  : >"$lifecycle_log"
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=1
  storage_cleanup_ledger_has_pending_longhorn_targets() {
    printf '%s\n' ledger-inspected >>"$lifecycle_log"
    return 1
  }
  uninstall_longhorn() { printf '%s\n' helm-uninstall >>"$lifecycle_log"; }
  cleanup_longhorn_force() { printf '%s\n' forced-cleanup >>"$lifecycle_log"; }
  delete_namespace_with_progress() { printf '%s\n' namespace-delete >>"$lifecycle_log"; }

  if cleanup_longhorn_release \
      >"$test_dir/longhorn-retained-vlogs-guard.out" \
      2>"$test_dir/longhorn-retained-vlogs-guard.stderr"; then
    fail "Longhorn cleanup proceeded while VictoriaLogs cleanup guards were retained"
  fi
  [[ ! -s "$lifecycle_log" ]] \
    || fail "Longhorn cleanup performed destructive work despite retained VictoriaLogs guards"
  assert_contains "refusing to uninstall Longhorn" \
    "$test_dir/longhorn-retained-vlogs-guard.stderr"
)

test_operator_cleanup_retains_namespace_containing_victoria_logs_guards() (
  source "$kubeton"

  local lifecycle_log="$test_dir/operator-cleanup-retained-guards.lifecycle"
  : >"$lifecycle_log"
  OP_NAMESPACE=operator-ns
  RELEASE_NAME=custom-release
  KUBETON_RETAIN_VICTORIA_LOGS_GUARDS=1

  helm() { printf 'helm %s\n' "$*" >>"$lifecycle_log"; }
  kubectl() {
    printf 'kubectl %s\n' "$*" >>"$lifecycle_log"
    if [[ "$*" == "get namespace operator-ns --ignore-not-found -o name" ]]; then
      printf '%s\n' namespace/operator-ns
      return 0
    fi
    if [[ "$*" == *"-n operator-ns get networkpolicy,configmap "* ]]; then
      printf '%s\n' \
        networkpolicy.networking.k8s.io/kubeton-vlogs-access-ingress \
        configmap/kubeton-vlogs-state-logs-ns-backend-release-123
      return 0
    fi
    return 0
  }
  delete_namespace_with_progress() {
    printf '%s\n' namespace-deletion-attempted >>"$lifecycle_log"
  }

  if cleanup_operator_release \
      >"$test_dir/operator-cleanup-retained-guards.out" \
      2>"$test_dir/operator-cleanup-retained-guards.stderr"; then
    fail "operator cleanup deleted a namespace containing retained VictoriaLogs guards"
  fi
  assert_contains "helm uninstall custom-release -n operator-ns" "$lifecycle_log"
  assert_not_contains "namespace-deletion-attempted" "$lifecycle_log"
  assert_contains "retaining namespace operator-ns" "$test_dir/operator-cleanup-retained-guards.stderr"
)

test_victoria_logs_state_mirrors_canonical_and_preserves_identity_records() (
  source "$kubeton"

  local applied_objects="$test_dir/vlogs-state-applied-objects.tsv"
  local manifests="$test_dir/vlogs-state-manifests.yaml"
  local namespaces="$test_dir/vlogs-state-namespaces.log"
  local record_a record_b
  : >"$applied_objects"
  : >"$manifests"
  : >"$namespaces"

  ensure_namespace() {
    printf '%s\n' "$1" >>"$namespaces"
  }
  kubectl() {
    local ns payload
    if [[ "$1" == "-n" && "$3" == "apply" && "$4" == "-f" && "$5" == "-" ]]; then
      ns="$2"
      payload="$(cat)"
      printf '# namespace=%s\n%s\n' "$ns" "$payload" >>"$manifests"
      printf '%s\n' "$payload" \
        | awk -v ns_name="$ns" '/^  name: / {print ns_name "\t" $2}' \
        >>"$applied_objects"
      return 0
    fi
    return 1
  }

  record_a="$(victoria_logs_state_record_name logs-ns backend-a collector-a)"
  record_b="$(victoria_logs_state_record_name logs-ns backend-b collector-b)"
  [[ "$record_a" != "$record_b" ]] || fail "distinct VictoriaLogs identities collided in the state ledger"
  write_victoria_logs_state operator-ns logs-ns backend-a collector-a access-a collector-ds-a
  write_victoria_logs_state operator-ns logs-ns backend-b collector-b access-b collector-ds-b

  [[ "$(grep -Fc $'operator-ns\t'"$VICTORIA_LOGS_STATE_CONFIGMAP" "$applied_objects")" == "2" ]] \
    || fail "canonical VictoriaLogs state was not updated for both identities in the operator namespace"
  [[ "$(grep -Fc $'logs-ns\t'"$VICTORIA_LOGS_STATE_CONFIGMAP" "$applied_objects")" == "2" ]] \
    || fail "canonical VictoriaLogs state was not mirrored beside both logging identities"
  for ns in operator-ns logs-ns; do
    grep -Fxq "$ns"$'\t'"$record_a" "$applied_objects" \
      || fail "identity A ledger record was not preserved in $ns"
    grep -Fxq "$ns"$'\t'"$record_b" "$applied_objects" \
      || fail "identity B ledger record was not preserved in $ns"
  done
  assert_contains 'releaseName: "backend-a"' "$manifests"
  assert_contains 'releaseName: "backend-b"' "$manifests"
  assert_contains 'collectorBufferPath: "/var/lib/kubeton-vlogs-buffer-logs-ns-collector-a"' "$manifests"
  assert_contains 'collectorBufferPath: "/var/lib/kubeton-vlogs-buffer-logs-ns-collector-b"' "$manifests"
  [[ "$(grep -c '^operator-ns$' "$namespaces")" == "2" \
    && "$(grep -c '^logs-ns$' "$namespaces")" == "2" ]] \
    || fail "VictoriaLogs cleanup state was not mirrored into both namespaces on every write"
)

test_victoria_logs_access_network_policy_is_exact() (
  export VICTORIA_LOGS_NETWORK_POLICY_ENABLED=true
  export VICTORIA_METRICS_NAMESPACE=auth-ns
  source "$kubeton"

  local network_policy_file="$test_dir/victoria-access-network-policy.yaml"
  local service_file="$test_dir/victoria-access-service.yaml"
  local actual_spec expected_spec result
  : >"$network_policy_file"
  : >"$service_file"

  victoria_logs_access_service_name() { printf '%s' vlogs-access; }
  victoria_metrics_stack_name() { printf '%s' auth-stack; }
  kubectl() {
    local payload
    if [[ "$*" == *" apply -f -"* ]]; then
      payload="$(cat)"
      if grep -Fq 'kind: NetworkPolicy' <<<"$payload"; then
        printf '%s\n' "$payload" >"$network_policy_file"
        return 0
      fi
      if grep -Fq 'kind: Service' <<<"$payload"; then
        printf '%s\n' "$payload" >"$service_file"
        return 0
      fi
    fi
    return 1
  }

  result="$(ensure_victoria_logs_access_service logs-ns backend-release collector-release 9428)"
  [[ "$result" == "vlogs-access" ]] \
    || fail "VictoriaLogs access helper returned '$result', expected vlogs-access"

  actual_spec="$(sed -n '/^spec:/,$p' "$network_policy_file")"
  expected_spec="$(cat <<'EOF'
spec:
  podSelector:
    matchLabels:
      app: server
      app.kubernetes.io/instance: backend-release
      app.kubernetes.io/name: victoria-logs-single
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/instance: collector-release
              app.kubernetes.io/name: victoria-logs-collector
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: auth-ns
          podSelector:
            matchLabels:
              app.kubernetes.io/instance: auth-stack
              app.kubernetes.io/name: vmauth
      ports:
        - protocol: TCP
          port: http
EOF
)"
  if [[ "$actual_spec" != "$expected_spec" ]]; then
    echo "unexpected VictoriaLogs NetworkPolicy spec:" >&2
    printf '%s\n' "$actual_spec" >&2
    fail "VictoriaLogs backend policy is not restricted to the exact collector and VMAuth peers"
  fi
  assert_contains "app.kubernetes.io/instance: backend-release" "$service_file"
  assert_contains "app.kubernetes.io/name: victoria-logs-single" "$service_file"
  assert_contains "targetPort: http" "$service_file"
)

test_victoria_logs_access_service_failure_blocks_collector() (
  export VICTORIA_LOGS_STORAGE_CLASS=""
  export VICTORIA_LOGS_NODE_SELECTOR=""
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR=""
  export LONGHORN_NODE_SELECTOR=""
  export VICTORIA_LOGS_NETWORK_POLICY_ENABLED=true
  source "$kubeton"

  local helm_log="$test_dir/victoria-access-failure-helm.log"
  local network_policy_file="$test_dir/victoria-access-failure-network-policy.yaml"
  local service_file="$test_dir/victoria-access-failure-service.yaml"
  : >"$helm_log"
  cluster_is_k3d() { return 0; }
  ensure_namespace() { :; }
  ensure_helm_repo() { :; }
  victoria_logs_service_name() { printf '%s' vlogs-server; }
  victoria_logs_collector_daemonset_name() { printf '%s' vlogs-collector; }
  victoria_logs_access_service_name() { printf '%s' vlogs-access; }
  victoria_metrics_stack_name() { printf '%s' auth-stack; }
  run_with_timeout() {
    shift
    "$@"
  }
  helm() {
    printf '%s\n' "$*" >>"$helm_log"
  }
  kubectl() {
    local payload
    if [[ "$*" == "get storageclass longhorn" ]]; then
      return 1
    fi
    if [[ "$*" == *" apply -f -"* ]]; then
      payload="$(cat)"
      if grep -Fq 'kind: NetworkPolicy' <<<"$payload"; then
        printf '%s\n' "$payload" >"$network_policy_file"
        return 1
      fi
      if grep -Fq 'kind: Service' <<<"$payload"; then
        printf '%s\n' "$payload" >"$service_file"
        return 0
      fi
    fi
    return 1
  }

  KUBETON_NODE_CHECK_TON_SELECTOR=""
  if ensure_victoria_logs_stack vm vlogs collector 9428 11d 12Gi 60 60 \
      >"$test_dir/victoria-access-failure.out" 2>"$test_dir/victoria-access-failure.stderr"; then
    fail "VictoriaLogs stack accepted a failed access Service apply"
  fi
  [[ -s "$network_policy_file" ]] || fail "failed-policy test never attempted NetworkPolicy apply"
  [[ ! -e "$service_file" ]] || fail "VictoriaLogs Service was applied after NetworkPolicy failure"
  assert_not_contains "upgrade --install vlogs " "$helm_log"
  assert_not_contains "upgrade --install collector " "$helm_log"
  assert_contains "failed to protect VictoriaLogs backend" "$test_dir/victoria-access-failure.stderr"
)

test_sequential_start_rechecks_log_coverage_before_each_scaleup() (
  source "$kubeton"

  local event_log="$test_dir/sequential-log-coverage.events"
  local coverage_calls=0
  : >"$event_log"

  wait_ton_statefulsets_present() { :; }
  list_ton_statefulsets() { printf 'default\ttonnode\t0\n'; }
  set_tonnode_or_statefulset_replicas() {
    printf 'scale-%s\n' "$3" >>"$event_log"
  }
  wait_pod_volume_stage_complete() {
    printf 'stage-%s\n' "$2" >>"$event_log"
  }
  verify_start_victoria_logs_collection_ready() {
    coverage_calls=$((coverage_calls + 1))
    printf 'coverage-%s\n' "$coverage_calls" >>"$event_log"
    (( coverage_calls == 1 ))
  }

  if sequential_start_ton_fleet 3 >"$test_dir/sequential-log-coverage.out" 2>&1; then
    fail "sequential start scaled through loss of VictoriaLogs coverage"
  fi
  assert_order "scale-1" "stage-tonnode-0" "$event_log"
  assert_order "stage-tonnode-0" "coverage-1" "$event_log"
  assert_order "coverage-1" "scale-2" "$event_log"
  assert_order "scale-2" "stage-tonnode-1" "$event_log"
  assert_order "stage-tonnode-1" "coverage-2" "$event_log"
  assert_not_contains "scale-3" "$event_log"
  assert_not_contains "stage-tonnode-2" "$event_log"
  [[ "$(grep -c '^coverage-' "$event_log")" == "2" ]] \
    || fail "sequential start did not recheck log coverage before every ordinal after zero"
)

test_run_start_rechecks_log_coverage_immediately_before_helm() (
  export KUBETON_SKIP_NODE_PREREQ_CHECK=false
  export KUBETON_START_WAIT_FOR_BOOTSTRAP=false
  source "$kubeton"

  local event_log="$test_dir/start-final-log-gate.events"
  local helm_log="$test_dir/start-final-log-gate.helm"
  local selector_file="$test_dir/start-final-log-gate-selector.yaml"
  local csi_wait_count=0
  : >"$event_log"
  : >"$helm_log"
  : >"$selector_file"

  require_bin() { :; }
  resolve_ton_replicas_from_values_file() { printf '%s' 3; }
  should_bootstrap_baremetal() { return 1; }
  longhorn_manager_exists() { return 0; }
  storage_class_is_longhorn() { return 1; }
  prepare_node_prerequisites_for_workload() {
    KUBETON_NODE_CHECK_REQUIRED_NODES=3
    KUBETON_NODE_CHECK_TON_SELECTOR="ton-ready=true"
    printf '%s\n' initial-node-preflight >>"$event_log"
  }
  build_ton_node_selector_values_file() { printf '%s' "$selector_file"; }
  fleet_has_stop_annotations() { return 1; }
  ensure_ton_storage_class_available() { :; }
  append_ton_storage_overrides() { :; }
  should_use_sequential_ton_start() { return 1; }
  validate_external_key_prereqs() { :; }
  wait_ton_selected_nodes_longhorn_csi_ready() {
    csi_wait_count=$((csi_wait_count + 1))
    printf 'csi-wait-%s\n' "$csi_wait_count" >>"$event_log"
  }
  ensure_start_victoria_logs() {
    printf '%s\n' initial-log-coverage >>"$event_log"
  }
  delete_stale_ton_pvcs_before_fresh_start() {
    printf '%s\n' stale-pvc-cleanup >>"$event_log"
  }
  run_node_prerequisite_check() {
    printf '%s\n' final-node-recheck >>"$event_log"
  }
  node_check_selector_is_all_compatible() {
    printf '%s\n' final-selector-recheck >>"$event_log"
  }
  verify_ton_selected_nodes_longhorn_csi_ready() {
    printf '%s\n' final-csi-probe >>"$event_log"
  }
  verify_start_victoria_logs_collection_ready() {
    printf '%s\n' final-log-coverage >>"$event_log"
    return 1
  }
  helm() {
    printf '%s\n' "$*" >>"$helm_log"
  }

  if run_start >"$test_dir/start-final-log-gate.out" 2>&1; then
    fail "run_start continued after final VictoriaLogs coverage disappeared"
  fi
  assert_contains "initial-log-coverage" "$event_log"
  assert_order "initial-log-coverage" "stale-pvc-cleanup" "$event_log"
  assert_order "stale-pvc-cleanup" "csi-wait-2" "$event_log"
  assert_order "csi-wait-2" "final-node-recheck" "$event_log"
  assert_order "final-node-recheck" "final-selector-recheck" "$event_log"
  assert_order "final-selector-recheck" "final-csi-probe" "$event_log"
  assert_order "final-csi-probe" "final-log-coverage" "$event_log"
  [[ ! -s "$helm_log" ]] || fail "run_start invoked TON Helm after final log coverage disappeared"
  [[ ! -e "$selector_file" ]] || fail "run_start left its generated selector file after final log gate failure"
)

test_start_does_not_synthesize_collector_selector() (
  export KUBETON_START_VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_ENABLED=true
  export VICTORIA_LOGS_NODE_SELECTOR=logs-backend=true
  export VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR=""
  source "$kubeton"

  local selector_log="$test_dir/start-victoria-selectors.log"
  require_bin() { :; }
  victoria_logs_namespace() { printf '%s' vm; }
  victoria_logs_release_name() { printf '%s' vlogs; }
  victoria_logs_collector_release_name() { printf '%s' collector; }
  resolve_victoria_metrics_rollout_timeout_seconds() { printf '%s' 60; }
  resolve_victoria_logs_helm_timeout_seconds() { printf '%s' 60; }
  write_victoria_logs_state() { :; }
  ensure_victoria_logs_stack() {
    printf '%s\t%s\n' "$VICTORIA_LOGS_NODE_SELECTOR" "$VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR" >"$selector_log"
    printf 'access\tbackend\tcollector-ds\thttp://access:9428\t2\t3\n'
  }

  KUBETON_NODE_CHECK_TON_SELECTOR="ton-ready=true"
  ensure_start_victoria_logs >"$test_dir/start-victoria.out" 2>"$test_dir/start-victoria.stderr"
  assert_contains $'logs-backend=true\t' "$selector_log"
  assert_not_contains "ton-ready=true" "$selector_log"
  [[ "$(cut -f2 "$selector_log")" == "" ]] \
    || fail "ensure_start_victoria_logs synthesized a collector selector from selected TON nodes"
)

test_launch_session_term_kills_command_tree
test_launch_session_term_before_command_spawn_never_starts_command
test_owned_process_tree_uses_ps_when_proc_is_unavailable
test_owned_process_tree_ps_fallback_rejects_reused_pid
test_run_start_rechecks_log_coverage_immediately_before_helm
test_launch_session_begin_permissions
test_run_with_launch_session_exit_and_evidence
test_install_waits_for_operator_rollout_inside_launch_session
test_launch_session_preserves_enabled_errexit
test_launch_session_preserves_errexit
test_container_followers_reconnect_independently
test_log_supervisor_spawns_every_container
test_launch_watchers_track_and_stop_cluster_event_stream
test_event_watchers_use_atomic_list_watch_without_replay_timeout
test_launch_snapshot_captures_dependency_diagnostics_without_secrets
test_running_without_commit_is_extracting
test_scheduled_pending_pod_reports_attach_failure
test_bootstrap_wait_requires_every_replica
test_bootstrap_wait_fails_repeated_crashloop
test_victoria_logs_requires_ready_collector_per_selected_node
test_clusterwide_collector_verify_requires_current_complete_rollout
test_unconstrained_ton_rejects_restricted_collector_before_daemonset_query
test_victoria_logs_helm_durability_settings
test_victoria_logs_collector_buffer_path_matches_early_and_full_install
test_prebootstrap_collector_is_ready_before_storage_bootstrap
test_failed_victoria_logs_cleanup_retains_guards_and_generic_sweep_excludes_them
test_successful_victoria_logs_cleanup_removes_policy_and_state
test_victoria_logs_cleanup_requires_collector_and_both_helm_identities_gone
test_victoria_logs_cleanup_retains_state_when_strict_pvc_inventory_fails
test_victoria_logs_cleanup_stops_before_destructive_work_when_release_inventory_fails
test_victoria_logs_collector_cleanup_detects_remaining_daemonset_or_pod
test_victoria_logs_helm_release_check_uses_supported_all_flag
test_longhorn_cleanup_refuses_while_victoria_logs_guards_are_retained
test_operator_cleanup_retains_namespace_containing_victoria_logs_guards
test_victoria_logs_state_mirrors_canonical_and_preserves_identity_records
test_victoria_logs_access_network_policy_is_exact
test_victoria_logs_access_service_failure_blocks_collector
test_sequential_start_rechecks_log_coverage_before_each_scaleup
test_start_does_not_synthesize_collector_selector

echo "kubeton launch logging tests passed"
