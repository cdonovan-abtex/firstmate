#!/usr/bin/env bash
# bottle-write-guard — GATE BEATS DISCIPLINE (Captain's ruling 2026-07-06). A PreToolUse
# deny-hook (Stratum A, harness-enforced — the officer can't route around it) that makes
# hand-splicing the message-in-a-bottle channel STRUCTURALLY IMPOSSIBLE. The only way to
# write the channel is `bottle post` (atomic, lock-guarded, unique-Id, routed). This turns
# "we'll use the tool" from a promise (which just failed twice — ID collisions + a dropped
# message) into a gate.
#
# DENIES: any Edit/Write/MultiEdit/NotebookEdit targeting a routes/*/YEOMAN.md, and any Bash
# command whose WRITE TARGETS a bottle YEOMAN.md by any means other than `bottle post`.
# ALLOWS: `bottle post`, and all READS (grep/cat/sed -n/head/tail) of the channel — including
# reads that carry unrelated shell plumbing (2>/dev/null, comparisons like >=, or writes to
# other files like > /tmp/x). Mere co-occurrence of the path with a redirect is NOT a write.
set -u
DECISION="$(cat | python3 -c '
import json, re, sys
try: d = json.load(sys.stdin)
except Exception: print("allow"); sys.exit(0)
tool = d.get("tool_name","")
ti   = d.get("tool_input",{}) or {}

# a bottle channel file: .../message-in-a-bottle/routes/<route>/YEOMAN.md
BOTTLE = re.compile(r"message-in-a-bottle/routes/[^/]+/YEOMAN\.md")

def deny(reason): print("deny\t"+reason); sys.exit(0)

if tool in ("Edit","Write","MultiEdit","NotebookEdit"):
    fp = str(ti.get("file_path") or ti.get("notebook_path") or "")
    if BOTTLE.search(fp):
        deny("Direct "+tool+" of the bottle channel is gated. Post with: bottle post <route> --author firstmate (body on stdin). Hand-splicing causes ID collisions + dropped messages.")

if tool == "Bash":
    cmd = str(ti.get("command",""))
    if BOTTLE.search(cmd) or re.search(r"routes/[^/]+/YEOMAN\.md", cmd):
        # a legit post goes through the bottle CLI
        is_post = re.search(r"\bbottle\b[^\n]*\bpost\b", cmd) is not None
        # A write must TARGET a bottle YEOMAN.md. Co-occurrence of the path with an unrelated
        # redirect (2>/dev/null), comparison (>=), or a write to another file (> /tmp/x) is
        # NOT a bottle write. Three precise signals:
        writes = (
            # 1) a redirect straight INTO a bottle path: >> YEOMAN.md, > ~/...YEOMAN.md
            re.search(r">>?[ \t]*[\x27\"]?[^ |&;()\n]*YEOMAN\.md", cmd) is not None
            # 2) in-place edit / move / remove / tee whose target is a bottle path
            or re.search(r"\b(sed[^|&;\n]*-i|tee|truncate|rm|mv|cp)\b[^|&;\n]*YEOMAN\.md", cmd) is not None
            # 3) a python-object write (path usually held in a var, so the bottle-path match
            #    above is the association): .write_text / .writelines / open(...,"w")
            or re.search(r"\.write_text|\.writelines|open\([^)]*[\x27\"][wax]", cmd) is not None
        )
        if writes and not is_post:
            deny("This Bash command writes to the bottle channel directly. That is gated — use: bottle post <route> --author firstmate. Only bottle post may write the channel.")
print("allow")
' 2>/dev/null || echo "allow")"

kind="${DECISION%%$'\t'*}"; reason="${DECISION#*$'\t'}"
if [ "$kind" = "deny" ]; then
  python3 - "$reason" <<'PY'
import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}))
PY
  exit 0
fi
exit 0
