#!/usr/bin/env python3
# completeness_check.py — DISH #3. Upgrades the watchdog from PRESENCE ("a log exists")
# to COMPLETENESS ("the log captured what actually happened"). Catches the insidious case
# the presence-check sails past: a log that EXISTS but silently dropped real work (a 6/29
# that named the OKF work but omitted the Paycor build).
#
# Time-based DAILY (not session-triggered) — the only trigger that sees inside a multi-day
# session, where the guard's Stop-hook and the recovery hook never fire. FREE + credential-
# free: digests the day's transcript, diffs it against that day's log via the local model,
# and writes a COVERAGE-FLAG file if significant work is missing. FLAGS, never auto-edits
# (provenance stays honest — the officer reconciles the gap into the log).
#
# Usage: completeness_check.py --officer xo|firstmate --day YYYY-MM-DD
import argparse, glob, json, os, subprocess, sys, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DIGEST = next((q for q in [os.path.join(HERE,"digest.py"), os.path.join(HERE,"backfill-sources","digest.py")] if os.path.exists(q)), os.path.join(HERE,"digest.py"))
# Engine: 'codex' (precise, uses the paid Codex overhead — default) or 'local' (free qwen
# on the mini — cheaper but noisier; kept as fallback). Codex fixed the local model's
# false-positive/inconsistency problem on the completeness judgment.
ENGINE = os.environ.get("CC_ENGINE", "codex")
HOST = "http://abtex-mini:11434/api/chat"
LOCAL_MODEL = os.environ.get("CC_LOCAL_MODEL", "qwen3.5:35b-a3b-coding-nvfp4")

OFFICERS = {
  "xo": {
    "tdir": os.path.expanduser("~/.claude/projects/-Users-christiandonovan-Documents-Obsidian"),
    "logdir": os.path.expanduser("~/Documents/Obsidian/_activity_logs"),
    "flagdir": os.path.expanduser("~/.claude/state/actlog"),
  },
  "firstmate": {
    "tdir": os.path.expanduser("~/.claude/projects/-Users-christiandonovan-Developer-firstmate"),
    "logdir": os.path.expanduser("~/Developer/firstmate/data/activity-logs"),
    "flagdir": os.path.expanduser("~/.claude/state/actlog"),
  },
}

# The bar is ABSENCE, not brevity. A log that MENTIONS work (even in one terse bullet) has
# captured it — the reader knows it happened and can dig. Only flag work/decisions a reader
# of the log would have NO IDEA occurred (the insidious case: a 6/29 that drops Paycor
# entirely). Flagging summarization = alert-fatigue = the cry-wolf we're preventing.
PROMPT = (
 "You audit whether a whole WORKSTREAM went entirely unlogged. Below is a DIGEST of a day "
 "(source of truth) and the LOG written for it.\n"
 "Work at the level of WHOLE WORKSTREAMS — a distinct project, feature, incident, meeting, "
 "or deliverable. List up to 3 whole workstreams present in the DIGEST but with NO trace at "
 "all in the LOG.\n"
 "GRANULARITY — this is the whole test:\n"
 "  • FLAG only if an ENTIRE workstream is absent. Example: the log covers OKF but the day "
 "also had a whole Paycor integration build that appears NOWHERE -> flag Paycor.\n"
 "  • Do NOT flag details, findings, sub-steps, config values, or decisions WITHIN a "
 "workstream the log already mentions. If the log says 'built the Malish report', do NOT "
 "flag the specific BAQ mappings, the COMM2 finding, or the branch name — those live under "
 "a logged workstream. Brevity is fine; only a MISSING WHOLE THREAD counts.\n"
 "  • Ask yourself: 'is there a whole area of work the Captain would not know happened AT "
 "ALL from this log?' If no such whole area exists, reply with exactly: COMPLETE\n"
 "Format each missing workstream as one line: '- <the whole missing workstream>'. No preamble.")

def digest_day(tdir, day):
    parts = []
    for f in glob.glob(os.path.join(tdir, "*.jsonl")):
        r = subprocess.run([sys.executable, DIGEST, f, day], capture_output=True, text=True)
        if r.stdout.strip() and "0 entries" not in r.stdout.splitlines()[0]:
            parts.append(r.stdout)
    return "\n".join(parts)

def ask_codex(prompt):
    """One-shot headless Codex (precise). Clean answer via --output-last-message."""
    pf = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False); pf.write(prompt); pf.close()
    outf = pf.name + ".ans"
    try:
        with open(pf.name) as stdin:
            subprocess.run(["codex", "exec", "--skip-git-repo-check", "--sandbox", "read-only",
                            "--output-last-message", outf, "-"],
                           stdin=stdin, capture_output=True, text=True, timeout=240)
        return open(outf, encoding="utf-8", errors="ignore").read().strip() if os.path.exists(outf) else ""
    finally:
        for p in (pf.name, outf):
            try: os.remove(p)
            except OSError: pass

def ask_local(prompt):
    body = {"model": LOCAL_MODEL, "stream": False, "think": False, "keep_alive": "30m",
            "options": {"num_ctx": 32768, "num_predict": 800},
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(HOST, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=600).read()).get("message", {}).get("content", "").strip()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--officer", required=True, choices=list(OFFICERS))
    ap.add_argument("--day", required=True)
    a = ap.parse_args()
    cfg = OFFICERS[a.officer]

    dg = digest_day(cfg["tdir"], a.day)
    if len(dg) < 200:
        print(f"{a.officer} {a.day}: no meaningful activity in transcripts — skip"); return
    logpath = os.path.join(cfg["logdir"], f"{a.day}.md")
    log = open(logpath, encoding="utf-8", errors="ignore").read() if os.path.exists(logpath) else "(NO LOG EXISTS FOR THIS DAY)"

    full = PROMPT + f"\n\n=== DIGEST ({a.day}) ===\n{dg[:80000]}\n\n=== LOG ({a.day}) ===\n{log[:20000]}"
    out = (ask_codex(full) if ENGINE == "codex" else ask_local(full)).strip()

    flagpath = os.path.join(cfg["flagdir"], f"coverage-{a.officer}-{a.day}.flag")
    if not out or out.upper().startswith("COMPLETE") or "COMPLETE" == out.upper().strip():
        if os.path.exists(flagpath): os.remove(flagpath)
        print(f"{a.officer} {a.day}: COMPLETE — log covers the significant work"); return
    os.makedirs(cfg["flagdir"], exist_ok=True)
    with open(flagpath, "w") as fh:
        fh.write(f"COVERAGE GAP — {a.officer} log for {a.day} may be missing:\n{out}\n")
    print(f"{a.officer} {a.day}: GAP flagged ->\n{out}")

if __name__ == "__main__":
    main()
