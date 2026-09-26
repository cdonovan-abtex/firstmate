#!/usr/bin/env bash
# Colocated test for .githooks/commit-msg, the agent-attribution gate.
#
# The hook resolves its harness detector as ../bin/fm-harness.sh relative to
# itself, so the hook is copied into a temp tree beside a controllable stub.
# That makes every branch assertable - including "human" and "detector missing",
# which cannot be reached honestly from inside an agent session, because the
# real detector walks process ancestry and would correctly find this one.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TMP=$(fm_test_tmproot githooks-commit-msg)
mkdir -p "$TMP/.githooks" "$TMP/bin"
cp "$ROOT/.githooks/commit-msg" "$TMP/.githooks/commit-msg"
HOOK="$TMP/.githooks/commit-msg"

# stub_harness <output> [mode]: control what the hook's detector reports.
stub_harness() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" > "$TMP/bin/fm-harness.sh"
  chmod "${2:-755}" "$TMP/bin/fm-harness.sh"
}

# run_hook <message>: feed the hook a commit message, echo its exit code.
run_hook() {
  printf '%s\n' "$1" > "$TMP/msg"
  bash "$HOOK" "$TMP/msg" >/dev/null 2>&1
  printf '%s\n' "$?"
}

TRAILER='Co-Authored-By: Some Model <noreply@example.com>'

# --- the gate itself --------------------------------------------------------
# An unattributed agent commit is refused. This single assertion is the reason
# the file exists: it is what makes the trailer rule a gate and not a hope.
stub_harness claude
[ "$(run_hook 'feat: a thing')" = 1 ] \
  || fail "agent commit with no trailer was allowed"
pass "agent commit with no trailer is refused"

[ "$(run_hook "feat: a thing

$TRAILER")" = 0 ] || fail "agent commit naming a model was refused"
pass "agent commit naming a model is allowed"

# --- the gate must not block a human ---------------------------------------
# The captain writing his own commit owes no trailer: he wrote it, so crediting
# him is already true. Blocking that would be a bug wearing rigor's clothes.
stub_harness unknown
[ "$(run_hook 'docs: typo')" = 0 ] \
  || fail "human commit with no trailer was refused"
pass "human commit with no trailer is allowed"

# A detector that cannot answer must fail OPEN. The cost of failing open is one
# missing trailer; the cost of failing closed is wedging every commit on the
# box, which would get the hook deleted within a day.
chmod 000 "$TMP/bin/fm-harness.sh" 2>/dev/null || true
[ "$(run_hook 'docs: typo')" = 0 ] || fail "unreadable detector failed closed"
pass "unreadable detector fails open, not closed"
rm -f "$TMP/bin/fm-harness.sh"
[ "$(run_hook 'docs: typo')" = 0 ] || fail "missing detector failed closed"
pass "missing detector fails open, not closed"

# --- attribution must mean what git means by it -----------------------------
stub_harness codex
[ "$(run_hook "feat: a thing

Co-authored-by: Some Model <noreply@example.com>")" = 0 ] \
  || fail "lowercase trailer refused; git's own parser accepts it"
pass "lowercase 'Co-authored-by' is accepted, matching git"

# Git strips comment lines before storing the message, so a commented trailer
# would leave the stored commit unattributed while looking attributed here.
[ "$(run_hook "feat: a thing

# $TRAILER")" = 1 ] || fail "a commented-out trailer counted as attribution"
pass "a commented-out trailer does not count"

[ "$(run_hook 'feat: a thing

Co-Authored-By:')" = 1 ] || fail "an empty Co-Authored-By value was accepted"
pass "an empty Co-Authored-By value is refused"

# --- every verified harness is gated, not just the one that wrote this ------
for h in claude codex opencode pi grok; do
  stub_harness "$h"
  [ "$(run_hook 'feat: a thing')" = 1 ] || fail "harness $h was not gated"
done
pass "every verified harness is gated (claude, codex, opencode, pi, grok)"
