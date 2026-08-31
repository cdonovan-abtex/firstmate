#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# The ordinary verb checks launch no agent: herdr's `pane report-agent` is the
# same registry the adapter reads, so registering and not registering an agent
# on a plain shell pane exercises exactly the classifier every verb gates on.
# The missing-endpoint case launches a local fake Pi process that registers in
# the lab pane and makes no provider call, proving the public relaunch reaches
# an alive replacement without touching the default Herdr session.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
SESSION=$("$HERDR_LAB_HELPER" name firstmate-missing-endpoint-recovery-v1) \
  || fail "could not generate an isolated Herdr lab name"
export HERDR_SESSION="$SESSION"
export HERDR_LAB_HELPER
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    HERDR_LAB_HELPER="$HERDR_LAB_HELPER" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=10 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source fm-control-smoke --agent fm-control-smoke-agent --state idle >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

"$HERDR_LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

# --- positively missing endpoint: create, rebind, and launch transactionally -

mkdir -p "$SCRATCH/fakebin"
cat > "$SCRATCH/fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo 'usage: pi [--tui-mode regular] [--model MODEL] [--thinking LEVEL]'
  exit 0
fi
"$HERDR_LAB_HELPER" run "$HERDR_SESSION" pane report-agent "$HERDR_PANE_ID" \
  --source fm-control-recovery-smoke --agent pi --state idle >/dev/null
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
SH
chmod +x "$SCRATCH/fakebin/pi"
printf 'preserved dirty work\n' > "$WT/dirty.txt"
if [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" != missing ]; then
  "$HERDR_LAB_HELPER" run "$SESSION" pane close "$PANE_ID" >/dev/null \
    || fail "could not remove the fixture endpoint"
fi
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = missing ] \
  || fail "the removed fixture endpoint was not positively classified missing"

OUT=$(run_control hsmoke relaunch --harness pi --model recovery-smoke-model \
  --effort xhigh --note "continue after abrupt Herdr pane loss") \
  || fail "missing Herdr endpoint relaunch should succeed: $OUT"
NEW_PANE_ID=$(grep '^herdr_pane_id=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)
[ -n "$NEW_PANE_ID" ] && [ "$NEW_PANE_ID" != "$PANE_ID" ] \
  || fail "missing Herdr recovery did not publish a replacement pane"
[ "$(fm_backend_agent_state herdr "$SESSION:$NEW_PANE_ID")" = alive ] \
  || fail "missing Herdr recovery did not launch a registered replacement agent"
[ "$(grep '^worktree=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)" = "$WT" ] \
  || fail "missing Herdr recovery changed the recorded worktree"
[ "$(grep '^model=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)" = recovery-smoke-model ] \
  || fail "missing Herdr recovery dropped the explicit model"
[ "$(grep '^effort=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)" = xhigh ] \
  || fail "missing Herdr recovery dropped the explicit effort"
[ "$(cat "$WT/dirty.txt")" = "preserved dirty work" ] \
  || fail "missing Herdr recovery changed dirty worktree contents"
grep -Fq "continue after abrupt Herdr pane loss" "$HOME_DIR/data/hsmoke/brief.md" \
  || fail "missing Herdr recovery did not retain the required progress note"
pass "real herdr: a positively missing worker endpoint is recreated around its exact dirty worktree and explicit profile"
