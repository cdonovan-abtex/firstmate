#!/usr/bin/env bash
# Public-interface regressions for Firstmate's no-mistakes worker boundary.
# The fake native command starts a real child for guarded validation calls, so
# denial assertions prove that no native agent child began rather than merely
# checking a wrapper message or implementation bytes.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/no-mistakes"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-policy)
BG_PIDS=()

cleanup_policy_test() {
  local pid
  for pid in "${BG_PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.1
  for pid in "${BG_PIDS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_policy_test EXIT
trap 'cleanup_policy_test; exit 130' INT
trap 'cleanup_policy_test; exit 143' TERM

make_native() { # <case-dir>
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/no-mistakes-native" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "$$" "$*" >> "$FM_FAKE_NATIVE_LOG"
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  case "${FM_FAKE_STATUS:-absent}" in
    active)
      printf '%s\n' 'run:' '  status: running' '  steps[1]{step,status}:' '    review,running'
      ;;
    parked)
      printf '%s\n' 'run:' '  status: awaiting_approval' '  awaiting_agent: parked 1s' 'gate: review'
      ;;
    terminal)
      printf '%s\n' 'run:' '  status: completed' 'outcome: passed'
      ;;
    *)
      printf '%s\n' 'No active run.'
      exit 1
      ;;
  esac
  exit 0
fi
fm_fake_read_only=0
fm_fake_consumes_next=0
for fm_fake_arg in "$@"; do
  if [ "$fm_fake_consumes_next" = 1 ]; then
    fm_fake_consumes_next=0
    continue
  fi
  case "$fm_fake_arg" in
    --skip|--intent|--action|--add-finding|--findings|--instructions|--step)
      fm_fake_consumes_next=1
      ;;
    --help|-h|--version|-v)
      fm_fake_read_only=1
      ;;
  esac
done
if [ "$fm_fake_read_only" = 1 ]; then
  printf '%s\n' "native:$*"
  exit 0
fi
case " $* " in
  *' axi run '*|*' axi respond '*|*' rerun '*) fm_fake_guarded=1 ;;
  *) fm_fake_guarded=0 ;;
esac
if [ "$fm_fake_guarded" = 1 ]; then
  mkdir -p "$FM_FAKE_CHILD_DIR"
  printf '%s\n' "$$" > "$FM_FAKE_CHILD_DIR/native.$$"
  (
    if [ "${FM_FAKE_DETACH_AGENT:-}" = 1 ]; then
      trap '' TERM INT HUP
    else
      trap 'exit 143' TERM INT HUP
    fi
    printf '%s\n' "${BASHPID:-$$}" > "$FM_FAKE_CHILD_DIR/agent.$$"
    touch "$FM_FAKE_CHILD_DIR/started.$$"
    if [ -n "${FM_FAKE_BLOCK_DIR:-}" ]; then
      while [ ! -e "$FM_FAKE_BLOCK_DIR/release" ]; do sleep 0.03; done
    fi
    touch "$FM_FAKE_CHILD_DIR/completed.$$"
  ) &
  child=$!
  if [ "${FM_FAKE_DETACH_AGENT:-}" = 1 ]; then
    trap 'exit 143' TERM INT HUP
  else
    trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM INT HUP
  fi
  wait "$child"
  exit $?
fi
printf '%s\n' "native:$*"
SH
  chmod +x "$dir/fakebin/no-mistakes-native"
}

make_case() { # <name> [agent]
  local agent=${2:-codex} dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/config" "$dir/nm" "$dir/slots" "$dir/children"
  make_native "$dir"
  printf 'agent: %s\n' "$agent" > "$dir/nm/config.yaml"
  : > "$dir/native.log"
  git init -q --bare "$dir/origin.git"
  git --git-dir="$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$dir/repo"
  git -C "$dir/repo" config user.name fm-test
  git -C "$dir/repo" config user.email fm-test@example.com
  printf '%s\n' seed > "$dir/repo/.repo-seed"
  git -C "$dir/repo" add .repo-seed
  git -C "$dir/repo" commit -q -m seed
  git -C "$dir/repo" remote add origin "$dir/origin.git"
  git -C "$dir/repo" push -q -u origin main
  node --no-warnings - "$dir/nm/state.sqlite" "$dir/repo" <<'JS'
const fs = require("node:fs");
const { DatabaseSync } = require("node:sqlite");
const database = new DatabaseSync(process.argv[2]);
database.exec("CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL)");
database.prepare("INSERT INTO repos (id, working_path, upstream_url, default_branch, created_at) VALUES (?, ?, ?, ?, ?)")
  .run("test-repo", fs.realpathSync(process.argv[3]), "test-origin", "main", 1);
database.close();
JS
  printf '%s\n' "$dir"
}

