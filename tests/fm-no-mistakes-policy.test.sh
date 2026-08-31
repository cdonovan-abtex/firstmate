#!/usr/bin/env bash
# Public-interface regressions for Firstmate's no-mistakes worker boundary.
# The fake native command starts a real child for guarded validation calls, so
# denial assertions prove that no native agent child began rather than merely
# checking a wrapper message or implementation bytes.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/no-mistakes"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-policy)
BG_PIDS=()

cleanup_policy_test() {
  local pid
  for pid in "${BG_PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.1
  for pid in "${BG_PIDS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_policy_test EXIT
trap 'cleanup_policy_test; exit 130' INT
trap 'cleanup_policy_test; exit 143' TERM

make_native() { # <case-dir>
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/no-mistakes-native" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "$$" "$*" >> "$FM_FAKE_NATIVE_LOG"
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  case "${FM_FAKE_STATUS:-absent}" in
    active)
      printf '%s\n' 'run:' '  status: running' '  steps[1]{step,status}:' '    review,running'
      ;;
    parked)
      printf '%s\n' 'run:' '  status: awaiting_approval' '  awaiting_agent: parked 1s' 'gate: review'
      ;;
    terminal)
      printf '%s\n' 'run:' '  status: completed' 'outcome: passed'
      ;;
    *)
      printf '%s\n' 'No active run.'
      exit 1
      ;;
  esac
  exit 0
fi
if [ "${1:-}" = axi ] && { [ "${2:-}" = run ] || [ "${2:-}" = respond ]; }; then
  case " $* " in *' --help '*|*' -h '*) printf '%s\n' "native:$*"; exit 0 ;; esac
  mkdir -p "$FM_FAKE_CHILD_DIR"
  printf '%s\n' "$$" > "$FM_FAKE_CHILD_DIR/native.$$"
  (
    trap 'exit 143' TERM INT HUP
    printf '%s\n' "${BASHPID:-$$}" > "$FM_FAKE_CHILD_DIR/agent.$$"
    touch "$FM_FAKE_CHILD_DIR/started.$$"
    if [ -n "${FM_FAKE_BLOCK_DIR:-}" ]; then
      while [ ! -e "$FM_FAKE_BLOCK_DIR/release" ]; do sleep 0.03; done
    fi
  ) &
  child=$!
  trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM INT HUP
  wait "$child"
  exit $?
fi
printf '%s\n' "native:$*"
SH
  chmod +x "$dir/fakebin/no-mistakes-native"
}

make_case() { # <name> [agent]
  local agent=${2:-codex} dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/config" "$dir/nm" "$dir/slots" "$dir/children"
  make_native "$dir"
  printf 'agent: %s\n' "$agent" > "$dir/nm/config.yaml"
  : > "$dir/native.log"
  printf '%s\n' "$dir"
}

write_policy() { # <home> <allowed-json-array> <ceiling>
  printf '{"version":1,"allowedAgents":%s,"maxConcurrent":%s}\n' "$2" "$3" \
    > "$1/config/no-mistakes-policy.json"
}

wrapper_env() { # <case-dir> <home> <args...>
  local dir=$1 home=$2
  shift 2
  FM_NO_MISTAKES_POLICY_HOME="$home" \
  FM_NO_MISTAKES_NATIVE_BIN="$dir/fakebin/no-mistakes-native" \
  FM_NO_MISTAKES_NATIVE_PATH="$PATH" \
  FM_NO_MISTAKES_SLOT_ROOT="$dir/slots" \
  NM_HOME="$dir/nm" \
  FM_FAKE_NATIVE_LOG="$dir/native.log" \
  FM_FAKE_CHILD_DIR="$dir/children" \
  FM_FAKE_BLOCK_DIR="${FM_FAKE_BLOCK_DIR:-}" \
  FM_FAKE_STATUS="${FM_FAKE_STATUS:-}" \
    "$WRAPPER" "$@"
}

