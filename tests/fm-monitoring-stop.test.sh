#!/usr/bin/env bash
# Executable-interface regressions for the home-scoped automatic-monitoring stop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP="$ROOT/bin/fm-monitoring-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-monitoring-stop)
EXTERNAL_STOP_WATCHER_PIDS=()
cleanup_external_stop_watchers() {
  local pid
  for pid in "${EXTERNAL_STOP_WATCHER_PIDS[@]:-}"; do
    [ -z "$pid" ] || stop_fixture_watcher "$pid"
  done
  EXTERNAL_STOP_WATCHER_PIDS=()
}
trap 'cleanup_external_stop_watchers; fm_test_cleanup' EXIT

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
  [ -z "$out" ] || fail "arm must leave reporting to its visible caller: $out"
  assert_absent "$home/state/.monitoring-stop-reports" "arm consumed the active stop notice"
  assert_absent "$home/state/.watch.lock" "active stop still created a watcher lock"

  home="$TMP_ROOT/arm-malformed"
  write_active_receipt "$home"
  printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-watch-arm.sh" 2>&1); status=$?
  expect_code 3 "$status" "watch arm must refuse malformed stop evidence"
  [ -z "$out" ] || fail "arm must leave reporting to its visible caller: $out"
  assert_absent "$home/state/.monitoring-stop-reports" "arm consumed the malformed stop notice"
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
      if [ "$entry" = fm-watch-checkpoint.sh ]; then
        assert_contains "$out" AUTOMATIC_MONITORING_STOP "foreground checkpoint must report suppression"
      else
        [ -z "$out" ] || fail "$entry reported from a potentially hidden child: $out"
        assert_absent "$home/state/.monitoring-stop-reports" "$entry consumed report in a child"
      fi
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
    assert_absent "$home/state/.monitoring-stop-reports" "daemon consumed the report inside its terminal"
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
    cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-monitoring-stop.ts" "$home/.pi/extensions/lib/"
    cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$home/.omp/extensions/"
    cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$home/.opencode/plugins/"
    cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$home/.opencode/plugins/lib/"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" ADAPTER="$adapter" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
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
const precheck = spawnSync(`${home}/bin/fm-monitoring-stop.sh`, ["status", "--json"], { encoding: "utf8" });
assert.equal(JSON.parse(precheck.stdout).status, "none");
mkdirSync(`${home}/data/automatic-monitoring-pause`, { recursive: true });
writeFileSync(`${home}/data/automatic-monitoring-pause/receipt.json`, "{bad json\n");
const capturedArm = spawnSync(`${home}/bin/fm-watch-arm.sh`, [], { encoding: "utf8" });
assert.equal(capturedArm.status, 3);
assert.equal(existsSync(`${home}/state/.monitoring-stop-reports`), false, "hidden arm consumed diagnostic");
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
  pass "Pi, omp, and OpenCode display an arm-start race diagnostic once without continuation"
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
assert.equal(status, "stopped");
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

make_hook_harnesses() {
  mkdir -p "$TMP_ROOT/harnesses"
  cat > "$TMP_ROOT/harnesses/host.c" <<'C'
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  char path[4096];
  int status;
  pid_t child;
  if (argc != 2 || !getenv("FM_HOME")) return 64;
  snprintf(path, sizeof(path), "%s/state/.lock", getenv("FM_HOME"));
  FILE *lock = fopen(path, "w");
  if (!lock) return 73;
  fprintf(lock, "%ld\n", (long)getpid());
  fclose(lock);
  child = fork();
  if (child < 0) return 70;
  if (!child) { execl("/bin/bash", "bash", argv[1], (char *)0); _exit(127); }
  while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 71;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 72;
}
C
  cc -o "$TMP_ROOT/harnesses/claude" "$TMP_ROOT/harnesses/host.c" || fail "could not build hook harness"
  cp "$TMP_ROOT/harnesses/claude" "$TMP_ROOT/harnesses/cursor-agent"
}

test_resolved_secondmate_outcome_reaches_hooks() {
  local test_home harness script out status corr phase seq need drain generation
  for harness in claude cursor-agent; do
    test_home="$TMP_ROOT/queued-reply-$harness"
    make_guard_home "$test_home"
    printf 'kind=secondmate\nstatus=idle\n' > "$test_home/state/mini.meta"
    corr=$(FM_HOME="$test_home" bash -c '. "$1/bin/fm-pending-reply-lib.sh"; corr=$(fm_pending_reply_create "$2" "$2/state" mini "Report progress") || exit 1; fm_pending_reply_mark_delivered "$2/state" "$corr" || exit 1; printf "%s" "$corr"' _ "$ROOT" "$test_home")
    printf '%s\n' "$corr" > "$test_home/correlation"
    cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
corr=$(cat "$FM_HOME/correlation")
printf 'needs-decision [corr=%s]: choose the next action\n' "$corr" > "$FM_HOME/state/mini.status"
exec "$FM_HOME/bin/fm-watch-checkpoint.sh" --seconds 8
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh"
    if [ "$harness" = claude ]; then script=fm-claude-stop-autoarm.sh; else script=fm-turnend-guard-cursor.sh; fi
    out=$(printf '{"session_id":"reply-test","stop_hook_active":false,"loop_count":0}' \
      | env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" \
        FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CURSOR_PARK_POLL=1 \
        "$TMP_ROOT/harnesses/$harness" "$test_home/bin/$script" 2>&1); status=$?
    if [ "$harness" = claude ]; then
      expect_code 2 "$status" "Claude must deliver the resolved secondmate outcome: $out"
    else
      expect_code 0 "$status" "Cursor must deliver the resolved secondmate outcome: $out"
      out=$(printf '%s' "$out" | jq -er .followup_message) || fail "Cursor returned no follow-up"
    fi
    assert_contains "$out" 'firstmate watcher wake' "$harness discarded resolved secondmate outcome"
    assert_contains "$out" mini.status "$harness omitted the secondmate signal"
    phase=$(awk -F= '$1=="phase" {print $2}' "$test_home/state/pending-replies/$corr")
    [ "$phase" = resolved ] || fail "fixture did not resolve reply before delivery"
    seq=$(awk -F '\t' '$2>max {max=$2} END {print max}' "$test_home/state/.wake-queue")
    [ -n "$seq" ] || fail "secondmate outcome was not queued"
    need=$(FM_HOME="$test_home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2/state"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_PENDING_REPLIES" "$FM_SUP_NEEDED"' _ "$ROOT" "$test_home")
    [ "$need" = '0|0|true' ] || fail "queued outcome must independently require supervision: $need"
    write_active_receipt "$test_home"
    need=$(FM_HOME="$test_home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2/state"; printf "%s" "$FM_SUP_NEEDED"' _ "$ROOT" "$test_home")
    [ "$need" = false ] || fail "queued outcome overrode operator stop"
    rm "$test_home/data/automatic-monitoring-pause/receipt.json"
    drain=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-wake-drain.sh" 2>&1) || fail "could not present queued outcome: $drain"
    generation=$(printf '%s\n' "$drain" | awk '/^WAKE_ACK_REQUIRED:/ { for (i=1;i<NF;i++) if ($i=="--recovery-generation") print $(i+1) }')
    if [ -n "$generation" ]; then
      FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null || fail "could not acknowledge queued outcome"
    else
      FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-wake-drain.sh" --ack-through "$seq" >/dev/null || fail "could not acknowledge queued outcome"
    fi
    need=$(FM_HOME="$test_home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2/state"; printf "%s|%s|%s" "$FM_SUP_IN_FLIGHT" "$FM_SUP_PENDING_REPLIES" "$FM_SUP_NEEDED"' _ "$ROOT" "$test_home")
    [ "$need" = '0|0|false' ] || fail "acknowledged outcome kept infrastructure active: $need"
  done
  pass "Claude and Cursor deliver resolved secondmate outcomes until acknowledged"
}

test_cursor_reports_before_early_return_and_after_arm_race() {
  local test_home timing out status
  for timing in before-stop during-arm; do
    test_home="$TMP_ROOT/cursor-notice-$timing"
    make_guard_home "$test_home"
    mkdir -p "$test_home/data/automatic-monitoring-pause"
    printf '{bad json\n' > "$test_home/receipt.ready"
    cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "$FM_HOME/arm-ran"
mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
exit 3
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh"
    cat > "$test_home/turns.sh" <<'SH'
#!/usr/bin/env bash
payload='{"session_id":"cursor-notice","loop_count":0,"cursor_version":"test"}'
cp "$FM_HOME/state/.lock" "$FM_HOME/owner.before"
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/initial"
if [ "$TIMING" = before-stop ]; then
  mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
fi
printf 'kind=ship\n' > "$FM_HOME/state/work.meta"
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/first"
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/second"
cmp "$FM_HOME/owner.before" "$FM_HOME/state/.lock"
SH
    out=$(env -u PI_CODING_AGENT FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" TIMING="$timing" \
      FM_CURSOR_PARK_POLL=1 "$TMP_ROOT/harnesses/cursor-agent" "$test_home/turns.sh" 2>&1); status=$?
    expect_code 0 "$status" "Cursor stop diagnostic delivery failed: $out"
    [ ! -s "$test_home/initial" ] || fail "idle Cursor emitted a follow-up without stop or work"
    [ ! -s "$test_home/second" ] || fail "Cursor repeated the stop notice"
    out=$(jq -er .followup_message "$test_home/first") || fail "Cursor discarded malformed diagnostic"
    assert_contains "$out" AUTOMATIC_MONITORING_STOP_INVALID "Cursor omitted malformed diagnostic"
    assert_not_contains "$out" 'TURN WOULD END BLIND' "Cursor requested repair under stop"
    assert_absent "$test_home/state/.watch.lock" "Cursor armed despite stop"
    if [ "$timing" = before-stop ]; then
      assert_absent "$test_home/arm-ran" "Cursor tried to arm after recorded stop"
    else
      [ "$(cat "$test_home/arm-ran")" = arm ] || fail "Cursor retried suppressed arm"
    fi
  done
  pass "Cursor reports malformed evidence once before idle return and after arm suppression"
}

test_away_launcher_reports_visible_stop() {
  local test_home kind out second status mode
  for kind in active malformed; do
    for mode in start start-native; do
      test_home="$TMP_ROOT/launcher-$kind-$mode"
      write_active_receipt "$test_home"
      [ "$kind" != malformed ] || printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      out=$(FM_HOME="$test_home" "$ROOT/bin/fm-afk-launch.sh" "$mode" 2>&1); status=$?
      expect_code 3 "$status" "away launcher must intentionally suppress $kind stop: $out"
      assert_contains "$out" AUTOMATIC_MONITORING_STOP "away launcher did not report stop"
      second=$(FM_HOME="$test_home" "$ROOT/bin/fm-afk-launch.sh" "$mode" 2>&1); status=$?
      expect_code 3 "$status" "away launcher must remain suppressed"
      [ -z "$second" ] || fail "away launcher repeated stop notice: $second"
      assert_absent "$test_home/state/.afk-daemon-terminal" "stopped launcher created a terminal"
      assert_absent "$test_home/state/.afk" "stopped launcher changed away posture"
    done
    test_home="$TMP_ROOT/launcher-race-$kind"
    write_active_receipt "$test_home"
    [ "$kind" != malformed ] || printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/bin/fm-afk-launch.sh"
      fm_afk_launch_catchup_pending() { return 1; }
      fm_afk_launch_daemon_allowed() { return 0; }
      fm_afk_launch_record_require() { return 0; }
      discover_supervisor_target() { printf "test\n"; }
      discover_supervisor_backend() { printf "tmux\n"; }
      tmux() { [ "$1" = new-session ]; }
      fm_afk_launch_wait_ready() {
        mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
        "$FM_ROOT/bin/fm-supervise-daemon.sh" > "$FM_HOME/hidden-output" 2>&1
        printf "%s\n" "$?" > "$FM_HOME/child-status"
        return 1
      }
      fm_afk_launch_close_terminal() { printf "%s:%s\n" "$1" "$2" > "$FM_HOME/closed"; }
      fm_afk_launch_terminal_absent() { [ -s "$FM_HOME/closed" ]; }
      fm_afk_launch_main start
    ' _ "$ROOT" 2>&1); status=$?
    expect_code 3 "$status" "launcher must recognize stop during hidden daemon startup: $out"
    [ "$(cat "$test_home/child-status")" = 3 ] || fail "daemon did not suppress startup"
    [ ! -s "$test_home/hidden-output" ] || fail "daemon reported inside hidden terminal"
    assert_contains "$out" AUTOMATIC_MONITORING_STOP "launcher swallowed hidden-start diagnostic"
    assert_not_contains "$out" 'daemon did not become ready' "launcher misreported intentional suppression"
    assert_absent "$test_home/state/.afk-daemon-terminal" "launcher did not retire suppressed terminal"
    assert_absent "$test_home/state/.afk" "launcher did not roll back away posture"
    second=$(FM_HOME="$test_home" "$ROOT/bin/fm-afk-launch.sh" start 2>&1); status=$?
    expect_code 3 "$status" "launcher must remain suppressed after race"
    [ -z "$second" ] || fail "launcher race report repeated: $second"
  done
  pass "away launcher reports stops visibly, including hidden daemon startup races"
}

test_bootstrap_nudges_leave_notices_for_visible_boundary() {
  local scenario world test_home primary mate fakebin out second status
  fm_git_identity
  for scenario in success failure; do
    world="$TMP_ROOT/bootstrap-$scenario"
    test_home="$world/home"
    primary="$world/main"
    mate="$world/mini"
    fakebin="$world/fakebin"
    mkdir -p "$test_home/state" "$test_home/config" "$fakebin" "$primary/bin"
    git init -q -b main "$primary"
    printf 'state/\ndata/\nconfig/\nprojects/\n.fm-secondmate-home\n' > "$primary/.gitignore"
    printf 'initial instructions\n' > "$primary/AGENTS.md"
    printf 'true\n' > "$primary/bin/tool.sh"
    git -C "$primary" add .
    git -C "$primary" commit -qm initial
    git -C "$primary" worktree add -q --detach "$mate" HEAD
    printf 'mini\n' > "$mate/.fm-secondmate-home"
    printf 'window=firstmate:fm-mini\nkind=secondmate\nharness=codex\nhome=%s\n' "$mate" > "$test_home/state/mini.meta"
    printf '%s\n' "$$" > "$test_home/state/.lock"
    printf 'updated instructions\n' > "$primary/AGENTS.md"
    git -C "$primary" commit -qam update
    fm_fake_exit0 "$fakebin" gh
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*) printf 'fm-mini\n' ;;
  *display-message*'#{pane_current_command}'*) printf 'codex\n' ;;
  *display-message*'#{pane_id}'*) printf '%%1\n' ;;
  *display-message*'#{cursor_y}'*) printf '0\n' ;;
  *capture-pane*) printf '❯\n' ;;
esac
exit 0
SH
    chmod +x "$fakebin/tmux"
    write_active_receipt "$test_home"
    printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    [ "$scenario" != failure ] || : > "$test_home/state/mini.inbox"
    out=$(PATH="$fakebin:$PATH" FM_HOME="$test_home" FM_ROOT_OVERRIDE="$primary" \
      FM_BACKEND=tmux FM_SEND_SETTLE=0 FM_BOOTSTRAP_NETWORK=only "$ROOT/bin/fm-bootstrap.sh" 2>&1); status=$?
    expect_code 0 "$status" "bootstrap must complete with malformed evidence: $out"
    assert_not_contains "$out" AUTOMATIC_MONITORING_STOP "background bootstrap claimed a visible notice"
    assert_absent "$test_home/state/.monitoring-stop-reports" "nested send consumed the visible notice"
    assert_not_contains "$out" 'TURN WOULD END BLIND' "bootstrap prompted re-arm under a stop"
    [ "$(cat "$test_home/state/.lock")" = "$$" ] || fail "bootstrap relinquished session ownership"
    assert_absent "$test_home/state/.watch.lock" "bootstrap armed a stopped watcher"
    if [ "$scenario" = success ]; then
      assert_contains "$out" 'BOOTSTRAP_INFO: nudged fm-mini' "stop blocked the startup nudge: $out"
      assert_contains "$(cat "$test_home/state/mini.inbox/001.msg")" 'please re-read your AGENTS.md' "startup nudge was not delivered"
    else
      assert_contains "$out" 'NUDGE_SECONDMATES: secondmate mini: send failed:' "bootstrap lost the send failure behind the stop notice"
      assert_not_contains "$out" 'send failed: AUTOMATIC_MONITORING_STOP' "bootstrap repeated the stop notice as a send failure"
      assert_present "$test_home/state/.secondmate-nudge-pending/mini.pending" "failed nudge lost retry marker"
      rm "$test_home/state/mini.inbox"
    fi
    second=$(PATH="$fakebin:$PATH" FM_HOME="$test_home" FM_ROOT_OVERRIDE="$primary" \
      FM_BACKEND=tmux FM_SEND_SETTLE=0 FM_BOOTSTRAP_NETWORK=only "$ROOT/bin/fm-bootstrap.sh" 2>&1)
    assert_not_contains "$second" AUTOMATIC_MONITORING_STOP "bootstrap repeated the stop diagnostic"
    assert_absent "$test_home/state/.secondmate-nudge-pending/mini.pending" "successful retry retained its marker: $second"
    assert_contains "$(cat "$test_home/state/mini.inbox/001.msg")" 'please re-read your AGENTS.md' "bootstrap retry did not deliver the nudge"
    second=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$primary" "$ROOT/bin/fm-guard.sh" 2>&1)
    assert_not_contains "$second" AUTOMATIC_MONITORING_STOP "operation guard claimed a visible notice"
    assert_absent "$test_home/state/.monitoring-stop-reports" "background operations claimed the notice"
    out=$(printf '{}' | FM_HOME="$test_home" FM_ROOT_OVERRIDE="$primary" "$ROOT/bin/fm-turnend-guard.sh" 2>&1); status=$?
    expect_code 0 "$status" "visible turn-end must be nonblocking under stop"
    assert_contains "$out" AUTOMATIC_MONITORING_STOP_INVALID "visible turn-end lost background-observed evidence"
    second=$(printf '{}' | FM_HOME="$test_home" FM_ROOT_OVERRIDE="$primary" "$ROOT/bin/fm-turnend-guard.sh" 2>&1)
    assert_not_contains "$second" AUTOMATIC_MONITORING_STOP "visible boundary repeated its notice"
  done
  pass "startup preserves live secondmates and nudge delivery without claiming visible notices"
}

