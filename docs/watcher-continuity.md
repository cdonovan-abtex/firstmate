# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
While supervision is still needed and away mode remains inactive, an actionable close or typed failure wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Notification boundary

`bin/fm-watch.sh` is the single harness-neutral owner of whether a supervision observation is actionable enough to close a watcher cycle.
Claude and Grok expose that close through native background-task completion, Codex exposes it through a foreground checkpoint, and the Pi and OpenCode adapters restore continuity before delivering it.
Those adapters must not reclassify task state because a backend-neutral decision in the watcher keeps all five primary harnesses aligned.

The signal and stale paths both reuse `bin/fm-classify-lib.sh`'s authoritative `working|paused|none` crew classification.
An unchanged authoritative `paused` state advances the signal and stale suppressors without enqueuing or closing the cycle.
A real `needs-decision`, `blocked`, `done`, or `failed` status still enqueues before suppression and closes exactly one cycle.
That guarantee survives a same-turn `paused:` line appended after the decision: the paused absorb consults `status_open_decisions`, the authoritative durable fold, rather than the last status line, so a masked open decision surfaces once instead of waiting out the pause cadence.
The stale path absorbs the successor's observation of an unchanged terminal event through a one-shot token armed by the path that surfaced it, which prevents a second adapter prompt after the first drain already consumed the durable rows.
That token is deliberately separate from the heartbeat backstop's surfaced-status marker and is consumed by the single observation it deduped, so the next distinct pane observation - a crash or resume prompt, an interactive menu that reports a finish with no new status line - still surfaces.
An authoritative `working` state outranks that dedupe seam, because only the provably-working absorb arms the wedge timer that still escalates a genuinely frozen run on an unchanged pane.
Authenticated checks remain independent actionable sources, so a quiet paused service stays silent while a healthy check prints nothing and wakes when that check reports a failure.

This boundary is runtime-backend independent.
Tmux, Zellij, Orca, and cmux feed the same polling classifier through capture and busy-state fallbacks, while Herdr's native push path retains its shared transition policy and declared-pause exemption before returning to the same poll backstop.
No runtime adapter gains a notification policy, cross-home suppression, or process-wide kill path from this behavior.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.
`tests/fm-watch-triage.test.sh` deterministically holds the signal grace window open while a working event is superseded by `paused` plus turn-end, then proves the unchanged idle pane remains in the same quiet watcher cycle.
The same suite proves `needs-decision`, `blocked`, `done`, and `failed` each close one cycle while the successor absorbs the unchanged terminal stale observation, that a `needs-decision` or `blocked` masked by a later `paused:` line still closes exactly one cycle, and that the successor dedupe releases after one observation so a new pane event behind an unchanged terminal status still escalates.
`tests/fm-wake-queue.test.sh` proves a registered service-health check remains silent during a healthy pause and preserves the queued actionable wake when the service fails.

## Deterministic notification-noise verification, 2026-07-23

The end-user reproduction used the event order observed for `epicoracle-quoting-devserver-v1`: a working service-ready event entered signal grace, the same turn appended `paused` and turn-end, and the successor then observed the unchanged idle pane.
Before the fix, the fixture printed `signal: ...task.status ...task.turn-ended` and completed the watcher.
After the fix, the same process remained live with no reason output or queue row and entered the existing pause cadence.

Command: `tests/fm-watch-triage.test.sh`.
Observed results included `ok - a signal superseded by unchanged paused state stays in one quiet watcher cycle` and `ok - needs-decision, blocked, done, and failed each wake once without a stale successor duplicate`.

Command: `tests/fm-wake-queue.test.sh`.
Observed result included `ok - a paused service's health check stays silent while healthy and wakes on failure`.

Commands: `tests/fm-supervision-events.test.sh`, `tests/fm-transition-lib.test.sh`, `tests/fm-supervision-instructions.test.sh`, `tests/fm-watch-checkpoint.test.sh`, and `tests/fm-pi-watch-extension.test.sh`.
Observed result: every deterministic primary-harness and Herdr push assertion passed.

Commands: `tests/fm-backend.test.sh`, `tests/fm-backend-herdr.test.sh`, `tests/fm-backend-zellij.test.sh`, `tests/fm-backend-orca.test.sh`, and `tests/fm-backend-cmux.test.sh`.
Observed result: every runtime-backend unit assertion passed.
No live Herdr lifecycle command was necessary because this change does not alter lifecycle mechanics, session targeting, or the backend event producer.

Command: `bin/fm-lint.sh` with pinned ShellCheck 0.11.0.
Observed result: exit 0 with no findings.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