wait_for_count() { # <glob-parent> <prefix> <count>
  local dir=$1 prefix=$2 wanted=$3 count tries=0
  while [ "$tries" -lt 200 ]; do
    count=$(find "$dir" -maxdepth 1 -type f -name "$prefix.*" | wc -l | tr -d ' ')
    [ "$count" -ge "$wanted" ] && return 0
    sleep 0.03
    tries=$((tries + 1))
  done
  return 1
}

# Explicit identity is admitted and the native child starts.
d=$(make_case allowed codex)
write_policy "$d/home" '["codex"]' 2
out=$(wrapper_env "$d" "$d/home" axi run --intent allowed 2>&1)
assert_contains "$out" 'agent=codex active=1 available=1 ceiling=2; slot acquired' \
  "allowed validation did not report its acquired service slot"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "allowed explicit agent did not start exactly one native agent child"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
[ "$status" = 'policy=enabled agent=codex allowed=true active=0 available=2 ceiling=2 participants=1' ] \
  || fail "policy status did not report released capacity: $status"
pass "allowed explicit agent starts through an inspectable slot"

# Missing policy preserves the old native path.
d=$(make_case missing-policy auto)
out=$(wrapper_env "$d" "$d/home" axi run --intent unconfigured 2>&1)
assert_not_contains "$out" 'Firstmate no-mistakes policy:' \
  "absent policy changed guarded command output"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "absent policy did not preserve native validation behavior"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
[ "$status" = 'policy=disabled active=0 available=unbounded ceiling=unbounded participants=0' ] \
  || fail "absent policy did not inspect as disabled: $status"
pass "globally missing policy preserves existing behavior"

# auto and a concrete non-allowed identity both stop before native invocation.
for denied_agent in auto claude; do
  d=$(make_case "denied-$denied_agent" "$denied_agent")
  write_policy "$d/home" '["codex"]' 2
  set +e
  out=$(wrapper_env "$d" "$d/home" axi run --intent denied 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 78 ] || fail "denied $denied_agent exited $rc instead of 78"
  assert_contains "$out" "denied effective agent \"$denied_agent\"" \
    "denial did not name effective identity $denied_agent"
  [ ! -s "$d/native.log" ] || fail "denied $denied_agent reached native no-mistakes"
  [ -z "$(find "$d/children" -name 'started.*' -print -quit)" ] \
    || fail "denied $denied_agent started a native agent child"
done
pass "auto and disallowed explicit identities are denied before native agent launch"

# Malformed policy fails one guarded boundary, while harmless reads still pass.
d=$(make_case malformed codex)
printf '%s\n' '{"version":1,"allowedAgents":["codex"],"maxConcurrent":"many"}' \
  > "$d/home/config/no-mistakes-policy.json"
