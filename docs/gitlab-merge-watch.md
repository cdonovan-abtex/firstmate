# GitLab merge request watch and merge verification

Empirical record for the merge watch and the merge path on GitLab, alongside the existing GitHub ones.
The original live-forge commands through "Upgrade path from an existing armed watch" were run on 2026-07-21; "Merging a merge request" was run on 2026-08-22.
Those historical outputs are retained where they establish forge behavior, while the current destination-qualified interface is verified by the dated executable regression section below.

## Versions

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

The merge evidence dated 2026-08-22 was collected on a different host, on:

```
$ glab --version
glab 1.82.0-<local build tag> (<local build commit>)

$ jq --version
jq-1.8.1

$ bash --version | head -1
GNU bash, version 5.2.15(1)-release (x86_64-amazon-linux-gnu)
```

That `glab` is a locally built 1.82.0; only its build tag and commit are elided, because they name a private build rather than a released version.

## The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

## Why the host is data rather than a constant

GitLab runs mostly on self-hosted instances, so a merge request can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
`tests/fm-pr-check-security.test.sh` asserts that neither `bin/fm-pr-lib.sh` nor `bin/fm-pr-poll.sh` contains the string `gitlab.com` at all.

## How plain glab is invoked, and why

Two things about plain `glab` were established by running it, because assuming either one would have failed silently into a permanent "not merged".

First, plain `glab` has no field selector.
`glab mr view -F json` exposes both `state` and `target_branch`, while `glab repo view -F json` exposes `default_branch`; the outcome path parses those fields with `jq`.
Both `glab` and `jq` are checked at registration, so neither can become an unnamed permanently silent dependency.
Only an exact `merged` wakes firstmate, so malformed JSON, a changed field shape, or an unreadable merge request produces no merge outcome.

Second, `glab` cannot take a merge request URL the way `gh pr view` can.
That form shells out to git for the current repository, and the watcher runs in no repository:

```
$ cd /tmp && glab mr view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
fatal: not a git repository (or any parent up to mount point /)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
git: exit status 128
```

Passing the project URL to `-R` with the merge request number works from anywhere, and resolves the instance from that URL rather than from glab's configured default:

```
$ cd /tmp && glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
title:	Add the merged example file
state:	merged
author:	KarotKris
labels:	
assignees:	
reviewers:	
comments:	0
number:	1
url:	https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
--
This merge request is the merged half of the fixture. It is merged on purpose, so that reading its state returns merged.

$ cd /tmp && glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture | sed -n 's/^state:[[:space:]]*//p'
open
```

## End to end: arming and polling a real merge request

Three tasks were armed, two against the fixture and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

The provenance record for the non-default host, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

The original 2026-07-21 published-poll transcript, before destination qualification was added, established exact merged-state detection and silence for open or unreachable merge requests:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

That historical merged fixture produced exactly one `merged` line.
The current formatter replaces that token with the full URL and forge-reported destination, while the open and unreachable cases remain silent.

The historical sidecar-driven transcript exercised the same bytes while the published check located its own record:

```
$ state/e1x.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `glab` or `jq` would otherwise be indistinguishable from a merge request that is never merged.
With either dependency removed from `PATH`, the poll stays silent even for a merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Registration is the visible point where that can be reported, so it refuses there instead of arming a watch that can never fire.
The original missing-`glab` transcript used the earlier diagnostic; current tests assert named refusals for both tools:

```
$ PATH="$noglab" fm-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e6 https://github.com/kunchenguid/firstmate/pull/750
armed: state/e6.check.sh
```

## Upgrade path from an existing armed watch

The stored record gained the provider tag, so its version moved to `fm-pr-poll-registration-v2` and a record written by the previous release no longer parses.
The existing non-executing migration handles that: it never runs the old artifact, and rebuilds the poll from the task's recorded pull request URL.
Starting from a poll armed exactly as the previous release wrote it:

```
$ head -1 state/t1.pr-poll-registration
fm-pr-poll-registration-v1
$ fm-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home
$ head -2 state/t1.pr-poll-registration
fm-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

The historical rebuilt poll worked against a merge request that was genuinely merged; current polls retain that upgrade behavior and add the qualified destination:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

No armed watch is lost by upgrading.

## Current destination-outcome verification

The destination-qualified public interfaces were reverified on 2026-08-23 with GNU Bash 5.3.9, jq 1.7.1-apple, gh 2.96.0, and Git 2.50.1.
The executable matrix covers a genuine default-branch merge, an integration-branch merge with an explicit not-default-delivery result, unavailable or invalid branch evidence that leaves default-branch delivery unverified, and a ready result that records its forge base without looking up the repository default.
The same suite exercises GitHub and GitLab extraction, canonical PR identity binding, static poll provenance, retirement, guarded merge recording, unavailable-forge silence, and named `glab`/`jq` registration refusals.

