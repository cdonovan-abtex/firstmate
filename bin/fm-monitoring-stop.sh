#!/usr/bin/env bash
# Inspect or request a home-scoped automatic-monitoring stop.
#
# Usage:
#   bin/fm-monitoring-stop.sh status --json
#   bin/fm-monitoring-stop.sh stop --home <absolute-home> --reason <text>
#
# stop records the verified local caller in the canonical private receipt, then
# asks that home's arm owner to wait for its watcher to honor the receipt.
# Outcome exits are 0=stopped, 3=already stopped (idempotent success), and
# 4=could not stop. Invalid syntax exits 2. A failure reason is written to stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-monitoring-stop-lib.sh
. "$SCRIPT_DIR/fm-monitoring-stop-lib.sh"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

stop_failure() {  # <home> <reason>
  printf 'could-not-stop home=%s: %s\n' "$1" "$2" >&2
  exit 4
}

status_json() {
  fm_monitoring_stop_status "$STATE"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg status "$FM_MONITORING_STOP_STATUS" \
      --arg time "$FM_MONITORING_STOP_TIME" \
      --arg detail "$FM_MONITORING_STOP_DETAIL" \
      --arg receipt "$FM_MONITORING_STOP_RECEIPT" \
      --arg origin "$FM_MONITORING_STOP_ORIGIN" \
      --arg caller "$FM_MONITORING_STOP_CALLER" \
      --arg caller_identity "$FM_MONITORING_STOP_CALLER_IDENTITY" \
      --arg reason "$FM_MONITORING_STOP_REASON" \
      '{status:$status,time:$time,detail:$detail,receipt:$receipt,origin:$origin,caller:$caller,caller_identity:$caller_identity,reason:$reason}'
  else
    printf '{"status":"malformed","time":"","detail":"jq is required to validate the receipt","receipt":"","origin":"","caller":"","caller_identity":"","reason":""}\n'
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  status)
    if [ "$#" -ne 2 ] || [ "$2" != --json ]; then
      usage >&2
      exit 2
    fi
    status_json
    exit 0
    ;;
  stop)
    if [ "$#" -ne 5 ] || [ "$2" != --home ] || [ "$4" != --reason ] || [ -z "$3" ] || [ -z "$5" ]; then
      usage >&2
      exit 2
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

