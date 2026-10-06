#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Optional reviewer evidence: export actual CLI output and persisted reply state
# to FM_REMOTE_REPLY_TEST_EVIDENCE_DIR before fixture cleanup removes them.
EVIDENCE_DIR=${FM_REMOTE_REPLY_TEST_EVIDENCE_DIR:-}
[ -z "$EVIDENCE_DIR" ] || mkdir -p "$EVIDENCE_DIR" || fail "could not create evidence directory"

capture_evidence() { # <name> <label> <persisted-file> [...]
  local name=$1 label path
  shift
  [ -n "$EVIDENCE_DIR" ] || return 0
  {
    while [ "$#" -gt 0 ]; do
      label=$1 path=$2
      shift 2
      printf '\n%s\n' "$label"
      cat "$path" || fail "could not read $label evidence"
    done
  } > "$EVIDENCE_DIR/$name.txt" || fail "could not export $name evidence"
}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
LOCK_FIXTURE_OWNERS=()
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
lock_fixture_forget() {
  local pid=$1 record retained=()
  for record in ${LOCK_FIXTURE_OWNERS[@]+"${LOCK_FIXTURE_OWNERS[@]}"}; do
    [ "${record%%$'\t'*}" = "$pid" ] || retained+=("$record")
  done
  LOCK_FIXTURE_OWNERS=(${retained[@]+"${retained[@]}"})
}

lock_fixture_track() {
  local pid=$1 identity
  identity=$(pid_identity "$pid") || return 1
  [ -n "$identity" ] || return 1
  lock_fixture_forget "$pid"
  LOCK_FIXTURE_OWNERS+=("$pid"$'\t'"$identity")
}

