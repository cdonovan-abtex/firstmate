#!/usr/bin/env bash
# Behavior tests for bin/fm-agent-context.py through its public CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-context)
EMITTER=${FM_CONTEXT_TEST_EMITTER:-"$ROOT/bin/fm-agent-context.py"}
export FM_CONTEXT_ORIGINAL="$ROOT/bin/fm-agent-context.py"

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
  python3 - "$agents" <<'PY' || fail "expected exactly one AGENT-CONTEXT marker envelope"
from pathlib import Path
import sys
content = Path(sys.argv[1]).read_bytes()
begin, end = b"<!-- AGENT-CONTEXT:BEGIN -->", b"<!-- AGENT-CONTEXT:END -->"
assert content.count(begin) == content.count(end) == 1
assert content.index(begin) < content.index(end)
PY
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
  cp "$repo/AGENTS.md" "$repo/before-check"
  out=$(expect_failure "compare-only drift mutation" "$EMITTER" check --repo "$repo") || fail "$out"
  assert_contains "$out" 'drift:' "compare-only drift failure did not identify drift"
  cmp -s "$repo/before-check" "$repo/AGENTS.md" || fail "drift check wrote AGENTS.md"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "emit did not correct deliberate measured drift"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "corrected measured drift did not compare cleanly"
  cp "$repo/AGENTS.md" "$repo/after-correction"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "second emit failed"
  cmp -s "$repo/after-correction" "$repo/AGENTS.md" \
    || fail "repeat emit was not byte-identical"
  pass "fm-agent-context.py: non-satellite emit is byte-identical and compare-only detects measured drift"
}

test_bin_entrypoints_filter_before_limit() {
  local variant repo name
  for variant in clean cluttered; do
    repo="$TMP_ROOT/bin-$variant"
    make_repo "$repo"
    mkdir "$repo/bin"
    for name in run-9 run-8 run-7 run-6 run-5 run-4 run-3 run-2 run; do
      printf '#!/bin/sh\nexit 0\n' > "$repo/bin/$name"
      chmod +x "$repo/bin/$name"
    done
    if [ "$variant" = cluttered ]; then
      mkdir "$repo/bin/00-directory"
      for name in a b c d e f g h; do
        printf 'not executable\n' > "$repo/bin/$name"
      done
    fi
    "$EMITTER" emit --repo "$repo" >/dev/null || fail "bin entrypoint emit failed"
    assert_grep '`bin/run`' "$repo/AGENTS.md" "executable hidden by unrelated bin entries"
    python3 - "$repo/AGENTS.md" <<'PY' || fail "bin entrypoint ordering or limit is incorrect"
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
entrypoints = [line for line in lines if line.startswith("- Entrypoints: ")]
commands = ["bin/run"] + [f"bin/run-{i}" for i in range(2, 9)]
assert entrypoints == ["- Entrypoints: " + "; ".join(f"`{command}`" for command in commands)]
PY
    "$EMITTER" check --repo "$repo" >/dev/null || fail "bin entrypoints did not compare cleanly"
  done
  pass "fm-agent-context.py: bin discovery filters executable files before its sorted eight-entry limit"
}