TARGET_HOME=$3
STOP_REASON=$5
case "$TARGET_HOME" in
  /*) ;;
  *) stop_failure "$TARGET_HOME" "--home must be an absolute canonical path" ;;
esac
case "$TARGET_HOME" in
  *$'\n'*|*$'\r'*) stop_failure "$TARGET_HOME" "--home must not contain line breaks" ;;
esac
[ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] \
  || stop_failure "$TARGET_HOME" "home must be an existing non-symlink directory"
CANONICAL_HOME=$(cd "$TARGET_HOME" 2>/dev/null && pwd -P) \
  || stop_failure "$TARGET_HOME" "home cannot be resolved"
[ "$TARGET_HOME" = "$CANONICAL_HOME" ] \
  || stop_failure "$TARGET_HOME" "--home is ambiguous; use canonical path $CANONICAL_HOME"
[ "${#STOP_REASON}" -le 4096 ] \
  || stop_failure "$TARGET_HOME" "--reason must be at most 4096 characters"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$TARGET_HOME" "$TARGET_HOME/state" \
  || stop_failure "$TARGET_HOME" "target is not a genuine primary or secondmate home"
[ -d "$TARGET_HOME/state" ] && [ ! -L "$TARGET_HOME/state" ] \
  || stop_failure "$TARGET_HOME" "state must be a non-symlink directory"
[ -d "$TARGET_HOME/data" ] && [ ! -L "$TARGET_HOME/data" ] \
  || stop_failure "$TARGET_HOME" "data must be a non-symlink directory"
OWNER_STOP="$TARGET_HOME/bin/fm-watch-arm.sh"
[ -f "$OWNER_STOP" ] && [ ! -L "$OWNER_STOP" ] && [ -x "$OWNER_STOP" ] \
  || stop_failure "$TARGET_HOME" "home has no executable non-symlink watcher owner at $OWNER_STOP"
command -v jq >/dev/null 2>&1 \
  || stop_failure "$TARGET_HOME" "jq is required to validate and write the stop receipt"

# The explicit target owns every path below. Ambient test/operator overrides must
# never redirect one named home's receipt or owner operation into another home.
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_PROC_ROOT_OVERRIDE
FM_HOME=$TARGET_HOME
STATE=$TARGET_HOME/state
export FM_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

OP_LOCK="$STATE/.monitoring-stop-command.lock"
LOCK_OWNED=0
RECEIPT_TMP=
OWNER_OUT=
OWNER_ERR=
monitoring_stop_cleanup() {
  [ -z "$RECEIPT_TMP" ] || rm -f "$RECEIPT_TMP" 2>/dev/null || true
  [ -z "$OWNER_OUT" ] || rm -f "$OWNER_OUT" 2>/dev/null || true
  [ -z "$OWNER_ERR" ] || rm -f "$OWNER_ERR" 2>/dev/null || true
  if [ "$LOCK_OWNED" -eq 1 ]; then
    fm_lock_release "$OP_LOCK" 2>/dev/null || true
    LOCK_OWNED=0
  fi
}
trap monitoring_stop_cleanup EXIT
trap 'monitoring_stop_cleanup; exit 1' HUP INT TERM

if ! fm_lock_try_acquire "$OP_LOCK"; then
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    stop_failure "$TARGET_HOME" "another monitoring-stop call holds the home lock (pid $FM_LOCK_HELD_PID)"
  fi
  stop_failure "$TARGET_HOME" "monitoring-stop operation lock is malformed or ambiguous"
fi
LOCK_OWNED=1
fm_current_pid STOP_PROCESS_PID \
  || stop_failure "$TARGET_HOME" "could not establish stop-command process identity"
STOP_PROCESS_IDENTITY=$(fm_pid_identity "$STOP_PROCESS_PID" 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "could not establish stop-command process identity"
printf '%s\n' "$STOP_PROCESS_IDENTITY" > "$OP_LOCK/pid-identity" 2>/dev/null \
  || stop_failure "$TARGET_HOME" "could not authenticate the monitoring-stop operation lock"
[ "$(cat "$OP_LOCK/pid-identity" 2>/dev/null || true)" = "$STOP_PROCESS_IDENTITY" ] \
  || stop_failure "$TARGET_HOME" "monitoring-stop operation-lock identity did not persist"

CALLER_PID=$PPID
case "$CALLER_PID" in
  ''|*[!0-9]*|0) stop_failure "$TARGET_HOME" "could not establish the calling process pid" ;;
esac
CALLER_IDENTITY=$(fm_pid_identity "$CALLER_PID" 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "could not authenticate the calling process identity"
CALLER_IDENTITY_CHECK=$(fm_pid_identity "$CALLER_PID" 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "calling process exited before its identity could be confirmed"
[ "$CALLER_IDENTITY" = "$CALLER_IDENTITY_CHECK" ] \
  || stop_failure "$TARGET_HOME" "calling process identity changed during authentication"
CALLER_UID=$(id -u 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "could not establish the calling OS uid"
case "$CALLER_UID" in
  ''|*[!0-9]*) stop_failure "$TARGET_HOME" "calling OS uid is not numeric" ;;
esac
CALLER_USER=$(id -un 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "could not establish the calling OS user"
[ -n "$CALLER_USER" ] \
  || stop_failure "$TARGET_HOME" "calling OS user is empty"
STOP_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
  || stop_failure "$TARGET_HOME" "could not timestamp the stop request"
fm_monitoring_stop_timestamp_valid "$STOP_AT" \
  || stop_failure "$TARGET_HOME" "system clock did not produce an RFC 3339 timestamp"

STOP_DIR="$TARGET_HOME/data/automatic-monitoring-pause"
if [ -e "$STOP_DIR" ] || [ -L "$STOP_DIR" ]; then
  [ -d "$STOP_DIR" ] && [ ! -L "$STOP_DIR" ] \
    || stop_failure "$TARGET_HOME" "stop-receipt directory must be a non-symlink directory"
else
  umask 077
  mkdir "$STOP_DIR" 2>/dev/null \
    || stop_failure "$TARGET_HOME" "could not create stop-receipt directory $STOP_DIR"
fi
RECEIPT="$STOP_DIR/receipt.json"
fm_monitoring_stop_status "$STATE"
PREVIOUS_STATUS=$FM_MONITORING_STOP_STATUS
case "$PREVIOUS_STATUS" in
  none|active|resumed) ;;
  malformed)
    stop_failure "$TARGET_HOME" "existing receipt is malformed: $FM_MONITORING_STOP_DETAIL"
    ;;
  *) stop_failure "$TARGET_HOME" "existing receipt has unknown status $PREVIOUS_STATUS" ;;
esac

umask 077
RECEIPT_TMP=$(mktemp "$STOP_DIR/.receipt.external.XXXXXX") \
  || stop_failure "$TARGET_HOME" "could not allocate an atomic stop receipt"
if [ "$PREVIOUS_STATUS" = active ]; then
  jq -c \
    --argjson caller_uid "$CALLER_UID" \
    --arg caller_user "$CALLER_USER" \
    --argjson caller_pid "$CALLER_PID" \
    --arg caller_identity "$CALLER_IDENTITY" \
    --arg at "$STOP_AT" \
    --arg reason "$STOP_REASON" \
    '.external_stop_request = {
      schema:"firstmate.monitoring-stop.external.v1",
      caller_uid:$caller_uid,
      caller_user:$caller_user,
      caller_pid:$caller_pid,
      caller_identity:$caller_identity,
      at:$at,
      reason:$reason
    }' "$RECEIPT" > "$RECEIPT_TMP" 2>/dev/null \
    || stop_failure "$TARGET_HOME" "could not append the external request audit to the active receipt"
elif [ "$PREVIOUS_STATUS" = resumed ]; then
  jq -c \
    --arg home "$TARGET_HOME" \
    --arg at "$STOP_AT" \
    --argjson caller_uid "$CALLER_UID" \
    --arg caller_user "$CALLER_USER" \
    --argjson caller_pid "$CALLER_PID" \
    --arg caller_identity "$CALLER_IDENTITY" \
    --arg reason "$STOP_REASON" '
    {
      instruction:"Stop automatic monitoring on a verified local-process request",
      time:$at,
      home:$home,
      scope:"Automatic monitoring only; existing workers and validation preserved",
      resume:"Explicit approval required; no automatic ownership recovery",
      action:"Stop the home-scoped watcher through bin/fm-watch-arm.sh --stop",
      completed:true,
      origin:"external",
      previous_stop:{time:.time,resumed_at:.resumed_at},
      external_stop_request:{
        schema:"firstmate.monitoring-stop.external.v1",
        caller_uid:$caller_uid,
        caller_user:$caller_user,
        caller_pid:$caller_pid,
        caller_identity:$caller_identity,
        at:$at,
        reason:$reason
      }
    }' "$RECEIPT" > "$RECEIPT_TMP" 2>/dev/null \
    || stop_failure "$TARGET_HOME" "could not replace the resumed receipt with a new stop"
else
  jq -cn \
    --arg home "$TARGET_HOME" \
    --arg at "$STOP_AT" \
    --argjson caller_uid "$CALLER_UID" \
    --arg caller_user "$CALLER_USER" \
    --argjson caller_pid "$CALLER_PID" \
    --arg caller_identity "$CALLER_IDENTITY" \
    --arg reason "$STOP_REASON" '
    {
      instruction:"Stop automatic monitoring on a verified local-process request",
      time:$at,
      home:$home,
      scope:"Automatic monitoring only; existing workers and validation preserved",
      resume:"Explicit approval required; no automatic ownership recovery",
      action:"Stop the home-scoped watcher through bin/fm-watch-arm.sh --stop",
      completed:true,
      origin:"external",
      external_stop_request:{
        schema:"firstmate.monitoring-stop.external.v1",
        caller_uid:$caller_uid,
        caller_user:$caller_user,
        caller_pid:$caller_pid,
        caller_identity:$caller_identity,
        at:$at,
        reason:$reason
      }
    }' > "$RECEIPT_TMP" 2>/dev/null \
    || stop_failure "$TARGET_HOME" "could not encode the external stop receipt"
fi
chmod 600 "$RECEIPT_TMP" 2>/dev/null \
  || stop_failure "$TARGET_HOME" "could not protect the external stop receipt"
OWNER_OUT=$(mktemp "$STATE/.monitoring-stop-owner.out.XXXXXX") \
  || stop_failure "$TARGET_HOME" "could not allocate watcher-owner output"
OWNER_ERR=$(mktemp "$STATE/.monitoring-stop-owner.err.XXXXXX") \
  || stop_failure "$TARGET_HOME" "could not allocate watcher-owner diagnostics"
FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$TARGET_HOME" "$OWNER_STOP" --stop-status > "$OWNER_OUT" 2> "$OWNER_ERR"
INITIAL_OWNER_RC=$?
mv -f "$RECEIPT_TMP" "$RECEIPT" 2>/dev/null \
  || stop_failure "$TARGET_HOME" "could not publish the external stop receipt"
RECEIPT_TMP=

fm_monitoring_stop_status "$STATE"
[ "$FM_MONITORING_STOP_STATUS" = active ] \
  || stop_failure "$TARGET_HOME" "published receipt did not validate as an active stop: $FM_MONITORING_STOP_DETAIL"
[ "$FM_MONITORING_STOP_CALLER_IDENTITY" = "$CALLER_IDENTITY" ] \
  || stop_failure "$TARGET_HOME" "published receipt did not retain the authenticated caller identity"
[ "$FM_MONITORING_STOP_REASON" = "$STOP_REASON" ] \
  || stop_failure "$TARGET_HOME" "published receipt did not retain the stop reason"

OWNER_RC=$INITIAL_OWNER_RC
case "$INITIAL_OWNER_RC" in
  0|3)
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$TARGET_HOME" "$OWNER_STOP" --stop > "$OWNER_OUT" 2> "$OWNER_ERR"
    OWNER_RC=$?
    ;;
esac
case "$OWNER_RC" in
  0)
    monitoring_stop_cleanup
    trap - EXIT HUP INT TERM
    printf 'stopped home=%s\n' "$TARGET_HOME"
    exit 0
    ;;
  3)
    monitoring_stop_cleanup
    trap - EXIT HUP INT TERM
    if [ "$PREVIOUS_STATUS" = active ] && [ "$INITIAL_OWNER_RC" -eq 3 ]; then
      printf 'already-stopped home=%s\n' "$TARGET_HOME"
      exit 3
    fi
    printf 'stopped home=%s\n' "$TARGET_HOME"
    exit 0
    ;;
  *)
    OWNER_DETAIL=$(cat "$OWNER_ERR" 2>/dev/null || true)
    [ -n "$OWNER_DETAIL" ] || OWNER_DETAIL=$(cat "$OWNER_OUT" 2>/dev/null || true)
    OWNER_DETAIL=$(printf '%s' "$OWNER_DETAIL" | tr '\r\n\t' '   ' | cut -c1-1024)
    [ -n "$OWNER_DETAIL" ] || OWNER_DETAIL="watcher owner path exited $OWNER_RC without a reason"
    stop_failure "$TARGET_HOME" "$OWNER_DETAIL"
    ;;
esac
