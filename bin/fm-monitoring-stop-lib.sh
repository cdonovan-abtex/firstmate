# shellcheck shell=bash
# Shared parser and once-only reporter for the home-scoped automatic-monitoring
# stop receipt.
#
# The receipt lives at
# data/automatic-monitoring-pause/receipt.json under the effective FM_HOME (or
# FM_DATA_OVERRIDE). docs/configuration.md owns the operator-facing schema.
# This library owns the runtime verdict:
#   none       no receipt exists; ordinary supervision applies
#   active     valid completed stop with no valid resumption; automatic watcher
#              arm, re-arm, and repair prompts are forbidden
#   resumed    valid stop plus explicit valid resumption; ordinary supervision
#              applies
#   malformed  receipt evidence exists but cannot be trusted; automatic watcher
#              arm, re-arm, and repair prompts are forbidden
#
# Call fm_monitoring_stop_status [state-dir] first. It always returns 0 and sets
# FM_MONITORING_STOP_STATUS, FM_MONITORING_STOP_TIME,
# FM_MONITORING_STOP_DETAIL, FM_MONITORING_STOP_RECEIPT,
# FM_MONITORING_STOP_ORIGIN, FM_MONITORING_STOP_CALLER,
# FM_MONITORING_STOP_CALLER_IDENTITY, and FM_MONITORING_STOP_REASON.

