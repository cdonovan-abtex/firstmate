#!/usr/bin/env bash
# Prompt-submitting live guard for Pi supervision-result continuation.
#
# It seeds one captain-facing synthetic completion in an isolated FM_HOME,
# launches the real Pi TUI inside one named non-default Herdr lab, and sends no
# user prompt. A fixture extension withholds the two action tools for the first
# two processing turns, then enables them; the landed extension must open its
# delayed bounded retry by itself, after which the real model must call the
# isolated synthetic next-action tool and acknowledge the exact outcome once.
# Every Herdr operation goes through bin/fm-herdr-lab.sh, whose teardown proves
# that the live default session stayed byte-identical.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_RESULT_CONTINUATION_HERDR_E2E herdr jq pi python3

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
: "${FM_PI_RESULT_CONTINUATION_PROVIDER:?set FM_PI_RESULT_CONTINUATION_PROVIDER to the approved Pi provider}"
: "${FM_PI_RESULT_CONTINUATION_MODEL:?set FM_PI_RESULT_CONTINUATION_MODEL to the approved Pi model}"

TMP_ROOT=$(fm_test_tmproot fm-pi-result-continuation-herdr-live)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
SESSIONS="$TMP_ROOT/sessions"
RECEIPT="$TMP_ROOT/action.receipt"
TOKEN=continuation-ok-anonymous
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PROJECT" "$SESSIONS"
printf '# Isolated synthetic continuation probe\n' > "$PROJECT/README.md"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-result-continuation-r1)
cleanup() {
  local status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

cat > "$TMP_ROOT/synthetic-action.ts" <<'EOF'
import { appendFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const receipt = process.env.FM_SYNTHETIC_ACTION_RECEIPT!;
const expected = process.env.FM_SYNTHETIC_ACTION_TOKEN!;
const delayedTools = ["synthetic_next_action", "fm_branch_processed"];

export default function (pi: ExtensionAPI) {
  let settledWithoutTools = 0;
  pi.registerTool({
    name: "synthetic_next_action",
    label: "Record synthetic next action",
    description: "Perform the authorized isolated synthetic continuation by recording its exact token.",
    promptSnippet: "Record an authorized isolated synthetic continuation token",
    promptGuidelines: [
      "Use synthetic_next_action when a supervision processing request explicitly authorizes the isolated synthetic next action.",
    ],
    parameters: Type.Object({ token: Type.String() }),
    async execute(_id, params) {
      if (params.token !== expected) throw new Error("unexpected synthetic token");
      appendFileSync(receipt, `${params.token}\n`, { mode: 0o600 });
      return {
        content: [{ type: "text", text: "authorized isolated synthetic next action recorded" }],
        details: {},
      };
    },
  });
  pi.on("session_start", () => {
    pi.setActiveTools(pi.getActiveTools().filter((name) => !delayedTools.includes(name)));
  });
  pi.on("agent_settled", () => {
    settledWithoutTools += 1;
    if (settledWithoutTools !== 2) return;
    pi.setActiveTools([...new Set([...pi.getActiveTools(), ...delayedTools])]);
  });
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\nFor an fm-branch-process request, if synthetic_next_action and fm_branch_processed are available, perform every explicitly authorized isolated synthetic action with synthetic_next_action before acknowledging the listed outcomes through fm_branch_processed. Do not wait for another prompt.`,
  }));
}
EOF

SEQ=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-branch-outcome.sh" append \
  --task synthetic-completion \
  --verdict captain \
  --summary "Synthetic worker completed. The authorized isolated next action is to call synthetic_next_action with token $TOKEN; then acknowledge this outcome. No external, destructive, access, production, or merge action is authorized.") \
  || fail "could not seed the isolated synthetic completion"

CREATE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$PROJECT" --label continuation-live --no-focus) \
  || fail "could not create the isolated Herdr workspace"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the isolated Herdr pane id"
sleep 2

CMD=$(printf 'printf "%%s\\n" "$$" > %q; exec env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_SYNTHETIC_ACTION_RECEIPT=%q FM_SYNTHETIC_ACTION_TOKEN=%q pi --no-extensions -e %q -e %q --no-context-files --no-skills --no-prompt-templates --no-themes --no-builtin-tools --provider %q --model %q --thinking low --session-dir %q' \
  "$HOME_DIR/state/.lock" \
  "$HOME_DIR" \
  "$ROOT" \
  "$RECEIPT" \
  "$TOKEN" \
  "$ROOT/.pi/extensions/fm-branch-supervision.ts" \
  "$TMP_ROOT/synthetic-action.ts" \
  "$FM_PI_RESULT_CONTINUATION_PROVIDER" \
  "$FM_PI_RESULT_CONTINUATION_MODEL" \
  "$SESSIONS")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" "$CMD" >/dev/null \
  || fail "could not type the isolated Pi launch command"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null \
  || fail "could not submit the isolated Pi launch command"

ok=0
for _ in $(seq 1 300); do
  marker=$(cat "$HOME_DIR/state/.branch-outcomes-processed" 2>/dev/null || true)
  if [ -f "$RECEIPT" ] && grep -Fxq "$TOKEN" "$RECEIPT" && [ "$marker" = "$SEQ" ]; then
    ok=1
    break
  fi
  sleep 0.5
done
if [ "$ok" -ne 1 ]; then
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane capture "$PANE" 2>/dev/null || true
  fail "the synthetic completion did not perform and acknowledge its authorized next action without a prompt"
fi

SESSION_FILE=$(find "$SESSIONS" -type f -name '*.jsonl' -print -quit)
[ -n "$SESSION_FILE" ] || fail "the isolated Pi session did not persist"
if ! python3 - "$SESSION_FILE" "$SEQ" "$TOKEN" <<'PY'
import json
import sys

path, sequence, token = sys.argv[1:]
process_times = []
actions = 0
acknowledgements = 0
drains = 0
for line in open(path, encoding="utf-8"):
    entry = json.loads(line)
    if (
        entry.get("type") == "custom_message"
        and entry.get("customType") == "fm-branch-process"
        and f"[seq {sequence}]" in entry.get("content", "")
    ):
        process_times.append(entry.get("timestamp"))
    if entry.get("type") != "message" or entry.get("message", {}).get("role") != "assistant":
        continue
    for item in entry["message"].get("content", []):
        if not isinstance(item, dict) or item.get("type") != "toolCall":
            continue
        if item.get("name") == "synthetic_next_action" and item.get("arguments", {}).get("token") == token:
            actions += 1
        if item.get("name") == "fm_branch_processed" and str(item.get("arguments", {}).get("through")) == sequence:
            acknowledgements += 1
        if item.get("name") in {"bash", "fm_wake_drain"}:
            drains += 1
if len(process_times) != 3 or actions != 1 or acknowledgements != 1 or drains != 0:
    raise SystemExit(
        "unexpected transcript cardinality "
        f"process={len(process_times)} action={actions} acknowledgement={acknowledgements} drains={drains}"
    )
from datetime import datetime
first = datetime.fromisoformat(process_times[0].replace("Z", "+00:00"))
third = datetime.fromisoformat(process_times[2].replace("Z", "+00:00"))
if (third - first).total_seconds() < 59:
    raise SystemExit(f"the third processing request was not delayed: {process_times}")
PY
then
  fail "the isolated Pi transcript did not prove processing, action, and exact acknowledgement"
fi

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/quit' >/dev/null \
  || fail "could not type /quit into the isolated Pi"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" Enter >/dev/null \
  || fail "could not submit /quit to the isolated Pi"
pass "a real Pi in a named Herdr lab retries a twice-ignored synthetic completion after its bounded delay, performs its authorized next action, and acknowledges exactly once without a human prompt"