test_opencode_idle_reports_arm_suppression_race() {
  local test_home kind out status
  for kind in active malformed; do
    test_home="$TMP_ROOT/opencode-idle-$kind"
    make_guard_home "$test_home"
    write_active_receipt "$test_home"
    [ "$kind" != malformed ] || printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    mv "$test_home/bin/fm-watch-arm.sh" "$test_home/bin/fm-watch-arm-real.sh"
    cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_HOME/arm-attempts"
mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
"$FM_HOME/bin/fm-watch-arm-real.sh" "$@"
status=$?
printf '%s\n' "$status" > "$FM_HOME/arm-status"
exit "$status"
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh"
    out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ROOT="$ROOT" STOP_KIND="$kind" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
const root = process.env.ROOT;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${home}/state/task.meta`, "kind=ship\n");
const messages = [];
let continuations = 0;
const client = { session: {
  prompt: async (request) => {
    assert.equal(request.path.id, "test");
    assert.equal(request.body.noReply, true);
    messages.push(request.body.parts[0].text);
  },
  promptAsync: async () => { continuations++; },
} };
const { FmPrimaryWatchArm } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`));
const { FmPrimaryTurnendGuard } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`));
await FmPrimaryWatchArm({ worktree: home, client });
const hooks = await FmPrimaryTurnendGuard({ worktree: home, client });
const idle = { event: { type: "session.idle", properties: { sessionID: "test" } } };
await hooks.event(idle);
assert.equal(readFileSync(`${home}/arm-status`, "utf8").trim(), "3");
assert.equal(messages.length, 1, "current idle swallowed arm suppression diagnostic");
if (process.env.STOP_KIND === "malformed") {
  assert.match(messages[0], /AUTOMATIC_MONITORING_STOP_INVALID:.*valid JSON/);
} else {
  assert.match(messages[0], /monitoring stopped by Captain order at 2026-09-21/);
}
assert.equal(continuations, 0, "suppression requested a repair turn");
assert.equal(existsSync(`${home}/state/.watch.lock`), false);
assert.equal(readFileSync(`${home}/state/.lock`, "utf8").trim(), String(process.pid));
assert.equal(await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("test", client),
  "stopped");
await hooks.event(idle);
assert.equal(messages.length, 1, "later idle repeated the diagnostic");
assert.equal(readFileSync(`${home}/arm-attempts`, "utf8"), "attempt\n", "suppression retried the arm");
assert.equal(continuations, 0);
JS
); status=$?
    expect_code 0 "$status" "OpenCode must report $kind arm suppression in the same idle: $out"
  done
  pass "OpenCode propagates arm suppression to nonblocking reporting in the current idle"
}

test_background_refresh_cannot_consume_visible_notice() {
  local test_home kind out status
  for kind in active malformed absent resumed; do
    test_home="$TMP_ROOT/background-$kind"
    make_guard_home "$test_home"
    mkdir -p "$test_home/projects"
    printf 'kind=ship\n' > "$test_home/state/task.meta"
    if [ "$kind" != absent ]; then
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
    fi
    FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-fleet-sync.sh" >/dev/null 2>&1
    assert_absent "$test_home/state/.monitoring-stop-reports" "background fleet refresh consumed $kind notice"
    out=$(printf '{}' | FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-turnend-guard.sh" 2>&1); status=$?
    case "$kind" in
      active|malformed)
        expect_code 0 "$status" "$kind primary turn-end prompted repair: $out"
        assert_contains "$out" AUTOMATIC_MONITORING_STOP "visible primary turn-end lost $kind notice"
        assert_not_contains "$out" 'TURN WOULD END BLIND' "$kind receipt prompted repair"
        out=$(printf '{}' | FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-turnend-guard.sh" 2>&1)
        [ -z "$out" ] || fail "visible primary turn-end repeated $kind notice: $out"
        ;;
      *)
        expect_code 2 "$status" "$kind work lost ordinary supervision: $out"
        assert_contains "$out" 'TURN WOULD END BLIND' "$kind work lost repair reporting"
        ;;
    esac
  done
  pass "background refresh leaves once-only notices to primary turn-end, preserving normal supervision"
}

make_watch_extension_fixture() {
  local test_home=$1
  mkdir -p "$test_home/.pi/extensions" "$test_home/.omp/extensions" \
    "$test_home/node_modules/@earendil-works/pi-tui" "$test_home/node_modules/typebox" \
    "$test_home/node_modules/@earendil-works/pi-coding-agent"
  cp -R "$ROOT/.pi/extensions/lib" "$test_home/.pi/extensions/"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$test_home/.pi/extensions/"
  cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$test_home/.omp/extensions/"
  printf '{"type":"module","exports":"./index.js"}\n' > "$test_home/node_modules/@earendil-works/pi-tui/package.json"
  printf 'export class Box { addChild(){} clear(){} setBgFn(){} }; export class Container {}; export class Text {};\n' > "$test_home/node_modules/@earendil-works/pi-tui/index.js"
  printf '{"type":"module","exports":"./index.js"}\n' > "$test_home/node_modules/typebox/package.json"
  printf 'export const Type = {Object: (properties) => ({type:"object",properties})};\n' > "$test_home/node_modules/typebox/index.js"
  printf '{"type":"module","exports":"./index.js"}\n' > "$test_home/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf 'export function getMarkdownTheme(){return {}}; export class UserMessageComponent {render(){return []} invalidate(){}};\n' > "$test_home/node_modules/@earendil-works/pi-coding-agent/index.js"
}

test_pi_and_omp_late_suppression_is_not_failure() {
  local test_home adapter kind out status
  for adapter in pi omp; do
    for kind in active malformed timeout absent resumed failure; do
      test_home="$TMP_ROOT/late-$adapter-$kind"
      make_guard_home "$test_home"
      make_watch_extension_fixture "$test_home"
      write_active_receipt "$test_home"
      [ "$kind" != malformed ] || printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      if [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
      mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
      mv "$test_home/bin/fm-watch-arm.sh" "$test_home/bin/fm-watch-arm-real.sh"
      cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_HOME/attempts"
count=$(wc -l < "$FM_HOME/attempts" | tr -d '[:space:]')
case "$count" in
  1) printf 'watcher: started pid=%s (beacon fresh)\nsignal: test outcome\n' "$$"; exit 0 ;;
  2) exit 1 ;;
esac
case "$STOP_KIND" in
  active|malformed)
    mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
    exec "$FM_HOME/bin/fm-watch-arm-real.sh" "$@"
    ;;
  timeout) mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json" ;;
  resumed)
    mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    ;;
  absent) printf 'watcher: started pid=%s (beacon fresh)\n' "$$" ;;
  failure) exit 1 ;;
esac
trap 'exit 0' TERM INT
for ((i=0; i<200; i++)); do sleep 0.05; done
SH
      chmod +x "$test_home/bin/fm-watch-arm.sh"
      out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ADAPTER="$adapter" STOP_KIND="$kind" \
        FM_PI_ARM_READY_TIMEOUT_MS=2000 FM_OMP_ARM_READY_TIMEOUT_MS=2000 FM_WATCH_REARM_RETRY_LIMIT=1 \
        FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME, adapter = process.env.ADAPTER, kind = process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(), messages = [];
let tool;
const api = {
  on: (name, handler) => handlers.set(name, handler),
  registerTool: (value) => { tool = value; },
  registerCommand() {},
  sendUserMessage: async (message) => { messages.push(message); },
};
const mod = await import(pathToFileURL(`${home}/.${adapter}/extensions/fm-primary-${adapter === "pi" ? "pi" : "omp"}-watch.ts`));
mod.default(api);
await tool.execute("start", {}, undefined, undefined, {});
try {
  const deadline = Date.now() + 12000;
  while (!messages.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(messages.length, 1, `expected original outcome, got ${messages}`);
  assert.match(messages[0], /signal: test outcome/);
  assert.equal(readFileSync(`${home}/attempts`, "utf8"), "attempt\nattempt\nattempt\n");
  if (kind === "failure") assert.match(messages[0], /could not restore watcher continuity/);
  else assert.doesNotMatch(messages[0], /watcher: FAILED|could not restore|repair missing/);
  assert.equal(readFileSync(`${home}/state/.lock`, "utf8").trim(), String(process.pid));
  assert.equal(existsSync(`${home}/state/.monitoring-stop-reports`), false, "background readiness claimed notice");
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(messages.length, 1, "suppression retried or requested repair");
} finally {
  await handlers.get("session_shutdown")({reason:"quit"});
}
JS
); status=$?
      expect_code 0 "$status" "$adapter $kind readiness must distinguish stop and failure: $out"
    done
  done
  pass "Pi and omp distinguish final-attempt stops, timeouts, failures, and ordinary readiness"
}

test_startup_liveness_respects_monitoring_policy() {
  local test_home kind out status fakebin
  for kind in active malformed absent resumed; do
    test_home="$TMP_ROOT/startup-liveness-$kind"
    make_guard_home "$test_home"
    fakebin="$test_home/fakebin"
    mkdir -p "$fakebin"
    fm_fake_exit0 "$fakebin" gh
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*) printf 'fm-mini\n' ;;
  *display-message*'#{pane_current_command}'*) printf 'zsh\n' ;;
esac
exit 0
SH
    cat > "$test_home/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/respawns"
SH
    chmod +x "$fakebin/tmux" "$test_home/bin/fm-spawn.sh"
    printf 'kind=secondmate\nharness=codex\nwindow=firstmate:fm-mini\n' > "$test_home/state/mini.meta"
    cp "$test_home/state/mini.meta" "$test_home/meta.before"
    if [ "$kind" != absent ]; then
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
    fi
    out=$(PATH="$fakebin:$PATH" FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" FM_BACKEND=tmux \
      FM_BOOTSTRAP_NETWORK=only "$test_home/bin/fm-bootstrap.sh" 2>&1); status=$?
    expect_code 0 "$status" "$kind startup liveness failed: $out"
    case "$kind" in
      active|malformed) assert_absent "$test_home/respawns" "$kind startup restarted parked infrastructure" ;;
      *) [ "$(cat "$test_home/respawns")" = 'mini --secondmate' ] || fail "$kind startup lost ordinary liveness: $out" ;;
    esac
    cmp "$test_home/meta.before" "$test_home/state/mini.meta" || fail "startup changed persistent metadata"
    assert_absent "$test_home/state/.monitoring-stop-reports" "background liveness claimed visible notice"
  done
  pass "startup liveness suppresses stopped relaunches and preserves absent/resumed recovery"
}

test_claude_late_stop_is_terminal_without_repair() {
  local test_home out status
  test_home="$TMP_ROOT/claude-late-stop"
  make_guard_home "$test_home"
  mkdir -p "$test_home/data/automatic-monitoring-pause"
  printf 'kind=ship\n' > "$test_home/state/work.meta"
  cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_HOME/attempts"
printf '{bad json\n' > "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
exit 3
SH
  chmod +x "$test_home/bin/fm-watch-arm.sh"
  out=$(printf '{"session_id":"late-stop","stop_hook_active":false}' \
    | env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" \
      "$TMP_ROOT/harnesses/claude" "$test_home/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "Claude suppression requested repair: $out"
  [ "$(cat "$test_home/attempts")" = attempt ] || fail "Claude retried an intentionally stopped arm"
  [ -z "$out" ] || fail "background Claude arm emitted a repair prompt: $out"
  assert_absent "$test_home/state/.monitoring-stop-reports" "background Claude arm claimed a visible notice"
  out=$(printf '{}' | FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" "$test_home/bin/fm-turnend-guard.sh" 2>&1)
  assert_contains "$out" AUTOMATIC_MONITORING_STOP_INVALID "primary turn-end lost late-stop notice"
  pass "Claude treats late arm suppression as terminal and leaves notice to primary turn-end"
}

test_cursor_fallback_delivers_late_stop_as_json() {
  local test_home kind out status
  for kind in active malformed absent resumed; do
    test_home="$TMP_ROOT/cursor-fallback-$kind"
    make_guard_home "$test_home"
    write_active_receipt "$test_home"
    case "$kind" in
      malformed) printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json" ;;
      resumed)
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
        ;;
    esac
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    printf 'kind=ship\n' > "$test_home/state/work.meta"
    # shellcheck disable=SC2016 # The generated script expands FM_HOME when it runs.
    printf '#!/usr/bin/env bash\nprintf "attempt\\n" >> "$FM_HOME/attempts"\nexit 1\n' > "$test_home/bin/fm-watch-arm.sh"
    mv "$test_home/bin/fm-turnend-guard.sh" "$test_home/bin/fm-turnend-guard-real.sh"
    cat > "$test_home/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
if [ "$STOP_KIND" != absent ] && [ -f "$FM_HOME/receipt.ready" ]; then
  mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
fi
exec "$FM_HOME/bin/fm-turnend-guard-real.sh" "$@"
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh" "$test_home/bin/fm-turnend-guard.sh"
    cat > "$test_home/turns.sh" <<'SH'
#!/usr/bin/env bash
payload='{"session_id":"fallback","loop_count":0,"cursor_version":"test"}'
cp "$FM_HOME/state/.lock" "$FM_HOME/owner.before"
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/first" || exit 1
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/second" || exit 1
cmp "$FM_HOME/owner.before" "$FM_HOME/state/.lock"
SH
    out=$(env -u PI_CODING_AGENT FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" STOP_KIND="$kind" \
      FM_CURSOR_PARK_ATTEMPTS=1 FM_CURSOR_PARK_POLL=1 "$TMP_ROOT/harnesses/cursor-agent" "$test_home/turns.sh" 2>&1); status=$?
    expect_code 0 "$status" "Cursor $kind fallback failed: $out"
    out=$(jq -se 'if length == 1 and (.[0].followup_message | type == "string") then .[0].followup_message else error("expected one follow-up") end' "$test_home/first") \
      || fail "Cursor $kind fallback did not emit one visible JSON follow-up: $(cat "$test_home/first")"
    case "$kind" in
      active|malformed)
        assert_contains "$out" AUTOMATIC_MONITORING_STOP "Cursor lost the successful guard diagnostic"
        assert_not_contains "$out" 'TURN WOULD END BLIND' "Cursor requested repair under $kind evidence"
        [ ! -s "$test_home/second" ] || fail "Cursor repeated its once-only notice"
        [ "$(cat "$test_home/attempts")" = attempt ] || fail "Cursor rearmed after late stop"
        assert_absent "$test_home/state/.turnend-cursor-blocks" "stop diagnostic spent Cursor's repair budget"
        ;;
      *)
        assert_contains "$out" 'TURN WOULD END BLIND' "Cursor $kind fallback lost ordinary failure reporting"
        [ -s "$test_home/state/.turnend-cursor-blocks" ] || fail "ordinary failure did not retain bounded repair budget"
        ;;
    esac
  done
  pass "Cursor encodes late successful guard diagnostics once and preserves ordinary repair output"
}

test_opencode_stopped_successor_preserves_outcome_without_failure() {
  local test_home kind out status
  for kind in active malformed absent resumed success; do
    test_home="$TMP_ROOT/opencode-delivery-$kind"
    make_guard_home "$test_home"
    write_active_receipt "$test_home"
    if [ "$kind" = malformed ]; then
      printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    elif [ "$kind" = resumed ]; then
      jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
        "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
      mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
    fi
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmation\n' >> "$FM_HOME/confirmations"
  case "$STOP_KIND" in
    active|malformed)
      for ((i=0; i<100; i++)); do
        [ -f "$FM_HOME/stopped" ] && break
        sleep 0.02
      done
      ;;
    success) exit 0 ;;
  esac
  exit 1
fi
printf 'attempt\n' >> "$FM_HOME/attempts"
count=$(wc -l < "$FM_HOME/attempts" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'signal: queued delivery outcome\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_HOME/successor.pid"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=delivery-test\n' "$$"
case "$STOP_KIND" in
  active|malformed)
    mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
    touch "$FM_HOME/stopped"
    exit 0
    ;;
  resumed) mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json" ;;
esac
trap 'exit 0' TERM INT
for ((i=0; i<400; i++)); do sleep 0.05; done
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh"
    out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ROOT="$ROOT" STOP_KIND="$kind" NODE_NO_WARNINGS=1 \
      node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME, root = process.env.ROOT, kind = process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${home}/state/work.meta`, "kind=ship\n");
