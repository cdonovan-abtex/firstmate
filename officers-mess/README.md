# Activity-Log Guard — the officer's-mess continuity kit (dish #1)

Built by firstmate for the XO (intervention, 2026-07-06), the first port of firstmate's
own continuity doctrine onto the XO: **memory is a cache; truth lives in durable state;
a restart is a non-event because you reconcile from that state.** The XO's daily
`_activity_log` is his handoff briefing from his past self to his next self — so he shows
up fresh-pressed and fully briefed instead of spinning wheels. It kept getting discounted
in the moment (11 of 24 days missing); this moves the write OUT of in-the-moment discretion.

## The three pieces (firstmate's state/backup pattern, mapped)

| firstmate mechanic | XO port (this kit) | file |
|---|---|---|
| durable state capture (`state/*.status`, wake-queue) | **manifest** — records every mutating action as raw material | `activity-log-manifest.sh` |
| `fm-guard` forcing-function | **guard** — blocks session end until today's log is written | `activity-log-guard.sh` |
| the watcher / liveness beacon | **watchdog** — external daily check, alerts the Captain if a day is missing | `activity-log-watchdog.sh` |

Deployed to `~/.claude/hooks/` (shared, both officers reach it). Source of truth here.

## Wiring — the XO's side (add to the vault `.claude/settings.json` hooks block)

```json
"SessionStart": [
  { "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/activity-log-manifest.sh\"" } ] }
],
"PostToolUse": [
  { "matcher": "*", "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/activity-log-manifest.sh\"" } ] }
],
"PreCompact": [
  { "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/activity-log-manifest.sh\"" } ] }
],
"Stop": [
  { "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/activity-log-guard.sh\"" } ] }
]
```
(The vault already has a SessionStart entry for `bottle-drain-xo.sh` and a PostToolUse:Read
entry for memory-decay — ADD to those arrays, don't replace them.)

## Wiring — firstmate's side (the watchdog)

A daily launchd/cron running `activity-log-watchdog.sh`, on the machine that can see the
vault (`~/Documents/Obsidian/_activity_logs/`). Checks YESTERDAY each morning; if the log
is absent or <200 bytes it fires `ACTLOG_ALERT_CMD` (a single executable path taking the
message as `$1`) on the Captain's real surface. **CONFIRM WITH XO:** (a) which machine sees
the vault (MBP vs synced-to-Mini), (b) the Captain's loud surface (Telegram bot? brief
injector?) → that becomes `ACTLOG_ALERT_CMD`. Until wired, it falls back to a marker file
+ macOS notification (never silent).

## Config (env, all optional)
- `ACTLOG_DIR` (default `~/Documents/Obsidian/_activity_logs`)
- `ACTLOG_STATE` (default `~/.claude/state/actlog`)
- `ACTLOG_MAX_BLOCKS` (default 2 — safety valve; after this the guard relents + the watchdog backstops)
- `ACTLOG_MIN_BYTES` (default 200), `ACTLOG_CHECK_DAY` (default `yesterday`), `ACTLOG_ALERT_CMD`

## Acceptance test (the XO's + the Captain's, together)
It catches a skipped log WITHOUT the XO, and it's LOUD, and the fourth conversation never happens.
Verified end-to-end: blocks on unlogged work · relents at the safety valve (never wedges) ·
passes when logged · no false block on a read-only session · watchdog loud on a missing day.

## Safety valve (protect, never trap)
The guard blocks at most `ACTLOG_MAX_BLOCKS` times, then relents with a loud warning and lets
the watchdog carry it. It can force the write; it can never lock the XO out of ending a session.
