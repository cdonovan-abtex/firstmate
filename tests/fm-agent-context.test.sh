#!/usr/bin/env bash
# Behavior tests for bin/fm-agent-context.py through its public CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-context)
EMITTER="$ROOT/bin/fm-agent-context.py"

make_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Firstmate Test"
  printf '# fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm initial
}

expect_failure() { # <message> <command...>
  local message=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$message: command unexpectedly passed"
  printf '%s\n' "$out"
}

write_satellite_schema() {
  cat > "$1/context.schema.json" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["context_state", "external_system", "operator_persona", "domain_summary", "entities", "events", "mcp_tools", "tier", "standalone_face", "write_posture", "operator_owned_fields", "canonical_fields", "tenants", "access_model", "operator_decision"],
  "properties": {
    "context_state": {"type": "string", "enum": ["validated", "signed", "injected"]},
    "external_system": {"type": "object"}, "operator_persona": {"type": "object"},
    "domain_summary": {"type": "string"}, "entities": {"type": "array"},
    "events": {"type": "array"}, "mcp_tools": {"type": "array"},
    "tier": {"type": "object"}, "standalone_face": {"type": "object"},
    "write_posture": {"type": "object"}, "operator_owned_fields": {"type": "array"},
    "canonical_fields": {"type": "array"}, "tenants": {"type": "object"},
    "access_model": {"type": "object"}, "operator_decision": {"type": "object"}
  }
}
EOF
}

write_valid_satellite_context() {
  cat > "$1/context.yaml" <<'EOF'
{
  "context_state": "validated",
  "external_system": {"name": "Fixture ERP", "category": "ERP", "integration_surface": "REST"},
  "operator_persona": {"role": "operator", "responsibilities": ["reconcile"]},
  "domain_summary": "fixture domain",
  "entities": [{"name": "Order", "attributes": ["id"], "source_of_truth": "ERP", "sensitivity": "HIGH"}],
  "events": [{"name": "order.changed", "description": "order changed", "payload_fields": ["id"]}],
  "mcp_tools": [{"name": "search_orders", "description": "search", "access": "read"}],
  "tier": {"level": 1, "rationale": "fixture"},
  "standalone_face": {"execution_face": "worker", "decision_face": "operator"},
  "write_posture": {"phase": "phase_1_pull_only", "approved_entities": []},
  "operator_owned_fields": [], "canonical_fields": ["id"],
  "tenants": {"primary": "primary", "secondary_sandbox": "sandbox"},
  "access_model": {"users": ["operator"], "roles": ["reader"], "entitlements": ["orders.read"]},
  "operator_decision": {"decision": "proceed", "signer_role": "operator", "signed_at": "2026-09-10", "notes": "fixture"}
}
EOF
}

assert_one_current_envelope() {
  local agents=$1
  [ "$(grep -Fc '<!-- AGENT-CONTEXT:BEGIN -->' "$agents")" -eq 1 ] \
    || fail "expected exactly one AGENT-CONTEXT begin marker"
  [ "$(grep -Fc '<!-- AGENT-CONTEXT:END -->' "$agents")" -eq 1 ] \
    || fail "expected exactly one AGENT-CONTEXT end marker"
}

test_non_satellite_repeat_identity_and_drift() {
  local repo out
  repo="$TMP_ROOT/non-satellite"
  make_repo "$repo"
  printf '{"scripts":{"start":"node server.js"}}\n' > "$repo/package.json"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "emit failed for a non-satellite repository"
  assert_one_current_envelope "$repo/AGENTS.md"
  assert_grep 'No validated context.yaml is configured' "$repo/AGENTS.md" \
    "non-satellite output did not state the optional context absence"
  assert_grep 'npm run start' "$repo/AGENTS.md" "entrypoint positive control was not measured"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "fresh non-satellite context did not compare cleanly"

  # Deliberately change a measured manifest. check must fail before emit repairs it.
  printf '{"scripts":{"start":"node changed.js"}}\n' > "$repo/package.json"
  out=$(expect_failure "compare-only drift mutation" "$EMITTER" check --repo "$repo")
  assert_contains "$out" 'drift:' "compare-only drift failure did not identify drift"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "emit did not correct deliberate measured drift"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "corrected measured drift did not compare cleanly"
  cp "$repo/AGENTS.md" "$repo/after-correction"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "second emit failed"
  cmp -s "$repo/after-correction" "$repo/AGENTS.md" \
    || fail "repeat emit was not byte-identical"
  pass "fm-agent-context.py: non-satellite emit is byte-identical and compare-only detects measured drift"
}