```sh
$ bin/fm-test-run.sh tests/fm-pr-check-security.test.sh
ok - static poll is silent except for one qualified merged outcome and remains watcher-bounded
ok - ready and merged outcomes distinguish default, integration, and unavailable branch evidence

$ bin/fm-test-run.sh tests/fm-pr-merge.test.sh
ok - fm-pr-merge merges a GitLab merge request through glab instead of refusing it
ok - fm-pr-merge refuses before recording anything when glab or jq is absent

$ bin/fm-test-run.sh tests/fm-teardown.test.sh
ok - fm-pr-check records the remote PR head when the local worktree lags

$ bin/fm-test-run.sh tests/fm-review-diff.test.sh tests/fm-x-mode.test.sh
ok - fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head=
ok - fm-x-link records and refreshes the X-request link without disturbing meta
```

The supported integration axes were inspected with repository-wide reference searches after the behavior change.
The PR outcome extractor and formatter sit above every supported primary harness and runtime backend; none of those adapters parses or rewrites a PR outcome, so Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, tmux, Herdr, Zellij, Orca, and cmux are unaffected.
GitHub and GitLab each have provider-specific extraction in `bin/fm-pr-poll.sh`, while local-only delivery never enters the PR outcome path and remains unchanged.

## Merging a merge request

The live transcript in this section predates destination-qualified registration output; its merge-safety findings remain current, while the registration prefix now names the full URL and forge-reported destination as verified above.
`bin/fm-pr-merge.sh` merges a GitLab merge request through the same recording and the same guards a GitHub pull request gets.
Every run below used a throwaway `FM_HOME`, so no live task record was touched, and a `glab` wrapper that refused any `merge` subcommand outright, so no merge could reach the forge even if a check were wrong.
That wrapper is why the open fixture merge request could be used as evidence at all: it is `mergeable` with discussions resolved, so the pipeline conditions are the only thing between it and a real merge.

Merging needs `glab` for the read and `jq` to parse it, and either one absent refuses before anything is recorded:

```
$ PATH="$noglab" fm-pr-merge.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
error: merging a GitLab merge request requires glab on PATH
$ echo $?
1
$ PATH="$nojq" fm-pr-merge.sh e6 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
error: merging a GitLab merge request requires jq on PATH
$ echo $?
1
```

Neither refusal armed a poll or recorded a `pr=`, so a missing tool leaves no half-prepared merge behind.

Both the watch and merge paths now read glab's JSON with `jq`.
The watch needs `state` and `target_branch`; the merge additionally needs `detailed_merge_status`, `has_conflicts`, `blocking_discussions_resolved`, and the head pipeline.
Both entrypoints report the missing parser before recording anything, while an already-armed poll remains silent rather than producing a false merge if a dependency later disappears.

The merged half of the fixture is refused, and every failing condition is listed rather than just the first:

```
$ fm-pr-merge.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
  - state is "merged", not open
  - detailed_merge_status is "not_open", not mergeable
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 33762fcf6777c8d993220d25fb541e56c48081b9
$ echo $?
1
```

The open half is `mergeable`, conflict-free, and has its discussions resolved, so only the pipeline conditions refuse it.
The fixture runs no CI, so its `head_pipeline` is `null`, which is reported as `none` rather than treated as nothing to check:

```
$ fm-pr-merge.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
$ echo $?
1
```

A project that runs no pipeline at all therefore cannot merge through this path.
That is the intended reading of the requirement rather than an oversight: a successful pipeline at the head is a condition, and "there is no pipeline" does not satisfy it.

Both refusals came after `pr=` was recorded and the merge poll was armed, exactly as a failing `gh-axi pr merge` does on the GitHub side, so a refusal still leaves the audit trail and the watch in place.

A recorded `pr_head=` that no longer matches the live head is reported, and the live head is what gets verified.
The stale value below was written into the task record by hand, because a GitLab task never records one on its own:

```
$ fm-pr-merge.sh e4 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e4.check.sh
notice: recorded head 1111111111111111111111111111111111111111 disagrees with the live head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8; verifying the live head
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

The remaining refusal conditions, and the merge itself, are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The conflict, unresolved-discussion, and running-pipeline conditions were additionally exercised against real merge requests on a private instance; those runs cannot be reproduced here, so their identifiers stay out of this record.
The merge itself is not exercised against any live merge request, in either direction: `glab mr merge` has no dry run, so a live success path would mean merging someone's work to produce evidence.

## Why the head is read live and bound to the merge

The verified head is passed to `glab mr merge --sha`, so GitLab refuses the merge if the source branch moved between the read and the merge.
Without it, a push landing in that window would merge commits nothing verified.

`--yes` is passed for the same reason the watch poll needs no terminal: an unattended run cannot answer a confirmation prompt, and a wedged prompt is worse than a refusal.
It skips only that prompt; the conditions above are what authorize the merge.

## Why a recorded head is not the authority

`bin/fm-pr-check.sh` records `pr_head=` only for GitHub, where `gh` exposes the head commit as a selectable field.
For both forges it also records a valid forge-reported `pr_base=` at registration and records `pr_default=` when registration observes an already-merged result.
Head evidence remains optional by design, and the other consumers already treat it that way: `bin/fm-teardown.sh` reads the head from the forge at teardown and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.

The merge path does not record one either, and deliberately does not depend on one.
A rebase moves the head and leaves any recorded value stale, so a merge decided from metadata can verify a commit that no longer exists.
Reading the head live at merge time, reporting a recorded value that disagrees, and binding the merge to what was actually verified is what closes that gap.
