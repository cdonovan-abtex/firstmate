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
  first=$(FM_HOME="$home" bash -c '. "$1/bin/fm-monitoring-stop-lib.sh"; fm_monitoring_stop_report_once' _ "$ROOT" 2>&1)
  jq '. + {history:[{at:"2026-09-22T00:00:00Z", action:"reasserted"}]}' "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  second=$(FM_HOME="$home" bash -c '. "$1/bin/fm-monitoring-stop-lib.sh"; fm_monitoring_stop_report_once' _ "$ROOT" 2>&1)
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

test_receipt_rejects_impossible_timestamps_and_extra_values() {
  local home receipt field value out
  home="$TMP_ROOT/strict-receipt"
  receipt="$home/data/automatic-monitoring-pause/receipt.json"
  for field in time resumed_at; do
    for value in 2026-09-31T10:00:00Z 2026-02-29T10:00:00Z 1900-02-29T10:00:00Z \
      2026-00-21T10:00:00Z 2026-13-21T10:00:00Z 2026-09-00T10:00:00Z \
      2026-09-21T24:00:00Z 2026-09-21T10:60:00Z 2026-09-21T10:00:61Z \
      2026-09-21T10:00:00+24:00 2026-09-21T10:00:00-05:60; do
      write_active_receipt "$home"
      jq --arg field "$field" --arg value "$value" \
        '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"} | .[$field]=$value' \
        "$receipt" > "$receipt.next"
      mv "$receipt.next" "$receipt"
      out=$(stop_status "$home")
      [ "$(printf '%s' "$out" | jq -r .status)" = malformed ] || fail "accepted impossible $field=$value: $out"
    done
  done
  for value in 2000-02-29T10:00:00Z 2024-02-29T23:59:59.001-05:30; do
    write_active_receipt "$home" "$value"
    out=$(stop_status "$home")
    [ "$(printf '%s' "$out" | jq -r .status)" = active ] || fail "rejected valid leap date: $out"
  done
  for value in '{}' 'null' 'true' '[]'; do
    write_active_receipt "$home"
    jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' "$receipt" > "$receipt.next"
    printf '%s\n' "$value" >> "$receipt.next"
    mv "$receipt.next" "$receipt"
    out=$(stop_status "$home")
    [ "$(printf '%s' "$out" | jq -r .status)" = malformed ] || fail "accepted extra JSON value: $out"
  done
  write_active_receipt "$home"
  cp "$receipt" "$home/active.json"
  jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' "$receipt" > "$receipt.next"
  cat "$home/active.json" >> "$receipt.next"
  mv "$receipt.next" "$receipt"
  out=$(stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = malformed ] || fail "ignored appended active receipt: $out"
  pass "receipt rejects impossible dates, times, offsets, and additional JSON values"
}

test_canonical_receipt_and_json_only_cli() {
  local home out status mode
  home="$TMP_ROOT/canonical"
  write_active_receipt "$home"
  jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
    "$home/data/automatic-monitoring-pause/receipt.json" > "$home/alternate.json"
  out=$(FM_MONITORING_STOP_RECEIPT_OVERRIDE="$home/alternate.json" stop_status "$home")
  [ "$(printf '%s' "$out" | jq -r .status)" = active ] || fail "alternate receipt bypassed the canonical stop: $out"
  for mode in status blocks report-once; do
    out=$(FM_HOME="$home" "$STOP" "$mode" 2>&1); status=$?
    expect_code 2 "$status" "surplus CLI mode $mode must be rejected"
  done
  assert_absent "$home/state/.monitoring-stop-reports" "read-only JSON query or rejected CLI consumed report"
  pass "receipt authority is canonical and CLI only accepts JSON status queries"
}

test_every_watcher_entry_refuses_stop() {
  local home kind entry out status second
  for kind in active malformed; do
    for entry in fm-watch.sh fm-watch-arm.sh fm-watch-checkpoint.sh fm-supervise-daemon.sh; do
      home="$TMP_ROOT/entry-$kind-$entry"
      write_active_receipt "$home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
      fi
      printf '%s\n' "$$" > "$home/state/.lock"
      out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" node --input-type=module - "$ROOT/bin/$entry" 2>&1 <<'JS'
import { spawnSync } from "node:child_process";
const result = spawnSync(process.argv[2], [], { encoding: "utf8", timeout: 5000 });
process.stdout.write(result.stdout || "");
process.stderr.write(result.stderr || "");
process.exit(result.status ?? 99);
JS
); status=$?
      expect_code 3 "$status" "$entry must intentionally suppress $kind monitoring"
      assert_contains "$out" AUTOMATIC_MONITORING_STOP "$entry must report suppression"
      second=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/$entry" 2>&1); status=$?
      expect_code 3 "$status" "$entry must keep suppressing monitoring"
      [ -z "$second" ] || fail "$entry repeated the report: $second"
      [ "$(cat "$home/state/.lock")" = "$$" ] || fail "$entry changed session ownership"
      assert_absent "$home/state/.watch.lock" "$entry acquired a watcher lock"
      assert_absent "$home/state/.last-watcher-beat" "$entry began monitoring"
      assert_absent "$home/state/.supervise-daemon.lock" "$entry acquired a daemon lock"
    done
  done
  pass "direct, arm, checkpoint, and daemon startups suppress stops and preserve ownership"
}

