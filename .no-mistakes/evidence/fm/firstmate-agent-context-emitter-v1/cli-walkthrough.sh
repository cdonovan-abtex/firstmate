#!/usr/bin/env bash
set -eu
EVIDENCE=/Users/christiandonovan/.no-mistakes/evidence/01M25YVC43QZ8C5JJ5CTSWD950
cli() {
  local repo=$1 expected=$2 rc=0
  shift 2
  printf '\n[%s] $ fm-agent-context.py' "$(basename "$repo")"
  printf ' %s' "$@"
  printf ' --repo .\n'
  (cd "$repo" && "$EMITTER" "$@" --repo .) || rc=$?
  printf 'exit: %s\n' "$rc"
  [ "$rc" = "$expected" ] || fail 'unexpected CLI exit'
}
evidence_walkthrough() {
  local repo="$TMP_ROOT/ordinary-cli" name kind source copy
  make_repo "$repo"
  printf '# Maintainer instructions above\n\n<!-- AGENT-CONTEXT:BEGIN -->\nstale\n<!-- AGENT-CONTEXT:END -->\n\n# Maintainer instructions below\n' > "$repo/AGENTS.md"
  git -C "$repo" remote add origin 'https://user:token@example.test/org/repo.git'
  printf '{"scripts":{"start":"node server.js"}}\n' > "$repo/package.json"
  mkdir "$repo/bin"
  for name in a b c d e f g h; do printf 'reference material\n' > "$repo/bin/$name"; done
  printf '#!/bin/sh\nexit 0\n' > "$repo/bin/run"
  chmod +x "$repo/bin/run"
  cli "$repo" 0 emit
  cat "$repo/AGENTS.md"
  cp "$repo/AGENTS.md" "$EVIDENCE/ordinary-generated-AGENTS.md"
  cp "$repo/AGENTS.md" "$repo/before"
  cli "$repo" 0 emit
  cmp "$repo/before" "$repo/AGENTS.md"
  printf 'Repeat emit preserved every byte. Executable bin/run remains visible after eight non-executable files.\n'
  cli "$repo" 0 check
  printf '{"scripts":{"start":"node changed.js"}}\n' > "$repo/package.json"
  cli "$repo" 1 check
  cmp "$repo/before" "$repo/AGENTS.md"
  printf 'Drift check preserved every byte of AGENTS.md.\n'
  cli "$repo" 0 emit
  cli "$repo" 0 check
  git -C "$repo" remote set-url origin 'https://example.test/org/repo.git'
  cli "$repo" 0 emit
  cat "$repo/AGENTS.md"
  printf '\nThe credential-free origin remains visible (positive control).\n'
  test_validated_satellite_and_guarded_legacy_migrations
  for kind in satellite non-satellite; do
    source="$TMP_ROOT/$kind-source"
    copy="$TMP_ROOT/$kind-cli-copy"
    git clone -q --no-local "$source" "$copy"
    printf '\nLegacy input on disposable %s clone:\n' "$kind"
    cat "$copy/AGENTS.md"
    cp "$copy/AGENTS.md" "$copy/before"
    cli "$copy" 1 emit
    cmp "$copy/before" "$copy/AGENTS.md"
    cli "$copy" 0 emit --migrate-legacy
    cat "$copy/AGENTS.md"
    cp "$copy/AGENTS.md" "$EVIDENCE/$kind-migrated-AGENTS.md"
    cli "$copy" 0 check
    cli "$copy" 1 emit --migrate-legacy
    [ -z "$(git -C "$source" status --porcelain)" ] || fail 'source was changed'
    printf 'Source repository remains unchanged.\n'
  done
  repo="$TMP_ROOT/satellite-cli-copy"
  cp "$repo/AGENTS.md" "$repo/pre-schema"
  python3 - "$repo/context.schema.json" "$repo/context.yaml" <<'PY'
import json,sys
from pathlib import Path
schema, context = map(Path, sys.argv[1:])
s = json.loads(schema.read_text()); c = json.loads(context.read_text())
s['properties']['domain_summary']['minLength'] = 10
c['domain_summary'] = 'x'
schema.write_text(json.dumps(s)); context.write_text(json.dumps(c))
PY
  cli "$repo" 1 emit
  cmp "$repo/pre-schema" "$repo/AGENTS.md"
  printf 'Invalid domain facts refused before modifying the generated file.\n'
  printf '\nPublished tenant-scope contract:\n'
  "$EMITTER" --help | sed -n '/Tenant scope/,$p'
}
source tests/fm-agent-context.test.sh --case evidence_walkthrough
