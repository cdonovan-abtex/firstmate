#!/usr/bin/env python3
# digest.py — turn a giant session transcript (.jsonl, 14-34MB) into a COMPACT per-date
# digest that a model can actually synthesize a log from. The raw transcripts stall
# subagents (600s no-progress) because tool_result bodies + thinking blocks are enormous.
# This keeps only the SIGNAL: user asks, assistant summary text, and tool actions
# (name + target), filtered to one date. Output is a few KB, not 30MB.
#
# Usage: digest.py <transcript.jsonl> <YYYY-MM-DD>  > digest.txt
import json, sys

def blocks(msg):
    c = msg.get("content", [])
    if isinstance(c, str): return [("text", c)]
    out = []
    for b in c if isinstance(c, list) else []:
        if not isinstance(b, dict): continue
        t = b.get("type")
        if t == "text": out.append(("text", b.get("text", "")))
        elif t == "tool_use":
            ti = b.get("input", {}) or {}
            tgt = ti.get("file_path") or ti.get("path") or ti.get("command") or ti.get("pattern") or ti.get("description") or ""
            if not isinstance(tgt, str): tgt = str(tgt)
            out.append(("tool", f"{b.get('name','?')}: {tgt[:140]}"))
        # tool_result + thinking: dropped on purpose (that's the bloat)
    return out

def main():
    path, day = sys.argv[1], sys.argv[2]
    lines_out, ntool = [], 0
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: d = json.loads(line)
            except Exception: continue
            ts = d.get("timestamp", "")
            if not (isinstance(ts, str) and ts[:10] == day): continue
            msg = d.get("message", {})
            role = (msg.get("role") or d.get("type") or "")
            for kind, val in blocks(msg):
                val = (val or "").strip()
                if not val: continue
                if kind == "text":
                    # keep user asks whole-ish; trim long assistant prose to its gist
                    cap = 500 if role == "user" else 700
                    lines_out.append(f"[{role.upper()}] {val[:cap]}")
                else:
                    ntool += 1
                    lines_out.append(f"  · {val}")
    print(f"# DIGEST {day} — from {path.split('/')[-1]}  ({len(lines_out)} entries, {ntool} tool-actions)\n")
    print("\n".join(lines_out))

if __name__ == "__main__":
    main()
