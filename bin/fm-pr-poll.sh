#!/usr/bin/env bash
# Authoritative forge outcome extractor and formatter for ready and merged PRs.
# The static watcher program accepts only a validated provider-tagged identity,
# asks the forge for the PR state and destination branch, asks the repository for
# its default branch, and emits a qualified outcome only for an exact merge.
# Ready callers use --validated-machine ready and receive the same extraction
# and wording path before publishing the merge poll.
#
# Machine output is one control-character-delimited record consumed only by
# trusted Firstmate scripts. Sidecar-driven and legacy --validated invocations
# print only the human outcome. Every lookup error in poll mode stays silent, so
# an unreadable PR can never be reported as merged. Missing destination/default
# evidence in ready mode is surfaced explicitly rather than inferred.
set -u
LC_ALL=C
export LC_ALL

machine=0
phase=poll
if [ "$#" -eq 7 ] && [ "$1" = --validated-machine ]; then
  machine=1
  phase=$2
  provider=$3
  url=$4
  host=$5
  path=$6
  number=$7
  case "$phase" in ready|poll) ;; *) exit 0 ;; esac
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

branch_valid() {
  [ -n "${1-}" ] && git check-ref-format --branch "$1" >/dev/null 2>&1
}

json_field() {
  command -v node >/dev/null 2>&1 || return 1
  node -e '
const fs = require("fs");
let value;
try {
  value = JSON.parse(fs.readFileSync(0, "utf8"));
  for (const key of process.argv[1].split(".")) value = value == null ? undefined : value[key];
} catch (_) {
  process.exit(1);
}
if (typeof value !== "string") process.exit(1);
process.stdout.write(value);
' "$1"
}

state=
base=
default_branch=
head=
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    pr_json=$(gh pr view "$url" --json state,baseRefName,headRefOid 2>/dev/null) || pr_json=
    if [ -n "$pr_json" ]; then
      state=$(printf '%s' "$pr_json" | json_field state 2>/dev/null || true)
      base=$(printf '%s' "$pr_json" | json_field baseRefName 2>/dev/null || true)
      head=$(printf '%s' "$pr_json" | json_field headRefOid 2>/dev/null || true)
    fi
    repo_json=$(gh repo view "$path" --json defaultBranchRef 2>/dev/null) || repo_json=
    if [ -n "$repo_json" ]; then
      default_branch=$(printf '%s' "$repo_json" | json_field defaultBranchRef.name 2>/dev/null || true)
    fi
    [ "$state" = MERGED ] && state=merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    project_url="https://$host/$path"
    mr_json=$(glab mr view "$number" -R "$project_url" -F json 2>/dev/null) || mr_json=
    if [ -n "$mr_json" ]; then
      state=$(printf '%s' "$mr_json" | json_field state 2>/dev/null || true)
      base=$(printf '%s' "$mr_json" | json_field target_branch 2>/dev/null || true)
    fi
    repo_json=$(glab repo view "$project_url" -F json 2>/dev/null) || repo_json=
    if [ -n "$repo_json" ]; then
      default_branch=$(printf '%s' "$repo_json" | json_field default_branch 2>/dev/null || true)
    fi
    ;;
  *) exit 0 ;;
esac

branch_valid "$base" || base=
branch_valid "$default_branch" || default_branch=
case "$head" in
  ''|*[!0-9a-f]*) head= ;;
  *)
    [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ] || head=
    ;;
esac

if [ "$phase" = poll ]; then
  [ "$state" = merged ] || exit 0
  outcome_state=merged
  verb="merged"
else
  if [ "$state" = merged ]; then
    outcome_state=merged
    verb="merged"
  else
    outcome_state=ready
    verb="is ready for review"
  fi
fi

if [ -n "$base" ] && [ -n "$default_branch" ] && [ "$base" = "$default_branch" ]; then
  human="PR $url $verb into '$base', the repository default branch."
elif [ -n "$base" ] && [ -n "$default_branch" ]; then
  human="PR $url $verb into '$base'; the repository default branch is '$default_branch'."
  if [ "$outcome_state" = merged ]; then
    human="$human This is not default-branch delivery."
  fi
elif [ -n "$base" ]; then
  human="PR $url $verb into '$base'; the repository default branch could not be established."
  if [ "$outcome_state" = merged ]; then
    human="$human Default-branch delivery is unverified."
  fi
elif [ -n "$default_branch" ]; then
  human="PR $url $verb, but its destination branch is unavailable from the forge; the repository default branch is '$default_branch'."
  if [ "$outcome_state" = merged ]; then
    human="$human Default-branch delivery is unverified."
  fi
else
  human="PR $url $verb, but its destination branch and the repository default branch are unavailable from the forge."
  if [ "$outcome_state" = merged ]; then
    human="$human Default-branch delivery is unverified."
  fi
fi

if [ "$machine" -eq 1 ]; then
  unit_separator=$(printf '\037')
  printf 'fm-pr-outcome-v1%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$unit_separator" "$outcome_state" \
    "$unit_separator" "$url" \
    "$unit_separator" "$base" \
    "$unit_separator" "$default_branch" \
    "$unit_separator" "$head" \
    "$unit_separator" "$human"
else
  printf '%s\n' "$human"
fi
exit 0
