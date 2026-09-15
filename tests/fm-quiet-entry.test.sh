#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quiet-entry)

launch() {
  local home=$1 harness=$2 mode=$3
  shift 3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_MODE="$mode" FM_TEST_HARNESS="$harness" \
    bash -c '. "$1"; shift; fm_afk_launch_primary_harness() { printf "%s" "$FM_TEST_HARNESS"; }; fm_afk_launch_main "$@"' \
    _ "$ROOT/bin/fm-afk-launch.sh" "$@"
}

for harness in pi pi-signed; do
  home="$TMP_ROOT/$harness"
  mkdir -p "$home/state"
  for command in propose confirm start start-native; do
    if out=$(launch "$home" "$harness" quiet "$command" 2>&1); then
      fail "$harness: quiet $command was accepted"
    fi
    assert_contains "$out" "quiet mode is unsupported on $harness" "$harness: refusal did not explain unsupported quiet mode"
    [ -z "$(ls -A "$home/state")" ] || fail "$harness: quiet $command mutated empty mode state"
  done
  launch "$home" "$harness" away propose --words 'keep working while away' >/dev/null \
    || fail "$harness: ordinary away proposal was refused"
  cp -R "$home/state" "$home/proposed-before"
  if launch "$home" "$harness" quiet confirm >/dev/null 2>&1; then
    fail "$harness: quiet confirmation accepted an existing away proposal"
  fi
  diff -r "$home/proposed-before" "$home/state" >/dev/null || fail "$harness: quiet confirmation changed the proposal"
  launch "$home" "$harness" away confirm >/dev/null || fail "$harness: ordinary away confirmation was refused"
  [ -s "$home/state/.afk-contract" ] || fail "$harness: ordinary away posture was not recorded"
  printf 'away\n1234\n' > "$home/state/.afk"
  cp -R "$home/state" "$home/confirmed-before"
  for command in propose confirm start start-native; do
    if launch "$home" "$harness" quiet "$command" >/dev/null 2>&1; then
      fail "$harness: quiet $command replaced an existing away posture"
    fi
    diff -r "$home/confirmed-before" "$home/state" >/dev/null || fail "$harness: quiet $command changed existing mode state"
  done
  pass "$harness: quiet entry refuses without state mutation while ordinary away entry remains supported"
done

home="$TMP_ROOT/claude"
mkdir -p "$home/state"
launch "$home" claude quiet propose >/dev/null || fail "supported quiet proposal failed"
launch "$home" claude quiet confirm >/dev/null || fail "supported quiet confirmation failed"
launch "$home" claude quiet start-native >/dev/null || fail "supported quiet preparation failed"
[ "$(head -n 1 "$home/state/.afk")" = quiet ] || fail "supported quiet entry did not persist quiet mode"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-return.sh" guard \
  || fail "supported quiet entry blocked ordinary work"
launch "$home" claude quiet stop >/dev/null || fail "supported quiet stop failed"
[ ! -e "$home/state/.afk" ] && [ ! -e "$home/state/.afk-contract" ] \
  || fail "supported quiet stop left active posture"
pass "supported quiet entry persists its mode and exits through the existing lifecycle"