lock_fixture_signal() {
  local record=$1 pid identity actual
  pid=${record%%$'\t'*}
  identity=${record#*$'\t'}
  [ "$identity" != "$record" ] && [ -n "$identity" ] || return 1
  actual=$(pid_identity "$pid" 2>/dev/null) || return 1
  [ "$actual" = "$identity" ] || return 1
  kill "$pid" 2>/dev/null
}

lock_fixture_stop() {
  local pid=$1 record
  for record in ${LOCK_FIXTURE_OWNERS[@]+"${LOCK_FIXTURE_OWNERS[@]}"}; do
    [ "${record%%$'\t'*}" = "$pid" ] || continue
    if lock_fixture_signal "$record" || ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
    fi
    lock_fixture_forget "$pid"
    return 0
  done
}

lock_fixture_cleanup() {
  local record pid pending=()
  for record in ${LOCK_FIXTURE_OWNERS[@]+"${LOCK_FIXTURE_OWNERS[@]}"}; do
    pid=${record%%$'\t'*}
    if lock_fixture_signal "$record" || ! kill -0 "$pid" 2>/dev/null; then
      pending+=("$pid")
    fi
  done
  for pid in ${pending[@]+"${pending[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
  LOCK_FIXTURE_OWNERS=()
}

# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  lock_fixture_cleanup
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

write_lock_owner() {
  local lock=$1 pid=$2 identity=${3:-} owner recorded
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
  owner=$(mktemp -d "$lock.owner.fixture.XXXXXX") || return 1
  printf '%s\n' "$pid" > "$owner/pid" || return 1
  [ -z "$identity" ] || printf '%s\n' "$identity" > "$owner/owner-identity" || return 1
  ln -s "$owner" "$lock" || return 1
  [ "$(readlink "$lock")" = "$owner" ] || return 1
  [ "$(cat "$lock/pid")" = "$pid" ] || return 1
  recorded=$(cat "$lock/owner-identity" 2>/dev/null || true)
  [ "$recorded" = "$identity" ]
}

write_lifecycle_owner() { # <pid> [identity]
  write_lock_owner "$PARENT/state/.remote-reply-lifecycle-ios.lock" "$@"
}

pid_identity() { # <pid>
  FM_STATE_OVERRIDE="$PARENT/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_pid_identity "$2"
  ' _ "$ROOT" "$1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

lock_fixture_cleanup
[ -z "${LOCK_FIXTURE_OWNERS[0]:-}" ] || fail "empty fixture cleanup created an owner record"
pass "empty fixture tracking survives cleanup under nounset"

"$(command -v sleep)" 30 &
cleanup_fixture_pid=$!
lock_fixture_track "$cleanup_fixture_pid" || fail "could not track the cleanup fixture"
[ -n "${LOCK_FIXTURE_OWNERS[0]:-}" ] || fail "tracking did not record the fixture owner"
lock_fixture_stop "$cleanup_fixture_pid"
[ -z "${LOCK_FIXTURE_OWNERS[0]:-}" ] || fail "stopped and reaped fixture remained tracked"
lock_fixture_cleanup
kill -0 "$cleanup_fixture_pid" 2>/dev/null && fail "stopping a tracked fixture left it alive"
pass "stopped and reaped fixtures are removed before later cleanup"

"$(command -v sleep)" 30 &
cleanup_fixture_pid=$!
lock_fixture_track "$cleanup_fixture_pid" || fail "could not track the mismatched cleanup fixture"
LOCK_FIXTURE_OWNERS[0]="$cleanup_fixture_pid"$'\t'reused-cleanup-birth
lock_fixture_cleanup
cleanup_remaining_record=${LOCK_FIXTURE_OWNERS[0]:-}
kill -0 "$cleanup_fixture_pid" 2>/dev/null || fail "cleanup signalled a process with a mismatched birth identity"
lock_fixture_track "$cleanup_fixture_pid" || fail "could not restore the actual cleanup fixture owner"
[ -z "$cleanup_remaining_record" ] || fail "cleanup retained an unrelated process record"
lock_fixture_cleanup
kill -0 "$cleanup_fixture_pid" 2>/dev/null && fail "cleanup left its identity-matched fixture alive"
pass "cleanup preserves mismatched processes and stops identity-matched fixtures"

if LC_ALL=C ps -p "$$" -o lstart= >/dev/null 2>&1; then
  "$(command -v sleep)" 30 &
  timezone_owner_pid=$!
  lock_fixture_track "$timezone_owner_pid" || fail "could not track the timezone lock owner"
  raw_utc=$(LC_ALL=C TZ=UTC0 ps -p "$timezone_owner_pid" -o lstart=)
  raw_new_york=$(LC_ALL=C TZ=America/New_York ps -p "$timezone_owner_pid" -o lstart=)
  if [ -n "$EVIDENCE_DIR" ]; then
    printf 'Raw process birth timestamp in UTC: %s\nRaw process birth timestamp in New York: %s\n' \
      "$raw_utc" "$raw_new_york" > "$EVIDENCE_DIR/timezone-ownership.txt"
  fi
  if [ "$(uname)" = Darwin ]; then
    [ "$raw_utc" != "$raw_new_york" ] || fail "macOS fixture did not expose timezone-sensitive process timestamps"
  fi
  timezone_lock="$PARENT/state/.test-timezone.lock"
  timezone_baseline=''
  for owner_timezone in UTC0 America/New_York; do
    timezone_identity=$(TZ="$owner_timezone" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
      pid_identity "$timezone_owner_pid") || fail "could not read the owner's portable birth identity"
    case "$timezone_identity" in
      ps-lstart=*) ;;
      *) fail "timezone fixture did not exercise the portable process identity" ;;
    esac
    if [ -n "$timezone_baseline" ]; then
      [ "$timezone_identity" = "$timezone_baseline" ] || fail "portable birth identity varied with the caller's timezone"
    else
      timezone_baseline=$timezone_identity
    fi
    write_lock_owner "$timezone_lock" "$timezone_owner_pid" "$timezone_identity" \
      || fail "could not install the timezone-bound lock owner"
    timezone_owner_dir=$(readlink "$timezone_lock")
    contender_timezone=UTC0
    [ "$owner_timezone" != UTC0 ] || contender_timezone=America/New_York
    # shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
    TZ="$contender_timezone" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" remote_env bash -c '
      . "$1/bin/fm-wake-lib.sh"
      if fm_lock_try_acquire "$2"; then
        fm_lock_release "$2"
        exit 2
      fi
      fm_lock_owner_state "$2" "$3" || exit 1
      [ "$FM_LOCK_HELD_PID" = "$3" ] || exit 3
    ' _ "$ROOT" "$timezone_lock" "$timezone_owner_pid" \
      || fail "a contender with a different timezone displaced the live lock owner"
    [ "$(readlink "$timezone_lock")" = "$timezone_owner_dir" ] \
      || fail "timezone contention replaced the live owner's lock record"
    kill -0 "$timezone_owner_pid" 2>/dev/null || fail "timezone contention signalled the live owner"
    if [ -n "$EVIDENCE_DIR" ]; then
      printf 'Owner timezone: %s\nContender timezone: %s\nRecorded identity: %s\nContender could not acquire; original lock path and process preserved.\n' \
        "$owner_timezone" "$contender_timezone" "$timezone_identity" >> "$EVIDENCE_DIR/timezone-ownership.txt"
    fi
    rm -f -- "$timezone_lock" "$timezone_owner_dir/pid" "$timezone_owner_dir/owner-identity"
    rmdir -- "$timezone_owner_dir"
  done
  lock_fixture_stop "$timezone_owner_pid"
  pass "portable birth identity protects live lock owners across timezones"
else
  pass "portable timezone identity check skipped where ps lstart is unsupported"
fi

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
# One remote note, one announcement: the adapter declares self-announcing, so a
# fully autohandled capture publishes NO check wake - the mirrored status bytes
# are the single announcement, observed here through the same signature-vs-seen
# gate the watcher's signal scan and the drain's annotation check consume.
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an autohandled remote-reply capture still published a duplicate check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" && fail "the mirrored reply bytes are not visible to the watcher signal scan"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

# The runner applies a captured result through this adapter itself, so the reply
# is already mirrored, acknowledged, and the next source re-armed before any
# handler runs. That is the primary guarantee; assert it before exercising the
# handler's own path below.
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
capture_evidence automatic-reply \
  'Remote append-only status stream' "$REMOTE/state/parent-replies.status" \
  'Parent status stream after automatic capture (no handle command)' "$PARENT/state/ios.status" \
  'Locally copied remote report' "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  'Committed reply cursor' "$PARENT/state/remote-replies/ios.cursor" \
  'Durable acknowledgement' "$PARENT/state/procevent-inbox/$SID.1.handled" \
  'Next registered source' "$PARENT/state/procevent/$SID.source"
pass "a captured delta is applied, acknowledged, and re-armed without a handler"

# Now the handler's own retry path, from the state a crash between applying and
# acknowledging leaves behind: the acknowledgement is gone and re-arming fails.
rm -f "$PARENT/state/procevent-inbox/$SID.1.handled"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=0' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not replay the committed reply"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

# A captured completion must not leave Main idle behind a legacy lifecycle owner.
# The live fixture process deliberately has no recorded identity, so the adapter
# preserves it rather than guessing, returns in the configured bound, and lets
# the runner publish the durable retry notification.
"$(command -v sleep)" 30 &
legacy_owner_pid=$!
lock_fixture_track "$legacy_owner_pid" || fail "could not track the legacy lifecycle owner"
write_lifecycle_owner "$legacy_owner_pid" || fail "could not create a legacy lifecycle owner"
printf 'done [key=legacy-owner]: captured result waits for an uncertain legacy owner\n' \
  >> "$REMOTE/state/parent-replies.status"
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/legacy-owner.out" 2>&1 \
  || fail "legacy lifecycle owner prevented result capture"
RESULT_LEGACY="$PARENT/state/procevent-inbox/$SID.2.result"
assert_present "$RESULT_LEGACY" "legacy lifecycle owner did not leave a durable captured result"
assert_absent "$PARENT/state/procevent-inbox/$SID.2.handled" \
  "legacy lifecycle owner allowed an unproven result application"
assert_grep "procevent remote-reply $SID 2" "$PARENT/state/.wake-queue" \
  "bounded lifecycle-owner contention did not surface the captured result"
assert_present "$PARENT/state/.remote-reply-lifecycle-ios.lock" \
  "legacy live lifecycle owner was not protected"
capture_evidence legacy-owner-retry \
  'Runner output with a one-second legacy-owner wait' "$TMP_ROOT/legacy-owner.out" \
  'Durable retry notification' "$PARENT/state/.wake-queue" \
  'Captured reply retained for retry' "$RESULT_LEGACY" \
  'Protected legacy owner PID' "$PARENT/state/.remote-reply-lifecycle-ios.lock/pid"
lock_fixture_stop "$legacy_owner_pid"
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT_SECONDS=1 remote_env "$ADAPTER" handle ios 2 "$RESULT_LEGACY" >/dev/null \
  || fail "captured result did not replay after its legacy owner exited"
assert_present "$PARENT/state/procevent-inbox/$SID.2.handled" \
  "replayed result was not acknowledged after legacy owner exit"
assert_present "$PARENT/state/procevent/$SID.source" \
  "replayed result did not re-arm after legacy owner exit"
pass "a legacy live lifecycle owner is bounded, surfaced, and replayed without guessing"
[ ! -e "$PARENT/state/.remote-reply-lifecycle-ios.lock" ] \
  && [ ! -L "$PARENT/state/.remote-reply-lifecycle-ios.lock" ] \
  || fail "ingesting a replay leaked the lifecycle lock"

# New owner records contain process identity, so a recorded pid now belonging to
# an unrelated process is reclaimed without signalling that process.
"$(command -v sleep)" 30 &
reused_owner_pid=$!
lock_fixture_track "$reused_owner_pid" || fail "could not track the reused-pid lifecycle owner"
write_lifecycle_owner "$reused_owner_pid" 'reused-pid-identity' \
  || fail "could not create a reused-pid lifecycle owner"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(FM_LOCK_STALE_AFTER=0 remote_env "$ADAPTER" handle ios 2 "$RESULT_LEGACY")
printf '%s\n' "$out" > "$TMP_ROOT/reused-owner-recovery.out"
assert_contains "$out" 'ingested: ios appended=0' \
  "reused-pid lifecycle owner did not permit durable replay"
assert_contains "$out" 'handled: remote-reply-ios 2' \
  "reused-pid lifecycle owner did not acknowledge the replay"
kill -0 "$reused_owner_pid" 2>/dev/null \
  || fail "reused-pid recovery signalled the unrelated live process"
assert_absent "$PARENT/state/.remote-reply-lifecycle-ios.lock" \
  "reused-pid lifecycle owner was not reclaimed"
assert_present "$PARENT/state/procevent/$SID.source" \
  "reused-pid replay did not re-arm the remote source"
capture_evidence reused-owner-recovery \
  'Reply handle output after stale birth identity recovery' "$TMP_ROOT/reused-owner-recovery.out" \
  'Deduplicated parent status stream' "$PARENT/state/ios.status" \
  'Recovered reply acknowledgement' "$PARENT/state/procevent-inbox/$SID.2.handled" \
  'Re-armed source' "$PARENT/state/procevent/$SID.source"
lock_fixture_stop "$reused_owner_pid"
pass "a reused lifecycle pid is rejected without harming its unrelated process"

# The complementary identity match remains protected even when an application
# caller is willing to wait only one second.
"$(command -v sleep)" 30 &
live_owner_pid=$!
lock_fixture_track "$live_owner_pid" || fail "could not track the live lifecycle owner"
live_owner_identity=$(pid_identity "$live_owner_pid") \
  || fail "could not identify the live lifecycle owner"
write_lifecycle_owner "$live_owner_pid" "$live_owner_identity" \
  || fail "could not create a live lifecycle owner"
set +e
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT_SECONDS=1 remote_env "$ADAPTER" arm ios > "$TMP_ROOT/live-owner.out" 2>&1
live_owner_rc=$?
set -e
[ "$live_owner_rc" -ne 0 ] || fail "live identity-matched lifecycle owner was displaced"
assert_grep 'identity-uncertain' "$TMP_ROOT/live-owner.out" \
  "bounded live lifecycle owner did not explain the retained contention"
assert_present "$PARENT/state/.remote-reply-lifecycle-ios.lock" \
  "live identity-matched lifecycle owner was reclaimed"
kill -0 "$live_owner_pid" 2>/dev/null \
  || fail "live lifecycle-owner protection signalled its owner"
lock_fixture_stop "$live_owner_pid"
remote_env "$ADAPTER" arm ios >/dev/null || fail "source could not re-arm after live owner exit"
pass "an identity-matched live lifecycle owner remains protected"

for inner_lock in "$PARENT/state/.remote-reply-ingest-ios.lock" "$CLAIMS/$SID.lock"; do
  "$(command -v sleep)" 30 &
  inner_owner_pid=$!
  lock_fixture_track "$inner_owner_pid" || fail "could not track the legacy inner-lock owner"
  write_lock_owner "$inner_lock" "$inner_owner_pid" \
    || fail "could not install the legacy inner-lock owner"
  rm -f "$PARENT/state/procevent-inbox/$SID.2.handled" \
    "$PARENT/state/remote-replies/ios.2.ingested"
  inner_started=$(date +%s)
  inner_rc=0
  # shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
  FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT_SECONDS=1 remote_env bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    fm_run_timed 10 "$1/bin/fm-procevent-remote-reply.sh" handle ios 2 "$2"
  ' _ "$ROOT" "$RESULT_LEGACY" > "$TMP_ROOT/inner-lock.out" 2>&1 || inner_rc=$?
  [ "$inner_rc" -ne 0 ] && [ "$inner_rc" -ne 124 ] \
    || fail "reply application did not refuse within its inner-lock deadline"
  [ "$(( $(date +%s) - inner_started ))" -lt 8 ] \
    || fail "legacy inner-lock contention exhausted the outer test watchdog"
  assert_absent "$PARENT/state/procevent-inbox/$SID.2.handled" \
    "legacy inner-lock contention acknowledged an incomplete application"
  [ "$(cat "$inner_lock/pid")" = "$inner_owner_pid" ] \
    || fail "legacy inner-lock contention displaced its live owner"
  kill -0 "$inner_owner_pid" 2>/dev/null || fail "legacy inner-lock recovery signalled its owner"
  [ ! -e "$PARENT/state/.remote-reply-lifecycle-ios.lock" ] \
    && [ ! -L "$PARENT/state/.remote-reply-lifecycle-ios.lock" ] \
    || fail "inner-lock contention leaked the lifecycle lock"
  lock_fixture_stop "$inner_owner_pid"
  remote_env "$ADAPTER" handle ios 2 "$RESULT_LEGACY" >/dev/null \
    || fail "reply application did not recover after its inner owner exited"
  assert_present "$PARENT/state/procevent-inbox/$SID.2.handled" \
    "recovered inner-lock application did not acknowledge the capture"
  [ ! -e "$inner_lock" ] && [ ! -L "$inner_lock" ] \
    || fail "recovered inner-lock application left its lock behind"

  "$(command -v sleep)" 30 &
  inner_owner_pid=$!
  lock_fixture_track "$inner_owner_pid" || fail "could not track the reused-pid inner-lock owner"
  write_lock_owner "$inner_lock" "$inner_owner_pid" reused-pid-identity \
    || fail "could not install the reused-pid inner-lock owner"
  rm -f "$PARENT/state/procevent-inbox/$SID.2.handled" \
    "$PARENT/state/remote-replies/ios.2.ingested"
  # shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
  FM_LOCK_STALE_AFTER=0 remote_env bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    fm_run_timed 10 "$1/bin/fm-procevent-remote-reply.sh" handle ios 2 "$2"
  ' _ "$ROOT" "$RESULT_LEGACY" > "$TMP_ROOT/inner-reused-pid.out" 2>&1 \
    || fail "reply application did not reclaim its reused-pid inner-lock owner"
  assert_present "$PARENT/state/procevent-inbox/$SID.2.handled" \
    "reused-pid inner-lock recovery did not acknowledge the capture"
  [ "$(grep -cF 'done [key=legacy-owner]' "$PARENT/state/ios.status")" -eq 1 ] \
    || fail "inner-lock recovery duplicated the mirrored reply"
  [ ! -e "$inner_lock" ] && [ ! -L "$inner_lock" ] \
    || fail "reused-pid inner-lock recovery left its lock behind"
  kill -0 "$inner_owner_pid" 2>/dev/null || fail "reused-pid inner-lock recovery signalled its owner"
  capture_evidence "inner-lock-$(basename "$inner_lock")" \
    'Bounded legacy inner-lock refusal' "$TMP_ROOT/inner-lock.out" \
    'Reply output after reused PID recovery' "$TMP_ROOT/inner-reused-pid.out" \
    'Durable recovered acknowledgement' "$PARENT/state/procevent-inbox/$SID.2.handled"
  lock_fixture_stop "$inner_owner_pid"
done
pass "legacy ingest and source locks are bounded and reused inner pids are reclaimed"

handoff_lock="$PARENT/state/.test-handoff.lock"
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2" || exit 1
  trap '\''fm_lock_release "$2"'\'' EXIT
  fm_current_pid owner_pid
  [ "$(cat "$2/owner-identity")" = "$(fm_lock_pid_identity "$owner_pid")" ] || exit 2
  printf "%s\n" "$owner_pid" > "$3.tmp" || exit 3
  mv -f -- "$3.tmp" "$3" || exit 3
  for _ in $(seq 1 200); do
    [ -e "$4" ] && break
    sleep 0.05
  done
  [ -e "$4" ] || exit 4
' _ "$ROOT" "$handoff_lock" "$TMP_ROOT/handoff-ready" "$TMP_ROOT/handoff-release" &
handoff_owner_pid=$!
lock_fixture_track "$handoff_owner_pid" || fail "could not track the handoff publisher"
wait_for "$TMP_ROOT/handoff-ready" || fail "shared lock publication did not bind its owner's identity"
handoff_child_pid=$(cat "$TMP_ROOT/handoff-ready")
[ "$handoff_child_pid" = "$handoff_owner_pid" ] \
  || fail "handoff fixture owner differs from its tracked pid: $handoff_child_pid != $handoff_owner_pid"
# shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shells and EXIT trap.
remote_env bash -c '
  . "$1/bin/fm-wake-lib.sh"
  _fm_wake_require_timeout
  fm_run_timed() {
    : > "$release_path"
    fm_run_bash_timeout "$@"
  }
  release_path=$3
  fm_lock_acquire_wait_bounded "$2" 5 || exit 1
  trap '\''fm_lock_release "$2"'\'' EXIT
  fm_current_pid owner_pid
  [ "$(cat "$2/pid")" = "$owner_pid" ] || exit 2
  [ "$(cat "$2/owner-identity")" = "$(fm_lock_pid_identity "$owner_pid")" ] || exit 3
  FM_STATE_OVERRIDE=$STATE bash -c '\''
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" && exit 1
    exit 0
  '\'' _ "$1" "$2" || exit 4
' _ "$ROOT" "$handoff_lock" "$TMP_ROOT/handoff-release" \
  || fail "bounded shared lock handoff did not bind and protect its caller identity"
wait "$handoff_owner_pid" || fail "shared lock publisher failed"
lock_fixture_forget "$handoff_owner_pid"
[ ! -e "$handoff_lock" ] && [ ! -L "$handoff_lock" ] \
  || fail "shared lock handoff leaked its owner record"
pass "shared lock publication and bounded handoff bind the actual owner's birth identity"

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.3.result"
# The runner already applied and acknowledged this capture. Drop that genuine
# acknowledgement and put an unsafe one in its place, so the handler's refusal
# to trust a non-regular marker stays under test.
rm -f "$PARENT/state/procevent-inbox/$SID.3.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.3.handled"
set +e
remote_env "$ADAPTER" handle ios 3 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.4.result"
remote_env "$ADAPTER" handle ios 4 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.3.handled"
out=$(remote_env "$ADAPTER" handle ios 3 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 3' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# The channel mirrors the remote mate's content-bearing status lines at most once
# while omitting blank separators. A remote mate's own progress line and a NEWLY
# raised needs-decision carry no corr= by charter contract, and a delta carrying
# them alongside a correlated answer must ingest whole: every content-bearing
# line reaches the parent stream, the new decision reaches the parent's
# open-decision fold, the correlated line still settles its pending-reply record,
# and the cursor advances so the channel cannot wedge on a line it once refused.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{
  printf 'working [key=version-audit]: family --version audit complete (data/reply/report.md)\n'
  printf 'needs-decision [key=rough-cut-version]: implement --version or retire the tool\n'
  printf 'done [corr=%s]: release chain audited\n' "$PENDING_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the mirrored status stream was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.5.result"
remote_env "$ADAPTER" handle ios 5 "$RESULT_FOUR" > "$TMP_ROOT/handle-mirror.out" 2>&1 \
  || fail "an uncorrelated status line stopped the delta: $(cat "$TMP_ROOT/handle-mirror.out")"
assert_grep 'working [key=version-audit]' "$PARENT/state/ios.status" "an uncorrelated progress line never reached the parent stream"
assert_grep 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status" "a newly raised remote decision never reached the parent stream"
assert_grep "done [corr=$PENDING_CORR]" "$PARENT/state/ios.status" "the correlated answer sharing the delta was lost"
mirror_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past an uncorrelated line"
pass "the remote status and decision model mirrors and the cursor advances"

# The newly raised decision must be indistinguishable from a local mate's, so the
# shared fold - not this adapter - decides it is open.
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
OPEN=$(status_open_decisions "$PARENT/state/ios.status")
printf '%s' "$OPEN" | grep -q '^rough-cut-version	needs-decision	' \
  || fail "the remote mate's new decision did not surface as open to the parent: $OPEN"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$PENDING_CORR" phase)" = resolved ] \
  || fail "the correlated answer in the same delta did not settle its pending-reply record"
pass "a remote mate's new decision folds open exactly as a local mate's does"

# Ingesting the same generation again is idempotent: no duplicated lines and no
# cursor movement, so a replay can never wedge or double-count the stream.
remote_env "$ADAPTER" handle ios 5 "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replaying the mirrored delta duplicated the new decision"
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "replaying the mirrored delta moved the cursor"
pass "a replayed mirrored delta is idempotent in both the stream and the cursor"

# Bytes crossing a machine boundary are normalized, never dropped: a control
# character cannot make the parent's status file unsafe and cannot stop the
# stream either.
printf 'blocked [key=ctl]: escape \033[31mhere\033[0m bell \007 caf\xc3\xa9 end\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the control-character line was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.6.result"
remote_env "$ADAPTER" handle ios 6 "$RESULT_FIVE" >/dev/null 2>&1 \
  || fail "a control character stopped the stream"
assert_grep 'blocked [key=ctl]: escape ?[31mhere' "$PARENT/state/ios.status" \
  "the control-character line was not mirrored in normalized form"
[ -z "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$PARENT/state/ios.status")" ] \
  || fail "a control byte reached the parent status file"
assert_grep "$(printf 'caf\xc3\xa9 end')" "$PARENT/state/ios.status" \
  "normalization mangled a UTF-8 note a local secondmate could have written"
ctl_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$ctl_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a control-character line"
pass "transported control bytes are normalized in place and never stop the stream"

printf 'status=delta\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the header-collision line was not captured"
RESULT_SIX="$PARENT/state/procevent-inbox/$SID.7.result"
remote_env "$ADAPTER" handle ios 7 "$RESULT_SIX" >/dev/null 2>&1 \
  || fail "a payload protocol-field name stopped the stream"
assert_grep 'status=delta' "$PARENT/state/ios.status" \
  "the payload protocol-field line did not reach the parent stream"
collision_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$collision_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a payload protocol-field line"
pass "payload protocol-field names cannot collide with transport metadata"

printf 'working [key=nul-byte]: before\000after\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the NUL-bearing line was not captured"
RESULT_SEVEN="$PARENT/state/procevent-inbox/$SID.8.result"
remote_env "$ADAPTER" handle ios 8 "$RESULT_SEVEN" >/dev/null 2>&1 \
  || fail "a NUL byte stopped the stream"
assert_grep 'working [key=nul-byte]: before?after' "$PARENT/state/ios.status" \
  "the NUL byte was not normalized in place"
nul_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$nul_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a NUL-bearing line"
pass "NUL bytes are normalized in place before shell line processing"

printf '# Retryable remote answer\n' > "$REMOTE/data/reply/retry.md"
printf 'done [key=retry-document]: retry local storage (data/reply/retry.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
# Obstruct local document storage BEFORE the capture, so the runner's own
# automatic application fails for real. That is the documented fallback: a
# capture whose application does not complete stays unacknowledged and
# uncommitted, and the handler finishes it once storage recovers.
retry_destination="$PARENT/data/remote-secondmates/ios/data/reply/retry.md"
retry_decoy="$TMP_ROOT/retry-decoy.md"
printf 'local decoy\n' > "$retry_decoy"
ln -s "$retry_decoy" "$retry_destination"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the retryable document line was not captured"
RESULT_EIGHT="$PARENT/state/procevent-inbox/$SID.9.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.9.handled" \
  "a capture whose automatic application failed was acknowledged anyway"
# The self-announcing declaration never silences a capture the adapter could
# NOT fully apply: this one must still publish its check wake for the handler.
assert_grep "procevent remote-reply $SID 9" "$PARENT/state/.wake-queue" \
  "a not-fully-applied capture lost its check-wake announcement"
assert_no_grep 'retry local storage' "$PARENT/state/.wake-queue" \
  "reply payload leaked into the event queue"
retry_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
set +e
remote_env "$ADAPTER" handle ios 9 "$RESULT_EIGHT" > "$TMP_ROOT/handle-local-document-failure.out" 2>&1
local_document_rc=$?
set -e
[ "$local_document_rc" -ne 0 ] || fail "local document storage failure committed the delta"
assert_grep 'could not store referenced remote document' "$TMP_ROOT/handle-local-document-failure.out" \
  "local document storage failure was misclassified as remote refusal"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$retry_cursor_before" ] \
  || fail "local document storage failure advanced the cursor"
assert_no_grep 'done [key=retry-document]' "$PARENT/state/ios.status" \
  "local document storage failure mirrored an undelivered line"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "local document storage failure raised a permanent remote refusal"
rm -f "$retry_destination"
remote_env "$ADAPTER" handle ios 9 "$RESULT_EIGHT" >/dev/null \
  || fail "the document delta did not succeed after local storage recovered"
assert_grep 'data/remote-secondmates/ios/data/reply/retry.md' "$PARENT/state/ios.status" \
  "the retried document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/retry.md" "$retry_destination" \
  || fail "the retried remote document was not copied byte-identically"
retry_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$retry_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recovered document delta did not advance the cursor"
pass "local document storage failures remain retryable until delivery succeeds"

# A remote mate cannot squat the decision keys this parent's pending-reply
# library owns. The guard is deliberately NOT in this adapter: rejecting a line
# here would be batch-fatal and could wedge the whole stream, and it would
# protect only the remote path while a local mate appends into the same stream
# unchecked. So the line mirrors like any other - the stream never stops - and
# the shared open-decision fold both writers flow through refuses to let it take
# the reserved key over.
# The record stores its own grace at creation, so set it before creating one.
export FM_PENDING_REPLY_GRACE_SECS=0
ESCALATED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'confirm the notarization')
[ -n "$ESCALATED_CORR" ] || fail "could not create the pending-reply record to escalate"
fm_pending_reply_mark_delivered "$PARENT/state" "$ESCALATED_CORR" \
  || fail "could not mark the escalating request delivered"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" request