set +e
out=$(wrapper_env "$d" "$d/home" axi respond --action approve 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "malformed policy exited $rc instead of 78"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "malformed policy emitted more than one diagnostic: $out"
assert_contains "$out" 'field maxConcurrent must be an integer' \
  "malformed policy diagnostic was not actionable"
[ ! -s "$d/native.log" ] || fail "malformed policy reached native guarded command"
read_out=$(wrapper_env "$d" "$d/home" doctor)
assert_contains "$read_out" 'native:doctor' "doctor was not harmless pass-through under malformed policy"
help_out=$(wrapper_env "$d" "$d/home" axi run --help)
assert_contains "$help_out" 'native:axi run --help' "guarded-command help was not read-only pass-through"
[ -z "$(find "$d/children" -name 'started.*' -print -quit)" ] \
  || fail "read-only no-mistakes commands started a native agent child"
pass "invalid policy stops guarded work once and leaves read-only commands harmless"

# A missing no-mistakes config is not guessed when policy is active.
d=$(make_case missing-global codex)
write_policy "$d/home" '["codex"]' 2
rm -f "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "missing global config exited $rc instead of 78"
assert_contains "$out" 'cannot determine the effective work agent' \
  "missing global config did not explain the unknown effective identity"
[ ! -s "$d/native.log" ] || fail "missing global config reached native guarded command"
pass "missing effective-agent configuration is refused instead of guessed"

# A worker launched while explicit policy is safe re-reads drift before its first call.
d=$(make_case launch-drift codex)
write_policy "$d/home" '["codex"]' 2
cat > "$d/launched-worker.sh" <<'SH'
#!/usr/bin/env bash
set -eu
touch "$FM_DRIFT_READY"
while [ ! -e "$FM_DRIFT_GO" ]; do sleep 0.03; done
no-mistakes axi run --intent drift
SH
chmod +x "$d/launched-worker.sh"
set +e
drift_native_path=$PATH
PATH="$ROOT/bin:$drift_native_path" \
FM_NO_MISTAKES_POLICY_HOME="$d/home" \
FM_NO_MISTAKES_NATIVE_BIN="$d/fakebin/no-mistakes-native" \
FM_NO_MISTAKES_NATIVE_PATH="$drift_native_path" \
FM_NO_MISTAKES_SLOT_ROOT="$d/slots" \
NM_HOME="$d/nm" FM_FAKE_NATIVE_LOG="$d/native.log" FM_FAKE_CHILD_DIR="$d/children" \
FM_DRIFT_READY="$d/ready" FM_DRIFT_GO="$d/go" \
  "$d/launched-worker.sh" > "$d/drift.out" 2>&1 &
drift_pid=$!
BG_PIDS+=("$drift_pid")
set -e
while [ ! -e "$d/ready" ]; do sleep 0.03; done
printf 'agent: auto\n' > "$d/nm/config.yaml"
touch "$d/go"
set +e
wait "$drift_pid"
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "post-launch config drift exited $rc instead of 78"
assert_contains "$(cat "$d/drift.out")" 'denied effective agent "auto"' \
  "post-launch drift was not re-read at validation start"
[ ! -s "$d/native.log" ] || fail "post-launch drift reached native no-mistakes"
pass "worker launch does not cache a safe agent across later config drift"

# Continuation is an equal policy boundary.
d=$(make_case continuation-drift codex)
write_policy "$d/home" '["codex"]' 2
wrapper_env "$d" "$d/home" axi run --intent initial >/dev/null 2>&1
printf 'agent: auto\n' > "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" axi respond --action approve 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "drifted continuation exited $rc instead of 78"
[ "$(grep -c $'\taxi respond ' "$d/native.log" || true)" -eq 0 ] \
  || fail "drifted continuation reached native no-mistakes"
assert_contains "$out" 'denied effective agent "auto"' \
  "continuation drift was not re-read"
pass "every validation continuation re-reads effective agent policy"

# Two slots run together; status exposes the cohort and a third call is refused.
d=$(make_case two-slots codex)
write_policy "$d/home" '["codex"]' 2
mkdir -p "$d/block"
cohort_pids=()
for cohort in one two; do
  FM_FAKE_BLOCK_DIR="$d/block" wrapper_env "$d" "$d/home" axi run --intent "$cohort" \
    > "$d/$cohort.out" 2>&1 &
  cohort_pids+=("$!")
  BG_PIDS+=("$!")
done
wait_for_count "$d/children" started 2 || fail "two-slot cohort did not start two native agent children"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=2 available=0 ceiling=2' \
  "active two-slot cohort was not inspectable"
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent third 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "over-limit validation exited $rc instead of 75"
assert_contains "$out" 'capacity reached: agent=codex active=2 available=0 ceiling=2' \
  "over-limit diagnostic did not expose capacity"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "over-limit validation started a third native agent child"
touch "$d/block/release"
wait "${cohort_pids[0]}"
wait "${cohort_pids[1]}"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=0 available=2 ceiling=2' \
  "normal cohort completion did not release slots"
pass "parallel cohorts use multiple visible slots and refuse over-limit starts"

# Independent homes sharing one NM_HOME share participants and slots.
d=$(make_case shared-service codex)
mkdir -p "$d/home-two/config" "$d/home-unconfigured/config" "$d/block"
write_policy "$d/home" '["codex","pi"]' 2
write_policy "$d/home-two" '["codex"]' 2
shared_pids=()
for home in "$d/home" "$d/home-two"; do
  FM_FAKE_BLOCK_DIR="$d/block" wrapper_env "$d" "$home" axi run --intent shared \
    > "$d/shared.$(basename "$home").out" 2>&1 &
  shared_pids+=("$!")
  BG_PIDS+=("$!")
done
wait_for_count "$d/children" started 2 || fail "independent homes did not share a two-slot cohort"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=2 available=0 ceiling=2 participants=2' \
  "independent home registrations were not combined"
set +e
out=$(wrapper_env "$d" "$d/home-unconfigured" axi run --intent service-wide 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "unconfigured sibling home bypassed registered service ceiling (exit $rc)"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "unconfigured sibling home started an over-limit child"
touch "$d/block/release"
wait "${shared_pids[0]}"
wait "${shared_pids[1]}"
rm -f "$d/home/config/no-mistakes-policy.json" "$d/home-two/config/no-mistakes-policy.json"
status=$(wrapper_env "$d" "$d/home-unconfigured" fm-policy-status)
[ "$status" = 'policy=disabled active=0 available=unbounded ceiling=unbounded participants=0' ] \
  || fail "removed home policies remained registered: $status"
pass "independent homes sharing one service use one conservative slot pool"

# A normal interruption is relayed only to the exact native boundary and releases.
d=$(make_case interruption codex)
write_policy "$d/home" '["codex"]' 1
mkdir -p "$d/block"
FM_FAKE_BLOCK_DIR="$d/block" wrapper_env "$d" "$d/home" axi run --intent interrupt \
  > "$d/interrupt.out" 2>&1 &
interrupt_wrapper=$!
BG_PIDS+=("$interrupt_wrapper")
wait_for_count "$d/children" started 1 || fail "interruption fixture did not start"
kill -TERM "$interrupt_wrapper"
set +e
wait "$interrupt_wrapper"
rc=$?
set -e
[ "$rc" -eq 143 ] || fail "interrupted boundary exited $rc instead of 143"
wrapper_env "$d" "$d/home" axi run --intent after-interrupt >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "handled interruption did not release its slot"
pass "handled interruption relays to one native child and restores capacity"

# A dead wrapper retains a live native child, then recovers without manual files.
d=$(make_case abnormal-exit codex)
write_policy "$d/home" '["codex"]' 1
mkdir -p "$d/block"
FM_FAKE_BLOCK_DIR="$d/block" FM_FAKE_STATUS=terminal \
  wrapper_env "$d" "$d/home" axi run --intent crash > "$d/crash.out" 2>&1 &
crash_wrapper=$!
BG_PIDS+=("$crash_wrapper")
wait_for_count "$d/children" started 1 || fail "abnormal-exit fixture did not start"
native_pid=$(cat "$d/children"/native.*)
agent_pid=$(cat "$d/children"/agent.*)
kill -KILL "$crash_wrapper"
set +e
wait "$crash_wrapper" 2>/dev/null
set -e
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent while-native-lives 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "dead wrapper released a still-live native boundary (exit $rc)"
kill -KILL "$native_pid" "$agent_pid" 2>/dev/null || true
for _ in $(seq 1 100); do
  kill -0 "$native_pid" 2>/dev/null || break
  sleep 0.03
done
wrapper_env "$d" "$d/home" axi run --intent recovered > "$d/recovered.out" 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "dead holder lease did not recover after native work disappeared"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=0 available=1 ceiling=1' \
  "abnormal-exit recovery did not restore capacity"
pass "abnormal worker exit neither frees live native work nor requires manual lease deletion"

printf '%s\n' '# all fm-no-mistakes-policy tests passed'