test_repeat_identity() {
  local repo="$TMP_ROOT/repeat"
  make_repo "$repo"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "initial identity emit failed"
  cp "$repo/AGENTS.md" "$repo/first-output"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "repeat identity emit failed"
  cmp -s "$repo/first-output" "$repo/AGENTS.md" || fail "repeat emit was not byte-identical"
  pass "fm-agent-context.py: repeat emission preserves exact bytes"
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
  python3 - "$repo/AGENTS.md" <<'PY' || fail "replacement changed surrounding prose bytes"
from pathlib import Path
import sys
content = Path(sys.argv[1]).read_bytes()
assert content.split(b"<!-- AGENT-CONTEXT:BEGIN -->")[0] == b"# Prose above\n\n"
assert content.split(b"<!-- AGENT-CONTEXT:END -->\n")[1] == b"\n# Prose below\n"
PY
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
  out=$(expect_failure "malformed marker mutation" "$EMITTER" emit --repo "$malformed") || fail "$out"
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
  local satellite non_satellite out source copy
  satellite="$TMP_ROOT/satellite-legacy"
  non_satellite="$TMP_ROOT/non-satellite-legacy"
  source="$TMP_ROOT/satellite-source"
  make_repo "$source"
  write_satellite_schema "$source"
  write_valid_satellite_context "$source"
  printf '%s\n' '# Satellite prose above' '' '## DOMAIN SPECIALIZATION (generated from context.yaml — do not hand-edit)' '' '<!-- DOMAIN SPECIALIZATION:BEGIN -->' 'old domain payload' '<!-- DOMAIN SPECIALIZATION:END -->' '' '# Satellite prose below' '<!-- GROUND-TRUTH:BEGIN generated by legacy -->' 'old shape' '<!-- GROUND-TRUTH:END -->' > "$source/AGENTS.md"
  git -C "$source" add .
  git -C "$source" commit -qm 'satellite source snapshot'
  git clone -q --no-local "$source" "$satellite" || fail "satellite scratch copy failed"
  cp "$source/AGENTS.md" "$TMP_ROOT/satellite-source-before"
  cp "$satellite/AGENTS.md" "$TMP_ROOT/satellite-copy-before"
  out=$(expect_failure "unguarded domain migration" "$EMITTER" emit --repo "$satellite")
  assert_contains "$out" 'migrate-legacy' "legacy domain pair was not guarded"
  cmp -s "$TMP_ROOT/satellite-copy-before" "$satellite/AGENTS.md" || fail "unguarded migration wrote satellite copy"
  "$EMITTER" emit --migrate-legacy --repo "$satellite" >/dev/null || fail "guarded satellite migration failed"
  assert_one_current_envelope "$satellite/AGENTS.md"
  assert_grep 'Fixture ERP' "$satellite/AGENTS.md" "validated satellite domain facts were not rendered"
  assert_grep '# Satellite prose above' "$satellite/AGENTS.md" "satellite migration lost prose above"
  assert_grep '# Satellite prose below' "$satellite/AGENTS.md" "satellite migration lost prose below"
  assert_not_contains "$(<"$satellite/AGENTS.md")" 'DOMAIN SPECIALIZATION:BEGIN' "satellite legacy marker survived migration"
  assert_not_contains "$(<"$satellite/AGENTS.md")" 'GROUND-TRUTH:BEGIN' "satellite ground-truth marker survived migration"
  "$EMITTER" check --repo "$satellite" >/dev/null || fail "migrated satellite did not compare cleanly"
  out=$(expect_failure "one-time satellite migration" "$EMITTER" emit --migrate-legacy --repo "$satellite")
  assert_contains "$out" 'no legacy marker pair remains' "second satellite migration was not refused"
  cmp -s "$TMP_ROOT/satellite-source-before" "$source/AGENTS.md" || fail "migration changed satellite source"
  [ -z "$(git -C "$source" status --porcelain)" ] || fail "satellite source became dirty"

  source="$TMP_ROOT/non-satellite-source"
  make_repo "$source"
  # shellcheck disable=SC2016 # Backticks are literal legacy marker text.
  printf '%s\n' '# Non-satellite prose above' '' '<!-- GROUND-TRUTH:BEGIN generated by `ground-truth emit` -- measured, not authored. -->' 'old measured payload' '<!-- GROUND-TRUTH:END -->' '' '# Non-satellite prose below' > "$source/AGENTS.md"
  git -C "$source" add .
  git -C "$source" commit -qm 'non-satellite source snapshot'
  git clone -q --no-local "$source" "$non_satellite" || fail "non-satellite scratch copy failed"
  cp "$source/AGENTS.md" "$TMP_ROOT/non-satellite-source-before"
  cp "$non_satellite/AGENTS.md" "$TMP_ROOT/non-satellite-copy-before"
  out=$(expect_failure "unguarded ground-truth migration" "$EMITTER" emit --repo "$non_satellite")
  assert_contains "$out" 'migrate-legacy' "legacy ground-truth pair was not guarded"
  cmp -s "$TMP_ROOT/non-satellite-copy-before" "$non_satellite/AGENTS.md" || fail "unguarded migration wrote non-satellite copy"
  "$EMITTER" emit --migrate-legacy --repo "$non_satellite" >/dev/null || fail "guarded non-satellite migration failed"
  assert_one_current_envelope "$non_satellite/AGENTS.md"
  assert_grep '# Non-satellite prose above' "$non_satellite/AGENTS.md" "non-satellite migration lost prose above"
  assert_grep '# Non-satellite prose below' "$non_satellite/AGENTS.md" "non-satellite migration lost prose below"
  assert_not_contains "$(<"$non_satellite/AGENTS.md")" 'GROUND-TRUTH:BEGIN' "ground-truth marker survived migration"
  "$EMITTER" check --repo "$non_satellite" >/dev/null || fail "migrated non-satellite did not compare cleanly"
  out=$(expect_failure "one-time non-satellite migration" "$EMITTER" emit --migrate-legacy --repo "$non_satellite")
  assert_contains "$out" 'no legacy marker pair remains' "second non-satellite migration was not refused"
  cmp -s "$TMP_ROOT/non-satellite-source-before" "$source/AGENTS.md" || fail "migration changed non-satellite source"
  [ -z "$(git -C "$source" status --porcelain)" ] || fail "non-satellite source became dirty"
  for copy in "$satellite" "$non_satellite"; do
    python3 - "$copy/AGENTS.md" "$copy/../$(basename "$copy" -legacy)-source/AGENTS.md" <<'PY' || fail "migration changed surrounding prose bytes"
from pathlib import Path
import re
import sys
actual, original = (Path(path).read_bytes() for path in sys.argv[1:])
actual = re.sub(rb"<!-- AGENT-CONTEXT:BEGIN -->.*?<!-- AGENT-CONTEXT:END -->\n", b"", actual, flags=re.S)
original = re.sub(rb"## DOMAIN SPECIALIZATION[^\n]*\n\n<!-- DOMAIN SPECIALIZATION:BEGIN -->.*?<!-- DOMAIN SPECIALIZATION:END -->", b"", original, flags=re.S)
original = re.sub(rb"<!-- GROUND-TRUTH:BEGIN.*?<!-- GROUND-TRUTH:END -->", b"", original, flags=re.S)
assert actual == original
PY
    cp "$copy/AGENTS.md" "$TMP_ROOT/migrated-before"
    "$EMITTER" emit --repo "$copy" >/dev/null || fail "post-migration emit failed"
    cmp -s "$TMP_ROOT/migrated-before" "$copy/AGENTS.md" || fail "post-migration emission changed bytes"
  done
  pass "fm-agent-context.py: guarded migration converts disposable copies and leaves source repositories unchanged"
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

test_schema_constraints_are_enforced_or_refused() {
  local repo="$TMP_ROOT/schema-constraints"
  make_repo "$repo"
  write_satellite_schema "$repo"
  write_valid_satellite_context "$repo"
  python3 - "$EMITTER" "$repo" <<'PY' || fail "schema constraint CLI regressions failed"
import copy
import json
from pathlib import Path
import subprocess
import sys

emitter, repo = sys.argv[1], Path(sys.argv[2])
schema_path = repo / "context.schema.json"
context_path = repo / "context.yaml"
schema = json.loads(schema_path.read_text())
context = json.loads(context_path.read_text())
agents = repo / "AGENTS.md"
agents.write_bytes(b"Untouched caller prose\n")
original = agents.read_bytes()
cases = [
    ("length", "domain_summary", {"type": "string", "minLength": 10}, "x", "character(s)"),
    ("pattern", "domain_summary", {"pattern": "^required$"}, "x", "unsupported schema keyword"),
    ("reference", "domain_summary", {"$ref": "#/definitions/summary"}, "x", "unsupported schema keyword"),
    ("absent property", "absent", {"pattern": "x"}, None, "unsupported schema keyword"),
    ("unused items", "operator_owned_fields", {"items": {"$ref": "#/x"}}, [], "unsupported schema keyword"),
    ("invalid length", "domain_summary", {"minLength": "10"}, "x", "malformed schema"),
    ("invalid type", "domain_summary", {"type": "invented"}, "x", "malformed schema"),
    ("union type", "domain_summary", {"type": ["string", "null"]}, "x", "malformed schema"),
    ("additional schema", "external_system", {"additionalProperties": {"type": "string"}}, {}, "malformed schema"),
    ("fractional minimum", "probe", {"type": "number", "minimum": 2}, 1.5, "must be >="),
    ("fractional maximum", "probe", {"maximum": 1}, 1.5, "must be <="),
    ("enum boolean", "probe", {"enum": [1]}, True, "expected one of"),
    ("enum nested boolean", "probe", {"enum": [{"a": [1]}]}, {"a": [True]}, "expected one of"),
]
for label, key, constraint, value, diagnostic in cases:
    candidate_schema, candidate_context = copy.deepcopy(schema), copy.deepcopy(context)
    candidate_schema["properties"][key] = constraint
    if key != "absent":
        candidate_context[key] = value
    schema_path.write_text(json.dumps(candidate_schema))
    context_path.write_text(json.dumps(candidate_context))
    for mode in ("emit", "check"):
        result = subprocess.run([emitter, mode, "--repo", str(repo)], capture_output=True, text=True)
        assert result.returncode == 1 and diagnostic in result.stderr, (label, mode, result)
        assert agents.read_bytes() == original, label
schema["properties"]["domain_summary"]["minLength"] = 10
schema["properties"]["probe"] = {"type": "integer", "enum": [1], "minimum": 1, "maximum": 1}
context["probe"] = 1.0
schema_path.write_text(json.dumps(schema))
context_path.write_text(json.dumps(context))
for mode in ("emit", "check"):
    subprocess.run([emitter, mode, "--repo", str(repo)], check=True, capture_output=True)
assert b"fixture domain" in agents.read_bytes()
PY
  pass "fm-agent-context.py: schema constraints are enforced or refused before any write"
}

test_rendered_markers_are_escaped() {
  local repo="$TMP_ROOT/rendered-markers"
  make_repo "$repo"
  write_satellite_schema "$repo"
  write_valid_satellite_context "$repo"
  python3 - "$repo" <<'PY'
import json
from pathlib import Path
import sys
repo = Path(sys.argv[1])
markers = ["<!-- AGENT-CONTEXT:BEGIN -->", "<!-- AGENT-CONTEXT:END -->",
           "<!-- DOMAIN SPECIALIZATION:BEGIN -->", "<!-- DOMAIN SPECIALIZATION:END -->",
           "<!-- GROUND-TRUTH:BEGIN generated by fixture -->", "<!-- GROUND-TRUTH:END -->"]
(repo / "package.json").write_text(json.dumps({"scripts": {f"script-{i}-{marker}": f"echo '{marker}'" for i, marker in enumerate(markers)}}))
path = repo / "context.yaml"
context = json.loads(path.read_text())
context["domain_summary"] = "\n".join(markers)
path.write_text(json.dumps(context))
PY
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "marker-valued input failed to emit"
  assert_one_current_envelope "$repo/AGENTS.md"
  assert_grep '&lt;!-- AGENT-CONTEXT:END -->' "$repo/AGENTS.md" "reserved marker text was lost instead of escaped"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "marker-valued output did not compare cleanly"
  cp "$repo/AGENTS.md" "$repo/before-repeat"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "marker-valued repeat failed"
  cmp -s "$repo/before-repeat" "$repo/AGENTS.md" || fail "marker-valued repeat changed bytes"
  pass "fm-agent-context.py: rendered values cannot introduce current or legacy markers"
}

test_candidate_validation_refuses_broken_renderer() {
  local repo="$TMP_ROOT/invalid-candidate" out
  make_repo "$repo"
  printf 'Preserved prose\n' > "$repo/AGENTS.md"
  cp "$repo/AGENTS.md" "$repo/before"
  out=$(expect_failure "broken renderer" env FM_CONTEXT_MUTATION=candidate "$TMP_ROOT/mutant.py" emit --repo "$repo") || fail "$out"
  assert_contains "$out" 'malformed or duplicate' "candidate refusal did not inspect rendered markers"
  cmp -s "$repo/before" "$repo/AGENTS.md" || fail "invalid candidate reached AGENTS.md"
  "$EMITTER" emit --repo "$repo" >/dev/null || fail "correct renderer did not emit"
  "$EMITTER" check --repo "$repo" >/dev/null || fail "correct renderer did not compare cleanly"
  pass "fm-agent-context.py: candidate validation refuses a broken renderer without writing"
}

test_guarantee_mutations_are_detected() {
  local mutation case_name diagnostic out
  cat > "$TMP_ROOT/mutant.py" <<'PY'
#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import sys
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("emitter", os.environ["FM_CONTEXT_ORIGINAL"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
mutation = os.environ["FM_CONTEXT_MUTATION"]
render = module.render
inspect = module.inspect_markers
pair = module._single_pair

if mutation == "identity":
    def unstable(context, measured):
        return render(context, measured).replace(module.END, uuid.uuid4().hex.encode() + b"\n" + module.END)
    module.render = unstable
elif mutation in {"above", "below"}:
    def widened(content):
        current, legacy = inspect(content)
        if current:
            current = (0, current[1]) if mutation == "above" else (current[0], len(content))
        return current, legacy
    module.inspect_markers = widened
elif mutation in {"malformed", "duplicate"}:
    def permissive(content, begin, end, label):
        count = content.count(begin)
        if label == "AGENT-CONTEXT" and ((mutation == "malformed" and count == 1 and not content.count(end)) or (mutation == "duplicate" and count > 1)):
            return (0, len(content))
        return pair(content, begin, end, label)
    module._single_pair = permissive
elif mutation == "redaction":
    module._redact_userinfo = lambda url: url or ""
elif mutation == "no-context":
    def require_context(context, measured):
        if context is None:
            raise module.ContractError("mutant requires context.yaml")
        return render(context, measured)
    module.render = require_context
elif mutation == "candidate":
    module.render = lambda context, measured: render(context, measured) + module.END
elif mutation == "drift":
    if sys.argv[1] == "check":
        sys.argv[1] = "emit"
elif mutation == "check-write":
    status = module.main()
    if sys.argv[1] == "check" and status:
        repo = Path(sys.argv[sys.argv.index("--repo") + 1])
        agents = repo / "AGENTS.md"
        agents.write_bytes(agents.read_bytes() + b"mutant check wrote\n")
    raise SystemExit(status)
else:
    raise RuntimeError(mutation)
raise SystemExit(module.main())
PY
  chmod +x "$TMP_ROOT/mutant.py"
  while IFS='|' read -r mutation case_name diagnostic; do
    if out=$(FM_CONTEXT_TEST_EMITTER="$TMP_ROOT/mutant.py" FM_CONTEXT_MUTATION="$mutation" \
      bash "${BASH_SOURCE[0]}" --case "$case_name" 2>&1); then
      fail "$mutation mutant survived its behavioral test"
    fi
    assert_contains "$out" "$diagnostic" "$mutation mutant failed for an unrelated reason"
    pass "fm-agent-context.py: $mutation mutant is rejected by its behavioral assertion"
  done <<'EOF'
identity|test_repeat_identity|repeat emit was not byte-identical
above|test_targeted_replacement_preserves_surrounding_prose|replacement lost prose above
below|test_targeted_replacement_preserves_surrounding_prose|replacement lost prose below
malformed|test_malformed_and_duplicate_markers_are_refused|malformed marker mutation: command unexpectedly passed
duplicate|test_malformed_and_duplicate_markers_are_refused|duplicate marker refusal did not name duplicate markers
redaction|test_remote_userinfo_is_redacted_with_positive_control|userinfo reached AGENTS.md
no-context|test_non_satellite_repeat_identity_and_drift|emit failed for a non-satellite repository
drift|test_non_satellite_repeat_identity_and_drift|compare-only drift mutation: command unexpectedly passed
check-write|test_non_satellite_repeat_identity_and_drift|drift check wrote AGENTS.md
EOF
}

if [ "${1:-}" = --case ]; then
  "$2"
  exit
fi

test_guarantee_mutations_are_detected
test_repeat_identity
test_non_satellite_repeat_identity_and_drift
test_bin_entrypoints_filter_before_limit
test_targeted_replacement_preserves_surrounding_prose
test_malformed_and_duplicate_markers_are_refused
test_remote_userinfo_is_redacted_with_positive_control
test_validated_satellite_and_guarded_legacy_migrations
test_schema_validation_refuses_mutated_domain_contract
test_schema_constraints_are_enforced_or_refused
test_rendered_markers_are_escaped
test_candidate_validation_refuses_broken_renderer