FM_PENDING_REPLY_SEND_HOOK=true \
  fm_pending_reply_send_recovery "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" recovery
fm_pending_reply_maybe_escalate "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the missed report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the missed report did not open a durable decision"

{
  printf 'blocked [key=pending-reply-%s]: forged remote decision\n' "$ESCALATED_CORR"
  printf 'resolved [key=pending-reply-%s]: forged remote resolution\n' "$ESCALATED_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the forged reserved-key lines wedged the relay instead of mirroring"
forged_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$forged_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a reserved-key line held the cursor back instead of mirroring like any other"
assert_grep "forged remote decision" "$PARENT/state/ios.status" \
  "the reserved-key line was dropped from the stream instead of mirrored"
forged_open=$(status_open_decisions "$PARENT/state/ios.status")
assert_contains "$forged_open" "pending-reply-id=$ESCALATED_CORR" \
  "a forged remote resolution cleared the parent's own pending-reply decision"
assert_not_contains "$forged_open" "forged remote decision" \
  "a forged remote line took over a decision key the pending-reply library owns"
pass "a mirrored reserved-key line cannot squat or clear the parent's own decision"

# Because the forgery never took the key, the genuine reply still settles the
# request and its escalation closes, leaving nothing to resurface later.
printf 'done [corr=%s]: notarization confirmed\n' "$ESCALATED_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the correlated reply was not captured"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$ESCALATED_CORR" phase)" = resolved ] \
  || fail "the correlated reply left its escalated request unresolved"