const outcome = "1\t1\tsignal\ttask\tsignal: queued delivery outcome\n";
writeFileSync(`${home}/state/.wake-queue`, outcome);
const wakes = [], notices = [];
const client = { session: {
  promptAsync: async request => wakes.push(request.body.parts[0].text),
  prompt: async request => {
    assert.equal(request.body.noReply, true);
    notices.push(request.body.parts[0].text);
  },
} };
const { FmPrimaryWatchArm } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`));
const { FmPrimaryTurnendGuard } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`));
await FmPrimaryWatchArm({worktree: home, client});
const guard = await FmPrimaryTurnendGuard({worktree: home, client});
try {
  await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("test", client);
  const deadline = Date.now() + 12000;
  while (!wakes.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(wakes.length, 1, `actionable outcome missing or duplicated: ${wakes}`);
  assert.match(wakes[0], /signal: queued delivery outcome/);
  assert.equal(readFileSync(`${home}/state/.wake-queue`, "utf8"), outcome, "delivery consumed queued outcome");
  assert.equal(readFileSync(`${home}/attempts`, "utf8"), "attempt\nattempt\n");
  const confirmations = existsSync(`${home}/confirmations`) ? readFileSync(`${home}/confirmations`, "utf8").trim().split("\n").length : 0;
  if (kind === "active" || kind === "malformed") {
    assert.doesNotMatch(wakes[0], /watcher: FAILED|re-arm|repair|could not restore/);
    assert.ok(confirmations <= 1, "stopped successor retried confirmation");
    const idle = {event:{type:"session.idle",properties:{sessionID:"test"}}};
    await guard.event(idle);
    await guard.event(idle);
    assert.equal(notices.length, 1, "late stop did not remain visibly reportable exactly once");
    assert.match(notices[0], /AUTOMATIC_MONITORING_STOP/);
    assert.equal(wakes.length, 1, "stop diagnostic prompted a repair turn");
  } else if (kind === "success") {
    assert.equal(confirmations, 1);
    assert.doesNotMatch(wakes[0], /watcher: FAILED/);
  } else {
    assert.equal(confirmations, 2);
    assert.match(wakes[0], /watcher: FAILED - handling delivery confirmation was rejected/);
  }
  assert.equal(readFileSync(`${home}/state/.lock`, "utf8").trim(), String(process.pid));
} finally {
  unlinkSync(`${home}/state/.lock`);
  if (existsSync(`${home}/successor.pid`)) {
    const pid = Number(readFileSync(`${home}/successor.pid`, "utf8"));
    try { process.kill(pid, "SIGTERM"); } catch {}
    for (let i = 0; i < 100; i++) {
      try { process.kill(pid, 0); } catch { break; }
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
}
JS
); status=$?
    expect_code 0 "$status" "OpenCode $kind delivery must preserve outcome and stop semantics: $out"
  done
  pass "OpenCode suppresses stopped-successor confirmation failures while preserving queued outcomes"
}

test_pi_and_omp_stop_during_handling_confirmation() {
  local test_home adapter kind out status
  for adapter in pi omp; do
    for kind in active malformed absent resumed success; do
      test_home="$TMP_ROOT/confirmation-$adapter-$kind"
      make_guard_home "$test_home"
      make_watch_extension_fixture "$test_home"
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
      mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
      cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmation\n' >> "$FM_HOME/confirmations"
  if [ -f "$FM_HOME/receipt.ready" ]; then
    case "$STOP_KIND" in
      active|malformed|resumed) mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json" ;;
    esac
  fi
  case "$STOP_KIND" in
    active|malformed) kill -TERM "$4" ;;
    success) exit 0 ;;
  esac
  exit 1
