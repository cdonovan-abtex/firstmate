#!/usr/bin/env bash
# activity-completeness-daily — DISH #3 daily trigger. TIME-BASED (not session-triggered),
# because a multi-day session never crosses the session boundaries the guard + recovery hook
# wait on — only a daily clock sees inside it (Captain's correction). Runs the completeness
# check for BOTH officers on the target day, then routes each coverage flag to the right
# surface by cadence:
#   - XO flag  -> coverage-xo-<day>.flag  -> surfaced by the recovery brief at next SessionStart.
#   - firstmate flag -> coverage-firstmate-<day>.flag + ENQUEUED on firstmate's wake-queue,
#     so a long-running firstmate session surfaces it mid-session (its own boundary never fires).
# Credential-free (flag files, no Telegram). Runs on the always-on MBP; the mini serves the
# free local model. Always exits 0.
set -u

FM_ROOT="${FM_ROOT_OVERRIDE:-$HOME/Developer/firstmate}"
CHECK="$FM_ROOT/officers-mess/completeness_check.py"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
FLAGDIR="${ACTLOG_STATE:-$HOME/.claude/state/actlog}"

# target day: yesterday by default (a full day should be complete by the next run);
# override ACTLOG_CHECK_DAY=YYYY-MM-DD to re-check a specific day.
DAY="${ACTLOG_CHECK_DAY:-$(date -v-1d +%Y-%m-%d)}"

for officer in xo firstmate; do
  python3 "$CHECK" --officer "$officer" --day "$DAY" >>"$FLAGDIR/completeness.log" 2>&1 || true
done

# route firstmate's flag onto its wake-queue for mid-long-session surfacing
FM_FLAG="$FLAGDIR/coverage-firstmate-$DAY.flag"
if [ -f "$FM_FLAG" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  if . "$FM_ROOT/bin/fm-wake-lib.sh" 2>/dev/null; then
    STATE="$STATE" fm_wake_append check "coverage-firstmate-$DAY" \
      "completeness: firstmate log for $DAY may be missing a whole workstream — see $FM_FLAG" 2>/dev/null || true
  fi
fi
exit 0
