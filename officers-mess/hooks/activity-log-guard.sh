#!/usr/bin/env bash
# activity-log-guard — the forcing-function that keeps the XO's daily _activity_log
# from silently vanishing. Runs as a claude **Stop** hook in the XO's vault session.
#
# WHY: the daily log is the XO's handoff briefing from his past self to his future
# self — the thing that lets him restart fresh-pressed and fully briefed instead of
# spinning wheels. Heads-down, the log gets discounted in the moment; then the session
# ends and the day is gone. Empirically self-policing failed (11 of 24 days missing).
# So the guard moves the decision OUTSIDE the agent's discretion: it refuses to let a
# session END if real work happened and today's log wasn't touched.
#
# It does NOT write the log (a machine can't synthesize the judgment) — it BLOCKS the
# stop and hands the agent a clear instruction + the raw session-manifest as material,
# so the forced write has substance. Safety valve: after MAX_BLOCKS it relents with a
# LOUD warning (the external watchdog is the backstop) — it can protect, never wedge.
#
# Contract (claude Stop hook): reads hook JSON on stdin; to block, prints
# {"decision":"block","reason":"..."} on stdout. Exit 0 + no block = stop proceeds.
set -u

STATE="${ACTLOG_STATE:-$HOME/.claude/state/actlog}"
LOGDIR="${ACTLOG_DIR:-$HOME/Documents/Obsidian/_activity_logs}"
MAX_BLOCKS="${ACTLOG_MAX_BLOCKS:-2}"
mkdir -p "$STATE" 2>/dev/null

# --- read the hook payload (session_id, stop_hook_active) ---
IN="$(cat)"
read -r SID STOP_ACTIVE < <(printf '%s' "$IN" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("session_id","nosession"), str(d.get("stop_hook_active",False)).lower())
' 2>/dev/null || echo "nosession false")

TODAY="$(date +%Y-%m-%d)"
LOG="$LOGDIR/$TODAY.md"
MAN="$STATE/$SID.manifest"
STARTF="$STATE/$SID.start"
BLKF="$STATE/$SID.blocks"

# --- gate 1: did real (state-mutating) work happen this session? ---
# The manifest is appended by activity-log-manifest.sh on each mutating tool use.
# No manifest / empty -> nothing worth logging -> never block.
if [ ! -s "$MAN" ]; then
  exit 0
fi

# --- gate 2: was today's log touched THIS session? ---
# Touched-this-session = log exists and is newer than the session-start marker.
# (SessionStart drops the marker; if absent, fall back to "log exists and non-trivial".)
logged=false
if [ -f "$LOG" ]; then
  if [ -f "$STARTF" ]; then
    [ "$LOG" -nt "$STARTF" ] && logged=true
  else
    # no marker: accept a non-trivial log as good-enough (avoids false blocks)
    [ "$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" -ge 200 ] && logged=true
  fi
fi
if [ "$logged" = true ]; then
  rm -f "$BLKF" 2>/dev/null   # clean state; day is satisfied
  exit 0
fi

# --- safety valve: never wedge. After MAX_BLOCKS, relent with a loud warning. ---
blocks=0; [ -f "$BLKF" ] && blocks="$(cat "$BLKF" 2>/dev/null || echo 0)"
if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
  echo "activity-log-guard: RELENTING after $blocks blocks — today's log ($TODAY) is STILL unwritten. The external watchdog will flag this to the Captain today. Write it when you can." >&2
  exit 0
fi
echo $((blocks + 1)) > "$BLKF"

# --- build the raw-material summary so the forced write has substance ---
SUMMARY="$(tail -n 40 "$MAN" 2>/dev/null | sed 's/"/'"'"'/g')"

# --- BLOCK: hand the agent a crystal-clear, un-skippable instruction ---
python3 - "$TODAY" "$LOG" "$SUMMARY" <<'PY'
import json,sys
today, log, summary = sys.argv[1], sys.argv[2], sys.argv[3]
reason = (
 f"STOP — today's activity log is not written and real work happened this session.\n\n"
 f"This log is your handoff briefing to your own next session — skip it and tomorrow's "
 f"you spins wheels or loses the day (this has cost real work before). It is NOT optional "
 f"and this is by design: the choice to skip has been moved out of your hands.\n\n"
 f"WRITE NOW: append today's decisions + actions to  {log}\n"
 f"Match your normal format (RESTART-READY STATE / decisions+rationale / Done today). "
 f"Synthesize — don't just paste the manifest.\n\n"
 f"RAW MATERIAL captured this session (source, not the log itself):\n{summary}\n\n"
 f"This message clears the moment {today}.md reflects this session. "
 f"(Safety valve: if you truly cannot, it relents after a couple tries and the watchdog "
 f"flags it to the Captain — it will never trap you.)"
)
print(json.dumps({"decision":"block","reason":reason}))
PY
exit 0