set_trusted_repo_config() { # <case-dir> <yaml-text>
  local dir=$1 text=$2
  printf '%s\n' "$text" > "$dir/repo/.no-mistakes.yaml"
  git -C "$dir/repo" add .no-mistakes.yaml
  git -C "$dir/repo" commit -q -m config
  git -C "$dir/repo" push -q origin main
}

set_registered_default_branch() { # <case-dir> <branch>
  node --no-warnings -e 'const {DatabaseSync}=require("node:sqlite");const d=new DatabaseSync(process.argv[1]);d.prepare("UPDATE repos SET default_branch = ? WHERE id = ?").run(process.argv[2],"test-repo");d.close()' \
    "$1/nm/state.sqlite" "$2"
}

write_policy() { # <home> <allowed-json-array> <ceiling>
  printf '{"version":1,"allowedAgents":%s,"maxConcurrent":%s}\n' "$2" "$3" \
    > "$1/config/no-mistakes-policy.json"
}

wrapper_env() { # <case-dir> <home> <args...>
  local dir=$1 home=$2
  shift 2
  (
    cd "$dir/repo" || exit 1
    exec env \
      FM_NO_MISTAKES_POLICY_HOME="$home" \
      FM_NO_MISTAKES_NATIVE_BIN="$dir/fakebin/no-mistakes-native" \
      FM_NO_MISTAKES_NATIVE_PATH="$PATH" \
      FM_NO_MISTAKES_SLOT_ROOT="$dir/slots" \
      NM_HOME="$dir/nm" \
      FM_FAKE_NATIVE_LOG="$dir/native.log" \
      FM_FAKE_CHILD_DIR="$dir/children" \
      FM_FAKE_BLOCK_DIR="${FM_FAKE_BLOCK_DIR:-}" \
      FM_FAKE_DETACH_AGENT="${FM_FAKE_DETACH_AGENT:-}" \
      FM_FAKE_STATUS="${FM_FAKE_STATUS:-}" \
      "$WRAPPER" "$@"
  )
}

# Background lifecycle cases need $! to identify the wrapper itself rather than
# a waiting helper shell, so this variant replaces its calling subshell.
exec_wrapper_env() { # <case-dir> <home> <args...>
  local dir=$1 home=$2
  shift 2
  cd "$dir/repo" || exit 1
  exec env \
    FM_NO_MISTAKES_POLICY_HOME="$home" \
    FM_NO_MISTAKES_NATIVE_BIN="$dir/fakebin/no-mistakes-native" \
    FM_NO_MISTAKES_NATIVE_PATH="$PATH" \
    FM_NO_MISTAKES_SLOT_ROOT="$dir/slots" \
    NM_HOME="$dir/nm" \
    FM_FAKE_NATIVE_LOG="$dir/native.log" \
    FM_FAKE_CHILD_DIR="$dir/children" \
    FM_FAKE_BLOCK_DIR="${FM_FAKE_BLOCK_DIR:-}" \
    FM_FAKE_DETACH_AGENT="${FM_FAKE_DETACH_AGENT:-}" \
    FM_FAKE_STATUS="${FM_FAKE_STATUS:-}" \
    "$WRAPPER" "$@"
}

wrapper_env_stable_root() { # <case-dir> <home> <xdg-state-home> <args...>
  local dir=$1 home=$2 xdg=$3
  shift 3
  (
    cd "$dir/repo" || exit 1
    exec env -u FM_NO_MISTAKES_SLOT_ROOT \
      XDG_STATE_HOME="$xdg" \
      FM_NO_MISTAKES_POLICY_HOME="$home" \
      FM_NO_MISTAKES_NATIVE_BIN="$dir/fakebin/no-mistakes-native" \
      FM_NO_MISTAKES_NATIVE_PATH="$PATH" \
      NM_HOME="$dir/nm" \
      FM_FAKE_NATIVE_LOG="$dir/native.log" \
      FM_FAKE_CHILD_DIR="$dir/children" \
      FM_FAKE_BLOCK_DIR="${FM_FAKE_BLOCK_DIR:-}" \
      FM_FAKE_DETACH_AGENT="${FM_FAKE_DETACH_AGENT:-}" \
      FM_FAKE_STATUS="${FM_FAKE_STATUS:-}" \
      "$WRAPPER" "$@"
  )
}

