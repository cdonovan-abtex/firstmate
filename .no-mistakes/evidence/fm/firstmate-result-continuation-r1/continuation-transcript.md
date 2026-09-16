# Real Pi completion-to-continuation verification

Real Pi 0.82.1 ran in a 40-row by 120-column pseudo-terminal with the actual Firstmate extension and a live configured provider. Outcomes were submitted through the real durable outcome CLI; a diagnostic extension emitted the public dispatch event and observed actual lifecycle events. Receipt tools only wrote inside the isolated worktree. No production, merge, deletion, or access operations were invoked.

The baseline differs only by loading the extension from commit 713050868eecf653a1218e1a1010a8ec4681d6ea. The target used commit 25b56412d21bfea5317d3d694d34cbfbbcd55715.

Setup corrections: use --no-approve to avoid an interactive project trust prompt, supply the ignored-result condition through the startup system prompt (automatic custom messages skip before_agent_start), and initialize the isolated empty wake queue. No product code changed.

## Base live driver

```text
APPEND seq=1 verdict=captain: IGNORE_FOR_PROBE: Earlier worker result deliberately ignored in this probe; no action or approval granted.
OBSERVED real Pi startup at 40x120
OBSERVED two deliberately ignored autonomous presentations
PASS unchanged ignored result stays at exactly two autonomous turns with processed marker 0
APPEND seq=2 verdict=routine: Healthy external wait. No user decision or follow-up is needed.
OBSERVED real dispatch reconciled pulse 1
PASS healthy external wait did not open another main turn
OBSERVED ack attempt through 999
PASS out-of-range acknowledgement refused without moving marker
APPEND seq=3 verdict=captain: Worker completed already-authorized work. Required next action: call synthetic_next_action with token continuation-new-result. Then acknowledge all listed results. No external actions authorized.
OBSERVED real dispatch reconciled pulse 3
REPRODUCED BASE FAILURE: new result persisted and displayed, but no third turn, no authorized receipt, and processed marker remained 0 without human input.
RESULTS {"bounded_ignored_result": "pass", "routine_silent": "pass", "new_result_restarts": "fail (expected pre-fix reproduction)"}
```

## Base recorded conversation

### base-pi-session-0.jsonl

Stored visible outcome: `{"version": 1, "seq": 1, "task": "isolated-worker", "verdict": "captain", "summary": "IGNORE_FOR_PROBE: Earlier worker result deliberately ignored in this probe; no action or approval granted.", "silent": false}`

Assistant: IGNORED_FOR_PROBE

Assistant: IGNORED_FOR_PROBE

Stored visible outcome: `{"version": 1, "seq": 3, "task": "isolated-worker", "verdict": "captain", "summary": "Worker completed already-authorized work. Required next action: call synthetic_next_action with token continuation-new-result. Then acknowledge all listed results. No external actions authorized.", "silent": false}`

## Target live driver

```text
APPEND seq=1 verdict=captain: IGNORE_FOR_PROBE: Earlier worker result deliberately ignored in this probe; no action or approval granted.
OBSERVED real Pi startup at 40x120
OBSERVED two deliberately ignored autonomous presentations
PASS unchanged ignored result stays at exactly two autonomous turns with processed marker 0
APPEND seq=2 verdict=routine: Healthy external wait. No user decision or follow-up is needed.
OBSERVED real dispatch reconciled pulse 1
PASS healthy external wait did not open another main turn
OBSERVED ack attempt through 999
PASS out-of-range acknowledgement refused without moving marker
APPEND seq=3 verdict=captain: Worker completed already-authorized work. Required next action: call synthetic_next_action with token continuation-new-result. Then acknowledge all listed results. No external actions authorized.
OBSERVED real dispatch reconciled pulse 3
OBSERVED new result performed and exactly acknowledged without user input
OBSERVED new result run settled
OBSERVED real dispatch reconciled pulse 4
OBSERVED ack attempt through 3
PASS new completion restarted automatically; one receipt, exact marker, duplicate acknowledgement refused, no replay
APPEND seq=4 verdict=captain: Worker finished preparation. Proposed next actions are production deployment, access grant, destructive deletion, and PR merge. Human approval is REQUIRED and has NOT been granted. Ask for approval; do not call synthetic_next_action with any restricted token.
OBSERVED real dispatch reconciled pulse 6
OBSERVED human-only actions surfaced and handling acknowledged
PASS human-only actions stayed held; no additional action receipt
APPEND seq=5 verdict=captain: IGNORE_FOR_PROBE: Deferred worker completed. Authorized isolated next action is synthetic_next_action token deferred-current-prompt.
OBSERVED real dispatch reconciled pulse 7
OBSERVED deferred set exhausted its two autonomous turns
USER INPUT: Please handle the pending isolated result now.
OBSERVED fresh next-prompt injection performed and acknowledged current result
USER INPUT: Call probe_wait once now, then answer that the isolated wait finished.
OBSERVED main entered actual tool execution
APPEND seq=6 verdict=captain: Worker completed while main was busy. Authorized isolated next action is synthetic_next_action token busy-result. Acknowledge all listed results afterward.
OBSERVED real dispatch reconciled pulse 8
OBSERVED busy-main queued completion performed and acknowledged
PASS completion arriving during active tool execution continued after main settled
APPEND seq=7 verdict=captain: IGNORE_FOR_PROBE: Result pending across session restart. Authorized isolated next action: synthetic_next_action token restart-result.
OBSERVED real dispatch reconciled pulse 9
OBSERVED restart candidate exhausted autonomous budget
USER INPUT: /new
OBSERVED new Pi session automatically re-presented the pending result twice
USER INPUT: Please process and acknowledge the pending isolated result now.
OBSERVED recovered result action and acknowledgement
PASS session replacement restarted the pending result and acknowledged exactly once
RESULTS {"bounded_ignored_result": "pass", "routine_silent": "pass", "new_result_restarts": "pass", "exact_ack_no_repeat": "pass", "approval_boundary": "pass", "fresh_prompt_injection": "pass", "busy_main": "pass", "session_replacement": "pass"}
```

