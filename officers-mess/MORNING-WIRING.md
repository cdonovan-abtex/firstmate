# Morning wiring — the 2 reserved steps (Captain / XO)

Everything else is done and live. These two were correctly gated away from firstmate
(deployment to your machines) — each is a short, deliberate action for you.

## What's already live (no action)
- **The guard** is wired in the XO's vault and enforcing now. Today's log can't be silently skipped.
- **The backfill** is drafted for all missing days in `backfill-drafts/` — the XO verifies + places them.

## Step 1 — load the watchdog (on the MBP, ~10 seconds)
The daily fail-loud check is built + its LaunchAgent is written; it just needs loading:
```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.fleet.activity-log-watchdog.plist
launchctl kickstart -p gui/$(id -u)/com.fleet.activity-log-watchdog   # optional: fire once now to test
```
It runs daily at 08:30, checks yesterday's log, and (until step 2) falls back to a marker
file + macOS notification — never silent. To remove: `launchctl bootout gui/$(id -u)/com.fleet.activity-log-watchdog`.

## Step 2 — wire the LOUD surface (Telegram via the XO's Hermes)
Firstmate is (correctly) blocked from reaching the Mini's Hermes creds autonomously, so this
is the XO's to provide: a single executable that takes the message as `$1` and sends it to
the Captain's Telegram. Then add it to the plist's `EnvironmentVariables`:
```
<key>ACTLOG_ALERT_CMD</key>
<string>/path/to/telegram-send.sh</string>
```
and reload (bootout + bootstrap). Until then, the fallback keeps it non-silent.

## Note on the host (XO #000443)
The vault is live on the **MBP**; the Mini's Obsidian Sync is stale (to 6/09), so the watchdog
runs on the MBP for now. If the Mini's sync is made current, the always-on Mini becomes the
better host — a later improvement, not needed today.

## Source of truth
Scripts + plist + README + officer's-mess doctrine: `data/activity-log-guard/`.
