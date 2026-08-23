#!/usr/bin/env bash
# End-to-end demonstration of PR/MR outcome reporting as an operator sees it.
# Real bin/fm-pr-check.sh and bin/fm-pr-poll.sh run; only the forge CLIs are
# local stubs that serve real JSON and evaluate the caller's real --jq program.
set -u
ROOT=$1
OUT=$2
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
REAL_JQ=$(command -v jq)
WORK=$(mktemp -d /tmp/fm-outcome-demo/case.XXXXXX)

mkcase() {
  local name=$1 dir
  dir="$WORK/$name"
  mkdir -p "$dir/home/state" "$dir/wt" "$dir/fakebin" "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  chmod +x "$dir/root/bin/fm-guard.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'GH_EMBEDDED_JQ=%s\n' "$(printf '%q' "$REAL_JQ")"
    cat <<'SH'
[ -z "${GH_LOG:-}" ] || printf '%s\n' "$*" >> "$GH_LOG"
gh_fields=; gh_prog=; gh_prev=
for a in "$@"; do
  case "$gh_prev" in --json) gh_fields=$a ;; --jq) gh_prog=$a ;; esac
  gh_prev=$a
done
serve() {
  local payload=$1 known=$2 f
  local IFS=,
  for f in $gh_fields; do
    case ",$known," in *",$f,"*) ;; *) printf 'unknown JSON field: "%s"\n' "$f" >&2; exit 1 ;; esac
  done
  unset IFS
  printf '%s' "$payload" | "$GH_EMBEDDED_JQ" -r "$gh_prog"
}
case "${1:-} ${2:-}" in
  "pr view")
    [ "${GH_FAIL:-0}" = 0 ] || exit 1
    if [ "${GH_DRAFT:-0}" = 0 ]; then d=false; else d=true; fi
    p=$("$GH_EMBEDDED_JQ" -n --arg state "${GH_STATE:-OPEN}" --argjson isDraft "$d" \
        --arg baseRefName "${GH_BASE:-main}" \
        --arg headRefOid "${GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" \
        '{state:$state,isDraft:$isDraft,baseRefName:$baseRefName,headRefOid:$headRefOid}')
    serve "$p" 'state,isDraft,baseRefName,headRefOid,number,url,title' ;;
  "repo view")
    [ "${GH_DEFAULT_FAIL:-0}" = 0 ] || exit 1
    p=$("$GH_EMBEDDED_JQ" -n --arg name "${GH_DEFAULT:-main}" '{defaultBranchRef:{name:$name}}')
    serve "$p" 'defaultBranchRef,name,owner,isPrivate' ;;
esac
SH
  } > "$dir/fakebin/gh"
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "mr view")
    [ "${GLAB_FAIL:-0}" = 0 ] || exit 1
    if [ "${GLAB_DRAFT:-0}" = 0 ]; then d=false; else d=true; fi
    if [ "${GLAB_BASE_ABSENT:-0}" = 0 ]; then
      printf '{"state":"%s","draft":%s,"target_branch":"%s","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' \
        "${GLAB_STATE:-opened}" "$d" "${GLAB_BASE:-main}"
    else
      printf '{"state":"%s","draft":%s,"target_branch":null}\n' "${GLAB_STATE:-opened}" "$d"
    fi ;;
  "repo view")
    [ "${GLAB_DEFAULT_FAIL:-0}" = 0 ] || exit 1
    printf '{"default_branch":"%s"}\n' "${GLAB_DEFAULT:-main}" ;;
esac
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'stub gh-axi: %s\n' "$*"
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/glab" "$dir/fakebin/gh-axi"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  {
    printf 'window=firstmate:fm-task-a\n'
    printf 'endpoint_task_id=task-a\n'
    printf 'worktree=%s\n' "$dir/wt"
    printf 'project=%s\n' "$dir/project"
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
  } > "$dir/home/state/task-a.meta"
  printf '%s\n' "$dir"
}

section() { printf '\n=== %s ===\n' "$1"; }