fi
printf 'attempt\n' >> "$FM_HOME/attempts"
count=$(wc -l < "$FM_HOME/attempts" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\nsignal: confirmation outcome\n' "$$"
  exit 0
fi
trap 'exit 1' TERM INT
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=confirmation-test\n' "$$"
for ((i=0; i<400; i++)); do sleep 0.05; done
SH
      chmod +x "$test_home/bin/fm-watch-arm.sh"
      out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ADAPTER="$adapter" STOP_KIND="$kind" \
        NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME, adapter = process.env.ADAPTER, kind = process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const queue = "1\t1\tsignal\ttask\tsignal: confirmation outcome\n";
writeFileSync(`${home}/state/.wake-queue`, queue);
const handlers = new Map(), messages = [];
let tool;
const api = {
  on: (name, handler) => handlers.set(name, handler),
  registerTool: value => { tool = value; },
  registerCommand() {},
  sendUserMessage: async message => { messages.push(message); },
};
const mod = await import(pathToFileURL(`${home}/.${adapter}/extensions/fm-primary-${adapter}-watch.ts`));
mod.default(api);
try {
  await tool.execute("start", {}, undefined, undefined, {});
  const deadline = Date.now() + 12000;
  while (!messages.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(messages.length, 1, `missing or duplicated outcome: ${messages}`);
  assert.match(messages[0], /signal: confirmation outcome/);
  assert.equal(readFileSync(`${home}/state/.wake-queue`, "utf8"), queue);
  assert.equal(readFileSync(`${home}/attempts`, "utf8"), "attempt\nattempt\n");
  const stopped = kind === "active" || kind === "malformed";
  const confirmations = readFileSync(`${home}/confirmations`, "utf8").trim().split("\n").length;
  assert.equal(confirmations, stopped || kind === "success" ? 1 : 2);
  if (stopped || kind === "success") assert.doesNotMatch(messages[0], /watcher: FAILED|repair|re-arm/);
  else assert.match(messages[0], /watcher: FAILED - handling delivery confirmation was rejected/);
  assert.equal(existsSync(`${home}/state/.monitoring-stop-reports`), false);
  assert.equal(readFileSync(`${home}/state/.lock`, "utf8").trim(), String(process.pid));
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(messages.length, 1);
} finally {
  await handlers.get("session_shutdown")({reason:"quit"});
}
JS
); status=$?
      expect_code 0 "$status" "$adapter $kind handling confirmation broke stop semantics: $out"
    done
  done
  pass "Pi and omp preserve queued outcomes when stopped during handling confirmation"
}

test_running_and_attached_arm_stop_on_termination() {
  local test_home mode kind out status
  for mode in started attached; do
    for kind in active malformed absent resumed; do
      test_home="$TMP_ROOT/termination-$mode-$kind"
      make_guard_home "$test_home"
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
      mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
      mkdir -p "$test_home/fakebin"
      # shellcheck disable=SC2016 # The generated script reads its own first argument.
      printf '#!/usr/bin/env bash\n[ "${1:-}" = list-windows ]\n' > "$test_home/fakebin/tmux"
      chmod +x "$test_home/fakebin/tmux"
      touch "$test_home/state/home-summary.json"
      out=$(PATH="$test_home/fakebin:$PATH" FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ARM_MODE="$mode" STOP_KIND="$kind" \
        FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=1 FM_ARM_ATTACH_POLL=0.1 \
        python3 - 2>&1 <<'PYTEST'
import os, signal, subprocess, time
from pathlib import Path
home = Path(os.environ['FM_HOME'])
mode, kind = os.environ['ARM_MODE'], os.environ['STOP_KIND']
state = home / 'state'
(state / '.lock').write_text(str(os.getpid()) + '\n')
seed = arm = None
watcher_pid = None
def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('timed out waiting for watcher readiness')
try:
    with (home / 'watch.out').open('w') as watcher_out, (home / 'arm.out').open('w') as arm_out:
        if mode == 'attached':
            seed = subprocess.Popen([str(home / 'bin/fm-watch.sh')], stdout=watcher_out, stderr=watcher_out)
            wait_for(lambda: (state / '.last-watcher-beat').exists())
        arm = subprocess.Popen([str(home / 'bin/fm-watch-arm.sh')], stdout=arm_out, stderr=arm_out)
        wait_for(lambda: f'watcher: {mode} pid=' in (home / 'arm.out').read_text())
        watcher_pid = int((state / '.watch.lock/pid').read_text())
        if kind != 'absent':
            (home / 'receipt.ready').rename(home / 'data/automatic-monitoring-pause/receipt.json')
        os.kill(watcher_pid, signal.SIGTERM)
        code = arm.wait(timeout=12)
        if seed:
            seed.wait(timeout=5)
    output = (home / 'arm.out').read_text()
    if kind in ('active', 'malformed'):
        assert code == 3, (code, output)
        assert 'watcher: FAILED' not in output, output
        assert not (state / '.monitoring-stop-reports').exists()
    else:
        assert code not in (0, 3), (code, output)
        assert 'watcher: FAILED' in output, output
    assert (state / '.lock').read_text().strip() == str(os.getpid())
finally:
    for process in (arm, seed):
        if process and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    if watcher_pid:
        try: os.kill(watcher_pid, signal.SIGTERM)
        except ProcessLookupError: pass
PYTEST
); status=$?
      expect_code 0 "$status" "$mode arm $kind termination misreported its outcome: $out"
    done
  done
  pass "started and attached arms classify operator termination as stopped without hiding ordinary failures"
}

test_superseded_cursor_park_cannot_claim_stop_notice() {
  local test_home kind out status
  for kind in active malformed; do
    test_home="$TMP_ROOT/cursor-superseded-$kind"
    make_guard_home "$test_home"
    write_active_receipt "$test_home"
    [ "$kind" != malformed ] || printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    printf 'kind=ship\n' > "$test_home/state/work.meta"
    # shellcheck disable=SC2016 # The generated script expands FM_HOME when it runs.
    printf '#!/usr/bin/env bash\nprintf "attempt\\n" >> "$FM_HOME/attempts"\nexit 1\n' > "$test_home/bin/fm-watch-arm.sh"
    mv "$test_home/bin/fm-turnend-guard.sh" "$test_home/bin/fm-turnend-guard-real.sh"
    cat > "$test_home/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
"$FM_HOME/bin/fm-turnend-guard-real.sh" "$@" > "$FM_HOME/guard-output"
status=$?
touch "$FM_HOME/guard-finished"
for ((i=0; i<400; i++)); do
  [ -f "$FM_HOME/release-guard" ] && break
  sleep 0.05
done
cat "$FM_HOME/guard-output"
exit "$status"
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh" "$test_home/bin/fm-turnend-guard.sh"
    cat > "$test_home/turns.sh" <<'SH'
#!/usr/bin/env bash
payload='{"session_id":"superseded","loop_count":0,"cursor_version":"test"}'
cp "$FM_HOME/state/.lock" "$FM_HOME/owner.before"
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/first" &
first=$!
trap 'touch "$FM_HOME/release-guard"; wait "$first"' EXIT
for ((i=0; i<400; i++)); do
  [ -f "$FM_HOME/guard-finished" ] && break
  sleep 0.05
done
[ -f "$FM_HOME/guard-finished" ] || exit 1
[ ! -e "$FM_HOME/state/.monitoring-stop-reports" ] || exit 2
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/second" || exit 3
touch "$FM_HOME/release-guard"
wait "$first" || exit 4
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/third" || exit 5
cmp "$FM_HOME/owner.before" "$FM_HOME/state/.lock"
SH
    out=$(env -u PI_CODING_AGENT FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" \
      FM_CURSOR_PARK_ATTEMPTS=1 FM_CURSOR_PARK_POLL=1 "$TMP_ROOT/harnesses/cursor-agent" "$test_home/turns.sh" 2>&1); status=$?
    expect_code 0 "$status" "Cursor $kind superseded park consumed notice before ownership check: $out"
    [ ! -s "$test_home/first" ] || fail "superseded Cursor park emitted output"
    out=$(jq -er .followup_message "$test_home/second") || fail "replacement Cursor park lost visible diagnostic"
    assert_contains "$out" AUTOMATIC_MONITORING_STOP "replacement Cursor park lost stop notice"
    assert_not_contains "$out" 'TURN WOULD END BLIND' "replacement Cursor park requested repair"
    [ ! -s "$test_home/third" ] || fail "Cursor repeated its once-only notice"
    [ "$(cat "$test_home/attempts")" = attempt ] || fail "Cursor relaunched monitoring under a stop"
  done
  pass "Cursor claims stop notices only while the delivering park owns its output"
}

test_checkpoint_rechecks_stop_at_completion() {
  local test_home kind outcome out status expected
  for outcome in exit timeout wake; do
    for kind in active malformed absent resumed; do
      test_home="$TMP_ROOT/checkpoint-completion-$outcome-$kind"
      make_guard_home "$test_home"
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
      mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
      printf '1\t1\tsignal\ttask\tsignal: durable checkpoint outcome\n' > "$test_home/state/.wake-queue"
      cp "$test_home/state/.wake-queue" "$test_home/queue.before"
      cat > "$test_home/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
[ "$STOP_KIND" = absent ] || mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
case "$WATCH_OUTCOME" in
  exit) printf 'watcher: FAILED - test watcher terminated\n'; exit 1 ;;
  wake) printf 'signal: durable checkpoint outcome\n'; exit 0 ;;
