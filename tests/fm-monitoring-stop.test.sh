#!/usr/bin/env bash
# Executable-interface regressions for the home-scoped automatic-monitoring stop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP="$ROOT/bin/fm-monitoring-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-monitoring-stop)
trap fm_test_cleanup EXIT

write_active_receipt() {  # <home> [time]
  local home=$1 time=${2:-2026-09-21T18:42:20.023025+00:00}
  mkdir -p "$home/data/automatic-monitoring-pause" "$home/state"
  jq -n --arg home "$home" --arg time "$time" '{
    instruction: "Stop the automatic monitoring",
    time: $time,
    home: $home,
    scope: "Automatic monitoring only; existing workers and validation preserved",
    resume: "Explicit approval required; no automatic ownership recovery",
    action: "Stop watcher processes without relinquishing session ownership",
    completed: true
  }' > "$home/data/automatic-monitoring-pause/receipt.json"
}

stop_status() {  # <home>
  FM_HOME="$1" "$STOP" status --json
}

test_status_distinguishes_absent_active_resumed_and_malformed() {
  local home out
  home="$TMP_ROOT/status"
  mkdir -p "$home/state" "$home/data"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = none ] || fail "absent receipt was not status=none: $out"

  write_active_receipt "$home"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = active ] || fail "valid receipt was not status=active: $out"
  [ "$(printf '%s' "$out" | jq -r .time)" = '2026-09-21T18:42:20.023025+00:00' ] || fail "active receipt lost its operator-stop time: $out"

  jq '. + {resumed_at:"2026-09-28T10:00:00Z", resume_instruction:"Resume automatic monitoring"}' \
    "$home/data/automatic-monitoring-pause/receipt.json" > "$home/data/automatic-monitoring-pause/receipt.next"
  mv "$home/data/automatic-monitoring-pause/receipt.next" "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = resumed ] || fail "explicit resumption evidence was not status=resumed: $out"

  write_active_receipt "$home"
  jq '. + {resumed_at:"2026-09-28T10:00:00Z"}' \
    "$home/data/automatic-monitoring-pause/receipt.json" > "$home/data/automatic-monitoring-pause/receipt.next"
  mv "$home/data/automatic-monitoring-pause/receipt.next" "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = malformed ] || fail "partial resumption evidence did not refuse automatic monitoring safely: $out"
  assert_contains "$out" "required stop/resume schema" "partial resumption evidence did not name its schema problem"

  printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = malformed ] || fail "invalid JSON was not status=malformed: $out"
  assert_contains "$out" "valid JSON" "malformed receipt did not name the useful repair problem"
  pass "automatic-monitoring stop status distinguishes absent, active, resumed, and malformed evidence"
}

test_report_is_once_per_stop_identity() {
  local home first second receipt
  home="$TMP_ROOT/report-once"
  write_active_receipt "$home"
  receipt="$home/data/automatic-monitoring-pause/receipt.json"
  first=$(FM_HOME="$home" "$STOP" report-once 2>&1)
  jq '. + {history:[{at:"2026-09-22T00:00:00Z", action:"reasserted"}]}' "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  second=$(FM_HOME="$home" "$STOP" report-once 2>&1)
  assert_contains "$first" "monitoring stopped by Captain order at 2026-09-21T18:42:20.023025+00:00" \
    "first report did not name the order and time"
  [ -z "$second" ] || fail "one active stop was reported again after audit-history maintenance: $second"
  pass "automatic-monitoring stop is reported at most once per stop identity"
}

test_supervision_predicate_honors_stop_and_excludes_secondmate() {
  local home out
  home="$TMP_ROOT/predicate"
  mkdir -p "$home/state" "$home/data"
  printf 'kind=secondmate\nstatus=idle\n' > "$home/state/mini.meta"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED" "$FM_SUP_MONITORING_STOP_STATUS"' _ "$ROOT" "$home/state")
  [ "$out" = '0|false|none' ] || fail "parked secondmate inflated work or stop state: $out"

  printf 'kind=ship\n' > "$home/state/fix.meta"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED" "$FM_SUP_MONITORING_STOP_STATUS"' _ "$ROOT" "$home/state")
  [ "$out" = '1|true|none' ] || fail "normal no-stop ship did not require supervision: $out"

  write_active_receipt "$home"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED" "$FM_SUP_MONITORING_STOP_STATUS"' _ "$ROOT" "$home/state")
  [ "$out" = '1|false|active' ] || fail "active stop did not suppress supervision while retaining raw work count: $out"

  printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED" "$FM_SUP_MONITORING_STOP_STATUS"' _ "$ROOT" "$home/state")
  [ "$out" = '1|false|malformed' ] || fail "malformed stop evidence did not suppress automatic supervision safely: $out"
  pass "supervision keeps normal no-stop behavior, suppresses active/malformed stops, and excludes parked secondmates"
}

test_arm_wrapper_refuses_active_and_malformed_stop() {
  local home out status
  home="$TMP_ROOT/arm-active"
  write_active_receipt "$home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-watch-arm.sh" 2>&1); status=$?
  expect_code 3 "$status" "watch arm must refuse an active operator stop"
  assert_contains "$out" "monitoring stopped by Captain order at 2026-09-21T18:42:20.023025+00:00" \
    "active arm refusal did not report the stop once"
  assert_absent "$home/state/.watch.lock" "active stop still created a watcher lock"

  home="$TMP_ROOT/arm-malformed"
  write_active_receipt "$home"
  printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-watch-arm.sh" 2>&1); status=$?
  expect_code 3 "$status" "watch arm must refuse malformed stop evidence"
  assert_contains "$out" "AUTOMATIC_MONITORING_STOP_INVALID" "malformed arm refusal did not report a useful diagnostic"
  assert_absent "$home/state/.watch.lock" "malformed stop evidence still created a watcher lock"
  pass "watch arm refuses active and malformed stop evidence before watcher launch"
}

test_status_distinguishes_absent_active_resumed_and_malformed
test_report_is_once_per_stop_identity
test_supervision_predicate_honors_stop_and_excludes_secondmate
test_arm_wrapper_refuses_active_and_malformed_stop