exec_wrapper_env_stable_root() { # <case-dir> <home> <xdg-state-home> <args...>
  local dir=$1 home=$2 xdg=$3
  shift 3
  cd "$dir/repo" || exit 1
  exec env -u FM_NO_MISTAKES_SLOT_ROOT \
    XDG_STATE_HOME="$xdg" \
    FM_NO_MISTAKES_POLICY_HOME="$home" \
    FM_NO_MISTAKES_NATIVE_BIN="$dir/fakebin/no-mistakes-native" \
    FM_NO_MISTAKES_NATIVE_PATH="$PATH" \
    NM_HOME="$dir/nm" \
    FM_FAKE_NATIVE_LOG="$dir/native.log" \
    FM_FAKE_CHILD_DIR="$dir/children" \
    FM_FAKE_BLOCK_DIR="${FM_FAKE_BLOCK_DIR:-}" \
    FM_FAKE_DETACH_AGENT="${FM_FAKE_DETACH_AGENT:-}" \
    FM_FAKE_STATUS="${FM_FAKE_STATUS:-}" \
    "$WRAPPER" "$@"
}

wait_for_count() { # <glob-parent> <prefix> <count>
  local dir=$1 prefix=$2 wanted=$3 count tries=0
  while [ "$tries" -lt 200 ]; do
    count=$(find "$dir" -maxdepth 1 -type f -name "$prefix.*" | wc -l | tr -d ' ')
    [ "$count" -ge "$wanted" ] && return 0
    sleep 0.03
    tries=$((tries + 1))
  done
  return 1
}

service_state_root() { # <case-dir>
  node -e 'const c=require("node:crypto"),f=require("node:fs"); process.stdout.write(process.argv[1]+"/"+c.createHash("sha256").update(f.realpathSync(process.argv[2])).digest("hex"))' \
    "$1/slots" "$1/nm"
}

# Explicit identity is admitted and the native child starts.
d=$(make_case allowed codex)
write_policy "$d/home" '["codex"]' 2
out=$(wrapper_env "$d" "$d/home" axi run --intent allowed 2>&1)
assert_contains "$out" 'agent=codex active=1 available=1 ceiling=2; slot acquired' \
  "allowed validation did not report its acquired service slot"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "allowed explicit agent did not start exactly one native agent child"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
[ "$status" = 'policy=enabled agent=codex allowed=true active=0 available=2 ceiling=2 participants=1' ] \
  || fail "policy status did not report released capacity: $status"
pass "allowed explicit agent starts through an inspectable slot"

# Missing policy preserves the old native path.
d=$(make_case missing-policy auto)
out=$(wrapper_env "$d" "$d/home" axi run --intent unconfigured 2>&1)
assert_not_contains "$out" 'Firstmate no-mistakes policy:' \
  "absent policy changed guarded command output"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "absent policy did not preserve native validation behavior"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
[ "$status" = 'policy=disabled active=0 available=unbounded ceiling=unbounded participants=0' ] \
  || fail "absent policy did not inspect as disabled: $status"
pass "globally missing policy preserves existing behavior"

# auto and a concrete non-allowed identity both stop before native invocation.
for denied_agent in auto claude; do
  d=$(make_case "denied-$denied_agent" "$denied_agent")
  write_policy "$d/home" '["codex"]' 2
  set +e
  out=$(wrapper_env "$d" "$d/home" axi run --intent denied 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 78 ] || fail "denied $denied_agent exited $rc instead of 78"
  assert_contains "$out" "denied effective agent \"$denied_agent\"" \
    "denial did not name effective identity $denied_agent"
  [ ! -s "$d/native.log" ] || fail "denied $denied_agent reached native no-mistakes"
  [ -z "$(find "$d/children" -name 'started.*' -print -quit)" ] \
    || fail "denied $denied_agent started a native agent child"
done
pass "auto and disallowed explicit identities are denied before native agent launch"

