#!/usr/bin/env bash
# install.sh — deploy the officer's-mess continuity kit from this TRACKED source-of-truth
# to its runtime locations. Idempotent. Run after a clone/pull to (re)provision a machine —
# the whole point: the anti-loss infra is now itself recoverable from git.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/state/actlog" "$HOME/Library/LaunchAgents"
cp "$HERE"/hooks/*.sh "$HERE"/hooks/*.py "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/"activity-log-*.sh "$HOME/.claude/hooks/"activity-completeness-daily.sh 2>/dev/null || true
cp "$HERE"/com.fleet.*.plist "$HOME/Library/LaunchAgents/" 2>/dev/null || true
echo "deployed hooks -> ~/.claude/hooks and plists -> ~/Library/LaunchAgents"
echo "NEXT (Captain's word): launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.fleet.activity-completeness.plist"
echo "XO wiring (vault .claude/settings.json): manifest on SessionStart/PostToolUse/PreCompact, guard on Stop, recovery + coverage-surface on SessionStart/PostToolUse. See README.md."