arm() {  # <dir> <url> <env...>
  local dir=$1 url=$2
  shift 2
  printf '$ fm-pr-check.sh task-a %s\n' "$url"
  env -i PATH="$dir/fakebin:$BASE_PATH" HOME="$dir/home" \
    FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" "$@" \
    bash "$ROOT/bin/fm-pr-check.sh" task-a "$url" 2>&1
  printf '(exit %s)\n' "$?"
}

poll() {  # <dir> <env...>  -- runs the armed watcher check exactly as fm-watch.sh does
  local dir=$1
  shift
  printf '$ state/task-a.check.sh          # what the watcher executes each cycle\n'
  env -i PATH="$dir/fakebin:$BASE_PATH" HOME="$dir/home" "$@" \
    bash "$dir/home/state/task-a.check.sh" 2>&1
  printf '(exit %s)\n' "$?"
}

exec > "$OUT" 2>&1
printf 'Firstmate PR/MR outcome reporting - operator transcript\n'
printf 'Real bin/fm-pr-check.sh + bin/fm-pr-poll.sh; forge CLIs are local stubs.\n'

GH_URL=https://github.com/o/r/pull/41
GL_URL=https://gitlab.example/group/subgroup/project/-/merge_requests/17

section "GitHub - open PR targeting the repository default branch"
d=$(mkcase gh-ready-default); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=main

section "GitHub - open PR targeting an integration/release branch"
d=$(mkcase gh-ready-release); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=release/2026

section "GitHub - draft PR"
d=$(mkcase gh-draft); arm "$d" "$GH_URL" GH_STATE=OPEN GH_DRAFT=1 GH_BASE=main

section "GitHub - closed-without-merging PR"
d=$(mkcase gh-closed); arm "$d" "$GH_URL" GH_STATE=CLOSED GH_BASE=main

section "GitHub - forge unreachable at arming (identity still recorded, watch still armed)"
d=$(mkcase gh-unavailable); arm "$d" "$GH_URL" GH_FAIL=1
printf -- '--- recorded metadata ---\n'; cat "$d/home/state/task-a.meta"

section "GitHub - merged into the repository default branch"
d=$(mkcase gh-merged-default); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=main >/dev/null
poll "$d" GH_STATE=MERGED GH_BASE=main GH_DEFAULT=main

section "GitHub - merged into an integration/release branch (default is main)"
d=$(mkcase gh-merged-release); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=release/2026 >/dev/null
poll "$d" GH_STATE=MERGED GH_BASE=release/2026 GH_DEFAULT=main

section "GitHub - merged, repository default branch could not be established"
d=$(mkcase gh-merged-nodefault); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=release/2026 >/dev/null
poll "$d" GH_STATE=MERGED GH_BASE=release/2026 GH_DEFAULT_FAIL=1

section "GitHub - merged, neither destination nor default branch available"
d=$(mkcase gh-merged-nothing); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=main >/dev/null
poll "$d" GH_STATE=MERGED GH_BASE='invalid branch' GH_DEFAULT_FAIL=1

section "GitLab - open merge request targeting the default branch"
d=$(mkcase gl-ready); arm "$d" "$GL_URL" GLAB_STATE=opened GLAB_BASE=main

section "GitLab - closed-without-merging merge request"
d=$(mkcase gl-closed); arm "$d" "$GL_URL" GLAB_STATE=closed GLAB_BASE=main

section "GitLab - merged into the repository default branch"
d=$(mkcase gl-merged-default); arm "$d" "$GL_URL" GLAB_STATE=opened GLAB_BASE=main >/dev/null
poll "$d" GLAB_STATE=merged GLAB_BASE=main GLAB_DEFAULT=main

section "GitLab - merged into an integration/release branch (default is main)"
d=$(mkcase gl-merged-release); arm "$d" "$GL_URL" GLAB_STATE=opened GLAB_BASE=release/2026 >/dev/null
poll "$d" GLAB_STATE=merged GLAB_BASE=release/2026 GLAB_DEFAULT=main

