# The Officer's Mess — shared continuity doctrine (firstmate + XO eat the same dogfood)

Seeded by firstmate for the XO, 2026-07-06. The activity-log intervention exposed the
real gap: not a missing hook, but a missing *architecture*. firstmate survives restarts
as a non-event because it runs on a continuity doctrine. This is that doctrine, offered
as the shared standard both officers run on — so neither of us depends on remembering.

## The one principle everything descends from
**Your conversation memory is a CACHE. Truth lives in durable state. A restart is a
non-event because you RECONCILE from that state — you never rely on remembering.**

Everything below is a mechanism that makes that principle true in practice.

## The five mechanics (firstmate's kit → the XO's port)

1. **Durable state capture — write it as it happens, not from memory later.**
   - firstmate: `state/*.status`, `*.meta`, the durable `.wake-queue` — written continuously.
   - XO: the **manifest** (built) captures every mutating action as raw material, live.
   - Rule: if it only exists in the session's head, it's already lost.

2. **A structured durable ledger — the state-of-record, not narrative.**
   - firstmate: `backlog.md` (In-flight / Queued / Done), updated on every decision.
   - XO: the daily `_activity_log` IS this — RESTART-READY STATE / decisions+rationale /
     Done today. Treat it as load-bearing state, not optional prose.

3. **A forcing-function — discipline you can't quietly skip.**
   - firstmate: `fm-guard` rides the tool output you already read; can't be missed.
   - XO: the **guard** (built) blocks session-end until the ledger reflects the session.
   - Rule: continuity-critical writes don't get left to in-the-moment judgment.

4. **External liveness — an independent check outside the session.**
   - firstmate: the watcher + `.last-watcher-beat` beacon, singleton-locked.
   - XO: the **watchdog** (built) — daily, outside any session, alerts the Captain LOUD
     if a day went un-briefed. The trust-rebuilder: not "never breaks," but "known in a day."

5. **Recovery reconciliation — a startup protocol that rebuilds the picture from state.**
   - firstmate: section 5 — on every restart, reconcile tmux + state/ + backlog + treehouse
     before doing anything; surface only what needs the Captain.
   - XO: **the natural next dish** — a SessionStart reconciliation that reads yesterday's log
     + the manifest + open threads and hands the fresh session its briefing automatically.
     (Today the XO does this by hand when he remembers; make it a protocol.)

## The menu (dishes)
- **#1 — activity-log continuity kit** (manifest + guard + watchdog): BUILT + tested this session.
- **#2 — SessionStart recovery-reconciliation for the XO** (mechanic 5): BUILT + tested (activity-log-recovery.sh/.py). XO wires into SessionStart. Full loop closed.
- **#3+ — shared state-layout + backup conventions**: as we find the next place we're
  trusting memory instead of state.

## The standard
Both officers run on all five. When one of us finds a place we're leaning on memory instead
of durable state, it becomes the next dish — and we build it for both, not just the one who
tripped. That's what eating our own dogfood means here.
