#!/usr/bin/env bash
# Authoritative forge outcome extractor and formatter for ready and merged PRs.
# The static watcher program accepts only a validated provider-tagged identity,
# asks the forge for the PR state and destination branch, and asks for the
# repository default branch only after observing an exact merge.
# Ready callers use --validated-machine ready and receive the same extraction
# and wording path before publishing the merge poll.
#
# Machine output is one control-character-delimited record consumed only by
# trusted Firstmate scripts. Sidecar-driven and legacy --validated invocations
# print only the human outcome. Every lookup error in poll mode stays silent, so
# an unreadable PR can never be reported as merged. Missing destination/default
# evidence is surfaced explicitly rather than inferred.
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

outcome_fail() {
  if [ "$machine" -eq 1 ] && [ "$phase" = ready ]; then
    exit 1
  fi
  exit 0
}

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

parse_forge_record() {
  local record=${1-} separator extra
  case "$record" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  separator=$(printf '\037')
  IFS="$separator" read -r state base head extra <<< "$record"
  [ -z "$extra" ] && [ -n "$state" ]
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
    pr_record=$(gh pr view "$url" --json state,baseRefName,headRefOid \
      --jq '[.state // "", .baseRefName // "", ((.headRefOid // "") | if test("^[0-9a-f]{40}$|^[0-9a-f]{64}$") then . else "" end)] | join("\u001f")' \
      2>/dev/null) || outcome_fail
    parse_forge_record "$pr_record" || outcome_fail
    case "$state" in
      MERGED) state=merged ;;
      OPEN|CLOSED) state=ready ;;
      *) outcome_fail ;;
    esac
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
    command -v jq >/dev/null 2>&1 || outcome_fail
    project_url="https://$host/$path"
    mr_json=$(GITLAB_HOST="$host" glab mr view "$number" -R "$project_url" -F json 2>/dev/null) \
      || outcome_fail
    pr_record=$(printf '%s' "$mr_json" | jq -jr '
      if type == "object"
        and (.state | type == "string")
        and ((.target_branch | type) == "string" or (.target_branch | type) == "null")
      then [(.state), (.target_branch // ""), ""] | join("\u001f")
      else error("invalid merge request outcome")
      end' 2>/dev/null) || outcome_fail
    parse_forge_record "$pr_record" || outcome_fail
    case "$state" in
      merged) ;;
      opened|closed|locked) state=ready ;;
      *) outcome_fail ;;
    esac
    ;;
  *) exit 0 ;;
esac

branch_valid "$base" || base=
case "$head" in
  ''|*[!0-9a-f]*) head= ;;
  *)
    [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ] || head=
    ;;
esac

if [ "$phase" = poll ]; then
  [ "$state" = merged ] || exit 0
  outcome_state=merged
  verb=merged
else
  outcome_state=$state
  if [ "$state" = merged ]; then
    verb=merged
  else
    verb="is ready for review"
  fi
fi

# Default-branch evidence has no bearing on a ready outcome. Defer this second
# forge lookup until an exact merge needs default-delivery classification.
if [ "$outcome_state" = merged ]; then
  case "$provider" in
    github)
      default_branch=$(gh repo view "$path" --json defaultBranchRef \
        --jq '.defaultBranchRef.name // ""' 2>/dev/null) || default_branch=
      ;;
    gitlab)
      repo_json=$(GITLAB_HOST="$host" glab repo view "$project_url" -F json 2>/dev/null) \
        || repo_json=
      if [ -n "$repo_json" ]; then
        default_branch=$(printf '%s' "$repo_json" | jq -jr '
          if type == "object"
            and ((.default_branch | type) == "string" or (.default_branch | type) == "null")
          then (.default_branch // "")
          else error("invalid repository outcome")
          end' 2>/dev/null) || default_branch=
      fi
      ;;
  esac
  branch_valid "$default_branch" || default_branch=
fi

if [ "$outcome_state" = ready ]; then
  if [ -n "$base" ]; then
    human="PR $url $verb into '$base'."
  else
    human="PR $url $verb, but its destination branch is unavailable from the forge."
  fi
elif [ -n "$base" ] && [ -n "$default_branch" ] && [ "$base" = "$default_branch" ]; then
  human="PR $url $verb into '$base', the repository default branch."
elif [ -n "$base" ] && [ -n "$default_branch" ]; then
  human="PR $url $verb into '$base'; the repository default branch is '$default_branch'. This is not default-branch delivery."
elif [ -n "$base" ]; then
  human="PR $url $verb into '$base'; the repository default branch could not be established. Default-branch delivery is unverified."
elif [ -n "$default_branch" ]; then
  human="PR $url $verb, but its destination branch is unavailable from the forge; the repository default branch is '$default_branch'. Default-branch delivery is unverified."
else
  human="PR $url $verb, but its destination branch and the repository default branch are unavailable from the forge. Default-branch delivery is unverified."
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
