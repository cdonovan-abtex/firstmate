#!/usr/bin/env bash
# activity-log-manifest — the raw-material recorder behind the guard. One script,
# three claude hook events (branches on hook_event_name):
#
#   SessionStart -> drop the per-session start marker (the guard's "touched THIS
#                   session?" reference point).
#   PostToolUse  -> on a state-MUTATING tool (Edit/Write/Bash/NotebookEdit/MCP writes),
#                   append a terse line to the session manifest: time · tool · target.
#                   This is the substance the forced log synthesizes from, and it makes
#                   after-the-fact backfill possible from structured data, not transcripts.
#   PreCompact   -> compaction is the OTHER death-point (un-logged working memory gets
#                   summarized away). Copy the manifest to a dated recovery file so the
#                   material survives even if the log wasn't written before the compact.
#
# Always exits 0 — a recorder must never block or slow a session.
set -u

STATE="${ACTLOG_STATE:-$HOME/.claude/state/actlog}"
mkdir -p "$STATE" 2>/dev/null

IN="$(cat)"
eval "$(printf '%s' "$IN" | python3 -c '
import json,sys,shlex
try: d=json.load(sys.stdin)
except Exception: d={}
ev=d.get("hook_event_name","")
sid=d.get("session_id","nosession")
tool=d.get("tool_name","")
ti=d.get("tool_input",{}) or {}
# best-effort single-line target for the tool
tgt = ti.get("file_path") or ti.get("path") or ti.get("command") or ti.get("pattern") or ""
if isinstance(tgt,str): tgt=tgt.replace("\n"," ")[:120]
else: tgt=str(tgt)[:120]
print("EV=%s" % shlex.quote(ev))
print("SID=%s" % shlex.quote(sid))
print("TOOL=%s" % shlex.quote(tool))
print("TGT=%s" % shlex.quote(tgt))
' 2>/dev/null)"

EV="${EV:-}"; SID="${SID:-nosession}"; TOOL="${TOOL:-}"; TGT="${TGT:-}"
MAN="$STATE/$SID.manifest"

case "$EV" in
  SessionStart)
    : > "$STATE/$SID.start"            # fresh marker; truncates any stale one
    rm -f "$STATE/$SID.blocks" 2>/dev/null
    ;;
  PostToolUse)
    case "$TOOL" in
      Edit|Write|NotebookEdit|MultiEdit|Bash|Task|*write*|*save*|*create*|*update*|*delete*)
        printf '%s  %-10s  %s\n' "$(date +%H:%M:%S)" "$TOOL" "$TGT" >> "$MAN"
        ;;
    esac
    ;;
  PreCompact)
    if [ -s "$MAN" ]; then
      REC="$STATE/precompact-$(date +%Y-%m-%d)-$SID.manifest"
      cp "$MAN" "$REC" 2>/dev/null
    fi
    ;;
esac
exit 0