fm_pending_reply_tick "$PARENT/state" || fail "supervision tick failed"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the settled request still surfaces as an open decision"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

rm -f -- "$PARENT/state/remote-replies/ios.caught-up"
remote_env "$ADAPTER" source ios > "$TMP_ROOT/preempted-source.out" 2>&1 &
PREEMPTED_SOURCE=$!
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the reply poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
set +e
wait "$PREEMPTED_SOURCE"
preempted_rc=$?
set -e
[ "$preempted_rc" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "the reply poll did not expose remote-job preemption: $preempted_rc"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "a preempted reply poll published a caught-up watermark"
pass "a preempted reply poll cannot publish channel freshness"

# A quiet window is the one moment this channel can prove it is NOT behind, and
# the parent's pending-reply guard needs that proof: a remote report that exists
# but has not been mirrored yet must never be mistaken for a report the mate
# never wrote. The window opened with the log matching the committed cursor, so
# the published watermark is the window's start.
watermark_before=$(date +%s)
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
quiet_rc=$?
set -e
[ "$quiet_rc" -eq 75 ] || fail "a quiet reply window exited with an unexpected status: $quiet_rc"
watermark_after=$(date +%s)
caught_up=$(FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_remote_channel_epoch "$2/state" ios
' _ "$ROOT" "$PARENT")
[ -n "$caught_up" ] || fail "a quiet reply window published no caught-up watermark"
[ "$caught_up" -ge "$watermark_before" ] && [ "$caught_up" -le "$watermark_after" ] \
  || fail "the caught-up watermark ($caught_up) is outside the quiet window"
pass "a quiet reply window publishes the caught-up watermark the reply guard reads"

# The observed already-handled replay class: a lost cursor (an update or
# convergence retire) makes the next armed source recapture the WHOLE remote
# log from offset 0. Every line is already mirrored, so the at-most-once
# append adds no bytes, the adapter acknowledges the generation, and the
# self-announcing runner publishes nothing - the replay stays completely
# quiet, observed through the same seen-signature gate the watcher consumes.
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "could not prime the seen marker for the replay leg"
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-replay"
mv "$PARENT/state/.wake-queue" "$TMP_ROOT/wake-queue-before-replay" 2>/dev/null || true
rm -f "$PARENT/state/remote-replies/ios.cursor"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the cursor-loss recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.12.handled" \
  "the whole-log recapture was not acknowledged by the adapter"
cmp -s "$TMP_ROOT/ios-status-before-replay" "$PARENT/state/ios.status" \
  || fail "the whole-log recapture duplicated already-mirrored lines"
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 12" "$PARENT/state/.wake-queue"; then
  fail "an already-mirrored recapture still published a check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "a byte-identical recapture left unannounced status bytes behind"
replay_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$replay_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recapture did not rebuild the lost cursor"
pass "a cursor-loss whole-log recapture is acknowledged quietly with no duplicate wake"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.13.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TWELVE")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios 13 "$RESULT_TWELVE" > "$TMP_ROOT/handle-nine.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_TWELVE" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.13.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios 13 "$RESULT_TWELVE" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "adapter retirement left a caught-up watermark a later route could inherit"
pass "remote reply retirement quiesces and refuses unhandled captured results"

echo "ALL TESTS PASSED"
