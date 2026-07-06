#!/usr/bin/env bash
# activity-log-watchdog — the FAIL-LOUD backstop. Runs daily (launchd/cron), OUTSIDE
# any agent session, so it catches a skipped log even if the in-session hook was
# bypassed, disabled, or the session died mid-flight. This is the trust-rebuilder:
# the promise is not "it never breaks" but "the Captain knows within a day when it
# does" — no more week-old silent gaps.
#
# Checks that the target day's log exists AND is non-trivial (> MIN_BYTES). If not,
# it fires a LOUD alert on the Captain's real surface via ACTLOG_ALERT_CMD.
#
# Runs each morning and checks YESTERDAY by default (a full day should be briefed by
# the next morning; checking "today" at 6am would false-alarm on a day just begun).
# Override ACTLOG_CHECK_DAY=today for an end-of-day run.
set -u

LOGDIR="${ACTLOG_DIR:-$HOME/Documents/Obsidian/_activity_logs}"
MIN_BYTES="${ACTLOG_MIN_BYTES:-200}"
WHICH="${ACTLOG_CHECK_DAY:-yesterday}"
# ACTLOG_ALERT_CMD: a command that takes the alert text as $1 and delivers it to the
# Captain's real surface (Telegram bot, daily-brief injector, etc.). If unset, falls
# back to a local marker file + a macOS notification so nothing is silent even now.
ALERT_CMD="${ACTLOG_ALERT_CMD:-}"

# BSD/macOS date (vault + watchdog are macOS); date -v-1d is native here.
if [ "$WHICH" = "today" ]; then DAY="$(date +%Y-%m-%d)"; else DAY="$(date -v-1d +%Y-%m-%d)"; fi
LOG="$LOGDIR/$DAY.md"

size=0
[ -f "$LOG" ] && size="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"

if [ "$size" -ge "$MIN_BYTES" ]; then
  exit 0   # briefed. silent.
fi

MSG="⚠️ ACTIVITY LOG MISSING for $DAY — the XO's handoff briefing for that day is $([ "$size" -eq 0 ] && echo 'absent' || echo "only ${size}b"). A day of context is at risk of being lost. It needs backfilling from that day's session transcripts before it goes cold."

if [ -n "$ALERT_CMD" ]; then
  "$ALERT_CMD" "$MSG" || echo "$MSG" >&2
else
  # no surface wired yet: never be silent — marker file + desktop notice + stderr
  MARK="${ACTLOG_STATE:-$HOME/.claude/state/actlog}/ALERT-$DAY.txt"
  mkdir -p "$(dirname "$MARK")" 2>/dev/null; printf '%s\n' "$MSG" > "$MARK"
  command -v osascript >/dev/null 2>&1 && osascript -e "display notification \"activity log missing for $DAY\" with title \"XO Activity Log\"" >/dev/null 2>&1
  echo "$MSG" >&2
fi
exit 1
