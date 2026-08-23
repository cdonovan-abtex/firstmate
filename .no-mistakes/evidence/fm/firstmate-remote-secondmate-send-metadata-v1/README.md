# Evidence — parent → remote-secondmate message delivery

Deterministic remote fixture (`tests/remote-herdr-fixture.sh` + generic SSH boundary),
driven end to end through the supported public command:

    FM_HOME=<primary> bin/fm-send.sh ios '$5 is the remote build budget; acknowledge receipt'

| file | what it shows |
| --- | --- |
| `00-prefix-failure-transcript.txt` | Same public command, `bin/` reverted to the base commit `8714c9a`: the leading-`$` completion popup swallows Enter, fm-send retries Enter, the fixture records no agent submission, suite exits 1. |
| `01-parent-send-transcript.txt` | Post-fix: the public parent command returns exit 0 with no error output. |
| `02-remote-host-composer-log.txt` | Verbatim command log the *remote* host's agent CLI received: exactly one `pane send-text` carrying exactly one `[fm-from-firstmate]` marker and one `corr=` token, then exactly one `pane send-keys ... enter`. |
| `03-parent-pending-reply-record.txt` | The single durable parent correlation created by that send: `phase=awaiting_report`, `delivered_epoch` set, `request_summary` with the sender's bytes intact. |
| `04-remote-agent-submission-state.json` | Remote agent state after the send: the fixture's `submissions` counter for the pane went 1 → 2 (exactly one new submission), draft cleared — i.e. the remote agent actually started the turn. |
| `05-remote-supervision-banner.txt` | With genuine in-flight work in the remote home's *ordinary* state and no watcher beacon, one parent `--key` send raises that home's WATCHER DOWN alarm, counting the remote home's own task and carrying the send-specific continue line ("the requested message WILL still be sent"). |
| `06-parent-correlation-resolved.txt` | The remote agent's reply routed back to the parent status channel and resolved that one correlation (`phase=resolved`, `resolved_via=status`). |

No duplicate-marker, duplicate-correlation, or remote-local pending-reply record was created:
the e2e asserts both `$REMOTE_HOME/state/pending-replies` and the route-scoped
`$REMOTE_HOME/state/parent-route/pending-replies` counts are unchanged.

Runs: pre-fix `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` exits 1 at the new block;
post-fix the same suite passes all 28 assertions (6m10s).
