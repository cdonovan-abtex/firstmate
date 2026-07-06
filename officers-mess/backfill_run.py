#!/usr/bin/env python3
# backfill_run.py — grind the stalled backfill days on the FREE local model (mini ollama).
# digest each day's transcript -> feed the compact digest to a capable local model ->
# it drafts the activity-log entry. No cloud tokens. The days that stalled subagents,
# done for free.
import json, subprocess, urllib.request, os, sys

TDIR = os.path.expanduser("~/.claude/projects/-Users-christiandonovan-Documents-Obsidian")
OUT  = os.path.expanduser("~/Developer/firstmate/data/activity-log-guard/backfill-drafts")
DIGEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "digest.py")
os.makedirs(OUT, exist_ok=True)
MODEL = os.environ.get("BF_MODEL", "qwen3.5:35b-a3b-coding-nvfp4")
HOST  = "http://abtex-mini:11434/api/chat"

# day -> transcript file glob prefix (from firstmate's source map)
DAYS = {
  "2026-06-20": "dadafc01-901", "2026-06-21": "dadafc01-901",
  "2026-06-22": "dadafc01-901", "2026-06-23": "dadafc01-901",
  "2026-06-26": "fefd3495-6fd", "2026-07-01": "e8eb155c-86d", "2026-07-04": "70f5b231-d02",
}
MAXCHARS = 90000  # keep the digest within the model's context

FMT = ("You are reconstructing ONE day's ACTIVITY LOG for an engineering copilot (the XO), "
 "from a compact digest of that day's work session. Write it in Markdown as the XO would: "
 "a title '# <DATE> — Activity Log', then sections '## Done today' (bulleted, concrete: what "
 "was built/decided/shipped, with the WHY on key decisions) and '## Open threads' (what was "
 "left in flight). Be substantive and specific — names, files, decisions, outcomes — but do "
 "NOT invent anything not supported by the digest. If the day is thin, keep it short. This is "
 "a handoff briefing to the XO's future self, so lead with what he'd need to get back up to speed.")

def digest(day, prefix):
    import glob
    files = glob.glob(os.path.join(TDIR, prefix + "*.jsonl"))
    if not files: return ""
    parts = []
    for f in files:
        r = subprocess.run([sys.executable, DIGEST, f, day], capture_output=True, text=True)
        parts.append(r.stdout)
    return "\n".join(parts)

def synth(day, dg):
    body = {"model": MODEL, "stream": False, "keep_alive": "30m", "think": False,
            "options": {"num_ctx": 32768, "num_predict": 3500},
            "messages": [{"role": "user", "content": FMT + f"\n\nDIGEST for {day}:\n\n" + dg[:MAXCHARS]}]}
    req = urllib.request.Request(HOST, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=600).read())
    return r.get("message", {}).get("content", "")

for day, prefix in DAYS.items():
    outf = os.path.join(OUT, f"{day}.md")
    if os.path.exists(outf) and os.path.getsize(outf) > 200:
        print(f"{day}: exists, skip"); continue
    dg = digest(day, prefix)
    if len(dg) < 200:
        print(f"{day}: EMPTY digest (no content) — skip"); continue
    print(f"{day}: digest {len(dg)//1024}KB -> synthesizing on {MODEL} ...", flush=True)
    try:
        draft = synth(day, dg)
        with open(outf, "w") as fh: fh.write(draft)
        print(f"{day}: DRAFT written ({len(draft)} chars)", flush=True)
    except Exception as e:
        print(f"{day}: FAILED {e}", flush=True)
print("backfill run done.")