test_daemon_stands_down_after_child_exit() {
  local home out status kind
  for kind in active malformed; do
    home="$TMP_ROOT/daemon-restart-$kind"
    write_active_receipt "$home"
    if [ "$kind" = malformed ]; then
      printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
    fi
    mv "$home/data/automatic-monitoring-pause/receipt.json" "$home/receipt.ready"
    touch "$home/state/.afk"
    printf '%s\n' "$$" > "$home/state/.lock"
    cat > "$home/daemon.sh" <<'SH'
#!/usr/bin/env bash
. "$FM_ROOT_OVERRIDE/bin/fm-supervise-daemon.sh"
fm_backend_target_exists() { return 0; }
housekeeping() { :; }
handle_durable_wakes() {
  printf 'handled\n' >> "$FM_HOME/handled"
  mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
}
fm_super_main
SH
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISOR_TARGET=test \
      FM_SUPERVISOR_BACKEND=tmux FM_POLL=1 FM_HEARTBEAT=1 FM_SIGNAL_GRACE=0 \
      FM_WEDGE_ALARM_EXEC=discard node --input-type=module - "$home/daemon.sh" 2>&1 <<'JS'
import { spawnSync } from "node:child_process";
const result = spawnSync("bash", [process.argv[2]], { encoding: "utf8", timeout: 15000 });
process.stdout.write(result.stdout || "");
process.stderr.write(result.stderr || "");
process.exit(result.error ? 99 : result.status ?? 99);
JS
); status=$?
    expect_code 0 "$status" "daemon must exit cleanly after intentional $kind suppression: $out"
    [ "$(cat "$home/handled")" = handled ] || fail "daemon did not handle exactly one ordinary wake"
    assert_contains "$out" AUTOMATIC_MONITORING_STOP "daemon swallowed child suppression output"
    assert_not_contains "$(cat "$home/state/.supervise-daemon.log")" 'restarting after' "daemon treated intentional suppression as a crash"
    assert_absent "$home/state/.watch.lock/pid" "daemon left monitoring alive"
    assert_absent "$home/state/.supervise-daemon.pid" "daemon did not retire after stop"
    [ "$(cat "$home/state/.lock")" = "$$" ] || fail "daemon changed session ownership"
  done
  pass "daemon handles ordinary wake then retires stopped successor without crash retries"
}

make_guard_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config" "$home/data"
  cp -R "$ROOT/bin" "$home/bin"
  git init -q "$home"
  : > "$home/AGENTS.md"
}