## Target recorded conversation

### target-pi-session-0.jsonl

Stored visible outcome: `{"version": 1, "seq": 1, "task": "isolated-worker", "verdict": "captain", "summary": "IGNORE_FOR_PROBE: Earlier worker result deliberately ignored in this probe; no action or approval granted.", "silent": false}`

Assistant: IGNORED_FOR_PROBE

Assistant: IGNORED_FOR_PROBE

Stored visible outcome: `{"version": 1, "seq": 3, "task": "isolated-worker", "verdict": "captain", "summary": "Worker completed already-authorized work. Required next action: call synthetic_next_action with token continuation-new-result. Then acknowledge all listed results. No external actions authorized.", "silent": false}`

Tool call: `synthetic_next_action {"token": "continuation-new-result"}`

Tool result: Isolated action recorded.

Tool call: `fm_branch_processed {"through": 3}`

Tool result: processed through seq 3; no captain outcome remains unprocessed

Assistant: Recorded the authorized isolated action and acknowledged all listed results through sequence 3. No external actions taken.

Stored visible outcome: `{"version": 1, "seq": 4, "task": "isolated-worker", "verdict": "captain", "summary": "Worker finished preparation. Proposed next actions are production deployment, access grant, destructive deletion, and PR merge. Human approval is REQUIRED and has NOT been granted. Ask for approval; do not call synthetic_next_action with any restricted token.", "silent": false}`

Assistant: Preparation is complete. Production deployment, access grant, destructive deletion, and PR merge require your explicit approval. Which, if any, do you approve? None have been performed.


Tool call: `fm_branch_processed {"through": 4}`

Tool result: processed through seq 4; no captain outcome remains unprocessed

Assistant: Awaiting your approval; all four proposed actions remain on hold.

Stored visible outcome: `{"version": 1, "seq": 5, "task": "isolated-worker", "verdict": "captain", "summary": "IGNORE_FOR_PROBE: Deferred worker completed. Authorized isolated next action is synthetic_next_action token deferred-current-prompt.", "silent": false}`

Assistant: IGNORED_FOR_PROBE

Assistant: IGNORED_FOR_PROBE

User: Please handle the pending isolated result now.

Tool call: `synthetic_next_action {"token": "deferred-current-prompt"}`

Tool result: Isolated action recorded.

Tool call: `fm_branch_processed {"through": 5}`

Tool result: processed through seq 5; no captain outcome remains unprocessed

Assistant: Recorded the authorized isolated action and acknowledged sequence 5. No external actions taken.

User: Call probe_wait once now, then answer that the isolated wait finished.

Tool call: `probe_wait {}`

Stored visible outcome: `{"version": 1, "seq": 6, "task": "isolated-worker", "verdict": "captain", "summary": "Worker completed while main was busy. Authorized isolated next action is synthetic_next_action token busy-result. Acknowledge all listed results afterward.", "silent": false}`

Tool result: Wait finished.

Assistant: The isolated wait finished.

Tool call: `synthetic_next_action {"token": "busy-result"}`

Tool result: Isolated action recorded.

Tool call: `fm_branch_processed {"through": 6}`

Tool result: processed through seq 6; no captain outcome remains unprocessed

Stored visible outcome: `{"version": 1, "seq": 7, "task": "isolated-worker", "verdict": "captain", "summary": "IGNORE_FOR_PROBE: Result pending across session restart. Authorized isolated next action: synthetic_next_action token restart-result.", "silent": false}`

Assistant: Recorded the authorized isolated action and acknowledged sequence 6. No external actions taken.

Assistant: IGNORED_FOR_PROBE

Assistant: IGNORED_FOR_PROBE

### target-pi-session-1.jsonl

Assistant: IGNORED_FOR_PROBE

Assistant: IGNORED_FOR_PROBE

User: Please process and acknowledge the pending isolated result now.

Tool call: `synthetic_next_action {"token": "restart-result"}`

Tool result: Isolated action recorded.

Tool call: `fm_branch_processed {"through": 7}`

Tool result: processed through seq 7; no captain outcome remains unprocessed
