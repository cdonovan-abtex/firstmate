# Cleanup verification

Ran selected existing behavior tests (selected-tests.txt) through a temporary tests/.phase-recovery.test.sh runner. Captured CLI stdout/stderr, exit codes, metadata retention, and persisted backlog output.
Ran tests/.phase-live-pr43.test.sh using a sparse disposable Reports PR 43 record, installed gh-axi, and live GitHub API evidence; teardown reported PROVABLY-LANDED and removed its fixture record.
Both runners used TMPDIR="$PWD/.test-phase-tmp" and PHASE_EVIDENCE=/Users/christiandonovan/.no-mistakes/evidence/01M23G30T6JZCS7857Z0JYRV92.

A direct gh-axi API call using the guard's exact --jq predicate also returned true with exit 0.
The mutation check executed the real guard on lost scout work (exit 1, record retained), then a deliberately faulty guard treating absence as EMPTY (exit 0, record removed). The refusal expectations therefore reject the faulty behavior.

Nested tracked, untracked, ignored and assume-unchanged work was refused. Top-level assume-unchanged and skip-worktree edits were refused without changing index flags. Clean counterparts were accepted. Sparse legacy backlog ownership and EMPTY completion without a nonexistent report link passed.

All selected checks passed. Fixtures were self-cleaned; temporary runners were removed after verification. No graphical surface is involved. Backend disposal was mocked; the CLI classifications, real Git inspection, backlog changes, and recovery-record retirement were exercised.
