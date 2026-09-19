Live validation used the installed Pi 0.85.1 CLI with real openai-codex/gpt-5.6-sol responses and an unmodified git archive of the target commit inside the worktree.
All Firstmate homes, the private Pi authentication copy, sessions, browser profiles, and terminal frontend lived in a temporary worktree-local lab that was removed after validation.
No tracked source or test files changed.

Startup was driven through actual Pi extension loading and asynchronous native startup, with absent, previous-session, and missing-watcher configurations.
The descendant check launched an actual second Pi CLI through the primary Pi public RPC bash interface.
The same-process replacement used Pi's public new_session RPC command.
The outcome check appended a captain-facing result through bin/fm-branch-outcome.sh and observed the real extension's generated processing request, final response, and fm_branch_processed call.
The outcome contained a deliberately non-routable example.invalid review URL; no external review or merge was performed.
An initial driver assertion incorrectly expected the generated request as a user message; inspection showed the public custom fm-branch-process message, and the corrected driver passed on rerun.
The watcher check registered a real custom check through bin/fm-check-register.sh, armed through fm_watch_arm_pi, triggered the check, and observed the model drain, perform the authorized file write, acknowledge, and keep a successor watcher alive.

The Calm check ran the real Pi TUI in a PTY sized to 140 columns by 48 rows before startup, with the master continuously drained.
Real model replies provided short narration, a 91-character multiline note, and a 490-character single-paragraph note before real bash calls.
Screenshots show that terminal through xterm.js and headless Chrome, using the actual PTY byte stream from this run.
The Calm-on screenshot hides short narration while preserving both substantive notes and every final response.
The Calm-off top screenshot shows the previously hidden short note and real tool output restored.
The model session content was unchanged by the presentation toggle.

Focused existing executable tests covered marker ownership/acquisition, startup diagnostics, watcher successor/session-transition behavior, turn-end follow-up latching/retry, outcome durability/sequence acknowledgement, and Calm boundary/rendering behavior.
Their exact selected function names appear in the test-phase structured result; these deterministic checks are supplementary and are not claimed as live product runs.
No complete suite, static analysis, lint, formatting, push, PR, CI, or pipeline-control command ran in this phase.