esac
trap 'exit 1' TERM INT
for ((i=0; i<100; i++)); do sleep 0.05; done
SH
      chmod +x "$test_home/bin/fm-watch.sh"
      out=$(FM_HOME="$test_home" STOP_KIND="$kind" WATCH_OUTCOME="$outcome" FM_SIGNAL_GRACE=1 \
        "$test_home/bin/fm-watch-checkpoint.sh" --seconds 1 2>&1); status=$?
      case "$kind" in
        active|malformed)
          expect_code 3 "$status" "late $kind checkpoint $outcome was not intentionally stopped: $out"
          assert_contains "$out" AUTOMATIC_MONITORING_STOP "checkpoint lost its visible stop diagnostic"
          assert_not_contains "$out" 'watcher: FAILED' "stopped checkpoint requested recovery"
          assert_not_contains "$out" 'no actionable wake within' "stopped checkpoint requested another timeout cycle"
          ;;
        *)
          case "$outcome" in
            exit) expected=1; assert_contains "$out" 'watcher: FAILED' "ordinary checkpoint failure was hidden" ;;
            timeout) expected=124; assert_contains "$out" 'no actionable wake within 1s' "ordinary checkpoint timeout was hidden" ;;
            wake) expected=0 ;;
          esac
          expect_code "$expected" "$status" "$kind checkpoint changed ordinary $outcome handling: $out"
          ;;
      esac
      [ "$outcome" != wake ] || assert_contains "$out" 'signal: durable checkpoint outcome' "stop lost the completed watcher outcome"
      cmp "$test_home/queue.before" "$test_home/state/.wake-queue" || fail "checkpoint consumed queued work"
    done
  done
  pass "checkpoint completion rechecks late stops while preserving wakes and ordinary failures"
}

