#!/usr/bin/env bash
# Public-interface regression tests for the bounded long-child power owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-run-long-child.sh"
TMP_ROOT=$(fm_test_tmproot fm-long-child)
FAKEBIN="$TMP_ROOT/bin"
ASSERTION="$TMP_ROOT/assertion-active"
ARGS_LOG="$TMP_ROOT/caffeinate-args"
OWNER_READY="$TMP_ROOT/owner-ready"
OWNER_PID_LOG="$TMP_ROOT/owner-pid"
OWNER_TERMINATED="$TMP_ROOT/owner-terminated"
CHILD_PID_LOG="$TMP_ROOT/child-pid"
RUNNER_PID=
mkdir -p "$FAKEBIN"

cleanup() {
  if [ -n "$RUNNER_PID" ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH

cat > "$FAKEBIN/caffeinate" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "$FM_FAKE_ARGS_LOG"
[ "${1:-}" = -s ] && [ "${2:-}" = -i ] && [ "${3:-}" = -m ] || exit 97
shift 3
owner_pid=$$
printf '%s\n' "$owner_pid" > "$FM_FAKE_OWNER_PID_LOG"
(
  cleanup() {
    rm -f "$FM_FAKE_ASSERTION"
    : > "$FM_FAKE_OWNER_TERMINATED"
  }
  trap cleanup EXIT
  printf '%s\n' "$BASHPID" > "$FM_FAKE_CHILD_PID_LOG"
  : > "$FM_FAKE_ASSERTION"
  : > "$FM_FAKE_OWNER_READY"
  while kill -0 "$owner_pid" 2>/dev/null; do
    sleep 0.01
  done
) &
exec "$@"
SH

cat > "$FAKEBIN/held-child" <<'SH'
#!/usr/bin/env bash
set -u
printf 'ready\n' > "$FM_FAKE_READY"
trap 'printf "terminated\n" > "$FM_FAKE_TERMINATED"; exit 143' TERM
while [ ! -e "$FM_FAKE_RELEASE" ]; do
  sleep 0.02
done
exit "${FM_FAKE_CHILD_STATUS:-0}"
SH

chmod +x "$FAKEBIN/uname" "$FAKEBIN/caffeinate" "$FAKEBIN/held-child"

wait_for_file() {
  local path=$1 attempt=0
  while [ "$attempt" -lt 200 ]; do
    [ -e "$path" ] && return 0
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_pid_exit() {
  local pid=$1 attempt=0
  while [ "$attempt" -lt 200 ]; do
    ! kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

test_darwin_selects_utility_mode_and_binds_normal_lifetime() {
  local ready="$TMP_ROOT/normal-ready" release="$TMP_ROOT/normal-release"
  local child_pid owner_pid status
  rm -f "$ASSERTION" "$ARGS_LOG" "$OWNER_READY" "$OWNER_PID_LOG" \
    "$OWNER_TERMINATED" "$CHILD_PID_LOG" "$ready" "$release"
  env PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin \
    FM_LONG_CHILD_CAFFEINATE_BIN="$FAKEBIN/caffeinate" \
    FM_FAKE_ASSERTION="$ASSERTION" FM_FAKE_ARGS_LOG="$ARGS_LOG" \
    FM_FAKE_OWNER_READY="$OWNER_READY" FM_FAKE_OWNER_PID_LOG="$OWNER_PID_LOG" \
    FM_FAKE_OWNER_TERMINATED="$OWNER_TERMINATED" \
    FM_FAKE_CHILD_PID_LOG="$CHILD_PID_LOG" FM_FAKE_READY="$ready" \
    FM_FAKE_RELEASE="$release" FM_FAKE_TERMINATED="$TMP_ROOT/unused" \
    "$OWNER" "$FAKEBIN/held-child" &
  RUNNER_PID=$!
  wait_for_file "$OWNER_READY" || fail "assertion owner did not become ready"
  wait_for_file "$ready" || fail "normal child did not start through the public interface"
  owner_pid=$(cat "$OWNER_PID_LOG")
  child_pid=$(cat "$CHILD_PID_LOG")
  [ "$RUNNER_PID" = "$owner_pid" ] || fail "public wrapper PID $RUNNER_PID did not become utility owner $owner_pid"
  [ "$child_pid" != "$owner_pid" ] || fail "utility owner and assertion helper unexpectedly share PID $owner_pid"
  helper_parent=$(ps -o ppid= -p "$child_pid" | tr -d ' ')
  [ "$helper_parent" = "$owner_pid" ] || fail "assertion helper $child_pid was not bound beneath utility owner $owner_pid"
  [ -e "$ASSERTION" ] || fail "power assertion was not active while the owned child was active"
  expected=$(printf '%s\n' -s -i -m "$FAKEBIN/held-child")
  actual=$(cat "$ARGS_LOG")
  [ "$actual" = "$expected" ] || fail "Darwin argument selection was not utility-mode -s -i -m"
  : > "$release"
  wait "$RUNNER_PID"
  status=$?
  RUNNER_PID=
  [ "$status" -eq 0 ] || fail "normal child status changed to $status"
  wait_for_file "$OWNER_TERMINATED" || fail "assertion owner omitted its normal-exit termination handshake"
  [ ! -e "$ASSERTION" ] || fail "power assertion survived normal child exit"
  wait_for_pid_exit "$child_pid" || fail "assertion helper survived normal exit"
  pass "long child: Darwin selects utility-mode assertions and releases them on normal exit"
}

test_failure_status_and_cleanup_are_preserved() {
  local status
  rm -f "$ASSERTION" "$ARGS_LOG" "$OWNER_READY" "$OWNER_PID_LOG" \
    "$OWNER_TERMINATED" "$CHILD_PID_LOG"
  env PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin \
    FM_LONG_CHILD_CAFFEINATE_BIN="$FAKEBIN/caffeinate" \
    FM_FAKE_ASSERTION="$ASSERTION" FM_FAKE_ARGS_LOG="$ARGS_LOG" \
    FM_FAKE_OWNER_READY="$OWNER_READY" FM_FAKE_OWNER_PID_LOG="$OWNER_PID_LOG" \
    FM_FAKE_OWNER_TERMINATED="$OWNER_TERMINATED" \
    FM_FAKE_CHILD_PID_LOG="$CHILD_PID_LOG" \
    "$OWNER" /bin/sh -c 'exit 23'
  status=$?
  [ "$status" -eq 23 ] || fail "failing child status changed from 23 to $status"
  wait_for_file "$OWNER_TERMINATED" || fail "assertion owner omitted its failure termination handshake"
  [ ! -e "$ASSERTION" ] || fail "power assertion survived failing child exit"
  pass "long child: failure status is preserved and its assertion is released"
}

test_interruption_releases_assertion_and_terminates_child() {
  local ready="$TMP_ROOT/interrupt-ready" release="$TMP_ROOT/never-release"
  local child_terminated="$TMP_ROOT/interrupt-child-terminated"
  local child_pid owner_pid status
  rm -f "$ASSERTION" "$ARGS_LOG" "$OWNER_READY" "$OWNER_PID_LOG" \
    "$OWNER_TERMINATED" "$CHILD_PID_LOG" "$ready" "$release" "$child_terminated"
  env PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin \
    FM_LONG_CHILD_CAFFEINATE_BIN="$FAKEBIN/caffeinate" \
    FM_FAKE_ASSERTION="$ASSERTION" FM_FAKE_ARGS_LOG="$ARGS_LOG" \
    FM_FAKE_OWNER_READY="$OWNER_READY" FM_FAKE_OWNER_PID_LOG="$OWNER_PID_LOG" \
    FM_FAKE_OWNER_TERMINATED="$OWNER_TERMINATED" \
    FM_FAKE_CHILD_PID_LOG="$CHILD_PID_LOG" FM_FAKE_READY="$ready" \
    FM_FAKE_RELEASE="$release" FM_FAKE_TERMINATED="$child_terminated" \
    "$OWNER" "$FAKEBIN/held-child" &
  RUNNER_PID=$!
  wait_for_file "$OWNER_READY" || fail "interruptible assertion owner did not become ready"
  wait_for_file "$ready" || fail "interruptible child did not start"
  owner_pid=$(cat "$OWNER_PID_LOG")
  child_pid=$(cat "$CHILD_PID_LOG")
  [ "$RUNNER_PID" = "$owner_pid" ] || fail "signal target $RUNNER_PID was not assertion owner $owner_pid"
  [ -e "$ASSERTION" ] || fail "power assertion was not active before interruption"
  kill -TERM "$owner_pid"
  wait "$RUNNER_PID"
  status=$?
  RUNNER_PID=
  [ "$status" -eq 143 ] || fail "interrupted owner returned $status instead of 143"
  wait_for_file "$child_terminated" || fail "owned long child omitted its termination handshake"
  wait_for_file "$OWNER_TERMINATED" || fail "assertion owner omitted its termination handshake"
  [ ! -e "$ASSERTION" ] || fail "power assertion survived interruption"
  wait_for_pid_exit "$child_pid" || fail "assertion helper survived interruption"
  wait_for_pid_exit "$owner_pid" || fail "assertion owner survived interruption"
  pass "long child: interruption reaches the child and cannot orphan its assertion"
}

test_non_darwin_executes_directly() {
  local output status
  rm -f "$ARGS_LOG"
  output=$(PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Linux \
    FM_LONG_CHILD_CAFFEINATE_BIN="$FAKEBIN/caffeinate" \
    "$OWNER" /bin/sh -c 'printf "direct:%s" "$1"; exit 19' _ value)
  status=$?
  [ "$status" -eq 19 ] || fail "non-Darwin child status changed from 19 to $status"
  [ "$output" = direct:value ] || fail "non-Darwin child arguments changed: $output"
  [ ! -e "$ARGS_LOG" ] || fail "non-Darwin path invoked the macOS assertion interface"
  pass "long child: non-Darwin hosts execute the owned command directly"
}

test_missing_command_and_missing_macos_interface_fail_loudly() {
  local output status
  output=$(PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Linux "$OWNER" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "missing command returned $status instead of usage status 2"
  case "$output" in *"usage: fm-run-long-child.sh"*) ;; *) fail "missing command omitted usage" ;; esac

  output=$(PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin \
    FM_LONG_CHILD_CAFFEINATE_BIN="$TMP_ROOT/missing-caffeinate" \
    "$OWNER" /bin/true 2>&1)
  status=$?
  [ "$status" -eq 1 ] || fail "missing macOS assertion interface returned $status"
  case "$output" in *"requires executable caffeinate"*) ;; *) fail "missing caffeinate diagnostic was not actionable" ;; esac
  pass "long child: invalid or unprotected launches fail loudly"
}

test_darwin_selects_utility_mode_and_binds_normal_lifetime
test_failure_status_and_cleanup_are_preserved
test_interruption_releases_assertion_and_terminates_child
test_non_darwin_executes_directly
test_missing_command_and_missing_macos_interface_fail_loudly