test_targeted_replacement_preserves_surrounding_prose() {
  local repo out
  repo="$TMP_ROOT/prose"
  make_repo "$repo"
  printf '%s\n' '# Prose above' '' '<!-- AGENT-CONTEXT:BEGIN -->' 'deliberately stale generated payload' '<!-- AGENT-CONTEXT:END -->' '' '# Prose below' > "$repo/AGENTS.md"
  out=$(expect_failure "stale envelope positive control" "$EMITTER" check --repo "$repo")
  assert_contains "$out" 'drift:' "stale envelope was not compared"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "targeted replacement failed"
  assert_grep '# Prose above' "$repo/AGENTS.md" "replacement lost prose above the envelope"
  assert_grep '# Prose below' "$repo/AGENTS.md" "replacement lost prose below the envelope"
  assert_one_current_envelope "$repo/AGENTS.md"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "corrected targeted replacement did not compare cleanly"
  pass "fm-agent-context.py: targeted replacement preserves prose above and below"
}

test_malformed_and_duplicate_markers_are_refused() {
  local malformed duplicate legacy_malformed out
  malformed="$TMP_ROOT/malformed"
  duplicate="$TMP_ROOT/duplicate"
  legacy_malformed="$TMP_ROOT/legacy-malformed"
  make_repo "$malformed"
  printf '%s\n' '# prose' '<!-- AGENT-CONTEXT:BEGIN -->' 'unterminated' > "$malformed/AGENTS.md"
  out=$(expect_failure "malformed marker mutation" "$EMITTER" emit --repo "$malformed")
  assert_contains "$out" 'malformed' "malformed marker refusal did not name malformed markers"
  assert_grep 'unterminated' "$malformed/AGENTS.md" "malformed-marker refusal rewrote AGENTS.md"

  make_repo "$duplicate"
  printf '%s\n' '<!-- AGENT-CONTEXT:BEGIN -->' 'one' '<!-- AGENT-CONTEXT:END -->' '<!-- AGENT-CONTEXT:BEGIN -->' 'two' '<!-- AGENT-CONTEXT:END -->' > "$duplicate/AGENTS.md"
  out=$(expect_failure "duplicate marker mutation" "$EMITTER" check --repo "$duplicate")
  assert_contains "$out" 'duplicate' "duplicate marker refusal did not name duplicate markers"
  expect_failure "duplicate marker emit mutation" "$EMITTER" emit --repo "$duplicate" >/dev/null

  make_repo "$legacy_malformed"
  printf '%s\n' '<!-- GROUND-TRUTH:BEGIN generated by legacy -->' 'unterminated legacy payload' > "$legacy_malformed/AGENTS.md"
  out=$(expect_failure "malformed legacy marker mutation" "$EMITTER" emit --migrate-legacy --repo "$legacy_malformed")
  assert_contains "$out" 'malformed' "malformed legacy marker was not refused"

  "$EMITTER" emit --repo "$TMP_ROOT/non-satellite" >/dev/null || fail "positive-control normal marker emit failed"
  pass "fm-agent-context.py: malformed and duplicate marker pairs are refused without a write"
}

test_remote_userinfo_is_redacted_with_positive_control() {
  local secret bare_secret visible
  secret="$TMP_ROOT/redacted-origin"
  bare_secret="$TMP_ROOT/bare-redacted-origin"
  visible="$TMP_ROOT/visible-origin"
  make_repo "$secret"
  git -C "$secret" remote add origin 'https://user:token@example.test/org/repo.git'
  "$EMITTER" emit --repo "$secret" >/dev/null || fail "emit failed for userinfo origin fixture"
  assert_not_contains "$(<"$secret/AGENTS.md")" 'user:token' "userinfo reached AGENTS.md"
  assert_grep '<redacted>@example.test' "$secret/AGENTS.md" "userinfo redaction did not retain a redacted origin"
  "$EMITTER" check --repo "$secret" >/dev/null || fail "redacted origin did not compare cleanly"

  make_repo "$bare_secret"
  git -C "$bare_secret" remote add origin 'user:token@example.test:org/repo.git'
  "$EMITTER" emit --repo "$bare_secret" >/dev/null || fail "emit failed for bare userinfo origin fixture"
  assert_not_contains "$(<"$bare_secret/AGENTS.md")" 'user:token' "bare remote userinfo reached AGENTS.md"
  assert_grep '<redacted>@example.test:org/repo.git' "$bare_secret/AGENTS.md" \
    "bare remote userinfo was not redacted"

  make_repo "$visible"
  git -C "$visible" remote add origin 'https://example.test/org/repo.git'
  "$EMITTER" emit --repo "$visible" >/dev/null || fail "emit failed for normal origin fixture"
  assert_grep 'https://example.test/org/repo.git' "$visible/AGENTS.md" \
    "ordinary origin positive control was incorrectly removed"
  pass "fm-agent-context.py: remote userinfo is redacted at measurement while ordinary origins remain visible"
}