test_opencode_suppresses_failure_stopped_during_encoding() {
  local test_home kind out status
  for kind in active malformed absent resumed; do
    test_home="$TMP_ROOT/opencode-encoding-$kind"
    make_guard_home "$test_home"
    write_active_receipt "$test_home"
    if [ "$kind" = malformed ]; then
      printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
    elif [ "$kind" = resumed ]; then
      jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
        "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
      mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
    fi
    mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
    printf '#!/usr/bin/env bash\necho "watcher: FAILED - fixture failure"\nexit 1\n' > "$test_home/bin/fm-watch-arm.sh"
    mv "$test_home/bin/fm-operational-input.sh" "$test_home/bin/fm-operational-input-real.sh"
    cat > "$test_home/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/encoding-started"
for ((i=0; i<400; i++)); do
  [ -f "$FM_HOME/release-encoder" ] && break
  sleep 0.01
done
"$FM_HOME/bin/fm-operational-input-real.sh" "$@"
status=$?
touch "$FM_HOME/encoding-finished"
exit "$status"
SH
    chmod +x "$test_home/bin/fm-watch-arm.sh" "$test_home/bin/fm-operational-input.sh"
    out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ROOT="$ROOT" STOP_KIND="$kind" NODE_NO_WARNINGS=1 \
      FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
      node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME, root = process.env.ROOT, kind = process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${home}/state/work.meta`, "kind=ship\n");
const queue = "1\t1\tsignal\ttask\tsignal: encoding outcome\n";
writeFileSync(`${home}/state/.wake-queue`, queue);
const failures = [], notices = [];
const client = {session:{
  promptAsync: async request => failures.push(request.body.parts[0].text),
  prompt: async request => { assert.equal(request.body.noReply, true); notices.push(request.body.parts[0].text); },
}};
const { FmPrimaryWatchArm } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`));
const { FmPrimaryTurnendGuard } = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`));
await FmPrimaryWatchArm({worktree:home, client});
const guard = await FmPrimaryTurnendGuard({worktree:home, client});
const waitFor = async predicate => {
  const deadline = Date.now() + 6000;
  while (!predicate() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
  assert.ok(predicate(), "expected asynchronous encoding boundary was not reached");
};
try {
  await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("test", client);
  await waitFor(() => existsSync(`${home}/encoding-started`));
  assert.equal(failures.length, 0);
  if (kind !== "absent") renameSync(`${home}/receipt.ready`, `${home}/data/automatic-monitoring-pause/receipt.json`);
  writeFileSync(`${home}/release-encoder`, "");
  await waitFor(() => existsSync(`${home}/encoding-finished`));
  await new Promise(resolve => setTimeout(resolve, 200));
  if (kind === "active" || kind === "malformed") {
    assert.equal(failures.length, 0, `stopped failure requested repair: ${failures}`);
    assert.equal(existsSync(`${home}/state/.monitoring-stop-reports`), false);
    const idle = {event:{type:"session.idle",properties:{sessionID:"test"}}};
    await guard.event(idle);
    await guard.event(idle);
    assert.equal(notices.length, 1);
    assert.match(notices[0], /AUTOMATIC_MONITORING_STOP/);
    assert.equal(failures.length, 0);
  } else {
    assert.ok(failures.length > 0, "ordinary exhausted failure was hidden");
    assert.ok(failures.every(message => message.includes("watcher: FAILED")));
  }
  assert.equal(readFileSync(`${home}/state/.wake-queue`, "utf8"), queue);
  assert.equal(readFileSync(`${home}/state/.lock`, "utf8").trim(), String(process.pid));
} finally {
  writeFileSync(`${home}/release-encoder`, "");
  unlinkSync(`${home}/state/.lock`);
}
JS
); status=$?
    expect_code 0 "$status" "OpenCode $kind failure encoding ignored the final stop verdict: $out"
  done
  pass "OpenCode suppresses failure-only prompts stopped during asynchronous encoding"
}

test_bootstrap_rechecks_stop_after_secondmate_probes() {
  local test_home kind probe out status fakebin
  for probe in remote-readiness remote-state local-dead local-missing; do
    for kind in active malformed absent resumed; do
      test_home="$TMP_ROOT/probe-$probe-$kind"
      make_guard_home "$test_home"
      write_active_receipt "$test_home"
      if [ "$kind" = malformed ]; then
        printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
      elif [ "$kind" = resumed ]; then
        jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
          "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
        mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
      fi
      mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
      printf 'kind=secondmate\nharness=codex\nwindow=firstmate:fm-mini\n' > "$test_home/state/mini.meta"
      case "$probe" in remote-*) printf 'remote_host=fixture-host\n' >> "$test_home/state/mini.meta" ;; esac
      cp "$test_home/state/mini.meta" "$test_home/meta.before"
      printf '1\t1\tsignal\tmini\tsignal: queued secondmate outcome\n' > "$test_home/state/.wake-queue"
      cp "$test_home/state/.wake-queue" "$test_home/queue.before"
      cat > "$test_home/publish-stop.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/probed"
if [ "$STOP_KIND" != absent ] && [ -f "$FM_HOME/receipt.ready" ]; then
  mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
fi
SH
      cat > "$test_home/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
case "$2 ${3:-}" in
  'fm-remote-doctor.sh ')
    [ "$STOP_PROBE" != remote-readiness ] || bash "$FM_HOME/publish-stop.sh"
    ;;
  'fm-remote-secondmate-control.sh state')
    [ "$STOP_PROBE" != remote-state ] || bash "$FM_HOME/publish-stop.sh"
    printf 'dead\n'
    ;;
esac
exit 0
SH
      cat > "$test_home/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/respawns"
SH
      fakebin="$test_home/fakebin"
      mkdir -p "$fakebin"
      fm_fake_exit0 "$fakebin" gh
      cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*)
    if [ "$STOP_PROBE" = local-missing ]; then
      bash "$FM_HOME/publish-stop.sh"
    else
      printf 'fm-mini\n'
    fi
    ;;
  *display-message*'#{pane_current_command}'*)
    [ "$STOP_PROBE" != local-dead ] || bash "$FM_HOME/publish-stop.sh"
    printf 'zsh\n'
    ;;
  kill-window*) printf 'kill\n' >> "$FM_HOME/endpoint-kills" ;;
esac
exit 0
SH
      chmod +x "$fakebin/tmux" "$test_home/bin/fm-spawn.sh" "$test_home/bin/fm-on.sh"
      out=$(PATH="$fakebin:$PATH" FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" FM_BACKEND=tmux \
        STOP_KIND="$kind" STOP_PROBE="$probe" FM_BOOTSTRAP_NETWORK=only "$test_home/bin/fm-bootstrap.sh" 2>&1); status=$?
      expect_code 0 "$status" "$probe $kind bootstrap failed: $out"
      [ -f "$test_home/probed" ] || fail "$probe never reached the late-stop probe boundary: $out"
      case "$kind" in
        active|malformed)
          assert_absent "$test_home/respawns" "$probe relaunched infrastructure after a stop"
          assert_absent "$test_home/endpoint-kills" "$probe tore down infrastructure after a stop"
          ;;
        *)
          [ "$(cat "$test_home/respawns")" = 'mini --secondmate' ] || fail "$probe lost ordinary $kind recovery: $out"
          [ "$probe" != local-dead ] || [ "$(cat "$test_home/endpoint-kills")" = kill ] || fail "local recovery did not retire dead endpoint"
          ;;
      esac
      cmp "$test_home/meta.before" "$test_home/state/mini.meta" || fail "$probe changed persistent route metadata"
      cmp "$test_home/queue.before" "$test_home/state/.wake-queue" || fail "$probe consumed queued outcomes"
      assert_absent "$test_home/state/.monitoring-stop-reports" "background probe claimed a visible notice"
    done
  done
  pass "startup recovery rechecks stops after remote readiness, remote state, and local state probes"
}

stage_delivery_stop() {
  local test_home=$1 kind=$2
  write_active_receipt "$test_home"
  if [ "$kind" = malformed ]; then
    printf '{bad json\n' > "$test_home/data/automatic-monitoring-pause/receipt.json"
  elif [ "$kind" = resumed ]; then
    jq '. + {resumed_at:"2026-09-28T10:00:00Z",resume_instruction:"Resume monitoring"}' \
      "$test_home/data/automatic-monitoring-pause/receipt.json" > "$test_home/receipt.next"
    mv "$test_home/receipt.next" "$test_home/data/automatic-monitoring-pause/receipt.json"
  fi
  mv "$test_home/data/automatic-monitoring-pause/receipt.json" "$test_home/receipt.ready"
}

install_stop_during_encoder() {
  local test_home=$1
  mv "$test_home/bin/fm-operational-input.sh" "$test_home/bin/fm-operational-input-real.sh"
  cat > "$test_home/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = encode ]; then
  touch "$FM_HOME/encoded"
  if [ "$STOP_KIND" != absent ] && [ -f "$FM_HOME/receipt.ready" ]; then
    mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
  fi
fi
exec "$FM_HOME/bin/fm-operational-input-real.sh" "$@"
SH
  chmod +x "$test_home/bin/fm-operational-input.sh"
}

test_pi_omp_watch_delivery_rechecks_after_encoding() {
  local test_home adapter kind mode out status
  for adapter in pi omp; do
    for mode in failure actionable; do
      for kind in active malformed absent resumed; do
        test_home="$TMP_ROOT/encoded-watch-$adapter-$mode-$kind"
        make_guard_home "$test_home"
        make_watch_extension_fixture "$test_home"
        stage_delivery_stop "$test_home" "$kind"
        install_stop_during_encoder "$test_home"
        cat > "$test_home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "$WAKE_MODE" = actionable ] && [ ! -f "$FM_HOME/woke" ]; then
  touch "$FM_HOME/woke"
  printf 'watcher: started pid=%s (beacon fresh)\nsignal: encoded actionable outcome\n' "$$"
  exit 0
fi
printf 'watcher: FAILED - fixture failure\n'
exit 1
SH
        chmod +x "$test_home/bin/fm-watch-arm.sh"
        out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ADAPTER="$adapter" STOP_KIND="$kind" WAKE_MODE="$mode" \
          FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
          NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home=process.env.FM_HOME, adapter=process.env.ADAPTER, mode=process.env.WAKE_MODE, kind=process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const queue="1\t1\tsignal\ttask\tsignal: encoded actionable outcome\n";
writeFileSync(`${home}/state/.wake-queue`, queue);
const handlers=new Map(), messages=[];
let tool;
const mod=await import(pathToFileURL(`${home}/.${adapter}/extensions/fm-primary-${adapter}-watch.ts`));
mod.default({on:(name,fn)=>handlers.set(name,fn),registerTool:value=>{tool=value},registerCommand(){},sendUserMessage:async text=>messages.push(text)});
try {
  await tool.execute("start", {}, undefined, undefined, {});
  const deadline=Date.now()+10000;
  while (!existsSync(`${home}/encoded`) && Date.now()<deadline) await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(existsSync(`${home}/encoded`), "delivery encoder was not reached");
  await new Promise(resolve=>setTimeout(resolve,100));
  if (kind==="active" || kind==="malformed") {
    assert.equal(messages.length, mode==="failure" ? 0 : 1, `${messages}`);
    if (mode==="actionable") {
      assert.match(messages[0], /signal: encoded actionable outcome/);
      assert.doesNotMatch(messages[0], /watcher: FAILED|repair|re-arm/);
    }
  } else {
    assert.ok(messages.length>0, "ordinary failure disappeared");
    assert.match(messages[0], /watcher: FAILED/);
    if (mode==="actionable") assert.match(messages[0], /signal: encoded actionable outcome/);
  }
  assert.equal(readFileSync(`${home}/state/.wake-queue`,"utf8"),queue);
  assert.equal(existsSync(`${home}/state/.monitoring-stop-reports`),false);
} finally { await handlers.get("session_shutdown")({reason:"quit"}); }
JS
); status=$?
        expect_code 0 "$status" "$adapter $mode $kind post-encoding delivery failed: $out"
      done
    done
  done
  pass "Pi and omp recheck stops after encoding without losing actionable outcomes"
}

test_turnend_delivery_rechecks_after_encoding() {
  local test_home adapter kind out status
  for adapter in pi omp opencode; do
    for kind in active malformed absent resumed; do
      test_home="$TMP_ROOT/encoded-guard-$adapter-$kind"
      make_guard_home "$test_home"
      make_watch_extension_fixture "$test_home"
      cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$test_home/.pi/extensions/"
      cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$test_home/.omp/extensions/"
      mkdir -p "$test_home/.opencode/plugins/lib"
      cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$test_home/.opencode/plugins/"
      cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$test_home/.opencode/plugins/lib/"
      FM_HOME="$test_home" FM_PROCEVENT_CLAIM_ROOT="$test_home/claims" \
        "$test_home/bin/fm-procevent.sh" register lavish late-guard -- /usr/bin/true >/dev/null || fail "could not register supervised source"
      stage_delivery_stop "$test_home" "$kind"
      install_stop_during_encoder "$test_home"
      out=$(FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" ADAPTER="$adapter" STOP_KIND="$kind" NODE_NO_WARNINGS=1 \
        node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home=process.env.FM_HOME, adapter=process.env.ADAPTER, kind=process.env.STOP_KIND;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const notices=[], repairs=[];
let endTurn, shutdown=async()=>{};
if(adapter==="opencode") {
  const client={session:{prompt:async request=>{assert.equal(request.body.noReply,true);notices.push(request.body.parts[0].text)},promptAsync:async request=>repairs.push(request.body.parts[0].text)}};
  const {FmPrimaryWatchArm}=await import(pathToFileURL(`${home}/.opencode/plugins/fm-primary-watch-arm.js`));
  await FmPrimaryWatchArm({worktree:home,client});
  const {FmPrimaryTurnendGuard}=await import(pathToFileURL(`${home}/.opencode/plugins/fm-primary-turnend-guard.js`));
  const guard=await FmPrimaryTurnendGuard({worktree:home,client});
  endTurn=()=>guard.event({event:{type:"session.idle",properties:{sessionID:"test"}}});
} else {
  const handlers=new Map();
  const mod=await import(pathToFileURL(`${home}/.${adapter}/extensions/fm-primary-turnend-guard.ts`));
  mod.default({on:(name,fn)=>handlers.set(name,fn),sendMessage:message=>{assert.equal(message.display,true);notices.push(message.content)},sendUserMessage:async text=>repairs.push(text)});
  endTurn=async()=>{const result=await handlers.get(adapter==="pi"?"agent_settled":"session_stop")({});if(result?.continue) repairs.push(result.additionalContext)};
  shutdown=()=>handlers.get("session_shutdown")();
}
try {
  await endTurn();
  assert.ok(existsSync(`${home}/encoded`), "initial guard did not reach repair encoding");
  if(kind==="active" || kind==="malformed") {
    assert.equal(repairs.length,0,`${adapter} delivered repair after stop: ${repairs}`);
    assert.equal(notices.length,1,"current turn lost the late-stop diagnostic");
    assert.match(notices[0],/AUTOMATIC_MONITORING_STOP/);
    await endTurn();
    assert.equal(repairs.length,0);
    assert.equal(notices.length,1,"late stop notice repeated");
  } else {
    assert.equal(repairs.length,1,"ordinary guard failure disappeared");
    assert.match(repairs[0],/TURN WOULD END BLIND/);
  }
  assert.equal(readFileSync(`${home}/state/.lock`,"utf8").trim(),String(process.pid));
} finally {await shutdown();}
JS
); status=$?
      expect_code 0 "$status" "$adapter $kind final turn-end verdict failed: $out"
    done
  done
  pass "Pi, omp, and OpenCode recheck turn-end repairs after encoding and report late stops once"
}

test_cursor_repair_rechecks_after_encoding_and_lock_wait() {
  local test_home kind stage out status fakebin real_jq real_cat
  real_jq=$(command -v jq)
  real_cat=$(command -v cat)
  for stage in encoding lock; do
    for kind in active malformed absent resumed; do
      test_home="$TMP_ROOT/cursor-delivery-$stage-$kind"
      make_guard_home "$test_home"
      stage_delivery_stop "$test_home" "$kind"
      printf 'kind=ship\n' > "$test_home/state/work.meta"
      printf '#!/usr/bin/env bash\nexit 1\n' > "$test_home/bin/fm-watch-arm.sh"
      chmod +x "$test_home/bin/fm-watch-arm.sh"
      fakebin="$test_home/fakebin"
      mkdir -p "$fakebin"
      cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -n ] && [ "${2:-}" = --arg ] && [ "${3:-}" = m ] && [ ! -f "$FM_HOME/encoding-wait" ]; then
  touch "$FM_HOME/encoding-wait"
  for ((i=0;i<400;i++)); do
    [ -f "$FM_HOME/release-encoder" ] && break
    sleep 0.025
  done
fi
exec "$REAL_JQ" "$@"
SH
      cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${CURSOR_WAIT_PROBE:-}" = 1 ] && [ "${1:-}" = "$FM_HOME/state/.cursor-park-owner.lock/pid" ] && [ -f "$FM_HOME/release-encoder" ]; then
  touch "$FM_HOME/lock-wait"
fi
exec "$REAL_CAT" "$@"
SH
      chmod +x "$fakebin/jq" "$fakebin/cat"
      cat > "$test_home/turns.sh" <<'SH'
#!/usr/bin/env bash
. "$FM_HOME/bin/fm-wake-lib.sh"
payload='{"session_id":"delivery","loop_count":0,"cursor_version":"test"}'
lock="$FM_HOME/state/.cursor-park-owner.lock"
wait_file() {
  local i
  for ((i=0;i<400;i++)); do
    [ -f "$1" ] && return 0
    sleep 0.025
  done
  return 1
}
cp "$FM_HOME/state/.lock" "$FM_HOME/owner.before"
printf '%s' "$payload" | CURSOR_WAIT_PROBE=1 "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/first" &
hook=$!
trap 'touch "$FM_HOME/release-encoder"; fm_lock_release "$lock"; wait "$hook"' EXIT
wait_file "$FM_HOME/encoding-wait" || exit 1
if [ "$STOP_STAGE" = lock ]; then
  fm_lock_try_acquire "$lock" || exit 2
  touch "$FM_HOME/release-encoder"
  wait_file "$FM_HOME/lock-wait" || exit 3
fi
[ "$STOP_KIND" = absent ] || mv "$FM_HOME/receipt.ready" "$FM_HOME/data/automatic-monitoring-pause/receipt.json"
touch "$FM_HOME/release-encoder"
[ "$STOP_STAGE" != lock ] || fm_lock_release "$lock"
wait "$hook" || exit 4
printf '%s' "$payload" | "$FM_HOME/bin/fm-turnend-guard-cursor.sh" > "$FM_HOME/second" || exit 5
cmp "$FM_HOME/owner.before" "$FM_HOME/state/.lock"
SH
      out=$(env -u PI_CODING_AGENT PATH="$fakebin:$PATH" REAL_JQ="$real_jq" REAL_CAT="$real_cat" \
        FM_HOME="$test_home" FM_ROOT_OVERRIDE="$test_home" STOP_KIND="$kind" STOP_STAGE="$stage" \
        FM_CURSOR_PARK_ATTEMPTS=1 FM_CURSOR_PARK_POLL=1 "$TMP_ROOT/harnesses/cursor-agent" "$test_home/turns.sh" 2>&1); status=$?
      expect_code 0 "$status" "Cursor $kind $stage delivery race failed: $out"
      out=$(jq -er .followup_message "$test_home/first") || fail "Cursor dropped its final visible outcome"
      case "$kind" in
        active|malformed)
          assert_contains "$out" AUTOMATIC_MONITORING_STOP "Cursor lost late stop notice"
          assert_not_contains "$out" 'TURN WOULD END BLIND' "Cursor delivered stale repair"
          [ ! -s "$test_home/second" ] || fail "Cursor repeated late-stop notice"
          assert_absent "$test_home/state/.turnend-cursor-blocks" "suppressed repair consumed nag budget"
          ;;
        *) assert_contains "$out" 'TURN WOULD END BLIND' "Cursor hid ordinary repair" ;;
      esac
    done
  done
  pass "Cursor rechecks stops after repair encoding and ownership-lock waits without spending repair budget"
}

make_external_stop_home() {  # <home> <primary|secondmate> [id]
  local home=$1 kind=$2 id=${3:-fixture}
  mkdir -p "$home/state" "$home/data"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  cp -R "$ROOT/bin" "$home/bin"
  case "$kind" in
    primary) git init -q "$home" ;;
    secondmate) printf '%s\n' "$id" > "$home/.fm-secondmate-home" ;;
    *) fail "unknown external-stop fixture kind: $kind" ;;
  esac
}

external_stop_pid_alive() {  # <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

start_external_stop_watcher() {  # <home> [real|unresponsive]
  local home=$1 mode=${2:-real} i
  if [ "$mode" = unresponsive ]; then
    cat > "$home/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?}
STATE="$FM_HOME/state"
. "$SCRIPT_DIR/fm-wake-lib.sh"
lock="$STATE/.watch.lock"
fm_lock_try_acquire "$lock" || exit 91
pid=${BASHPID:-$$}
cleanup() { fm_lock_release "$lock" 2>/dev/null || true; }
trap cleanup EXIT
printf '%s\n' "$FM_HOME" > "$lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$lock/watcher-path"
fm_pid_identity "$pid" > "$lock/pid-identity"
touch "$STATE/.last-watcher-beat"
deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; touch "$STATE/.last-watcher-beat"; done
SH
    chmod +x "$home/bin/fm-watch.sh"
  fi
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 "$home/bin/fm-watch.sh" > "$home/watcher.out" 2> "$home/watcher.err" &
  EXTERNAL_STOP_WATCHER_PID=$!
  EXTERNAL_STOP_WATCHER_PIDS+=("$EXTERNAL_STOP_WATCHER_PID")
  for ((i=0;i<200;i++)); do
    [ -s "$home/state/.watch.lock/pid-identity" ] && [ -e "$home/state/.last-watcher-beat" ] && return 0
    external_stop_pid_alive "$EXTERNAL_STOP_WATCHER_PID" || break
    sleep 0.025
  done
  fail "fixture watcher did not become ready: $(cat "$home/watcher.err" 2>/dev/null)"
}

stop_fixture_watcher() {  # <pid>
  local pid=$1
  case $'\n'$(jobs -pr; jobs -ps)$'\n' in
    *$'\n'"$pid"$'\n'*) ;;
    *) wait "$pid" 2>/dev/null || true; return 0 ;;
  esac
  external_stop_pid_alive "$pid" || return 0
  kill -CONT "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    external_stop_pid_alive "$pid" || break
    sleep 0.025
  done
  external_stop_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_external_stop_fixture_cleanup_and_timeout() {
  local home pid status i
  home="$TMP_ROOT/external-fixture-cleanup"
  make_external_stop_home "$home" secondmate fixture-cleanup
  (
    EXTERNAL_STOP_WATCHER_PIDS=()
    trap cleanup_external_stop_watchers EXIT
    start_external_stop_watcher "$home" unresponsive
    printf '%s\n' "$EXTERNAL_STOP_WATCHER_PID" > "$home/fixture.pid"
    fail 'intentional assertion failure'
  ) > "$home/out" 2> "$home/err"; status=$?
  expect_code 1 "$status" "fixture cleanup regression did not reach its intentional failure"
  assert_contains "$(cat "$home/err")" 'intentional assertion failure' "fixture failed before its assertion"
  pid=$(cat "$home/fixture.pid")
  external_stop_pid_alive "$pid" && fail "assertion failure left a fixture running"
  assert_absent "$home/state/.watch.lock" "failed fixture did not release its lock"

  FM_TEST_STUB_MAX_BLOCK_SECONDS=1 start_external_stop_watcher "$home" unresponsive
  pid=$EXTERNAL_STOP_WATCHER_PID
  for ((i=0;i<200;i++)); do
    external_stop_pid_alive "$pid" || break
    sleep 0.025
  done
  external_stop_pid_alive "$pid" && fail "unresponsive fixture ignored its timeout bound"
  wait "$pid" || fail "bounded fixture did not exit cleanly"
  assert_absent "$home/state/.watch.lock" "bounded fixture did not release its lock"
  pass "external-stop fixtures clean up after failed assertions and bound their own lifetime"
}

test_external_stop_notice_separates_stop_and_latest_request() {
  local home receipt first second
  home="$TMP_ROOT/external-notice"
  write_active_receipt "$home" 2026-09-21T10:00:00Z
  receipt="$home/data/automatic-monitoring-pause/receipt.json"
  jq '. + {origin:"external",external_stop_request:{
    schema:"firstmate.monitoring-stop.external.v1",caller_uid:501,
    caller_user:"requester-b",caller_pid:222,caller_identity:"process-b",
    at:"2026-09-22T11:00:00Z",reason:"repeat stop"
  }}' "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  first=$(FM_HOME="$home" bash -c '. "$1/bin/fm-monitoring-stop-lib.sh"; fm_monitoring_stop_report_once' _ "$ROOT")
  assert_contains "$first" 'monitoring stopped at 2026-09-21T10:00:00Z.' "notice lost original stop time"
  assert_contains "$first" 'Latest external request by local process requester-b[uid=501,pid=222] at 2026-09-22T11:00:00Z.' \
    "notice attributed the latest requester to the original stop"
  jq '.external_stop_request |= . + {caller_user:"requester-c",caller_pid:333,
    caller_identity:"process-c",at:"2026-09-23T12:00:00Z"}' "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  second=$(FM_HOME="$home" bash -c '. "$1/bin/fm-monitoring-stop-lib.sh"; fm_monitoring_stop_report_once' _ "$ROOT")
  [ -z "$second" ] || fail "a later external request repeated the same stop notice: $second"
  pass "external stop notices keep the original stop and latest request times distinct"
}

test_external_stop_reconciles_owner_cleanup_races() {
  local home stage prior pid status expected real_wc
  real_wc=$(command -v wc)
  for stage in before during initial; do
    for prior in none active; do
      [ "$stage:$prior" != initial:none ] || continue
      home="$TMP_ROOT/external-race-$stage-$prior"
      make_external_stop_home "$home" secondmate "race-$stage-$prior"
      start_external_stop_watcher "$home" real
      pid=$EXTERNAL_STOP_WATCHER_PID
      kill -STOP "$pid"
      if [ "$prior" = active ]; then
        write_active_receipt "$home"
      fi
      mv "$home/bin/fm-watch-arm.sh" "$home/bin/fm-watch-arm.real.sh"
      cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --stop ] && [ "$STOP_RACE_STAGE" = before ]; then
  kill -CONT "$STOP_RACE_PID"
  for ((i=0;i<400;i++)); do
    [ ! -e "$FM_HOME/state/.watch.lock" ] && [ ! -L "$FM_HOME/state/.watch.lock" ] && break
    sleep 0.025
  done
  [ ! -e "$FM_HOME/state/.watch.lock" ] && [ ! -L "$FM_HOME/state/.watch.lock" ] || exit 90
  touch "$FM_HOME/race-reached"
elif { [ "$1" = --stop ] && [ "$STOP_RACE_STAGE" = during ]; } ||
     { [ "$1" = --stop-status ] && [ "$STOP_RACE_STAGE" = initial ]; }; then
  export STOP_RACE_INSPECTION=1
fi
exec "$FM_HOME/bin/fm-watch-arm.real.sh" "$@"
SH
      mkdir "$home/fakebin"
      cat > "$home/fakebin/wc" <<'SH'
#!/usr/bin/env bash
if [ "${STOP_RACE_INSPECTION:-}" = 1 ] && [ "$*" = -l ] && [ ! -e "$FM_HOME/race-reached" ]; then
  kill -CONT "$STOP_RACE_PID"
  for ((i=0;i<400;i++)); do
    [ ! -e "$FM_HOME/state/.watch.lock" ] && [ ! -L "$FM_HOME/state/.watch.lock" ] && break
    sleep 0.025
  done
  [ ! -e "$FM_HOME/state/.watch.lock" ] && [ ! -L "$FM_HOME/state/.watch.lock" ] || exit 90
  touch "$FM_HOME/race-reached"
fi
exec "$REAL_WC" "$@"
SH
      chmod +x "$home/bin/fm-watch-arm.sh" "$home/fakebin/wc"
      PATH="$home/fakebin:$PATH" REAL_WC="$real_wc" STOP_RACE_STAGE="$stage" STOP_RACE_PID="$pid" \
        FM_WATCH_STOP_TIMEOUT=5 "$STOP" stop --home "$home" --reason 'cleanup race' > "$home/out" 2> "$home/err"; status=$?
      expected=0
      [ "$stage" != initial ] || expected=3
      expect_code "$expected" "$status" "$prior stop with $stage cleanup returned the wrong outcome: $(cat "$home/err")"
      assert_present "$home/race-reached" "owner cleanup race was not exercised"
      wait "$pid"; status=$?
      expect_code 3 "$status" "fixture watcher did not exit by honoring its receipt"
      assert_absent "$home/state/.watch.lock" "owner cleanup left a lock"
      [ "$(stop_status "$home" | jq -r .status)" = active ] || fail "cleanup race lost stop authority"
    done
  done
  pass "outside stop reconciles cleanup before and during owner inspection without losing live-retry outcomes"
}

test_owner_inspection_does_not_authorize_stop() {
  local home pid status
  home="$TMP_ROOT/external-inspection"
  make_external_stop_home "$home" secondmate inspection
  start_external_stop_watcher "$home" real
  pid=$EXTERNAL_STOP_WATCHER_PID
  FM_HOME="$home" "$home/bin/fm-watch-arm.sh" --stop-status > "$home/out" 2> "$home/err"; status=$?
  expect_code 0 "$status" "owner inspection did not report a live watcher"
  assert_absent "$home/data/automatic-monitoring-pause/receipt.json" "inspection authorized a stop"
  FM_HOME="$home" "$home/bin/fm-watch-arm.sh" --stop > "$home/out" 2> "$home/err"; status=$?
  expect_code 1 "$status" "owner shutdown accepted inspection as stop authorization"
  assert_contains "$(cat "$home/err")" 'no active monitoring-stop receipt' "shutdown lost its receipt requirement"
  external_stop_pid_alive "$pid" || fail "read-only inspection stopped the watcher"
  stop_fixture_watcher "$pid"
  pass "owner inspection leaves the receipt as the sole stop authorization"
}

test_external_stop_preserves_shared_operation_lock() {
  local home status lock
  home="$TMP_ROOT/external-operation-lock"
  make_external_stop_home "$home" secondmate operation-lock
  lock="$home/state/.monitoring-stop-command.lock"
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$FM_HOME/state/.monitoring-stop-command.lock"
    fm_lock_try_acquire "$lock" || exit 91
    trap '\''fm_lock_release "$lock"'\'' EXIT
    "$1/bin/fm-monitoring-stop.sh" stop --home "$FM_HOME" --reason "competing stop"
    status=$?
    [ "$(cat "$lock/pid")" = "$$" ] || exit 92
    exit "$status"
  ' _ "$ROOT" > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "stop acquired an already-held shared operation lock"
  assert_contains "$(cat "$home/err")" 'another monitoring-stop call holds the home lock' "contention lost its failure reason"
  assert_absent "$home/data/automatic-monitoring-pause/receipt.json" "contending stop published a receipt"
  assert_absent "$lock" "shared owner did not release its operation lock"

  printf 'invalid lock\n' > "$lock"
  "$STOP" stop --home "$home" --reason 'malformed operation lock' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "stop accepted a malformed operation lock"
  assert_contains "$(cat "$home/err")" 'operation lock is malformed or ambiguous' "malformed operation lock lost its failure reason"
  assert_absent "$home/data/automatic-monitoring-pause/receipt.json" "malformed operation lock allowed a receipt"
  pass "outside stop retains shared operation-lock contention and malformed-lock refusal"
}

test_external_stop_records_actual_caller_and_distinct_results() {
  local home receipt out status caller_identity
  home="$TMP_ROOT/external-primary"
  make_external_stop_home "$home" primary
  caller_identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not establish test caller identity"

  FM_HOME="$TMP_ROOT/ambient-must-not-select-target" "$STOP" stop --home "$home" --reason 'purser runaway backstop' \
    > "$home/stop.out" 2> "$home/stop.err"; status=$?
  out=$(cat "$home/stop.out")
  expect_code 0 "$status" "new external stop must return the stopped code: $(cat "$home/stop.err")"
  assert_contains "$out" 'stopped home=' "new external stop did not name its result"
  receipt="$home/data/automatic-monitoring-pause/receipt.json"
  [ "$(wc -l < "$receipt" | tr -d '[:space:]')" = 1 ] || fail "external stop receipt was not one physical audit line"
  jq -e --arg home "$home" --argjson pid "$$" --arg identity "$caller_identity" '
    .home == $home and .completed == true and .origin == "external" and
    .external_stop_request.schema == "firstmate.monitoring-stop.external.v1" and
    .external_stop_request.caller_pid == $pid and
    .external_stop_request.caller_identity == $identity and
    (.external_stop_request.caller_uid | type == "number") and
    (.external_stop_request.caller_user | type == "string" and length > 0) and
    .external_stop_request.reason == "purser runaway backstop" and
    (.external_stop_request.at | type == "string" and length > 0)
  ' "$receipt" >/dev/null || fail "external stop did not persist its authenticated caller, time, and reason: $(cat "$receipt")"
  out=$(FM_HOME="$home" "$STOP" status --json)
  [ "$(printf '%s' "$out" | jq -r .status)" = active ] || fail "external stop did not use the shared active receipt: $out"
  [ "$(printf '%s' "$out" | jq -r .origin)" = external ] || fail "status omitted the external stop origin: $out"
  assert_absent "$home/state/.monitoring-stop-command.lock" "successful stop retained its operation lock"

  FM_HOME="$TMP_ROOT/ambient-must-not-select-target" "$STOP" stop --home "$home" --reason 'repeat backstop tick' \
    > "$home/repeat.out" 2> "$home/repeat.err"; status=$?
  expect_code 3 "$status" "a true no-live-watcher repetition must return the already-stopped code"
  assert_contains "$(cat "$home/repeat.out")" 'already-stopped home=' "repeat did not report idempotent success"
  [ "$(jq -r .external_stop_request.reason "$receipt")" = 'repeat backstop tick' ] \
    || fail "repeat did not retain its own audit reason"

  "$STOP" stop --home "$home" > /dev/null 2> "$home/usage.err"; status=$?
  expect_code 2 "$status" "invalid stop syntax must remain distinct from stop outcomes"
  pass "outside stop records the actual OS caller in one line and distinguishes stopped, already stopped, and usage"
}

test_external_stop_ends_only_selected_home_and_retries_active_live_stop() {
  local mini sibling mini_pid sibling_pid status i
  mini="$TMP_ROOT/mini-fixture"
  sibling="$TMP_ROOT/sibling-fixture"
  make_external_stop_home "$mini" secondmate mini
  make_external_stop_home "$sibling" secondmate sibling
  start_external_stop_watcher "$mini" real
  mini_pid=$EXTERNAL_STOP_WATCHER_PID
  start_external_stop_watcher "$sibling" real
  sibling_pid=$EXTERNAL_STOP_WATCHER_PID

  kill -STOP "$mini_pid"
  write_active_receipt "$mini"
  FM_HOME="$TMP_ROOT/not-mini" FM_WATCH_STOP_TIMEOUT=5 "$STOP" stop --home "$mini" --reason 'retry existing stopped home with live owner' \
    > "$mini/stop.out" 2> "$mini/stop.err" &
  external_pid=$!
  for ((i=0;i<200;i++)); do
    jq -e '.external_stop_request.reason == "retry existing stopped home with live owner"' \
      "$mini/data/automatic-monitoring-pause/receipt.json" >/dev/null 2>&1 && break
    sleep 0.025
  done
  kill -CONT "$mini_pid"
  wait "$external_pid"; status=$?
  expect_code 0 "$status" "an active receipt with a live watcher must stop it, not return already stopped: $(cat "$mini/stop.err")"
  assert_contains "$(cat "$mini/stop.out")" 'stopped home=' "active/live retry did not report stopped"
  for ((i=0;i<200;i++)); do
    external_stop_pid_alive "$mini_pid" || break
    sleep 0.025
  done
  external_stop_pid_alive "$mini_pid" && fail "selected Mini-shaped fixture watcher remained alive"
  external_stop_pid_alive "$sibling_pid" || fail "a different home's watcher was stopped"
  [ "$(FM_HOME="$sibling" "$STOP" status --json | jq -r .status)" = none ] \
    || fail "selected-home stop wrote into the sibling home"
  stop_fixture_watcher "$sibling_pid"
  pass "outside stop retries an active/live home through its owner while leaving another home's watcher untouched"
}

test_external_stop_refuses_malformed_receipt_lock_and_owner_identity() {
  local home pid status before owner owner_identity
  home="$TMP_ROOT/external-malformed-receipt"
  make_external_stop_home "$home" secondmate malformed-receipt
  mkdir -p "$home/data/automatic-monitoring-pause"
  printf '{bad json\n' > "$home/data/automatic-monitoring-pause/receipt.json"
  cp "$home/data/automatic-monitoring-pause/receipt.json" "$home/receipt.before"
  "$STOP" stop --home "$home" --reason 'must not replace malformed evidence' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "malformed receipt must return could-not-stop"
  assert_contains "$(cat "$home/err")" 'could-not-stop' "malformed receipt failure lacked its typed outcome"
  assert_contains "$(cat "$home/err")" 'receipt' "malformed receipt failure lacked an actionable reason"
  cmp "$home/receipt.before" "$home/data/automatic-monitoring-pause/receipt.json" \
    || fail "malformed receipt was overwritten"

  home="$TMP_ROOT/external-malformed-lock"
  make_external_stop_home "$home" secondmate malformed-lock
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  "$STOP" stop --home "$home" --reason 'malformed lock check' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "watch lock missing its owner identity must return could-not-stop"
  assert_contains "$(cat "$home/err")" 'owner identity' "malformed lock failure did not name the missing owner identity"

  home="$TMP_ROOT/external-escaped-owner"
  make_external_stop_home "$home" secondmate escaped-owner
  owner="$TMP_ROOT/escaped-watch-owner"
  mkdir "$owner"
  owner_identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not establish escaped-owner fixture identity"
  printf '%s\n' "$$" > "$owner/pid"
  printf '%s\n' "$home" > "$owner/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$owner/watcher-path"
  printf '%s\n' "$owner_identity" > "$owner/pid-identity"
  ln -s "$owner" "$home/state/.watch.lock"
  "$STOP" stop --home "$home" --reason 'escaped owner check' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "lock owner outside the selected home must return could-not-stop"
  assert_contains "$(cat "$home/err")" 'direct child' "escaped lock owner failure did not name the home-scope problem"

  home="$TMP_ROOT/external-ambiguous-owner"
  make_external_stop_home "$home" secondmate ambiguous-owner
  start_external_stop_watcher "$home" unresponsive
  pid=$EXTERNAL_STOP_WATCHER_PID
  before=$(cat "$home/state/.watch.lock/pid-identity")
  printf '%s\n' 'forged-owner-identity' > "$home/state/.watch.lock/pid-identity"
  FM_WATCH_STOP_TIMEOUT=1 "$STOP" stop --home "$home" --reason 'ambiguous owner check' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "identity-mismatched live owner must return could-not-stop"
  assert_contains "$(cat "$home/err")" 'owner identity' "identity mismatch did not name the owner problem"
  external_stop_pid_alive "$pid" || fail "ambiguous owner was signalled despite failed identity proof"
  [ "$before" != 'forged-owner-identity' ] || fail "owner identity fixture was vacuous"
  stop_fixture_watcher "$pid"
  pass "outside stop preserves malformed receipts and refuses malformed or ambiguous watcher ownership"
}

test_external_stop_reports_unresponsive_owner_as_failure() {
  local home pid status
  home="$TMP_ROOT/external-unresponsive"
  make_external_stop_home "$home" secondmate unresponsive
  start_external_stop_watcher "$home" unresponsive
  pid=$EXTERNAL_STOP_WATCHER_PID
  FM_WATCH_STOP_TIMEOUT=1 "$STOP" stop --home "$home" --reason 'owner timeout proof' > "$home/out" 2> "$home/err"; status=$?
  expect_code 4 "$status" "unresponsive watcher owner must return could-not-stop"
  assert_contains "$(cat "$home/err")" 'could-not-stop' "unresponsive owner failure lacked its typed outcome"
  assert_contains "$(cat "$home/err")" 'did not stop' "unresponsive owner failure lacked an actionable reason"
  external_stop_pid_alive "$pid" || fail "unresponsive fixture unexpectedly exited"
  [ "$(FM_HOME="$home" "$STOP" status --json | jq -r .status)" = active ] \
    || fail "failed termination did not leave automatic re-arm suppression active"
  stop_fixture_watcher "$pid"
  pass "outside stop never reports success when the selected watcher owner does not stop"
}

test_external_stop_fixture_cleanup_and_timeout
test_external_stop_notice_separates_stop_and_latest_request
test_external_stop_reconciles_owner_cleanup_races
test_owner_inspection_does_not_authorize_stop
test_external_stop_preserves_shared_operation_lock
test_external_stop_records_actual_caller_and_distinct_results
test_external_stop_ends_only_selected_home_and_retries_active_live_stop
test_external_stop_refuses_malformed_receipt_lock_and_owner_identity
test_external_stop_reports_unresponsive_owner_as_failure
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
make_hook_harnesses
test_resolved_secondmate_outcome_reaches_hooks
test_cursor_reports_before_early_return_and_after_arm_race
test_away_launcher_reports_visible_stop
test_bootstrap_nudges_leave_notices_for_visible_boundary
test_opencode_idle_reports_arm_suppression_race
test_background_refresh_cannot_consume_visible_notice
test_pi_and_omp_late_suppression_is_not_failure
test_startup_liveness_respects_monitoring_policy
test_claude_late_stop_is_terminal_without_repair
test_cursor_fallback_delivers_late_stop_as_json
test_opencode_stopped_successor_preserves_outcome_without_failure
test_pi_and_omp_stop_during_handling_confirmation
test_running_and_attached_arm_stop_on_termination
test_superseded_cursor_park_cannot_claim_stop_notice
test_checkpoint_rechecks_stop_at_completion
test_opencode_suppresses_failure_stopped_during_encoding
test_bootstrap_rechecks_stop_after_secondmate_probes
test_pi_omp_watch_delivery_rechecks_after_encoding
test_turnend_delivery_rechecks_after_encoding
test_cursor_repair_rechecks_after_encoding_and_lock_wait
