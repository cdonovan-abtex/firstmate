#!/usr/bin/env bash
# activity-log-coverage-surface — DISH #3 mid-session surfacing for the XO. A PostToolUse
# hook so a coverage flag reaches a RUNNING (possibly multi-day) XO session, not only at the
# next SessionStart (the recovery brief). Rides the channel the agent already reads — its own
# tool output — the same principle as firstmate's fm-guard / wake-queue.
#
# Surfaces each coverage-xo-*.flag AT MOST ONCE per session (tracked via a per-session
# marker), so it nudges without nagging. Fast + silent when there's no new flag. Exits 0.
set -u
STATE="${ACTLOG_STATE:-$HOME/.claude/state/actlog}"
mkdir -p "$STATE" 2>/dev/null

SID="$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id","nosession"))
except Exception: print("nosession")' 2>/dev/null || echo nosession)"
SEEN="$STATE/$SID.coverage-surfaced"

# find the newest un-surfaced XO coverage flag
newflag=""
for f in "$STATE"/coverage-xo-*.flag; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  grep -qxF "$base" "$SEEN" 2>/dev/null && continue
  newflag="$f"; newbase="$base"
done
[ -z "$newflag" ] && exit 0

printf '%s\n' "$newbase" >> "$SEEN"
BODY="$(cat "$newflag" 2>/dev/null)"
[ -z "$BODY" ] && exit 0

python3 - "$BODY" <<'PY'
import json, sys
msg = ("[activity-log coverage check] " + sys.argv[1].strip() +
       "\nReconcile this into the log when you get a beat (flag-not-auto-edit); the flag clears once the work is in the log.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
PY
exit 0
