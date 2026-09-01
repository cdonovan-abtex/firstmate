# No-mistakes worker policy verification

This page records repeatable evidence for Firstmate's optional no-mistakes work-agent allowlist and machine-shared concurrency ceiling.
The operator contract and schema are owned by [`docs/configuration.md`](../configuration.md#no-mistakes-worker-policy-configno-mistakes-policyjson).
The executable mechanism is owned by [`bin/fm-no-mistakes.mjs`](../../bin/fm-no-mistakes.mjs).

## Selector separation

Verified on 2026-08-31 with no-mistakes v1.57.0, an outer Pi worker using the OpenAI Codex provider, and both Claude and Codex installed.
The reproduction used isolated `NM_HOME` directories under an ignored `scratchpad*` path and ran only `no-mistakes doctor`:

```sh
printf 'agent: auto\n' > scratchpad-selector/nm-auto/config.yaml
printf 'agent: codex\n' > scratchpad-selector/nm-codex/config.yaml
NM_HOME="$PWD/scratchpad-selector/nm-auto" NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes doctor
NM_HOME="$PWD/scratchpad-selector/nm-codex" NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes doctor
```

The outer worker reported `openai-codex/gpt-5.6-sol` in both cases.
The `agent: auto` doctor reported `gate validation  claude is runnable`.
The explicit `agent: codex` doctor reported `gate validation  codex is runnable`.
This confirms that initiating worker choice, no-mistakes work-agent selection, and any resulting native process wave are separate causal axes.
An outer Codex worker cannot mask an unsafe global `auto` selector, while an explicit native work-agent identity gives the boundary a stable positive identity to allow.

## Portable boundary regressions

Verified on 2026-09-01 with Node v22.23.1 and the repository behavior-test environment:

```sh
node --check bin/fm-no-mistakes.mjs
tests/fm-no-mistakes-policy.test.sh
```

The test printed twenty-two passing cases and `# all fm-no-mistakes-policy tests passed`.
It exercised behavior through the tracked `bin/no-mistakes` command and a fake native command that starts a real child process for guarded calls, including daemon-like children that survive interrupted and failed CLI clients.
The cases cover an allowed explicit identity, denied `auto`, denied disallowed explicit identity, malformed policy, missing policy, missing effective-agent configuration, trusted registered-default-branch and opted-in current-branch repository selectors, pooled-worktree repository identity with ambiguity refusal, quoted and uniformly indented YAML selector keys with unrelated-key disconfirmation, ordered fallback selectors, live-origin versus registered-default-branch divergence and its registered-branch counterfactual, normalized root-option and `rerun` forms, help-looking flag values, post-launch config drift, run-start selector binding with unchanged-selector disconfirmation, two simultaneous allowed slots, over-limit refusal, independent homes sharing one service across divergent `XDG_STATE_HOME` and ambient slot-root values, distinct-service separation, a policy-free sibling home under a registered service policy, normal gate return, spawn-to-identity handoff death, pre-launch interruption, daemon-active interruption recovery after signals and nonzero exits, stable explicit-run recovery after task-worktree removal, and abnormal wrapper and native-process exit recovery.
Denial cases assert that neither the fake native guarded command nor its child process started.
Read-only `doctor` and genuine help calls remain pass-through under malformed policy.
Assertions consume command output, exit status, process behavior, and child markers only, never implementation-source bytes.

## Harness and runtime applicability

The boundary is structural and does not consume vendor-rendered harness output.
`bin/fm-spawn.sh` adds one environment and PATH prefix after it has composed the harness-specific launch command and before `spawn_send_literal` hands that same command to the selected backend.

| Axis | Reviewed support | Applicability |
| --- | --- | --- |
| Primary harness | Claude, Codex, OpenCode, Pi, pi-signed, Grok, Cursor | The primary selects and supervises workers but does not become no-mistakes' work agent; every ordinary worker it launches receives the same boundary. |
| Worker and scout harness | Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, Muse | Applicable through inherited process PATH, with no harness-specific policy branch; Muse remains worker/scout-only for unrelated supervision reasons. |
| Persistent secondmate harness | Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor | The secondmate agent receives its own home as the policy home, inherits the primary policy bytes, proves its tracked boundary capability before launch, and passes the preserved native command route to its workers; Muse is not a supported secondmate. |
| tmux | Supported reference backend | Applicable because the common launch string is typed into the task shell before the harness starts. |
| Herdr | Supported experimental backend | Applicable through the same common launch string; local and remote secondmate homes run their child workers through their host-local service pool. |
| Zellij | Supported experimental worker backend | Applicable through the same common launch string; Zellij's shared session does not alter the machine service key. |
| Orca | Supported experimental worker backend | Applicable to ordinary workers through the same common launch string; Orca does not support secondmate spawns. |
| cmux | Supported experimental worker backend | Applicable to ordinary workers through the same common launch string; cmux does not support secondmate spawns. |
| Local secondmate | Supported | The inherited policy registers against the same canonical local `NM_HOME`, so its workers share the primary machine's participant set and slots. |
| Remote secondmate | Supported through Herdr placement | The policy is inherited through the authenticated remote material path, launch requires the destination's executable boundary capability, and a public-interface denial proves no disallowed native child starts; the policy registers against that host's distinct no-mistakes service, so no cross-machine ceiling is claimed. |
| Independent primary homes | Supported on one account and service | Registered policy files combine by allowlist intersection and smallest ceiling, and policy-free Firstmate wrappers still honor an already registered service policy. |
| Direct native invocation outside Firstmate | Not owned | An explicit absolute native-binary command or non-Firstmate client bypasses this cooperative boundary because Firstmate does not modify no-mistakes upstream. |

## Repository verification

Verified on 2026-09-01:

```sh
node --check bin/fm-no-mistakes.mjs
tests/fm-no-mistakes-policy.test.sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-secondmate-harness.test.sh
tests/fm-remote-secondmate-trace-context.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh --check-coverage
```

Every focused command passed.
The boundary test ended with `# all fm-no-mistakes-policy tests passed` after twenty-two cases.
The inheritance test ended with `# all fm-secondmate-harness tests passed`.
The remote placement test ended with `ALL TESTS PASSED` after proving an inherited disallow decision started no native validation child.
Lint reported ShellCheck 0.11.0 and actionlint 1.7.12 with all three workflow files valid.
The documentation check reported `fm-doc-audience-check: ok surfaces=90 local_links=304`.
The coverage check reported `FM_TEST_COVERAGE ok total=176 parallel=24 serial=140 serial_shards=4 herdr=12`.

The complete deterministic non-Herdr inventory was also covered with a physically resolved temporary directory because macOS `/var` aliases `/private/var` and process-event ownership intentionally compares physical homes:

```sh
PHYS_TMP=$(cd "${TMPDIR:-/tmp}" && pwd -P)
TMPDIR="$PHYS_TMP" bin/fm-test-run.sh --all --exclude-family real-herdr-gated
```

The inventory contained 164 scripts.
An outer 3600-second execution bound interrupted the serial runner after 125 completed scripts, so the exact 39 uncompleted scripts were selected from the runner markers and completed through the same runner; every policy-relevant family and every remaining script passed.
Two unrelated first-pass environment failures passed on immediate isolated rerun: the Calm follow-up case passed unchanged, and the Cursor primary case passed when `/usr/bin/cc` preceded a local `cc` alias that was actually Claude Code.
The remaining failure was `tests/fm-pi-branch-extension.test.sh`, where the installed Pi stock `ToolExecutionComponent` calm-off rendering differed from the repository expectation.
The same isolated test failed with the identical message from an untouched `git archive 4ad8cba`, so it is a pre-existing installed-Pi compatibility failure rather than a branch regression.
Real-Herdr lifecycle evidence remains separately owned by [`runtime-backends.md`](runtime-backends.md) and is not claimed by this portable policy verification.