section "GitLab - merged, repository default branch could not be established"
d=$(mkcase gl-merged-nodefault); arm "$d" "$GL_URL" GLAB_STATE=opened GLAB_BASE=main >/dev/null
poll "$d" GLAB_STATE=merged GLAB_BASE=main GLAB_DEFAULT_FAIL=1

section "GitLab - merged, destination branch absent from the forge payload"
d=$(mkcase gl-merged-nobase); arm "$d" "$GL_URL" GLAB_STATE=opened GLAB_BASE=main >/dev/null
poll "$d" GLAB_STATE=merged GLAB_BASE_ABSENT=1 GLAB_DEFAULT=main

section "GitLab - arming without jq on PATH names the missing tool instead of going silent"
d=$(mkcase gl-nojq)
rm -f "$d/fakebin/jq"
nojq="$d/nojq"
mkdir -p "$nojq"
while IFS= read -r bindir; do
  [ -d "$bindir" ] || continue
  for entry in "$bindir"/*; do
    [ -e "$entry" ] || continue
    nm=$(basename "$entry")
    [ "$nm" = jq ] && continue
    [ -e "$nojq/$nm" ] || ln -s "$entry" "$nojq/$nm" 2>/dev/null
  done
done <<EOF
$d/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
PATH="$nojq" command -v jq >/dev/null 2>&1 && printf 'WARN: jq still resolvable\n'
printf '$ PATH without jq; fm-pr-check.sh task-a %s\n' "$GL_URL"
env -i PATH="$nojq" HOME="$d/home" FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" \
  bash "$ROOT/bin/fm-pr-check.sh" task-a "$GL_URL" 2>&1
printf '(exit %s)\n' "$?"

section "GitHub - fm-pr-merge.sh frames the state it reads as pre-merge, not as the outcome"
d=$(mkcase gh-merge-prefix); arm "$d" "$GH_URL" GH_STATE=OPEN GH_BASE=main > /dev/null
printf '$ fm-pr-merge.sh task-a %s\n' "$GH_URL"
env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" \
  GH_STATE=OPEN GH_BASE=main \
  bash "$ROOT/bin/fm-pr-merge.sh" task-a "$GH_URL" 2>&1
printf '(exit %s)\n' "$?"

section "Deferred default-branch lookup - forge calls actually made"
d=$(mkcase gh-call-log)
printf 'ready arming:\n'
env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" \
  GH_STATE=OPEN GH_BASE=main GH_LOG="$d/gh.log" \
  bash "$ROOT/bin/fm-pr-check.sh" task-a "$GH_URL" 2>&1
sed 's/^/  gh /' "$d/gh.log"
: > "$d/gh.log"
printf 'poll while still open:\n'
env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" GH_STATE=OPEN GH_BASE=main GH_LOG="$d/gh.log" \
  bash "$d/home/state/task-a.check.sh" 2>&1
sed 's/^/  gh /' "$d/gh.log"
: > "$d/gh.log"
printf 'poll after the merge:\n'
env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" GH_STATE=MERGED GH_BASE=main GH_DEFAULT=main GH_LOG="$d/gh.log" \
  bash "$d/home/state/task-a.check.sh" 2>&1
sed 's/^/  gh /' "$d/gh.log"

section "Watcher wake - what the captain actually receives when the PR merges"
d=$(mkcase gh-watcher-wake)
env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" \
  GH_STATE=OPEN GH_BASE=release/2026 \
  bash "$ROOT/bin/fm-pr-check.sh" task-a "$GH_URL" 2>&1
printf '$ fm-watch.sh                     # one bounded supervision cycle after the merge lands\n'
perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM",$pid; waitpid $pid,0; exit 124 }; alarm 10; waitpid $pid,0; alarm 0; exit($? >> 8)' \
  env -i PATH="$d/fakebin:$BASE_PATH" HOME="$d/home" FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    GH_STATE=MERGED GH_BASE=release/2026 GH_DEFAULT=main \
    bash "$ROOT/bin/fm-watch.sh" 2>&1 | grep -a '^check:' 
printf '(watcher cycle complete)\n'
