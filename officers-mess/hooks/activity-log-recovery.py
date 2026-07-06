#!/usr/bin/env python3
# activity-log-recovery — DISH #2 brief assembler (XO-designed, firstmate-wired).
# Assembles a "watch-relief brief" from DURABLE STATE and emits it as claude SessionStart
# additionalContext, so a cold fresh session opens already oriented instead of the XO
# hand-reconstructing where things stand. Read-only. Prints nothing if there's nothing to
# reconcile from (stays silent). The /state principle, ported to the XO.
import os, sys, glob, json, datetime

LOGDIR  = os.environ.get("ACTLOG_DIR",  os.path.expanduser("~/Documents/Obsidian/_activity_logs"))
STATE   = os.environ.get("ACTLOG_STATE", os.path.expanduser("~/.claude/state/actlog"))
BACKLOG = os.environ.get("FM_BACKLOG",   os.path.expanduser("~/Developer/firstmate/data/backlog.md"))

today = datetime.date.today()
yest  = today - datetime.timedelta(days=1)
out = []

# DISH #3 surfacing: lead with any completeness coverage-gap flags (most actionable).
# The daily completeness check writes coverage-<officer>-<day>.flag when a whole workstream
# went unlogged. Surface it FIRST so a fresh session reconciles the gap before anything else.
cov = sorted(glob.glob(os.path.join(STATE, "coverage-*.flag")), reverse=True)
if cov:
    out.append("*** COVERAGE GAPS TO RECONCILE (completeness check flagged unlogged work) ***")
    for f in cov[:5]:
        out += ["  " + l for l in open(f, encoding="utf-8", errors="ignore").read().splitlines() if l.strip()]
    out.append("  ^ reconcile these into the log by hand (flag-not-auto-edit); then the flag clears.")
    out.append("")

def forward_sections(path):
    """pull forward-looking sections (open/active/carry threads) from a log."""
    if not os.path.exists(path): return []
    wanted = ("open thread","active thread","live thread","carry","carried","next session","restart")
    keep, grab = [], False
    for l in open(path, encoding="utf-8", errors="ignore").read().splitlines():
        if l.startswith("#"):
            grab = any(w in l.lower() for w in wanted)
        if grab and l.strip():
            keep.append(l)
    return keep[:40]

for label, day in (("YESTERDAY", yest), ("TODAY", today)):
    secs = forward_sections(os.path.join(LOGDIR, f"{day}.md"))
    if secs:
        out.append(f"- FROM {label}'S LOG ({day}) -")
        out += ["  " + s for s in secs]
    elif label == "TODAY":
        out.append(f"- TODAY ({day}): log not started yet -")

mans = sorted(glob.glob(os.path.join(STATE, "*.manifest")), key=os.path.getmtime, reverse=True)
if mans and os.path.getsize(mans[0]) > 0:
    tail = open(mans[0], encoding="utf-8", errors="ignore").read().splitlines()[-8:]
    out.append("- UNLOGGED ACTIONS THIS/LAST SESSION (manifest) -")
    out += ["  " + t for t in tail]

if os.path.exists(BACKLOG):
    grab, keep = False, []
    for l in open(BACKLOG, encoding="utf-8", errors="ignore").read().splitlines():
        if l.startswith("## "):
            grab = any(w in l.lower() for w in ("in flight","queued","awaiting","parked"))
        if grab and l.strip():
            keep.append(l)
    if keep:
        out.append("- FLEET LEDGER (firstmate backlog) -")
        out += ["  " + k for k in keep[:30]]

if not out:
    sys.exit(0)

brief = ("=== WATCH-RELIEF BRIEF (auto-reconciled from durable state — you're oriented, "
         "no hand-reconstruction needed) ===\n" + "\n".join(out) + "\n=== end brief ===")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": brief}}))