test_validated_satellite_and_guarded_legacy_migrations() {
  local satellite non_satellite out
  satellite="$TMP_ROOT/satellite-legacy"
  non_satellite="$TMP_ROOT/non-satellite-legacy"
  make_repo "$satellite"
  write_satellite_schema "$satellite"
  write_valid_satellite_context "$satellite"
  printf '%s\n' '# Satellite prose above' '' '## DOMAIN SPECIALIZATION (generated from context.yaml — do not hand-edit)' '' '<!-- DOMAIN SPECIALIZATION:BEGIN -->' 'old domain payload' '<!-- DOMAIN SPECIALIZATION:END -->' '' '# Satellite prose below' > "$satellite/AGENTS.md"
  out=$(expect_failure "unguarded domain migration" "$EMITTER" emit --repo "$satellite")
  assert_contains "$out" 'migrate-legacy' "legacy domain pair was not guarded"
  "$EMITTER" emit --migrate-legacy --repo "$satellite" >/dev/null || fail "guarded satellite migration failed"
  assert_one_current_envelope "$satellite/AGENTS.md"
  assert_grep 'Fixture ERP' "$satellite/AGENTS.md" "validated satellite domain facts were not rendered"
  assert_grep '# Satellite prose above' "$satellite/AGENTS.md" "satellite migration lost prose above"
  assert_grep '# Satellite prose below' "$satellite/AGENTS.md" "satellite migration lost prose below"
  assert_not_contains "$(<"$satellite/AGENTS.md")" 'DOMAIN SPECIALIZATION:BEGIN' "satellite legacy marker survived migration"
  "$EMITTER" check --repo "$satellite" >/dev/null || fail "migrated satellite did not compare cleanly"
  out=$(expect_failure "one-time satellite migration" "$EMITTER" emit --migrate-legacy --repo "$satellite")
  assert_contains "$out" 'no legacy marker pair remains' "second satellite migration was not refused"

  make_repo "$non_satellite"
  printf '%s\n' '# Non-satellite prose above' '' '<!-- GROUND-TRUTH:BEGIN generated by `ground-truth emit` -- measured, not authored. -->' 'old measured payload' '<!-- GROUND-TRUTH:END -->' '' '# Non-satellite prose below' > "$non_satellite/AGENTS.md"
  out=$(expect_failure "unguarded ground-truth migration" "$EMITTER" emit --repo "$non_satellite")
  assert_contains "$out" 'migrate-legacy' "legacy ground-truth pair was not guarded"
  "$EMITTER" emit --migrate-legacy --repo "$non_satellite" >/dev/null || fail "guarded non-satellite migration failed"
  assert_one_current_envelope "$non_satellite/AGENTS.md"
  assert_grep '# Non-satellite prose above' "$non_satellite/AGENTS.md" "non-satellite migration lost prose above"
  assert_grep '# Non-satellite prose below' "$non_satellite/AGENTS.md" "non-satellite migration lost prose below"
  assert_not_contains "$(<"$non_satellite/AGENTS.md")" 'GROUND-TRUTH:BEGIN' "ground-truth marker survived migration"
  "$EMITTER" check --repo "$non_satellite" >/dev/null || fail "migrated non-satellite did not compare cleanly"
  out=$(expect_failure "one-time non-satellite migration" "$EMITTER" emit --migrate-legacy --repo "$non_satellite")
  assert_contains "$out" 'no legacy marker pair remains' "second non-satellite migration was not refused"
  pass "fm-agent-context.py: guarded migration converts legacy satellite and non-satellite scratch fixtures"
}

test_schema_validation_refuses_mutated_domain_contract() {
  local repo out
  repo="$TMP_ROOT/schema-refusal"
  make_repo "$repo"
  write_satellite_schema "$repo"
  write_valid_satellite_context "$repo"
  python3 - "$repo/context.yaml" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["unexpected"] = "deliberate mutation"
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
  out=$(expect_failure "unknown domain field mutation" "$EMITTER" emit --repo "$repo")
  assert_contains "$out" 'unknown field' "schema mutation was not rejected"
  write_valid_satellite_context "$repo"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "corrected validated domain contract did not emit"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "corrected validated domain contract did not compare cleanly"
  pass "fm-agent-context.py: optional context.yaml is strictly schema-validated before writing"
}

test_non_satellite_repeat_identity_and_drift
test_targeted_replacement_preserves_surrounding_prose
test_malformed_and_duplicate_markers_are_refused
test_remote_userinfo_is_redacted_with_positive_control
test_validated_satellite_and_guarded_legacy_migrations
test_schema_validation_refuses_mutated_domain_contract
