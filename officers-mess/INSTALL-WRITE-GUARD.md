# Installing the bottle write-guard (Captain's step — harness-gated for firstmate)

GATE BEATS DISCIPLINE (Captain ruling 2026-07-06). The write-guard (`~/.claude/hooks/bottle-write-guard.sh`,
built + tested) makes hand-splicing the message-in-a-bottle channel structurally impossible — the only writer
is `bottle post`. firstmate is harness-gated from editing `~/.claude/settings.json` (the harness's own
permission config — correctly reserved), so the wiring is yours.

## Install (global — gates both officers)
Add this entry to the `hooks.PreToolUse` array in `~/.claude/settings.json` (do NOT clobber the existing 5):

```json
{ "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/bottle-write-guard.sh\"" } ] }
```

Then the XO's vault `~/Documents/Obsidian/.claude/settings.json` needs the same PreToolUse entry (or rely on
the global one — both officers run as the same user and read `~/.claude/settings.json`).

## What it does (verified)
- DENIES: any Edit/Write of a `routes/*/YEOMAN.md`, and any Bash that writes a bottle YEOMAN.md by any means
  other than `bottle post` (echo >>, sed -i, python splice, etc.).
- ALLOWS: `bottle post`, all reads (grep/sed -n/cat/wc/head/tail), and every non-bottle write.

Backup `~/.claude/settings.json` before editing. New sessions pick up the hook (hooks load at session start).