test_outstanding_secondmate_reply_keeps_supervision() {
  local home out corr status
  home="$TMP_ROOT/pending-reply"
  make_guard_home "$home"
  printf 'kind=secondmate\nstatus=idle\n' > "$home/state/mini.meta"
  corr=$(FM_HOME="$home" bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_create "$2" "$2/state" mini "Report progress"' _ "$ROOT" "$home")
  [ -n "$corr" ] || fail "could not create real pending reply expectation"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2/state"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_PENDING_REPLIES" "$FM_SUP_NEEDED"' _ "$ROOT" "$home")
  [ "$out" = '0|1|true' ] || fail "secondmate reply lost supervision or inflated task count: $out"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "outstanding secondmate reply must retain turn-end guard"
  assert_contains "$out" 'secondmate reply request(s) outstanding' "guard did not describe outstanding secondmate work"
  write_active_receipt "$home"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "operator stop must suppress secondmate-reply supervision"
  assert_not_contains "$out" 'TURN WOULD END BLIND' "stop prompted supervision repair"
  rm "$home/data/automatic-monitoring-pause/receipt.json"
  FM_HOME="$home" bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_set "$2/state/pending-replies/$3" phase resolved' _ "$ROOT" "$home" "$corr"
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2/state"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_PENDING_REPLIES" "$FM_SUP_NEEDED"' _ "$ROOT" "$home")
  [ "$out" = '0|0|false' ] || fail "resolved secondmate reply kept idle infrastructure active: $out"
  pass "secondmate replies require supervision until resolved without inflating task counts"
}

test_turnend_adapters_display_stop_diagnostic_once() {
  local home adapter out status
  for adapter in pi omp opencode; do
    home="$TMP_ROOT/diagnostic-$adapter"
    make_guard_home "$home"
    mkdir -p "$home/.pi/extensions/lib" "$home/.omp/extensions" "$home/.opencode/plugins/lib"
    cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$home/.pi/extensions/"
    cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$home/.pi/extensions/lib/"
    cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$home/.omp/extensions/"
    cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$home/.opencode/plugins/"
    cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$home/.opencode/plugins/lib/"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" ADAPTER="$adapter" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
const adapter = process.env.ADAPTER;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const messages = [];
let continuations = 0;
let endTurn;
let shutdown = async () => {};
if (adapter === "opencode") {
  const mod = await import(pathToFileURL(`${home}/.opencode/plugins/fm-primary-turnend-guard.js`));
  const hooks = await mod.FmPrimaryTurnendGuard({
    worktree: home,
    client: { session: {
      prompt: async (request) => {
        assert.equal(request.body.noReply, true);
        messages.push(request.body.parts[0].text);
      },
      promptAsync: async () => { continuations++; },
    } },
  });
  endTurn = () => hooks.event({ event: { type: "session.idle", properties: { sessionID: "test" } } });
} else {
  const handlers = new Map();
  const mod = await import(pathToFileURL(`${home}/.${adapter}/extensions/fm-primary-turnend-guard.ts`));
  mod.default({
    on: (name, handler) => handlers.set(name, handler),
    sendMessage: (message, options) => {
      assert.equal(message.display, true);
      assert.ok(!options?.triggerTurn);
      messages.push(message.content);
    },
    sendUserMessage: async () => { continuations++; },
  });
  endTurn = async () => {
    const result = await handlers.get(adapter === "pi" ? "agent_settled" : "session_stop")({});
    if (result?.continue) continuations++;
  };
  shutdown = () => handlers.get("session_shutdown")();
}
await endTurn();
assert.equal(messages.length, 0);
mkdirSync(`${home}/data/automatic-monitoring-pause`, { recursive: true });
writeFileSync(`${home}/data/automatic-monitoring-pause/receipt.json`, "{bad json\n");
await endTurn();
assert.equal(messages.length, 1, `${adapter} swallowed diagnostic`);
assert.match(messages[0], /AUTOMATIC_MONITORING_STOP_INVALID/);
assert.match(messages[0], /valid JSON/);
await endTurn();
assert.equal(messages.length, 1, `${adapter} repeated diagnostic`);
assert.equal(continuations, 0, `${adapter} started a rearm turn`);
await shutdown();
JS
); status=$?
    expect_code 0 "$status" "$adapter must visibly deliver nonblocking diagnostic: $out"
  done
  pass "Pi, omp, and OpenCode display newly malformed evidence once without continuation"
}

test_opencode_requires_shared_helper() {
  local home out status
  home="$TMP_ROOT/missing-helper"
  mkdir -p "$home/bin" "$home/state" "$home/config"
  git init -q "$home"
  : > "$home/AGENTS.md"
  : > "$home/state/task.meta"
  out=$(FM_HOME="$home" ROOT="$ROOT" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { FmPrimaryWatchArm } = await import(pathToFileURL(`${process.env.ROOT}/.opencode/plugins/fm-primary-watch-arm.js`));
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await FmPrimaryWatchArm({ worktree: process.env.FM_HOME, client: {} });
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("test", {});
assert.equal(status, "monitoring-malformed");
JS
); status=$?
  expect_code 0 "$status" "OpenCode must not invent a no-stop verdict without shared helper: $out"
  pass "OpenCode requires shared helper even when canonical receipt is absent"
}

test_checkpoint_preserves_absent_and_resumed_behavior() {
  local home kind out status
  for kind in absent resumed; do
    home="$TMP_ROOT/checkpoint-$kind"
    mkdir -p "$home/state" "$home/data" "$home/config"
    if [ "$kind" = resumed ]; then
      write_active_receipt "$home"
      jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
        "$home/data/automatic-monitoring-pause/receipt.json" > "$home/receipt.next"
      mv "$home/receipt.next" "$home/data/automatic-monitoring-pause/receipt.json"
    fi
    touch "$home/state/.afk"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=1 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 8 2>&1); status=$?
    expect_code 0 "$status" "$kind stop must permit normal checkpoint wake: $out"
    assert_contains "$out" heartbeat "$kind stop did not preserve normal supervision"
    [ -s "$home/state/.wake-queue" ] || fail "$kind checkpoint lost durable wake"
  done
  pass "absent and explicitly resumed stops preserve real checkpoint supervision"
}

test_status_distinguishes_absent_active_resumed_and_malformed
test_report_is_once_per_stop_identity
test_supervision_predicate_honors_stop_and_excludes_secondmate
test_arm_wrapper_refuses_active_and_malformed_stop
test_receipt_rejects_impossible_timestamps_and_extra_values
test_canonical_receipt_and_json_only_cli
test_every_watcher_entry_refuses_stop
test_daemon_stands_down_after_child_exit
test_outstanding_secondmate_reply_keeps_supervision
test_turnend_adapters_display_stop_diagnostic_once
test_opencode_requires_shared_helper
test_checkpoint_preserves_absent_and_resumed_behavior