fm_monitoring_stop_timestamp_valid() {
  local pattern year month day hour minute second offset_hour offset_minute days
  pattern='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-]([0-9]{2}):([0-9]{2}))$'
  [[ $1 =~ $pattern ]] || return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  hour=$((10#${BASH_REMATCH[4]}))
  minute=$((10#${BASH_REMATCH[5]}))
  second=$((10#${BASH_REMATCH[6]}))
  offset_hour=$((10#${BASH_REMATCH[9]:-00}))
  offset_minute=$((10#${BASH_REMATCH[10]:-00}))
  ((month >= 1 && month <= 12 && hour < 24 && minute < 60 && second < 60
    && offset_hour < 24 && offset_minute < 60)) || return 1
  case "$month" in
    4|6|9|11) days=30 ;;
    2)
      days=28
      if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then days=29; fi
      ;;
    *) days=31 ;;
  esac
  ((day >= 1 && day <= days))
}

fm_monitoring_stop_status() {  # [state-dir]
  local state=${1:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}
  local home data receipt parsed stop_time resumed_at external_at

  if [ -n "${FM_HOME:-}" ]; then
    home=$FM_HOME
  else
    home=$(cd "$(dirname "$state")" 2>/dev/null && pwd -P) || home=$(dirname "$state")
  fi
  data=${FM_DATA_OVERRIDE:-$home/data}
  receipt=$data/automatic-monitoring-pause/receipt.json

  FM_MONITORING_STOP_STATUS=none
  FM_MONITORING_STOP_TIME=
  FM_MONITORING_STOP_DETAIL=
  FM_MONITORING_STOP_RECEIPT=$receipt
  FM_MONITORING_STOP_ORIGIN=
  FM_MONITORING_STOP_CALLER=
  FM_MONITORING_STOP_CALLER_IDENTITY=
  FM_MONITORING_STOP_REASON=

  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if [ -L "$receipt" ] || [ ! -f "$receipt" ] || [ ! -r "$receipt" ]; then
    FM_MONITORING_STOP_STATUS=malformed
    FM_MONITORING_STOP_DETAIL="receipt must be a readable regular non-symlink file"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FM_MONITORING_STOP_STATUS=malformed
    FM_MONITORING_STOP_DETAIL="jq is required to validate the receipt"
    return 0
  fi
  parsed=$(jq -cser --arg home "$home" '
    if length != 1 then error("single-object") else .[0] end |
    def nonempty: type == "string" and length > 0;
    def valid_external_request:
      type == "object" and
      .schema == "firstmate.monitoring-stop.external.v1" and
      (.caller_uid | type == "number" and floor == . and . >= 0) and
      (.caller_user | nonempty) and
      (.caller_pid | type == "number" and floor == . and . > 0) and
      (.caller_identity | nonempty) and
      (.at | nonempty) and
      (.reason | nonempty);
    if type != "object" then error("object")
    elif ((.instruction | nonempty) | not) then error("instruction")
    elif ((.time | nonempty) | not) then error("time")
    elif .home != $home then error("home")
    elif ((.scope | nonempty) | not) then error("scope")
    elif ((.resume | nonempty) | not) then error("resume")
    elif ((.action | nonempty) | not) then error("action")
    elif .completed != true then error("completed")
    elif ((has("resumed_at") or has("resume_instruction"))
      and ((has("resumed_at") and has("resume_instruction")) | not)) then error("partial-resume")
    elif (has("resumed_at") and ((.resumed_at | nonempty) | not)) then error("resumed_at")
    elif (has("resume_instruction") and ((.resume_instruction | nonempty) | not)) then error("resume_instruction")
    elif (has("external_stop_request") and ((.external_stop_request | valid_external_request) | not)) then error("external_stop_request")
    elif (.origin == "external" and ((has("external_stop_request") and (.external_stop_request | valid_external_request)) | not)) then error("external-origin")
    else [
      .time,
      (.resumed_at // ""),
      (.origin // ""),
      (if has("external_stop_request") then
        (.external_stop_request.caller_user + "[uid=" + (.external_stop_request.caller_uid | tostring) + ",pid=" + (.external_stop_request.caller_pid | tostring) + "]")
       else "" end),
      (.external_stop_request.caller_identity // ""),
      (.external_stop_request.reason // ""),
      (.external_stop_request.at // "")
    ]
    end
  ' "$receipt" 2>/dev/null) || {
    FM_MONITORING_STOP_STATUS=malformed
    FM_MONITORING_STOP_DETAIL="receipt must contain valid JSON with exactly one object matching the required stop/resume schema, external-request audit schema when present, and effective home"
    return 0
  }

  stop_time=$(printf '%s\n' "$parsed" | jq -er '.[0]' 2>/dev/null) || stop_time=
  resumed_at=$(printf '%s\n' "$parsed" | jq -er '.[1]' 2>/dev/null) || resumed_at=
  FM_MONITORING_STOP_ORIGIN=$(printf '%s\n' "$parsed" | jq -er '.[2]' 2>/dev/null) || FM_MONITORING_STOP_ORIGIN=
  FM_MONITORING_STOP_CALLER=$(printf '%s\n' "$parsed" | jq -er '.[3]' 2>/dev/null) || FM_MONITORING_STOP_CALLER=
  FM_MONITORING_STOP_CALLER_IDENTITY=$(printf '%s\n' "$parsed" | jq -er '.[4]' 2>/dev/null) || FM_MONITORING_STOP_CALLER_IDENTITY=
  FM_MONITORING_STOP_REASON=$(printf '%s\n' "$parsed" | jq -er '.[5]' 2>/dev/null) || FM_MONITORING_STOP_REASON=
  external_at=$(printf '%s\n' "$parsed" | jq -er '.[6]' 2>/dev/null) || external_at=
  if ! fm_monitoring_stop_timestamp_valid "$stop_time"; then
    FM_MONITORING_STOP_STATUS=malformed
    FM_MONITORING_STOP_DETAIL="receipt time must be an RFC 3339 timestamp"
    return 0
  fi
  FM_MONITORING_STOP_TIME=$stop_time
  if [ -n "$external_at" ] && ! fm_monitoring_stop_timestamp_valid "$external_at"; then
    FM_MONITORING_STOP_STATUS=malformed
    FM_MONITORING_STOP_DETAIL="receipt external_stop_request.at must be an RFC 3339 timestamp"
    return 0
  fi
  if [ -n "$resumed_at" ]; then
    if ! fm_monitoring_stop_timestamp_valid "$resumed_at"; then
      FM_MONITORING_STOP_STATUS=malformed
      FM_MONITORING_STOP_DETAIL="receipt resumed_at must be an RFC 3339 timestamp"
      return 0
    fi
    FM_MONITORING_STOP_STATUS=resumed
  else
    FM_MONITORING_STOP_STATUS=active
  fi
  return 0
}

fm_monitoring_stop_blocks() {  # [state-dir]
  fm_monitoring_stop_status "$@"
  [ "$FM_MONITORING_STOP_STATUS" = active ] || [ "$FM_MONITORING_STOP_STATUS" = malformed ]
}

fm_monitoring_stop_report_once() {  # [state-dir]
  local state=${1:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}
  local identity checksum bytes claims claim
  fm_monitoring_stop_status "$state"
  case "$FM_MONITORING_STOP_STATUS" in
    active|malformed) ;;
    *) return 0 ;;
  esac

  if [ "$FM_MONITORING_STOP_STATUS" = active ]; then
    # The receipt may gain bounded audit history while the same stop remains in
    # force. Key the announcement to the stop identity, not mutable receipt
    # bytes, so that history maintenance cannot announce one order twice.
    read -r checksum bytes _ <<EOF
$(printf '%s\n' "$FM_MONITORING_STOP_TIME" | cksum 2>/dev/null || printf 'unreadable 0')
EOF
    identity="active-$checksum-$bytes"
  elif [ -r "$FM_MONITORING_STOP_RECEIPT" ] && [ ! -L "$FM_MONITORING_STOP_RECEIPT" ]; then
    read -r checksum bytes _ <<EOF
$(cksum "$FM_MONITORING_STOP_RECEIPT" 2>/dev/null || printf 'unreadable 0')
EOF
    identity="malformed-$checksum-$bytes"
  else
    identity="malformed-unreadable"
  fi
  claims="$state/.monitoring-stop-reports"
  if [ -L "$claims" ]; then
    return 0
  fi
  mkdir -p "$claims" 2>/dev/null || return 0
  claim="$claims/$identity"
  mkdir "$claim" 2>/dev/null || return 0

  if [ "$FM_MONITORING_STOP_STATUS" = active ]; then
    if [ "$FM_MONITORING_STOP_ORIGIN" = external ]; then
      printf 'AUTOMATIC_MONITORING_STOP: monitoring stopped by local process %s at %s. Automatic watcher startup remains disabled; this session retains fleet ownership.\n' \
        "$FM_MONITORING_STOP_CALLER" "$FM_MONITORING_STOP_TIME"
    else
      printf 'AUTOMATIC_MONITORING_STOP: monitoring stopped by Captain order at %s. Automatic watcher startup remains disabled; this session retains fleet ownership.\n' \
        "$FM_MONITORING_STOP_TIME"
    fi
  else
    printf 'AUTOMATIC_MONITORING_STOP_INVALID: automatic watcher startup remains disabled because %s: %s\n' \
      "$FM_MONITORING_STOP_RECEIPT" "$FM_MONITORING_STOP_DETAIL"
  fi
}
