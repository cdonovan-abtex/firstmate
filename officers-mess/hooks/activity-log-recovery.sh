#!/usr/bin/env bash
# activity-log-recovery — DISH #2 (XO-designed, firstmate-wired). Thin SessionStart-hook
# wrapper: passes env + execs the brief assembler (activity-log-recovery.py), which
# reconciles from durable state and emits a watch-relief brief as additionalContext so a
# cold fresh session opens already oriented. Read-only; silent when nothing to reconcile.
exec python3 "$HOME/.claude/hooks/activity-log-recovery.py"