# Trusted repository overrides and every ordered fallback are part of the
# selector admitted by policy, including the explicit branch opt-in.
d=$(make_case trusted-repo-denied codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" 'agent: claude'
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent repo-denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "trusted repository override exited $rc instead of 78"
assert_contains "$out" 'denied effective agent "claude"' \
  "trusted repository override did not replace the allowed global selector"
[ ! -s "$d/native.log" ] || fail "denied trusted repository override reached native no-mistakes"

d=$(make_case trusted-repo-fallback codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" 'agent: [codex, claude]'
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent fallback-denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "disallowed repository fallback exited $rc instead of 78"
assert_contains "$out" 'denied effective selector ["codex","claude"]' \
  "ordered fallback denial did not identify the complete selector"
[ ! -s "$d/native.log" ] || fail "disallowed repository fallback reached native no-mistakes"

d=$(make_case trusted-repo-allowed codex)
write_policy "$d/home" '["codex","pi"]' 2
set_trusted_repo_config "$d" $'agent:\n  - codex\n  - pi'
out=$(wrapper_env "$d" "$d/home" axi run --intent fallback-allowed 2>&1)
assert_contains "$out" 'agent=codex,pi active=1 available=1 ceiling=2' \
  "allowed ordered fallback list was not admitted as one guarded selector"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "allowed ordered fallback selector did not start native work"

d=$(make_case branch-repo-denied codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" $'allow_repo_commands: true\nagent: codex'
git -C "$d/repo" checkout -q -b feature
printf '%s\n' 'agent: claude' > "$d/repo/.no-mistakes.yaml"
git -C "$d/repo" add .no-mistakes.yaml
git -C "$d/repo" commit -q -m feature-config
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent branch-denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "opted-in branch override exited $rc instead of 78"
assert_contains "$out" 'denied effective agent "claude"' \
  "trusted allow_repo_commands opt-in did not select the current branch agent"
[ ! -s "$d/native.log" ] || fail "denied branch override reached native no-mistakes"
pass "trusted repository selectors and every ordered fallback are enforced"

d=$(make_case quoted-selector-key codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" '"agent": claude'
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent quoted-selector 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "quoted selector key exited $rc instead of 78"
assert_contains "$out" 'denied effective agent "claude"' \
  "quoted selector key did not select the disallowed repository agent"
[ ! -s "$d/native.log" ] || fail "quoted selector key bypass reached native no-mistakes"

d=$(make_case quoted-allow-key codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" $'"allow_repo_commands": true\n"agent": codex'
git -C "$d/repo" checkout -q -b feature
printf '%s\n' '"agent": claude' > "$d/repo/.no-mistakes.yaml"
git -C "$d/repo" add .no-mistakes.yaml
git -C "$d/repo" commit -q -m quoted-feature-config
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent quoted-opt-in 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "quoted allow_repo_commands key exited $rc instead of 78"
assert_contains "$out" 'denied effective agent "claude"' \
  "quoted allow_repo_commands key did not select the committed branch agent"
[ ! -s "$d/native.log" ] || fail "quoted allow_repo_commands bypass reached native no-mistakes"

d=$(make_case quoted-unrelated-key codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" '"agent_note": claude'
wrapper_env "$d" "$d/home" axi run --intent quoted-unrelated >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "an unrelated quoted key changed the effective global selector"
pass "quoted YAML selector keys are decoded without false matches"

d=$(make_case indented-selector-key codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" ' agent: claude'
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent indented-selector 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "uniformly indented selector exited $rc instead of 78"
assert_contains "$out" 'denied effective agent "claude"' \
  "uniform root indentation hid the disallowed repository selector"
[ ! -s "$d/native.log" ] || fail "uniformly indented selector bypass reached native no-mistakes"

d=$(make_case indented-unrelated-key codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" ' agent_note: claude'
wrapper_env "$d" "$d/home" axi run --intent indented-unrelated >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "an unrelated uniformly indented key changed the effective global selector"
pass "uniform YAML root indentation preserves selector semantics"

d=$(make_case registered-default-branch codex)
write_policy "$d/home" '["codex"]' 2
set_trusted_repo_config "$d" 'agent: claude'
git -C "$d/repo" checkout -q -b develop
printf '%s\n' 'agent: codex' > "$d/repo/.no-mistakes.yaml"
git -C "$d/repo" add .no-mistakes.yaml
git -C "$d/repo" commit -q -m develop-config
git -C "$d/repo" push -q origin develop
git --git-dir="$d/origin.git" symbolic-ref HEAD refs/heads/develop
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent registered-main 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "registered main selector exited $rc instead of 78 after origin HEAD drift"
assert_contains "$out" 'denied effective agent "claude"' \
  "origin HEAD drift replaced the registered main selector"
[ ! -s "$d/native.log" ] || fail "origin HEAD drift bypass reached native no-mistakes"
set_registered_default_branch "$d" develop
wrapper_env "$d" "$d/home" axi run --intent registered-develop >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "the registered develop selector did not control the counterfactual run"
pass "registered default-branch metadata controls trusted selector resolution"

# Command normalization guards rerun and root-option forms without treating a
# read-only argument value such as `--step run` as a validation boundary.
d=$(make_case normalized-boundaries codex)
write_policy "$d/home" '["codex"]' 2
wrapper_env "$d" "$d/home" --skip lint axi run --intent root-flags >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "root flags before axi run bypassed or failed the guarded boundary"
read_out=$(wrapper_env "$d" "$d/home" axi logs --step run)
assert_contains "$read_out" 'native:axi logs --step run' \
  "read-only logs command with a run-valued option was misclassified"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "read-only logs command started a native agent child"
printf 'agent: auto\n' > "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" --skip=lint axi respond --action approve 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "root-option continuation bypass exited $rc instead of 78"
printf 'agent: codex\n' > "$d/nm/config.yaml"
wrapper_env "$d" "$d/home" rerun --intent normalized >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "supported rerun did not pass through an allowed guarded boundary"
printf 'agent: auto\n' > "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" --skip lint rerun --intent denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "root-option rerun bypass exited $rc instead of 78"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "denied rerun started a native agent child"
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent --help 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "help-looking intent value bypass exited $rc instead of 78"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "help-looking intent value bypassed policy and started a native agent child"
pass "normalized start and continuation forms cannot bypass policy"

# Malformed policy fails one guarded boundary, while harmless reads still pass.
d=$(make_case malformed codex)
printf '%s\n' '{"version":1,"allowedAgents":["codex"],"maxConcurrent":"many"}' \
  > "$d/home/config/no-mistakes-policy.json"
set +e
out=$(wrapper_env "$d" "$d/home" axi respond --action approve 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "malformed policy exited $rc instead of 78"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "malformed policy emitted more than one diagnostic: $out"
assert_contains "$out" 'field maxConcurrent must be an integer' \
  "malformed policy diagnostic was not actionable"
[ ! -s "$d/native.log" ] || fail "malformed policy reached native guarded command"
read_out=$(wrapper_env "$d" "$d/home" doctor)
assert_contains "$read_out" 'native:doctor' "doctor was not harmless pass-through under malformed policy"
help_out=$(wrapper_env "$d" "$d/home" axi run --help)
assert_contains "$help_out" 'native:axi run --help' "guarded-command help was not read-only pass-through"
[ -z "$(find "$d/children" -name 'started.*' -print -quit)" ] \
  || fail "read-only no-mistakes commands started a native agent child"
pass "invalid policy stops guarded work once and leaves read-only commands harmless"

# A missing no-mistakes config is not guessed when policy is active.
d=$(make_case missing-global codex)
write_policy "$d/home" '["codex"]' 2
rm -f "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent denied 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "missing global config exited $rc instead of 78"
assert_contains "$out" 'cannot determine the effective work-agent selector' \
  "missing global config did not explain the unknown effective selector"
[ ! -s "$d/native.log" ] || fail "missing global config reached native guarded command"
pass "missing effective-agent configuration is refused instead of guessed"

# A worker launched while explicit policy is safe re-reads drift before its first call.
d=$(make_case launch-drift codex)
write_policy "$d/home" '["codex"]' 2
cat > "$d/launched-worker.sh" <<'SH'
#!/usr/bin/env bash
set -eu
touch "$FM_DRIFT_READY"
while [ ! -e "$FM_DRIFT_GO" ]; do sleep 0.03; done
cd "$FM_DRIFT_REPO"
no-mistakes axi run --intent drift
SH
chmod +x "$d/launched-worker.sh"
set +e
drift_native_path=$PATH
PATH="$ROOT/bin:$drift_native_path" \
FM_NO_MISTAKES_POLICY_HOME="$d/home" \
FM_NO_MISTAKES_NATIVE_BIN="$d/fakebin/no-mistakes-native" \
FM_NO_MISTAKES_NATIVE_PATH="$drift_native_path" \
FM_NO_MISTAKES_SLOT_ROOT="$d/slots" \
NM_HOME="$d/nm" FM_FAKE_NATIVE_LOG="$d/native.log" FM_FAKE_CHILD_DIR="$d/children" \
FM_DRIFT_READY="$d/ready" FM_DRIFT_GO="$d/go" FM_DRIFT_REPO="$d/repo" \
  "$d/launched-worker.sh" > "$d/drift.out" 2>&1 &
drift_pid=$!
BG_PIDS+=("$drift_pid")
set -e
while [ ! -e "$d/ready" ]; do sleep 0.03; done
printf 'agent: auto\n' > "$d/nm/config.yaml"
touch "$d/go"
set +e
wait "$drift_pid"
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "post-launch config drift exited $rc instead of 78"
assert_contains "$(cat "$d/drift.out")" 'denied effective agent "auto"' \
  "post-launch drift was not re-read at validation start"
[ ! -s "$d/native.log" ] || fail "post-launch drift reached native no-mistakes"
pass "worker launch does not cache a safe agent across later config drift"

# Continuation is an equal policy boundary.
d=$(make_case continuation-drift codex)
write_policy "$d/home" '["codex"]' 2
wrapper_env "$d" "$d/home" axi run --intent initial >/dev/null 2>&1
printf 'agent: auto\n' > "$d/nm/config.yaml"
set +e
out=$(wrapper_env "$d" "$d/home" axi respond --action approve 2>&1)
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "drifted continuation exited $rc instead of 78"
[ "$(grep -c $'\taxi respond ' "$d/native.log" || true)" -eq 0 ] \
  || fail "drifted continuation reached native no-mistakes"
assert_contains "$out" 'denied effective agent "auto"' \
  "continuation drift was not re-read"
pass "every validation continuation re-reads effective agent policy"

# Two slots run together; status exposes the cohort and a third call is refused.
d=$(make_case two-slots codex)
write_policy "$d/home" '["codex"]' 2
mkdir -p "$d/block"
cohort_pids=()
for cohort in one two; do
  FM_FAKE_BLOCK_DIR="$d/block" exec_wrapper_env "$d" "$d/home" axi run --intent "$cohort" \
    > "$d/$cohort.out" 2>&1 &
  cohort_pids+=("$!")
  BG_PIDS+=("$!")
done
wait_for_count "$d/children" started 2 || fail "two-slot cohort did not start two native agent children"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=2 available=0 ceiling=2' \
  "active two-slot cohort was not inspectable"
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent third 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "over-limit validation exited $rc instead of 75"
assert_contains "$out" 'capacity reached: agent=codex active=2 available=0 ceiling=2' \
  "over-limit diagnostic did not expose capacity"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "over-limit validation started a third native agent child"
touch "$d/block/release"
wait "${cohort_pids[0]}"
wait "${cohort_pids[1]}"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=0 available=2 ceiling=2' \
  "normal cohort completion did not release slots"
pass "parallel cohorts use multiple visible slots and refuse over-limit starts"

# Independent homes sharing one NM_HOME share participants and slots.
d=$(make_case shared-service codex)
mkdir -p "$d/home-two/config" "$d/home-unconfigured/config" "$d/block"
write_policy "$d/home" '["codex","pi"]' 2
write_policy "$d/home-two" '["codex"]' 2
shared_pids=()
for home in "$d/home" "$d/home-two"; do
  FM_FAKE_BLOCK_DIR="$d/block" exec_wrapper_env "$d" "$home" axi run --intent shared \
    > "$d/shared.$(basename "$home").out" 2>&1 &
  shared_pids+=("$!")
  BG_PIDS+=("$!")
done
wait_for_count "$d/children" started 2 || fail "independent homes did not share a two-slot cohort"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=2 available=0 ceiling=2 participants=2' \
  "independent home registrations were not combined"
set +e
out=$(wrapper_env "$d" "$d/home-unconfigured" axi run --intent service-wide 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "unconfigured sibling home bypassed registered service ceiling (exit $rc)"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "unconfigured sibling home started an over-limit child"
touch "$d/block/release"
wait "${shared_pids[0]}"
wait "${shared_pids[1]}"
rm -f "$d/home/config/no-mistakes-policy.json" "$d/home-two/config/no-mistakes-policy.json"
status=$(wrapper_env "$d" "$d/home-unconfigured" fm-policy-status)
[ "$status" = 'policy=disabled active=0 available=unbounded ceiling=unbounded participants=0' ] \
  || fail "removed home policies remained registered: $status"
pass "independent homes sharing one service use one conservative slot pool"

d=$(make_case xdg-shared-service codex)
d2=$(make_case xdg-distinct-service codex)
write_policy "$d/home" '["codex"]' 1
write_policy "$d2/home" '["codex"]' 1
mkdir -p "$d/block" "$d/xdg-one" "$d/xdg-two"
FM_FAKE_BLOCK_DIR="$d/block" exec_wrapper_env_stable_root "$d" "$d/home" "$d/xdg-one" axi run --intent xdg-one \
  > "$d/xdg-one.out" 2>&1 &
xdg_wrapper=$!
BG_PIDS+=("$xdg_wrapper")
wait_for_count "$d/children" started 1 || fail "first XDG cohort member did not start"
wrapper_env_stable_root "$d2" "$d2/home" "$d/xdg-one" axi run --intent distinct-service >/dev/null 2>&1
[ "$(find "$d2/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "a distinct no-mistakes service collided in the stable accounting root"
set +e
out=$(wrapper_env_stable_root "$d" "$d/home" "$d/xdg-two" axi run --intent xdg-two 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "different XDG_STATE_HOME bypassed the shared service ceiling (exit $rc)"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "different XDG_STATE_HOME started an over-limit native child"
touch "$d/block/release"
wait "$xdg_wrapper"
pass "service accounting ignores XDG drift without merging distinct services"

# Killing the wrapper in the widened spawn-to-identity handoff cannot free the
# slot or let the pipe-gated native command start. The conservative transitional
# lease later self-recovers after the exact gate child has exited.
d=$(make_case handoff-race codex)
write_policy "$d/home" '["codex"]' 1
mkdir -p "$d/psbin"
cat > "$d/psbin/ps" <<'SH'
#!/usr/bin/env bash
set -u
target=
args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) target=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${FM_HANDOFF_MARKER:-}" ] && [ "$target" != "$PPID" ]; then
  touch "$FM_HANDOFF_MARKER"
  while [ ! -e "$FM_HANDOFF_RELEASE" ]; do sleep 0.02; done
fi
exec /bin/ps "${args[@]}"
SH
chmod +x "$d/psbin/ps"
set +e
PATH="$d/psbin:$PATH" FM_HANDOFF_MARKER="$d/handoff-marker" FM_HANDOFF_RELEASE="$d/handoff-release" \
  exec_wrapper_env "$d" "$d/home" axi run --intent handoff > "$d/handoff.out" 2>&1 &
handoff_wrapper=$!
BG_PIDS+=("$handoff_wrapper")
set -e
for _ in $(seq 1 200); do
  [ -e "$d/handoff-marker" ] && break
  sleep 0.03
done
[ -e "$d/handoff-marker" ] || fail "handoff fixture never reached the widened pre-identity window"
kill -KILL "$handoff_wrapper"
set +e
wait "$handoff_wrapper" 2>/dev/null
set -e
touch "$d/handoff-release"
sleep 0.1
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent charged-handoff 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "transitional handoff lease was not conservatively charged (exit $rc)"
[ ! -s "$d/native.log" ] || fail "a native command started before durable handoff identity publication"
sleep 5.1
wrapper_env "$d" "$d/home" axi run --intent recovered-handoff >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "transitional handoff lease did not recover after the gate child exited"
pass "launch handoff remains charged and pipe-gated through identity publication"

# A signal observed while the wrapper waits for the shared lock exits before a
# lease or native command can be created, then leaves capacity usable.
d=$(make_case prelaunch-signal codex)
write_policy "$d/home" '["codex"]' 1
state_root=$(service_state_root "$d")
mkdir -p "$state_root/.lock"
owner_start=$(ps -p $$ -o lstart= | awk '{$1=$1; print}')
node -e 'const f=require("node:fs"); f.writeFileSync(process.argv[1], JSON.stringify({version:1,token:"test-owner",pid:Number(process.argv[2]),processStart:process.argv[3]})+"\n")' \
  "$state_root/.lock/owner.json" "$$" "$owner_start"
set +e
exec_wrapper_env "$d" "$d/home" axi run --intent interrupted-before-spawn > "$d/prelaunch.out" 2>&1 &
prelaunch_wrapper=$!
BG_PIDS+=("$prelaunch_wrapper")
set -e
sleep 0.2
kill -TERM "$prelaunch_wrapper"
set +e
wait "$prelaunch_wrapper"
rc=$?
set -e
[ "$rc" -eq 143 ] || fail "pre-launch interruption exited $rc instead of 143"
[ ! -s "$d/native.log" ] || fail "pre-launch interruption reached native no-mistakes"
[ -z "$(find "$d/children" -name 'started.*' -print -quit)" ] \
  || fail "pre-launch interruption started a native agent child"
rm -rf "$state_root/.lock"
wrapper_env "$d" "$d/home" axi run --intent after-prelaunch-interrupt >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "pre-launch interruption left capacity unavailable"
pass "an interrupt observed before spawn prevents native launch"

d=$(make_case interruption codex)
write_policy "$d/home" '["codex"]' 1
mkdir -p "$d/block"
FM_FAKE_BLOCK_DIR="$d/block" FM_FAKE_DETACH_AGENT=1 FM_FAKE_STATUS=active \
  exec_wrapper_env "$d" "$d/home" axi run --intent interrupt \
  > "$d/interrupt.out" 2>&1 &
interrupt_wrapper=$!
BG_PIDS+=("$interrupt_wrapper")
wait_for_count "$d/children" started 1 || fail "interruption fixture did not start"
interrupted_agent=$(cat "$d/children"/agent.*)
BG_PIDS+=("$interrupted_agent")
kill -TERM "$interrupt_wrapper"
set +e
wait "$interrupt_wrapper"
rc=$?
set -e
[ "$rc" -eq 143 ] || fail "interrupted boundary exited $rc instead of 143"
kill -0 "$interrupted_agent" 2>/dev/null || fail "daemon-owned agent did not survive its interrupted CLI"
set +e
out=$(FM_FAKE_STATUS=active wrapper_env "$d" "$d/home" axi run --intent while-daemon-active 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "interrupted CLI released an active daemon run lease (exit $rc)"
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "interrupted active daemon run admitted a second native child"
touch "$d/block/release"
wait_for_count "$d/children" completed 1 || fail "daemon-owned agent did not complete after release"
FM_FAKE_STATUS=terminal wrapper_env "$d" "$d/home" axi run --intent after-interrupt >/dev/null 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "terminal daemon status did not recover the interrupted lease"
pass "interrupted CLI leases wait for daemon-status-proven recovery"

# A dead wrapper retains a live native child, then recovers without manual files.
d=$(make_case abnormal-exit codex)
write_policy "$d/home" '["codex"]' 1
mkdir -p "$d/block"
FM_FAKE_BLOCK_DIR="$d/block" FM_FAKE_STATUS=terminal \
  exec_wrapper_env "$d" "$d/home" axi run --intent crash > "$d/crash.out" 2>&1 &
crash_wrapper=$!
BG_PIDS+=("$crash_wrapper")
wait_for_count "$d/children" started 1 || fail "abnormal-exit fixture did not start"
native_pid=$(cat "$d/children"/native.*)
agent_pid=$(cat "$d/children"/agent.*)
kill -KILL "$crash_wrapper"
set +e
wait "$crash_wrapper" 2>/dev/null
set -e
set +e
out=$(wrapper_env "$d" "$d/home" axi run --intent while-native-lives 2>&1)
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "dead wrapper released a still-live native boundary (exit $rc)"
kill -KILL "$native_pid" "$agent_pid" 2>/dev/null || true
for _ in $(seq 1 100); do
  kill -0 "$native_pid" 2>/dev/null || break
  sleep 0.03
done
wrapper_env "$d" "$d/home" axi run --intent recovered > "$d/recovered.out" 2>&1
[ "$(find "$d/children" -name 'started.*' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "dead holder lease did not recover after native work disappeared"
status=$(wrapper_env "$d" "$d/home" fm-policy-status)
assert_contains "$status" 'active=0 available=1 ceiling=1' \
  "abnormal-exit recovery did not restore capacity"
pass "abnormal worker exit neither frees live native work nor requires manual lease deletion"

printf '%s\n' '# all fm-no-mistakes-policy tests passed'
