# GitLab merge request watch verification

Empirical record for the merge watch on GitLab, alongside the existing GitHub watch.
The original merge-state evidence was collected on 2026-07-21, and the destination/default-branch extraction was refreshed against the same public fixture on 2026-08-10.
Bounded outputs below are either exact command output or an explicitly shown Node projection of forge JSON.

## Versions

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)

$ node --version
v22.23.1
```

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

First, `glab mr view -F json` exposes the merge request state and `target_branch`, while `glab repo view <project-url> -F json` exposes the repository `default_branch`.
The static outcome path parses those JSON objects with Node, which is already a common Firstmate prerequisite, and validates every returned branch with `git check-ref-format --branch` before recording or reporting it.
Only an exact `merged` state wakes firstmate, so malformed JSON, a changed field shape, or an unreadable merge request produces no merge outcome.

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
$ glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture -F json > mr1.json
$ glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture -F json > mr2.json
$ glab repo view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture -F json > repo.json
$ node -e 'const fs=require("fs");for(const f of process.argv.slice(1)){let o=JSON.parse(fs.readFileSync(f));console.log(f,JSON.stringify({state:o.state,target_branch:o.target_branch,default_branch:o.default_branch}))}' mr1.json mr2.json repo.json
mr1.json {"state":"merged","target_branch":"main"}
mr2.json {"state":"opened","target_branch":"main"}
repo.json {"default_branch":"main"}
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

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
PR https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1 merged into 'main', the repository default branch.
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged fixture merge request produces exactly one destination-qualified line.
The open one produces nothing, and the unreachable placeholder host produces nothing rather than a false merge.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1x.check.sh
PR https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1 merged into 'main', the repository default branch.
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `glab` would otherwise be indistinguishable from a merge request that is never merged.
With `glab` removed from `PATH`, the poll stays silent even for the merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

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

The rebuilt poll works, verified against a pull request that is genuinely merged:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
PR https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1 merged into 'main', the repository default branch.
```

No armed watch is lost by upgrading.

## Current regression and integration coverage

The public ready-registration and merged-notification interfaces were reverified on 2026-08-10.
The executable matrix covers a genuine default-branch merge, an integration-branch merge with an explicit not-default-delivery result, and unavailable or invalid base/default evidence that leaves default-branch delivery unverified.
The same suite exercises GitHub and GitLab extraction, canonical PR identity binding, static poll provenance, retirement, merge-wrapper recording, and unavailable-forge silence.
A live GitHub default-branch result was also read on 2026-08-10:

```sh
$ bin/fm-pr-poll.sh --validated github https://github.com/kunchenguid/firstmate/pull/750 github.com kunchenguid/firstmate 750
PR https://github.com/kunchenguid/firstmate/pull/750 merged into 'main', the repository default branch.

$ bin/fm-test-run.sh tests/fm-pr-check-security.test.sh tests/fm-pr-merge.test.sh tests/fm-teardown.test.sh
```

The supported integration axes were inspected with repository-wide reference searches after the behavior change.
The PR outcome extractor and formatter sit above every primary harness (Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Kimi) and every runtime backend (tmux, Herdr, Zellij, Orca, and cmux); none of those adapters parses or rewrites PR outcomes, so they are unaffected after inspection.
GitHub and GitLab each have provider-specific extraction in `bin/fm-pr-poll.sh`, while local-only delivery never enters the PR outcome path and remains unchanged.

## What this change does not cover

`bin/fm-pr-merge.sh` still addresses GitHub only, by owner and repository.
It refuses a GitLab merge request URL rather than sending it to the wrong forge, so merging a merge request stays a deliberate manual step until merge parity lands separately.

A GitLab task records no `pr_head=`.
The shared outcome extraction records its forge-reported `pr_base=` and `pr_default=` when available, while both head consumers continue treating `pr_head=` as optional: `bin/fm-teardown.sh` reads the head from the forge at cleanup and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.
